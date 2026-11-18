// Entorno de pruebas de la rotación de la DEK (§10.1): un "teléfono" que se
// puede reiniciar sobre el MISMO almacén seguro, disco y nube, y un
// comprobador que restaura en un teléfono limpio con un código.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/crypto/wrapped_key.dart';
import 'package:vault/core/crypto/vault_file_format.dart' show VaultByteSource;
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/folder_model.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/restore/vault_bootstrap.dart';
import 'package:vault/data/rotation/item_reencryptor.dart';
import 'package:vault/data/rotation/key_rotation_service.dart';
import 'package:vault/data/rotation/rotation_guard.dart';
import 'package:vault/data/rotation/rotation_repository.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/data/trash/trash_repository.dart';

import 'fake_cloud.dart';
import 'fakes.dart';

const rotationPin = '123456';

/// Corte simulado (lo lanza el inyector).
class SimulatedCrash implements Exception {
  const SimulatedCrash(this.point);
  final Object point;
  @override
  String toString() => 'SimulatedCrash($point)';
}

/// Almacén que deshace las últimas N escrituras ([dropLast]): simula el
/// `apply()` de Android (la app murió antes de que llegaran a disco).
class DroppingStore extends InMemorySecureStore {
  final List<(String, String?)> _journal = [];

  @override
  Future<void> write(String key, String value) async {
    _journal.add((key, data[key]));
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    _journal.add((key, data[key]));
    await super.delete(key);
  }

  void dropLast(int n) {
    for (var i = 0; i < n && _journal.isNotEmpty; i++) {
      final (key, old) = _journal.removeLast();
      if (old == null) {
        data.remove(key);
      } else {
        data[key] = old;
      }
    }
  }
}

/// "SQLCipher" de pruebas: la BD guarda su llave (`_fake_key`) y rechaza
/// otra. Una BD nueva la recibe al crearse.
Future<Database> fakeCipherOpener(
  String path, {
  String? password,
  required OpenDatabaseOptions options,
}) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: options);
  final has = (await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE name = '_fake_key'",
  )).isNotEmpty;
  if (!has) {
    await db.execute('CREATE TABLE _fake_key (k TEXT)');
    await db.insert('_fake_key', {'k': password});
    return db;
  }
  final k = (await db.query('_fake_key')).first['k'];
  if (k != password) {
    await db.close();
    throw Exception('file is not a database');
  }
  return db;
}

/// Copia con `VACUUM INTO` y cambia la llave del marcador.
class FakeRekeyer implements DbRekeyer {
  @override
  Future<void> exportTo(
    Database source,
    String destPath,
    String newPassword, {
    required int userVersion,
  }) async {
    final escaped = destPath.replaceAll("'", "''");
    await source.execute("VACUUM INTO '$escaped'");
    final dest = await databaseFactoryFfi.openDatabase(destPath);
    await dest.update('_fake_key', {'k': newPassword});
    await dest.execute('PRAGMA user_version = $userVersion');
    await dest.close();
  }
}

class _Bytes implements VaultByteSource {
  _Bytes(this._data);
  final Uint8List _data;
  int _pos = 0;
  @override
  Future<Uint8List> read(int length) async {
    final end = min(_pos + length, _data.length);
    final out = Uint8List.sublistView(_data, _pos, end);
    _pos = end;
    return out;
  }
}

Future<String> sha256Hex(List<int> b) async => (await Sha256().hash(
  b,
)).bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Un teléfono con la bóveda.
class RotationPhone {
  RotationPhone({FakeCloudStorage? cloud})
    : cloud = cloud ?? FakeCloudStorage();

  final FakeCloudStorage cloud;
  final DroppingStore store = DroppingStore();
  final FakeBiometricKeyStore bio = FakeBiometricKeyStore();
  final FakeNetworkMonitor net = FakeNetworkMonitor();
  late Directory dir;
  late VaultSession session;
  late AuthController auth;
  late VaultDatabase vdb;
  late VaultDataRepository items;
  late SyncQueueRepository queue;
  late SyncPreferences prefs;
  late SyncService sync;
  late RotationRepository repo;
  late ItemReencryptor reencryptor;
  late KeyRotationService service;
  final crypto = CryptoService();

