// D60/D62 (rotación de la DEK, paso 3): esquema v10 INCREMENTAL. Una BD v9
// (la del iPhone) sube a v10 sin perder nada y con todo en `keyGen = 1`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_database.dart';

/// Esquema v9 tal cual estaba antes de v10 (copia literal de
/// `VaultSchema.create` en v9), para no depender del código actual.
const _v9 = [
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
     trashRoot TEXT)''',
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
];

void main() {
  sqfliteFfiInit();
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('schema10'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// BD v[version] con datos de todas las tablas que existían entonces.
  Future<String> makeOld(int version) async {
    final path = p.join(dir.path, 'old$version.db');
    final db = await databaseFactoryFfi.openDatabase(path);
    for (final ddl in _v9) {
      final isTags = ddl.contains('tags') || ddl.contains('item_tags');
      final isMigration = ddl.contains('migration_');
      if (version < 9 && isTags) continue;
      if (version < 7 && isMigration) continue;
      await db.execute(ddl);
    }
    await db.insert('folders', {
      'id': 'f1',
      'name': 'Carpeta',
      'createdAt': '2026-01-01',
    });
    await db.insert('folders', {
      'id': 'f2',
      'name': 'Borrada',
      'createdAt': '2026-01-01',
      'deletedAt': 123,
      'trashRoot': 'f2',
    });
    await db.insert('vault_items', {
      'id': 'i1',
      'name': 'Foto.jpg',
      'folderId': 'f1',
      'encryptedPath': 'vault/i1.vault',
      'fileSize': 99,
      'mimeType': 'image/jpeg',
      'createdAt': '2026-01-01',
      'syncStatus': 'en_nube',
      'driveFileId': 'drive-1',
      'cloudMd5': 'abc',
      'cloudSize': 120,
      'thumbPath': 'thumbs/i1.thumb',
      'thumbDriveFileId': 'drive-t1',
      'fileId': 'fid-1',
      'thumbFileId': 'tfid-1',
      'contentHash': 'sha',
      'isFavorite': 1,
    });
    await db.insert('vault_items', {
      'id': 'i2',
      'name': 'En la papelera.mp4',
      'folderId': 'f2',
      'encryptedPath': 'vault/i2.vault',
      'fileSize': 5,
      'mimeType': 'video/mp4',
      'createdAt': '2026-01-02',
      'deletedAt': 123,
      'trashRoot': 'f2',
    });
    await db.insert('sync_queue', {
      'itemId': 'i9',
      'kind': 'delete_remote',
      'createdAt': 1,
      'payload': '{}',
    });
    if (version >= 9) {
      await db.insert('tags', {
        'id': 't1',
        'name': 'Viajes',
        'createdAt': '2026-01-01',
      });
      await db.insert('item_tags', {'itemId': 'i1', 'tagId': 't1'});
    }
    await db.execute('PRAGMA user_version = $version');
    await db.close();
    return path;
  }

  Future<Database> openCurrent(String path) => databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: VaultSchema.version,
      onCreate: (d, v) => VaultSchema.create(d),
      onUpgrade: (d, o, n) => VaultSchema.upgrade(d, o, n),
    ),
  );

  Future<Set<Object?>> names(Database db, String type) async =>
      (await db.rawQuery('SELECT name FROM sqlite_master WHERE type = ?', [
        type,
      ])).map((r) => r['name']).toSet();

  test('la versión actual es 10', () => expect(VaultSchema.version, 10));

  test('v9 -> v10 conserva TODOS los datos y deja keyGen = 1', () async {
    final db = await openCurrent(await makeOld(9));
    expect((await db.rawQuery('PRAGMA user_version')).single.values.first, 10);
    final items = {for (final r in await db.query('vault_items')) r['id']: r};
    expect(items.keys, {'i1', 'i2'});
    final i1 = items['i1']!;
    expect(i1['keyGen'], 1);
    expect(i1['encryptedPath'], 'vault/i1.vault');
    expect(i1['driveFileId'], 'drive-1');
    expect(i1['cloudMd5'], 'abc');
    expect(i1['cloudSize'], 120);
    expect(i1['thumbPath'], 'thumbs/i1.thumb');
    expect(i1['thumbDriveFileId'], 'drive-t1');
    expect(i1['fileId'], 'fid-1');
    expect(i1['thumbFileId'], 'tfid-1');
    expect(i1['contentHash'], 'sha');
    expect(i1['isFavorite'], 1);
    expect(i1['syncStatus'], 'en_nube');
    // Papelera intacta.
    expect(items['i2']!['deletedAt'], 123);
    expect(items['i2']!['trashRoot'], 'f2');
    expect(items['i2']!['keyGen'], 1);
    final folders = await db.query('folders', orderBy: 'id');
    expect(folders.map((f) => f['name']), ['Carpeta', 'Borrada']);
    expect(folders[1]['deletedAt'], 123);
    // Etiquetas y cola intactas.
    expect((await db.query('tags')).single['name'], 'Viajes');
    expect((await db.query('item_tags')).single['tagId'], 't1');
    expect((await db.query('sync_queue')).single['kind'], 'delete_remote');
    // Lo nuevo, vacío.
    expect(
      await names(db, 'table'),
      containsAll(['rotation_state', 'rotation_old_files']),
    );
    expect(await db.query('rotation_state'), isEmpty);
    expect(await db.query('rotation_old_files'), isEmpty);
    expect(await names(db, 'index'), contains('idx_items_keygen'));
    // El modelo lee la generación.
    expect(VaultItemModel.fromMap(i1).keyGen, 1);
    await db.close();
  });

  for (final from in [6, 7, 8]) {
    test('v$from -> v10 también, sin perder nada', () async {
      final db = await openCurrent(await makeOld(from));
      expect((await db.query('vault_items')).map((r) => r['keyGen']), [1, 1]);
      expect((await db.query('folders')).length, 2);
      expect(
        await names(db, 'table'),
        containsAll([
          'migration_state',
          'tags',
          'item_tags',
          'rotation_state',
          'rotation_old_files',
        ]),
      );
      await db.close();
    });
  }

  test('addRotationSchema es idempotente y no toca datos', () async {
    final db = await openCurrent(await makeOld(9));
    await db.update('vault_items', {'keyGen': 2}, where: "id = 'i2'");
    await VaultSchema.addRotationSchema(db);
    await VaultSchema.addRotationSchema(db);
    final rows = await db.query('vault_items', orderBy: 'id');
    expect(rows.map((r) => r['keyGen']), [1, 2]);
    expect(
      (await db.rawQuery(
        'PRAGMA table_info(vault_items)',
      )).where((c) => c['name'] == 'keyGen').length,
      1,
    );
    await db.close();
  });

  test('reabrir una v10 no cambia nada', () async {
    final path = await makeOld(9);
    final first = await openCurrent(path);
    await first.close();
    final db = await openCurrent(path);
    expect((await db.query('vault_items')).length, 2);
    await db.close();
  });

  test('una BD nueva trae keyGen (por defecto 1), tablas e índice', () async {
    final db = await openCurrent(p.join(dir.path, 'nueva.db'));
    await db.insert('vault_items', {
      'id': 'n1',
      'name': 'x',
      'encryptedPath': 'vault/n1.vault',
      'fileSize': 1,
      'createdAt': '2026-01-01',
    });
    expect((await db.query('vault_items')).single['keyGen'], 1);
    expect(
      await names(db, 'table'),
      containsAll(['rotation_state', 'rotation_old_files']),
    );
    expect(await names(db, 'index'), containsAll(VaultSchema.indexNames));
    await db.close();
  });

  test('toMap escribe keyGen y fromMap lo lee', () {
    const item = VaultItemModel(
      keyGen: 3,
      id: 'i1',
      name: 'n',
      encryptedPath: 'vault/i1.k3.vault',
      fileSize: 1,
      mimeType: 'image/jpeg',
      createdAt: '2026-01-01',
    );
    final map = item.toMap();
    expect(map['keyGen'], 3);
    expect(VaultItemModel.fromMap(map).keyGen, 3);
    expect(VaultItemModel.fromMap({...map}..remove('keyGen')).keyGen, 1);
  });
}
