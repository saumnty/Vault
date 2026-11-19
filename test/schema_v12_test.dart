// D86 (v2.2): esquema v12 INCREMENTAL. Una BD v11 (la del iPhone) sube a v12
// sin perder nada: `vault_items.sourceHash` (NULL), índice por
// `sourceAssetId` y tablas `import_batches`/`import_queue` vacías. La cola no
// viaja en el snapshot ni al restaurar.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_database.dart';

import 'support/f9_env.dart';

/// Esquema v11 tal cual (copia literal de `VaultSchema.create` en v11).
const _v11 = [
  '''CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL,
     parentId TEXT, createdAt TEXT NOT NULL,
     isOffline INTEGER NOT NULL DEFAULT 0, deletedAt INTEGER, trashRoot TEXT)''',
  '''CREATE TABLE vault_items (id TEXT PRIMARY KEY, name TEXT NOT NULL,
     folderId TEXT, encryptedPath TEXT NOT NULL, fileSize INTEGER NOT NULL,
     mimeType TEXT, createdAt TEXT NOT NULL,
     isOffline INTEGER NOT NULL DEFAULT 0, isFavorite INTEGER NOT NULL DEFAULT 0,
     driveFileId TEXT, syncStatus TEXT NOT NULL DEFAULT 'pendiente',
     thumbPath TEXT, lastAccessedAt INTEGER, contentHash TEXT,
     sourceAssetId TEXT, durationMs INTEGER, cloudMd5 TEXT, cloudSize INTEGER,
     thumbDriveFileId TEXT, fileId TEXT, thumbFileId TEXT, deletedAt INTEGER,
     trashRoot TEXT, keyGen INTEGER NOT NULL DEFAULT 1,
     cloudAccountTag TEXT, thumbAccountTag TEXT)''',
  '''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,
     itemId TEXT NOT NULL, kind TEXT NOT NULL,
     state TEXT NOT NULL DEFAULT 'pendiente',
     attempts INTEGER NOT NULL DEFAULT 0,
     nextAttemptAt INTEGER NOT NULL DEFAULT 0, lastError TEXT,
     createdAt INTEGER NOT NULL, payload TEXT, UNIQUE (itemId, kind))''',
  'CREATE INDEX idx_sync_queue_due ON sync_queue(state, nextAttemptAt)',
  'CREATE INDEX idx_items_folder ON vault_items(folderId)',
  'CREATE INDEX idx_items_sync ON vault_items(syncStatus)',
  'CREATE INDEX idx_items_lastAccessed ON vault_items(lastAccessedAt)',
  'CREATE INDEX idx_items_drive ON vault_items(driveFileId)',
  'CREATE INDEX idx_folders_parent ON folders(parentId)',
  'CREATE INDEX idx_items_deleted ON vault_items(deletedAt)',
  '''CREATE TABLE migration_state (id INTEGER PRIMARY KEY CHECK (id = 1),
     phase TEXT NOT NULL, oldEmail TEXT, newEmail TEXT,
     startedAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
     neededBytes INTEGER NOT NULL DEFAULT 0,
     downloadTotal INTEGER NOT NULL DEFAULT 0,
     downloadDone INTEGER NOT NULL DEFAULT 0, lastError TEXT)''',
  '''CREATE TABLE migration_items (itemId TEXT PRIMARY KEY,
     oldStatus TEXT NOT NULL, oldDriveFileId TEXT, oldCloudMd5 TEXT,
     oldCloudSize INTEGER, oldThumbDriveFileId TEXT)''',
  '''CREATE TABLE tags (id TEXT PRIMARY KEY,
     name TEXT NOT NULL UNIQUE COLLATE NOCASE, createdAt TEXT NOT NULL)''',
  '''CREATE TABLE item_tags (itemId TEXT NOT NULL, tagId TEXT NOT NULL,
     PRIMARY KEY (itemId, tagId))''',
  'CREATE INDEX idx_item_tags_tag ON item_tags(tagId)',
  'CREATE INDEX idx_items_keygen ON vault_items(keyGen)',
  '''CREATE TABLE rotation_state (id INTEGER PRIMARY KEY CHECK (id = 1),
     rotationId TEXT NOT NULL, fromGen INTEGER NOT NULL,
     toGen INTEGER NOT NULL, frozenAt INTEGER NOT NULL,
     frozenItems INTEGER NOT NULL, frozenFolders INTEGER NOT NULL,
     itemsInserted INTEGER NOT NULL DEFAULT 0,
     itemsDeleted INTEGER NOT NULL DEFAULT 0,
     foldersInserted INTEGER NOT NULL DEFAULT 0,
     foldersDeleted INTEGER NOT NULL DEFAULT 0, oldBackupDriveId TEXT,
     oldBackupMd5 TEXT, oldSnapshotDriveId TEXT, oldSnapshotMd5 TEXT,
     bridgeDriveId TEXT)''',
  '''CREATE TABLE rotation_old_files (driveId TEXT PRIMARY KEY,
     name TEXT NOT NULL, md5 TEXT, itemId TEXT, kind TEXT NOT NULL,
     quarantine INTEGER NOT NULL DEFAULT 0)''',
  'CREATE TABLE vault_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  '''CREATE TABLE diag_events (id INTEGER PRIMARY KEY AUTOINCREMENT,
     at INTEGER NOT NULL, level TEXT NOT NULL, category TEXT NOT NULL,
     message TEXT NOT NULL)''',
];

void main() {
  sqfliteFfiInit();
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('schema12'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> makeV11() async {
    final path = p.join(dir.path, 'v11.db');
    final db = await databaseFactoryFfi.openDatabase(path);
    for (final ddl in _v11) {
      await db.execute(ddl);
    }
    await db.insert('folders', {
      'id': 'f1',
      'name': 'Viaje',
      'createdAt': '2026-01-01',
    });
    for (final (id, asset) in [('i1', 'A1'), ('i2', 'A2'), ('i3', null)]) {
      await db.insert('vault_items', {
        'id': id,
        'name': '$id.jpg',
        'folderId': 'f1',
        'encryptedPath': 'vault/$id.vault',
        'fileSize': 99,
        'createdAt': '2026-01-01',
        'syncStatus': 'en_nube',
        'driveFileId': 'drive-$id',
        'contentHash': 'sha-$id',
        'sourceAssetId': asset,
        'cloudAccountTag': 'tag',
        'keyGen': 1,
      });
    }
    await db.insert('vault_meta', {'key': 'account_salt', 'value': 'ab'});
    await db.insert('diag_events', {
      'at': 1,
      'level': 'debug',
      'category': 'sync',
      'message': 'x',
    });
    await db.insert('tags', {'id': 't', 'name': 'T', 'createdAt': 'x'});
    await db.insert('item_tags', {'itemId': 'i1', 'tagId': 't'});
    await db.execute('PRAGMA user_version = 11');
    await db.close();
    return path;
  }

  Future<Database> openCurrent(String path) => databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: VaultSchema.version,
      onCreate: (d, v) => VaultSchema.create(d),
      onUpgrade: (d, o, n) => VaultSchema.upgrade(d, o, n),
      onDowngrade: (d, o, n) => throw VaultSchemaTooNewException(o, n),
    ),
  );

  Future<Set<Object?>> names(Database db, String type) async =>
      (await db.rawQuery('SELECT name FROM sqlite_master WHERE type = ?', [
        type,
      ])).map((r) => r['name']).toSet();

  test('la versión actual es 12', () => expect(VaultSchema.version, 12));

  test('v11 -> v12 conserva TODAS las filas; sourceHash NULL; tablas nuevas '
      'vacías', () async {
    final path = await makeV11();
    final raw = await databaseFactoryFfi.openDatabase(path);
    final before = <String, List<Map<String, Object?>>>{};
    for (final t in [
      'vault_items',
      'folders',
      'tags',
      'item_tags',
      'vault_meta',
      'diag_events',
    ]) {
      before[t] = await raw.query(t, orderBy: 'rowid');
    }
    final colsBefore = (await raw.rawQuery(
      'PRAGMA table_info(vault_items)',
    )).map((r) => r['name']).toSet();
    await raw.close();

    final db = await openCurrent(path);
    expect(
      (await db.rawQuery('PRAGMA user_version')).single.values.first,
      12,
    );
    for (final e in before.entries) {
      final after = await db.query(e.key, orderBy: 'rowid');
      expect(after.length, e.value.length, reason: e.key);
      for (var i = 0; i < after.length; i++) {
        for (final col in e.value[i].keys) {
          expect(after[i][col], e.value[i][col], reason: '${e.key}.$col');
        }
      }
    }
    final colsAfter = (await db.rawQuery(
      'PRAGMA table_info(vault_items)',
    )).map((r) => r['name']).toSet();
    expect(colsAfter.difference(colsBefore), {'sourceHash'});
    for (final r in await db.query('vault_items')) {
      expect(r['sourceHash'], isNull);
    }
    expect(
      await names(db, 'table'),
      containsAll(['import_batches', 'import_queue']),
    );
    expect(await db.query('import_batches'), isEmpty);
    expect(await db.query('import_queue'), isEmpty);
    expect(await names(db, 'index'), containsAll(VaultSchema.indexNames));
    final m = VaultItemModel.fromMap((await db.query('vault_items')).first);
    expect(m.sourceHash, isNull);
    expect(m.cloudAccountTag, 'tag');
    await db.close();
  });

  test('addImportQueueSchema es idempotente y no toca datos', () async {
    final db = await openCurrent(await makeV11());
    await db.update('vault_items', {'sourceHash': 'h'}, where: "id='i1'");
    await db.insert('import_batches', {
      'id': 'b',
      'state': 'running',
      'videoQuality': 'original',
      'createdAt': 1,
      'updatedAt': 1,
    });
    await VaultSchema.addImportQueueSchema(db);
    await VaultSchema.addImportQueueSchema(db);
    expect(
      (await db.rawQuery('PRAGMA table_info(vault_items)'))
          .where((c) => c['name'] == 'sourceHash')
          .length,
      1,
    );
    expect(
      (await db.query('vault_items', where: "id='i1'")).single['sourceHash'],
      'h',
    );
    expect((await db.query('import_batches')).single['id'], 'b');
    await db.close();
  });

  test('reabrir una v12 no cambia nada', () async {
    final path = await makeV11();
    final first = await openCurrent(path);
    await first.insert('import_queue', {
      'batchId': 'b',
      'seq': 0,
      'assetId': 'A9',
    });
    await first.close();
    final db = await openCurrent(path);
    expect((await db.query('import_queue')).single['state'], 'pending');
    expect((await db.query('vault_items')).length, 3);
    await db.close();
  });

  for (final from in [6, 10]) {
    test('v$from -> v12 también', () async {
      final path = p.join(dir.path, 'old$from.db');
      final raw = await databaseFactoryFfi.openDatabase(path);
      for (final ddl in _v11) {
        if (ddl.contains('vault_meta') || ddl.contains('diag_events')) continue;
        if (from < 10 &&
            (ddl.contains('rotation_') || ddl.contains('keygen'))) {
          continue;
        }
        if (from < 9 && (ddl.contains(' tags') || ddl.contains('item_tags'))) {
          continue;
        }
        if (from < 7 && ddl.contains('migration_')) continue;
        var d = ddl.replaceAll(
          RegExp(r',\s*cloudAccountTag TEXT, thumbAccountTag TEXT'),
          '',
        );
        if (from < 10) {
          d = d.replaceAll(', keyGen INTEGER NOT NULL DEFAULT 1', '');
        }
        await raw.execute(d);
      }
      await raw.insert('vault_items', {
        'id': 'a',
        'name': 'a',
        'encryptedPath': 'vault/a.vault',
        'fileSize': 1,
        'createdAt': 'x',
        'sourceAssetId': 'S',
      });
      await raw.execute('PRAGMA user_version = $from');
      await raw.close();
      final db = await openCurrent(path);
      final row = (await db.query('vault_items')).single;
      expect(row['sourceAssetId'], 'S');
      expect(row['sourceHash'], isNull);
      expect(row['keyGen'], 1);
      expect(
        await names(db, 'table'),
        containsAll(['import_queue', 'import_batches', 'diag_events']),
      );
      await db.close();
    });
  }

  test('toMap no escribe sourceHash nulo; fromMap lo lee', () {
    const item = VaultItemModel(
      keyGen: 1,
      id: 'i1',
      name: 'n',
      encryptedPath: 'vault/i1.vault',
      fileSize: 1,
      mimeType: 'image/jpeg',
      createdAt: '2026-01-01',
    );
    expect(item.toMap().containsKey('sourceHash'), isFalse);
    const hashed = VaultItemModel(
      keyGen: 1,
      id: 'i1',
      name: 'n',
      encryptedPath: 'vault/i1.vault',
      fileSize: 1,
      mimeType: 'image/jpeg',
      createdAt: '2026-01-01',
      sourceHash: 'h',
    );
    expect(VaultItemModel.fromMap(hashed.toMap()).sourceHash, 'h');
  });

  group('la cola de importación no sale del teléfono', () {
    late PhoneA a;
    setUp(() async {
      a = PhoneA();
      await a.setUp();
    });
    tearDown(() async => a.tearDown());

    test('el snapshot exportado va SIN la cola; la local la conserva', () async {
      final db = await a.vdb.database;
      await db.insert('import_batches', {
        'id': 'b',
        'state': 'running',
        'videoQuality': 'original',
        'createdAt': 1,
        'updatedAt': 1,
      });
      for (var i = 0; i < 30; i++) {
        await db.insert('import_queue', {
          'batchId': 'b',
          'seq': i,
          'assetId': 'asset-local-$i',
        });
      }
      final copy = await a.vdb.exportEncryptedSnapshot();
      final snap = await databaseFactoryFfi.openDatabase(copy.file.path);
      try {
        expect(await snap.query('import_queue'), isEmpty);
        expect(await snap.query('import_batches'), isEmpty);
      } finally {
        await snap.close();
      }
      // Ni rastro de los ids en el archivo (VACUUM).
      final bytes = await copy.file.readAsString(encoding: const Latin1Codec());
      expect(bytes.contains('asset-local-'), isFalse);
      await copy.file.delete();
      final local = await a.vdb.database;
      expect((await local.query('import_queue')).length, 30);
    });
  });
}