  /// Código de recuperación de la bóveda (A).
  late String codeA;

  /// Contenido en claro de cada item (para comprobar que todo abre).
  final Map<String, Uint8List> plains = {};

  /// Inyectores de cortes (se aplican al construir los servicios).
  void Function(RotationCrashPoint p)? crash;
  void Function(ReencryptStep s)? itemCrash;
  bool Function(String id)? inUse;

  /// La rotación se pausa justo al llegar al corte (`deletingOldCloud`).
  bool stopAtCut = false;

  int now = 1000000;

  Future<void> create() async {
    sqfliteFfiInit();
    dir = await Directory.systemTemp.createTemp('rot_phone');
    await AppPaths.init(baseDir: dir);
    _build();
    codeA = (await auth.createVault(rotationPin)).recoveryCode;
  }

  void _build() {
    session = VaultSession.create();
    auth = AuthController(
      storage: store,
      biometricStore: bio,
      kdfParams: fastKdf,
      session: session,
    );
    vdb = VaultDatabase.forTesting(
      session: session,
      dbPath: VaultDatabase.defaultDbPath,
      opener: fakeCipherOpener,
      useSqlCipher: true,
      markerStore: store,
      rekeyer: FakeRekeyer(),
    );
    items = VaultDataRepository(dbProvider: () => vdb.database);
    queue = SyncQueueRepository(dbProvider: () => vdb.database);
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
      rotation: StoreRotationGuard(auth.rotationStore),
      currentKeyGen: auth.currentKeyGen,
    );
    repo = RotationRepository(dbProvider: () => vdb.database);
    reencryptor = ItemReencryptor(
      items: items,
      cloud: cloud,
      workDir: () => Directory('${AppPaths.cacheDir.path}/rotation'),
      isInUse: (id) => inUse?.call(id) ?? false,
      nowMs: () => now,
      onStep: (s) => itemCrash?.call(s),
    );
    service = KeyRotationService(
      auth: auth,
      session: session,
      db: vdb,
      items: items,
      queue: queue,
      sync: sync,
      cloud: cloud,
      network: net,
      prefs: prefs,
      repo: repo,
      reencryptor: reencryptor,
      isInUse: (id) => inUse?.call(id) ?? false,
      crashPoint: (p) {
        crash?.call(p);
        // Para inspeccionar el estado del corte: se pausa justo después.
        if (stopAtCut && p == RotationCrashPoint.afterCut) service.pause();
      },
      nowMs: () => now,
      syncIdleTimeout: const Duration(seconds: 5),
    );
  }

  /// Reinicio de la app: objetos nuevos sobre el mismo almacén, disco y
  /// nube; arranque completo (iOS simulado) y desbloqueo con el PIN.
  Future<void> restart({bool unlock = true, bool biometric = false}) async {
    sync.dispose();
    service.pause();
    auth.lock();
    await vdb.close();
    await AppPaths.init(baseDir: dir);
    _build();
    final hasVault = await VaultBootstrap.decide(
      auth: auth,
      isIOS: true,
      sweepOrphans: false,
    );
    expect(hasVault, isTrue, reason: 'el arranque nunca descarta la bóveda');
    if (!unlock) return;
    final ok = biometric
        ? await auth.unlockWithBiometrics()
        : await auth.unlockWithPin(rotationPin);
    expect(ok, isTrue);
  }

  Future<void> dispose() async {
    sync.dispose();
    auth.lock();
    await vdb.close();
    AppPaths.resetForTesting();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Item con `.vault` y miniatura reales cifrados con la llave ACTUAL.
  Future<VaultItemModel> addItem(
    String id, {
    int size = 20000,
    bool thumb = true,
    String? folderId,
  }) async {
    final rng = Random(id.hashCode);
    final plain = Uint8List.fromList(
      List.generate(size, (_) => rng.nextInt(256)),
    );
    plains[id] = plain;
    final gen = session.currentGen;
    final rel = AppPaths.vaultRelativePath(id, gen: gen);
    final h = await crypto.encryptSource(
      _Bytes(plain),
      AppPaths.resolve(rel),
      session.filesKey!,
    );
    String? thumbRel;
    String? thumbFileId;
    if (thumb) {
      thumbRel = AppPaths.thumbRelativePath(id, gen: gen);
      final enc = await crypto.encryptBytes(
        utf8.encode('miniatura $id'),
        session.keys.thumbs,
      );
      AppPaths.resolve(thumbRel).writeAsBytesSync(enc);
      thumbFileId = CryptoService.fileIdOfHeader(enc);
    }
    await items.insertItem(
      VaultItemModel(
        keyGen: gen,
        id: id,
        name: '$id.jpg',
        folderId: folderId,
        encryptedPath: rel,
        fileSize: size,
        mimeType: 'image/jpeg',
        createdAt: '2026-01-01T00:00:00',
        contentHash: await sha256Hex(plain),
        fileId: h.fileIdString,
        thumbPath: thumbRel,
        thumbFileId: thumbFileId,
      ),
    );
    return (await items.getItem(id))!;
  }

  /// Bóveda típica: carpeta, 4 items (uno solo en la nube, uno en la
  /// Papelera, uno con etiqueta), todo subido.
  Future<void> seedVault() async {
    await items.createFolder(
      const FolderModel(id: 'f1', name: 'Viajes', createdAt: '2026-01-01'),
    );
    await addItem('i1', folderId: 'f1');
    await addItem('i2', size: 70000);
    await addItem('i3', thumb: false);
    await addItem('i4');
    final tags = TagRepository(dbProvider: () => vdb.database);
    final t = await tags.create('Playa');
    await tags.addTag(['i1'], t.id);
    await TrashRepository(
      dbProvider: () => vdb.database,
    ).trashItem('i4', now: now);
    await sync.run(manual: true);
    // i2 queda solo en la nube.
    final i2 = (await items.getItem('i2'))!;
    AppPaths.resolve(i2.encryptedPath).deleteSync();
  }

  /// Rotación hasta `confirmed`. Devuelve el código nuevo B.
  Future<String> startAndConfirm() async {
    final b = (await service.start(rotationPin))!;
    expect(await service.confirm(b), isTrue);
    return b;
  }

  Future<RotationRecord?> record() => auth.rotationRecord();

  /// Cada item vivo (no perdido) abre con la llave de su generación y da el
  /// claro original.
  Future<void> expectAllItemsOpen({Set<String> lost = const {}}) async {
    for (final i in await items.getAllItems()) {
      if (lost.contains(i.id)) continue;
      final key = session.filesKeyFor(i.keyGen);
      expect(key, isNotNull, reason: '${i.id}: sin llave gen ${i.keyGen}');
      final local = AppPaths.resolve(i.encryptedPath);
      final Uint8List enc = local.existsSync()
          ? local.readAsBytesSync()
          : await cloud.downloadBytes(i.driveFileId!);
      expect(
        await crypto.decryptBytes(enc, key!, expectedFileId: i.fileId),
        plains[i.id],
        reason: i.id,
      );
    }
  }

  /// §10.1 `expectRecoverable`: restaura en un teléfono LIMPIO con [code] y
  /// descifra cada item restaurado. `true` si funcionó.
  /// §10.1 `expectNoOldKeyMaterial`: nada en la nube (revisiones incluidas,
  /// salvo la cuarentena si [allowQuarantine], M6), en el disco ni en el
  /// almacén seguro se abre con la DEK vieja [old] ni con el código [oldCode].
  Future<void> expectNoOldKeyMaterial(
    KeyHierarchy old,
    String oldCode, {
    bool allowQuarantine = false,
  }) async {
    final oldPw = VaultDatabase.passwordFor(old);
    final oldDek = old.dekBytes();
    final recovery = KeyRecoveryService(kdfParams: fastKdf);
    final probe = File('${Directory.systemTemp.path}/rot_probe_$hashCode.db');
    Future<void> check(String where, Uint8List bytes) async {
      for (final k in [old.files, old.thumbs]) {
        Object? opened;
        try {
          opened = await crypto.decryptBytes(bytes, k);
        } on Object {
          opened = null;
        }
        expect(opened, isNull, reason: '$where abre con la DEK vieja');
      }
      // ¿Una BD (snapshot) cifrada con la llave vieja?
      if (bytes.length > 16 &&
          String.fromCharCodes(bytes.take(15)) == 'SQLite format 3') {
        probe.writeAsBytesSync(bytes);
        Object? key;
        try {
          final db = await databaseFactoryFfi.openDatabase(probe.path);
          try {
            key = (await db.query('_fake_key')).first['k'];
          } finally {
            await db.close();
          }
        } on Object {
          key = null;
        }
        if (probe.existsSync()) probe.deleteSync();
        expect(key, isNot(oldPw), reason: '$where es una BD con la vieja');
      }
      // ¿Un respaldo que abre con el código viejo?
      RecoveryBackup? b;
      try {
        b = RecoveryBackup.parse(utf8.decode(bytes, allowMalformed: true));
      } on FormatException {
        b = null;
      }
      if (b != null) {
        expect(
          await recovery.recoverDek(oldCode, b),
          isNull,
          reason: '$where abre con el código viejo',
        );
      }
    }

    for (final (name, bytes) in cloud.everyVersion) {
      if (allowQuarantine && name.startsWith('lost_')) continue;
      await check('nube:$name', bytes);
    }
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      await check('disco:${f.path}', f.readAsBytesSync());
    }
    for (final e in store.data.entries) {
      await check('almacén:${e.key}', Uint8List.fromList(utf8.encode(e.value)));
      // Envolturas del PIN que dieran la DEK vieja.
      WrappedKey? w;
      try {
        w = WrappedKey.decode(e.value, expectedPurpose: WrapPurpose.pin);
      } on FormatException {
        w = null;
      }
      final dek = await w?.unwrap(utf8.encode(rotationPin));
      if (dek != null) {
        expect(
          _eq(dek, oldDek),
          isFalse,
          reason: 'almacén:${e.key} da la DEK vieja',
        );
      }
    }
  }

  Future<bool> canRestoreWith(
    String code, {
    Set<String> lost = const {},
    Future<void> Function(Database db)? inspect,
  }) async {
    final saved = AppPaths.baseDir;
    final tmp = await Directory.systemTemp.createTemp('rot_restore');
    try {
      await AppPaths.init(baseDir: tmp);
      final s = VaultSession.create();
      final st = InMemorySecureStore();
      final a = AuthController(
        storage: st,
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
        session: s,
      );
      final dbPath = VaultDatabase.defaultDbPath;
      final r = RestoreService(
        cloud: cloud,
        auth: a,
        prefs: SyncPreferences(st),
        opener: fakeCipherOpener,
        dbPath: dbPath,
        parallelism: 1,
      );
      try {
        if (await r.probe() != RestoreProbeResult.found) return false;
        if (!await r.verifyCode(code)) return false;
        await r.restore(newPin: '654321');
        final vdb2 = VaultDatabase.forTesting(
          session: s,
          dbPath: dbPath,
          opener: fakeCipherOpener,
          useSqlCipher: true,
        );
        try {
          final restored = await VaultDataRepository(
            dbProvider: () => vdb2.database,
          ).getAllItems();
          if (restored.isEmpty) return false;
          for (final i in restored) {
            if (lost.contains(i.id)) continue;
            final key = s.filesKeyFor(i.keyGen);
            if (key == null || i.driveFileId == null) return false;
            final enc = await cloud.downloadBytes(i.driveFileId!);
            final plain = await crypto.decryptBytes(
              enc,
              key,
              expectedFileId: i.fileId,
            );
            if (!_eq(plain, plains[i.id]!)) return false;
          }
          await inspect?.call(await vdb2.database);
          return true;
        } finally {
          await vdb2.close();
        }
      } on Object {
        return false;
      } finally {
        r.dispose();
        a.lock();
      }
    } finally {
      await AppPaths.init(baseDir: saved);
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
