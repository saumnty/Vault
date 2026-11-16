import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/folder_model.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';

import 'fake_cloud.dart';
import 'fakes.dart';

/// Abre con sqlite ffi (sin cifrado real) pero exigiendo la llave: simula lo
/// que hace SQLCipher cuando la llave no corresponde.
DatabaseOpener strictOpener(String? expectedPassword, {List<String>? seen}) =>
    (path, {password, required options}) async {
      seen?.add(password ?? '<null>');
      if (password == null || password != expectedPassword) {
        throw Exception('file is not a database');
      }
      return databaseFactoryFfi.openDatabase(path, options: options);
    };

/// Almacén que falla al escribir una clave (una vez).
class FlakyStore extends InMemorySecureStore {
  String? failKey;

  @override
  Future<void> write(String key, String value) async {
    if (key == failKey) {
      failKey = null;
      throw StateError('fallo simulado de almacenamiento');
    }
    return super.write(key, value);
  }
}

/// "Teléfono A": bóveda real (llaves, BD sqlite, archivos cifrados) que sube
/// todo a un [FakeCloudStorage]. Después "teléfono B" restaura desde la nube.
class PhoneA {
  late Directory dir;
  late InMemorySecureStore store;
  late AuthController auth;
  late VaultSession session;
  late VaultDatabase vdb;
  late VaultDataRepository items;
  late SyncQueueRepository queue;
  late SyncService sync;
  late SyncPreferences prefs;
  late FakeNetworkMonitor net;
  FakeCloudStorage cloud = FakeCloudStorage();
  final crypto = CryptoService();
  late String recoveryCode;
  final Map<String, Uint8List> plains = {};
  final Map<String, Uint8List> thumbs = {};
  int now = 5000000;

  String get dbPath => p.join(dir.path, 'db', VaultSchema.dbFileName);

  Future<void> setUp() async {
    sqfliteFfiInit();
    dir = await Directory.systemTemp.createTemp('f9_a');
    await AppPaths.init(baseDir: dir);
    store = InMemorySecureStore();
    session = VaultSession.create();
    auth = AuthController(
      storage: store,
      biometricStore: FakeBiometricKeyStore(),
      kdfParams: fastKdf,
      session: session,
    );
    final created = await auth.createVault('123456');
    recoveryCode = created.recoveryCode;
    vdb = VaultDatabase.forTesting(
      session: session,
      dbPath: dbPath,
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
    );
    items = VaultDataRepository(dbProvider: () => vdb.database);
    queue = SyncQueueRepository(dbProvider: () => vdb.database);
    net = FakeNetworkMonitor();
    prefs = SyncPreferences(store);
    sync = SyncService(
      cloud: cloud,
      queue: queue,
      items: items,
      network: net,
      prefs: prefs,
      isUnlocked: () => session.isUnlocked,
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: auth.exportRecoveryBackup,
      snapshotProvider: vdb.exportEncryptedSnapshot,
      nowMs: () => now,
      random: Random(1),
      scheduleWakeups: false,
    );
  }

