// D75 (cambio de cuenta atascado, parte A paso 1): esquema v11 INCREMENTAL.
// Una BD v10 (la del iPhone, con un cambio de cuenta en `sign_in_new` y fotos
// `en_nube` con referencias de OTRA cuenta) sube a v11 sin perder nada: solo
// `ADD COLUMN` y `CREATE TABLE IF NOT EXISTS`; los tags quedan a NULL.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_database.dart';

/// Esquema v10 tal cual estaba antes de v11 (copia literal de
/// `VaultSchema.create` en v10), para no depender del código actual.
const _v10 = [
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
     trashRoot TEXT, keyGen INTEGER NOT NULL DEFAULT 1)''',
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
];

void main() {
  sqfliteFfiInit();
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('schema11'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// BD v10 «como la del iPhone»: cambio de cuenta en `sign_in_new`, dos
  /// fotos `en_nube` con referencias de la cuenta de pruebas, una en la
  /// Papelera, etiquetas, cola y una referencia guardada.
  Future<String> makeV10() async {
    final path = p.join(dir.path, 'v10.db');
    final db = await databaseFactoryFfi.openDatabase(path);
    for (final ddl in _v10) {
      await db.execute(ddl);
    }
    await db.insert('folders', {
      'id': 'f1',
      'name': 'Carpeta',
      'createdAt': '2026-01-01',
    });
    for (final (id, status) in [('i1', 'en_nube'), ('i2', 'en_cache')]) {
      await db.insert('vault_items', {
        'id': id,
        'name': '$id.jpg',
        'folderId': 'f1',
        'encryptedPath': 'vault/$id.vault',
        'fileSize': 99,
        'mimeType': 'image/jpeg',
        'createdAt': '2026-01-01',
        'syncStatus': status,
        'driveFileId': 'drive-$id',
        'cloudMd5': 'md5-$id',
        'cloudSize': 120,
        'thumbPath': 'thumbs/$id.thumb',
        'thumbDriveFileId': 'drive-t-$id',
        'fileId': 'fid-$id',
        'contentHash': 'sha-$id',
        'keyGen': 1,
      });
    }
    await db.insert('vault_items', {
      'id': 'i3',
      'name': 'Papelera.mp4',
      'encryptedPath': 'vault/i3.vault',
      'fileSize': 5,
      'createdAt': '2026-01-02',
      'deletedAt': 123,
      'trashRoot': 'i3',
      'syncStatus': 'en_nube',
      'driveFileId': 'drive-i3',
    });
    await db.insert('migration_state', {
      'id': 1,
      'phase': 'sign_in_new',
      'oldEmail': 'pruebas@example.com',
      'startedAt': 1,
      'updatedAt': 2,
      'lastError': 'No elegiste ninguna cuenta. Vuelve a intentarlo.',
    });
    await db.insert('migration_items', {
      'itemId': 'i1',
      'oldStatus': 'en_nube',
      'oldDriveFileId': 'drive-i1',
    });
    await db.insert('tags', {
      'id': 't1',
      'name': 'Viajes',
      'createdAt': '2026-01-01',
    });
    await db.insert('item_tags', {'itemId': 'i1', 'tagId': 't1'});
    await db.insert('sync_queue', {
      'itemId': 'i9',
      'kind': 'delete_remote',
      'createdAt': 1,
      'payload': '{}',
    });
    await db.execute('PRAGMA user_version = 10');
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

  Future<Set<Object?>> columns(Database db, String table) async =>
      (await db.rawQuery(
        'PRAGMA table_info($table)',
      )).map((r) => r['name']).toSet();

  test('la versión actual es 11', () => expect(VaultSchema.version, 11));

  test('v10 -> v11 conserva TODAS las filas y columnas; tags a NULL', () async {
    final path = await makeV10();
    // Foto de todo lo que había (sin las columnas nuevas).
    final raw = await databaseFactoryFfi.openDatabase(path);
    final before = <String, List<Map<String, Object?>>>{};
    for (final t in [
      'vault_items',
      'folders',
      'sync_queue',
      'migration_state',
      'migration_items',
      'tags',
      'item_tags',
    ]) {
      before[t] = await raw.query(t, orderBy: 'rowid');
    }
    final colsBefore = await columns(raw, 'vault_items');
    await raw.close();

    final db = await openCurrent(path);
    expect((await db.rawQuery('PRAGMA user_version')).single.values.first, 11);
    for (final e in before.entries) {
      final after = await db.query(e.key, orderBy: 'rowid');
      expect(after.length, e.value.length, reason: e.key);
      for (var i = 0; i < after.length; i++) {
        for (final col in e.value[i].keys) {
          expect(
            after[i][col],
            e.value[i][col],
            reason: '${e.key}.$col (fila $i)',
          );
        }
      }
    }
    // Columnas antiguas intactas + las dos nuevas, a NULL en todas las filas.
    final colsAfter = await columns(db, 'vault_items');
    expect(colsAfter, containsAll(colsBefore));
    expect(colsAfter.difference(colsBefore), {
      'cloudAccountTag',
      'thumbAccountTag',
    });
    for (final r in await db.query('vault_items')) {
      expect(r['cloudAccountTag'], isNull);
      expect(r['thumbAccountTag'], isNull);
    }
    // Tablas nuevas, vacías (la sal se crea al primer uso, no aquí).
    expect(await names(db, 'table'), containsAll(['vault_meta', 'diag_events']));
    expect(await db.query('vault_meta'), isEmpty);
    expect(await db.query('diag_events'), isEmpty);
    // El cambio de cuenta a medias sigue ahí, tal cual.
    final st = MigrationState.fromMap(
      (await db.query('migration_state')).single,
    );
    expect(st.phase, MigrationPhase.signInNew);
    expect(st.oldEmail, 'pruebas@example.com');
    // Los índices de siempre siguen.
    expect(await names(db, 'index'), containsAll(VaultSchema.indexNames));
    // El modelo lee los tags nulos.
    final m = VaultItemModel.fromMap((await db.query('vault_items')).first);
    expect(m.cloudAccountTag, isNull);
    expect(m.driveFileId, 'drive-i1');
    await db.close();
  });

  test('reabrir una v11 no cambia nada (doble apertura)', () async {
    final path = await makeV10();
    final first = await openCurrent(path);
    await first.update('vault_items', {
      'cloudAccountTag': 'tagX',
    }, where: "id = 'i1'");
    await first.close();
    final db = await openCurrent(path);
    expect((await db.query('vault_items')).length, 3);
    expect(
      (await db.query('vault_items', where: "id = 'i1'")).single['cloudAccountTag'],
      'tagX',
    );
    await db.close();
  });

  test('addAccountTagSchema es idempotente y no toca datos', () async {
    final db = await openCurrent(await makeV10());
    await db.update('vault_items', {'thumbAccountTag': 't'}, where: "id='i2'");
    await db.insert('vault_meta', {'key': 'account_salt', 'value': 'ab'});
    await VaultSchema.addAccountTagSchema(db);
    await VaultSchema.addAccountTagSchema(db);
    final cols = (await db.rawQuery('PRAGMA table_info(vault_items)'))
        .where((c) => c['name'] == 'cloudAccountTag')
        .length;
    expect(cols, 1);
    expect(
      (await db.query('vault_items', where: "id='i2'")).single['thumbAccountTag'],
      't',
    );
    expect((await db.query('vault_meta')).single['value'], 'ab');
    await db.close();
  });

  for (final from in [6, 9]) {
    test('v$from -> v11 también, con las tablas nuevas', () async {
      final path = p.join(dir.path, 'old$from.db');
      final raw = await databaseFactoryFfi.openDatabase(path);
      for (final ddl in _v10) {
        if (from < 10 && (ddl.contains('rotation_') || ddl.contains('keygen'))) {
          continue;
        }
        if (from < 9 && (ddl.contains(' tags') || ddl.contains('item_tags'))) {
          continue;
        }
        if (from < 7 && ddl.contains('migration_')) continue;
        // v6..v9 no tenían keyGen.
        await raw.execute(
          from < 10
              ? ddl.replaceAll(', keyGen INTEGER NOT NULL DEFAULT 1', '')
              : ddl,
        );
      }
      await raw.insert('vault_items', {
        'id': 'a',
        'name': 'a',
        'encryptedPath': 'vault/a.vault',
        'fileSize': 1,
        'createdAt': 'x',
        'driveFileId': 'd',
        'syncStatus': 'en_nube',
      });
      await raw.execute('PRAGMA user_version = $from');
      await raw.close();
      final db = await openCurrent(path);
      final row = (await db.query('vault_items')).single;
      expect(row['driveFileId'], 'd');
      expect(row['keyGen'], 1);
      expect(row['cloudAccountTag'], isNull);
      expect(
        await names(db, 'table'),
        containsAll([
          'migration_state',
          'tags',
          'rotation_state',
          'vault_meta',
          'diag_events',
        ]),
      );
      await db.close();
    });
  }

  test('una BD nueva trae columnas y tablas v11', () async {
    final db = await openCurrent(p.join(dir.path, 'nueva.db'));
    expect(
      await columns(db, 'vault_items'),
      containsAll(['cloudAccountTag', 'thumbAccountTag', 'keyGen']),
    );
    expect(await names(db, 'table'), containsAll(['vault_meta', 'diag_events']));
    await db.close();
  });

  test('una BD v12 (app más nueva) no se toca: VaultSchemaTooNewException', () async {
    final path = await makeV10();
    await (await openCurrent(path)).close();
    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.execute('PRAGMA user_version = 12');
    await raw.close();
    await expectLater(
      openCurrent(path),
      throwsA(isA<VaultSchemaTooNewException>()),
    );
    final check = await databaseFactoryFfi.openDatabase(path);
    expect((await check.query('vault_items')).length, 3);
    await check.close();
  });

  test('toMap no escribe tags nulos; fromMap los lee', () {
    const item = VaultItemModel(
      keyGen: 1,
      id: 'i1',
      name: 'n',
      encryptedPath: 'vault/i1.vault',
      fileSize: 1,
      mimeType: 'image/jpeg',
      createdAt: '2026-01-01',
    );
    expect(item.toMap().containsKey('cloudAccountTag'), isFalse);
    const tagged = VaultItemModel(
      keyGen: 1,
      id: 'i1',
      name: 'n',
      encryptedPath: 'vault/i1.vault',
      fileSize: 1,
      mimeType: 'image/jpeg',
      createdAt: '2026-01-01',
      cloudAccountTag: 'a',
      thumbAccountTag: 'b',
    );
    final back = VaultItemModel.fromMap(tagged.toMap());
    expect(back.cloudAccountTag, 'a');
    expect(back.thumbAccountTag, 'b');
  });

  test('una fase desconocida se lee como unknown (no como downloading)', () {
    expect(MigrationPhase.fromDb('fase_de_otra_version'), MigrationPhase.unknown);
    expect(MigrationPhase.fromDb('sign_in_new'), MigrationPhase.signInNew);
    expect(MigrationPhase.fromDb('?'), MigrationPhase.unknown);
  });
}
