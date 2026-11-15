import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/cache_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/folder_model.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/sync/offline_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';

import 'fake_cloud.dart';
import 'fakes.dart';

/// Entorno de pruebas de F6a: BD real (sqlite ffi), archivos reales en un
/// directorio temporal y nube/red falsas.
class F6Env {
  late Directory tmp;
  late VaultSession session;
  late VaultDatabase vdb;
  late VaultDataRepository items;
  late SyncQueueRepository queue;
  late FakeCloudStorage cloud;
  late FakeNetworkMonitor net;
  late InMemorySecureStore store;
  late SyncPreferences syncPrefs;
  late CachePreferences cachePrefs;
  late CacheManager cache;
  late VaultFileFetcher fetcher;
  late OfflineService offline;
  late SyncService sync;
  int now = 1000000;
  final crypto = CryptoService();

  Future<void> setUp() async {
    sqfliteFfiInit();
    tmp = await Directory.systemTemp.createTemp('f6_test');
    await AppPaths.init(baseDir: tmp);
    session = VaultSession.create();
    session.open(
      await KeyHierarchy.fromDek(
        Uint8List.fromList(List.generate(32, (i) => i * 3 + 1)),
      ),
    );
    vdb = VaultDatabase.forTesting(
      session: session,
      dbPath: p.join(tmp.path, 'db', 'f6.db'),
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
    );
    items = VaultDataRepository(dbProvider: () => vdb.database);
    queue = SyncQueueRepository(dbProvider: () => vdb.database);
    cloud = FakeCloudStorage();
    net = FakeNetworkMonitor();
    store = InMemorySecureStore();
    syncPrefs = SyncPreferences(store);
    cachePrefs = CachePreferences(store);
    cache = CacheManager(repository: items, preferences: cachePrefs);
    fetcher = VaultFileFetcher(
      cloud: cloud,
      items: items,
      resolvePath: AppPaths.resolve,
      nowMs: () => now,
    );
    offline = OfflineService(
      items: items,
      fetcher: fetcher,
      network: net,
      prefs: syncPrefs,
      isUnlocked: () => session.isUnlocked,
    );
    sync = SyncService(
      cloud: cloud,
      queue: queue,
      items: items,
      network: net,
      prefs: syncPrefs,
      isUnlocked: () => session.isUnlocked,
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: () async => null,
      snapshotProvider: () async => throw UnimplementedError(),
      nowMs: () => now,
      random: Random(1),
      scheduleWakeups: false,
    );
  }

  Future<void> tearDown() async {
    sync.dispose();
    offline.dispose();
    await vdb.close();
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }

  File localFile(String id) => AppPaths.resolve(AppPaths.vaultRelativePath(id));

  /// Crea un item `en_nube` (verificado) con `.vault` local de [size] bytes
  /// cifrados reales... salvo que [encrypt] sea false (bytes aleatorios).
  ///
  /// [plain] (si se da) se cifra de verdad con la subllave files.
  Future<VaultItemModel> addCloudItem(
    String id, {
    int size = 100 * 1024,
    Uint8List? plain,
    String? folderId,
    int? lastAccessedAt,
    String createdAt = '2026-01-01T00:00:00',
    SyncStatus status = SyncStatus.enNube,
    bool offline = false,
    bool verified = true,
    bool keepLocal = true,
    String name = 'foto.jpg',
    String mime = 'image/jpeg',
    bool thumb = true,
  }) async {
    final file = localFile(id);
    if (plain != null) {
      final src = File('${file.path}.plain');
      await src.writeAsBytes(plain);
      await crypto.encryptFile(src, file, session.filesKey!);
      await src.delete();
    } else {
      final rng = Random(id.hashCode);
      await file.writeAsBytes(
        Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256))),
      );
    }
    final bytes = await file.readAsBytes();
    String? driveId;
    if (verified) {
      driveId = (await cloud.uploadBytes(bytes: bytes, name: '$id.vault')).id;
    }
    String? thumbRel;
    if (thumb) {
      thumbRel = AppPaths.thumbRelativePath(id);
      await AppPaths.resolve(thumbRel).writeAsBytes([1, 2, 3]);
    }
    await items.insertItem(
      VaultItemModel(
        id: id,
        name: name,
        folderId: folderId,
        encryptedPath: AppPaths.vaultRelativePath(id),
        fileSize: plain?.length ?? size,
        mimeType: mime,
        createdAt: createdAt,
        isOffline: offline,
        driveFileId: driveId,
        syncStatus: status,
        thumbPath: thumbRel,
        lastAccessedAt: lastAccessedAt,
        cloudMd5: verified ? md5OfBytes(bytes) : null,
        cloudSize: verified ? bytes.length : null,
      ),
    );
    if (!keepLocal) await file.delete();
    return (await items.getItem(id))!;
  }

  Future<void> addFolder(String id, {String? parent, bool offline = false}) =>
      items.createFolder(
        FolderModel(
          id: id,
          name: 'Carpeta $id',
          parentId: parent,
          createdAt: '2026-01-01T00:00:00',
          isOffline: offline,
        ),
      );
}