  Future<void> tearDown() async {
    sync.dispose();
    await vdb.close();
    AppPaths.resetForTesting();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Importa un item como lo haría la app: archivo cifrado + miniatura.
  Future<VaultItemModel> addItem(
    String id,
    String name, {
    String? folderId,
    int plainSize = 40000,
    bool thumb = true,

    /// Miniatura cifrada de verdad (formato .vault con su fileId, S-09).
    bool realThumb = false,
  }) async {
    final rng = Random(id.hashCode);
    final plain = Uint8List.fromList(
      List.generate(plainSize, (_) => rng.nextInt(256)),
    );
    plains[id] = plain;
    final rel = AppPaths.vaultRelativePath(id);
    final file = AppPaths.resolve(rel);
    final src = File('${file.path}.plain');
    await src.writeAsBytes(plain);
    final header = await crypto.encryptFile(src, file, session.filesKey!);
    await src.delete();
    String? thumbRel;
    String? thumbFileId;
    if (thumb) {
      thumbRel = AppPaths.thumbRelativePath(id);
      final t = Uint8List.fromList(List.generate(300, (_) => rng.nextInt(256)));
      thumbs[id] = t;
      if (realThumb) {
        final enc = await crypto.encryptBytes(t, session.keys.thumbs);
        await AppPaths.resolve(thumbRel).writeAsBytes(enc);
        thumbFileId = CryptoService.fileIdOfHeader(enc);
      } else {
        await AppPaths.resolve(thumbRel).writeAsBytes(t);
      }
    }
    await items.insertItem(
      VaultItemModel(
        id: id,
        name: name,
        folderId: folderId,
        encryptedPath: rel,
        fileSize: plainSize,
        mimeType: 'image/jpeg',
        createdAt: '2026-02-01T00:00:00',
        thumbPath: thumbRel,
        sourceAssetId: 'asset-$id',
        fileId: header.fileIdString,
        thumbFileId: thumbFileId,
      ),
    );
    return (await items.getItem(id))!;
  }

  Future<void> addFolder(String id, String name, {String? parent}) =>
      items.createFolder(
        FolderModel(
          id: id,
          name: name,
          parentId: parent,
          createdAt: '2026-02-01T00:00:00',
        ),
      );

  /// Sube todo (archivos, miniaturas, respaldo de llaves y snapshot).
  Future<void> syncAll() async {
    await sync.run(manual: true);
  }

  /// Toma y sube un snapshot AHORA (para fijar un estado concreto).
  Future<void> republishSnapshot() async {
    final snap = await vdb.exportEncryptedSnapshot();
    final existing = await cloud.findByName(CloudNames.dbSnapshot);
    await cloud.uploadBytes(
      bytes: await snap.readAsBytes(),
      name: CloudNames.dbSnapshot,
      replaceFileId: existing?.id,
    );
    await snap.delete();
  }

  String get passwordA => VaultDatabase.passwordFor(session.keys);
}

/// "Teléfono B": instalación limpia (directorio y almacén nuevos).
class PhoneB {
  PhoneB({Argon2Clock? clock, InMemorySecureStore? store})
    : store = store ?? InMemorySecureStore(),
      _clock = clock;

  final Argon2Clock? _clock;
  late Directory dir;
  final InMemorySecureStore store;
  late AuthController auth;
  late VaultSession session;
  late RestoreService service;
  late SyncPreferences prefs;
  final seenPasswords = <String>[];

  String get dbPath => p.join(dir.path, 'db', VaultSchema.dbFileName);

  Future<void> setUp(
    FakeCloudStorage cloud, {
    required String? expectedPassword,
    int parallelism = 2,
  }) async {
    sqfliteFfiInit();
    dir = await Directory.systemTemp.createTemp('f9_b');
    await AppPaths.init(baseDir: dir);
    session = VaultSession.create();
    auth = newAuth();
    prefs = SyncPreferences(store);
    service = RestoreService(
      cloud: cloud,
      auth: auth,
      prefs: prefs,
      opener: strictOpener(expectedPassword, seen: seenPasswords),
      dbPath: dbPath,
      parallelism: parallelism,
      nowMs: () => 9000000,
    );
  }

  AuthController newAuth() => AuthController(
    storage: store,
    biometricStore: FakeBiometricKeyStore(),
    kdfParams: fastKdf,
    session: session,
    clock: _clock,
  );

  VaultDatabase openDb() => VaultDatabase.forTesting(
    session: session,
    dbPath: dbPath,
    opener: (path, {password, required options}) =>
        databaseFactoryFfi.openDatabase(path, options: options),
  );

  Future<void> tearDown() async {
    service.dispose();
    AppPaths.resetForTesting();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Claves del almacén seguro que describen una bóveda (no el contador de
  /// intentos del código de recuperación).
  List<String> get vaultKeys => store.data.keys
      .where((k) => k != AuthController.restoreAttemptsKey)
      .toList();
}

typedef Argon2Clock = DateTime Function();

String fakeJson(Map<String, Object?> m) => jsonEncode(m);
