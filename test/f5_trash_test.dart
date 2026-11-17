// Fase 5 (v2): Papelera. BD v8 incremental, marcar/restaurar, vencimiento a
// los 30 días (solo entonces se borra y se encola delete_remote), exclusión
// de caché/cuadrícula/candidatos a borrar originales.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' show Sqflite;
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/trash/trash_repository.dart';
import 'package:vault/features/vault/models/browser_entry.dart';
import 'package:vault/features/vault/services/trash_service.dart';
import 'package:vault/features/vault/vault_services.dart';

import 'support/f6_env.dart';

const _day = Duration.millisecondsPerDay;

/// DDL EXACTO de v7 (antes de la papelera) para probar la actualización.
const _v7Tables = [
  '''CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL,
     parentId TEXT, createdAt TEXT NOT NULL,
     isOffline INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE vault_items (id TEXT PRIMARY KEY, name TEXT NOT NULL,
     folderId TEXT, encryptedPath TEXT NOT NULL, fileSize INTEGER NOT NULL,
     mimeType TEXT, createdAt TEXT NOT NULL,
     isOffline INTEGER NOT NULL DEFAULT 0,
     isFavorite INTEGER NOT NULL DEFAULT 0, driveFileId TEXT,
     syncStatus TEXT NOT NULL DEFAULT 'pendiente', thumbPath TEXT,
     lastAccessedAt INTEGER, contentHash TEXT, sourceAssetId TEXT,
     durationMs INTEGER, cloudMd5 TEXT, cloudSize INTEGER,
     thumbDriveFileId TEXT, fileId TEXT, thumbFileId TEXT)''',
  '''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,
     itemId TEXT NOT NULL, kind TEXT NOT NULL,
     state TEXT NOT NULL DEFAULT 'pendiente',
     attempts INTEGER NOT NULL DEFAULT 0,
     nextAttemptAt INTEGER NOT NULL DEFAULT 0, lastError TEXT,
     createdAt INTEGER NOT NULL, payload TEXT, UNIQUE (itemId, kind))''',
  '''CREATE TABLE migration_state (id INTEGER PRIMARY KEY CHECK (id = 1),
     phase TEXT NOT NULL, oldEmail TEXT, newEmail TEXT,
     startedAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
     neededBytes INTEGER NOT NULL DEFAULT 0,
     downloadTotal INTEGER NOT NULL DEFAULT 0,
     downloadDone INTEGER NOT NULL DEFAULT 0, lastError TEXT)''',
  '''CREATE TABLE migration_items (itemId TEXT PRIMARY KEY,
     oldStatus TEXT NOT NULL, oldDriveFileId TEXT, oldCloudMd5 TEXT,
     oldCloudSize INTEGER, oldThumbDriveFileId TEXT)''',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('BD v8: actualización incremental', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('trash_up'));
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<String> makeOld(int version) async {
      final path = p.join(dir.path, 'old$version.db');
      final db = await databaseFactoryFfi.openDatabase(path);
      for (final t in _v7Tables) {
        await db.execute(t);
      }
      await db.insert('folders', {
        'id': 'f1',
        'name': 'Carpeta',
        'createdAt': '2026-01-01',
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
        'cloudSize': 99,
      });
      await db.insert('sync_queue', {
        'itemId': 'i1',
        'kind': 'delete_remote',
        'createdAt': 1,
        'payload': '{}',
      });
      await db.execute('PRAGMA user_version = $version');
      await db.close();
      return path;
    }

    Future<Database> upgrade(String path) => databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: VaultSchema.version,
        onUpgrade: (d, o, n) => VaultSchema.upgrade(d, o, n),
      ),
    );

    test('v7 -> v8 conserva TODOS los datos y agrega las columnas', () async {
      expect(VaultSchema.version, 8);
      final db = await upgrade(await makeOld(7));
      final item = (await db.query('vault_items')).single;
      expect(item['id'], 'i1');
      expect(item['driveFileId'], 'drive-1');
      expect(item['cloudMd5'], 'abc');
      expect(item['deletedAt'], isNull);
      expect(item['trashRoot'], isNull);
      expect((await db.query('folders')).single['name'], 'Carpeta');
      expect((await db.query('sync_queue')).single['kind'], 'delete_remote');
      final cols = (await db.rawQuery(
        'PRAGMA table_info(folders)',
      )).map((r) => r['name']).toSet();
      expect(cols, containsAll(['deletedAt', 'trashRoot']));
      expect(
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')),
        8,
      );
      await db.close();
    });

    test('v6 -> v8 también (migración y papelera) sin perder nada', () async {
      final path = p.join(dir.path, 'old6.db');
      final raw = await databaseFactoryFfi.openDatabase(path);
      for (final t in _v7Tables.take(3)) {
        await raw.execute(t);
      }
      await raw.insert('folders', {
        'id': 'f1',
        'name': 'C',
        'createdAt': '2026-01-01',
      });
      await raw.execute('PRAGMA user_version = 6');
      await raw.close();
      final db = await upgrade(path);
      expect((await db.query('folders')).single['id'], 'f1');
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((r) => r['name']).toSet();
      expect(tables, containsAll(['migration_state', 'migration_items']));
      await db.close();
    });

    test('addTrashColumns es idempotente', () async {
      final db = await upgrade(await makeOld(7));
      await VaultSchema.addTrashColumns(db);
      await VaultSchema.addTrashColumns(db);
      expect((await db.query('vault_items')).length, 1);
      await db.close();
    });

    test('una BD nueva trae las columnas y el índice', () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: VaultSchema.version,
          onCreate: (d, v) => VaultSchema.create(d),
        ),
      );
      final idx = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      )).map((r) => r['name']).toSet();
      expect(idx, containsAll(VaultSchema.indexNames));
      await db.close();
    });
  });

  group('papelera', () {
    late F6Env env;
    late TrashRepository repo;
    late TrashService trash;
    late List<RemoteDeleteTarget> remoteCalls;
    late List<String> cleaned;
    int now = 1000 * _day;

    setUp(() async {
      env = F6Env();
      await env.setUp();
      now = 1000 * _day;
      remoteCalls = [];
      cleaned = [];
      repo = TrashRepository(dbProvider: () => env.vdb.database);
      trash = TrashService(
        repository: repo,
        fileCleaner: (ids) async {
          cleaned.addAll(ids);
          for (final id in ids) {
            for (final rel in [
              AppPaths.vaultRelativePath(id),
              AppPaths.thumbRelativePath(id),
            ]) {
              final f = AppPaths.resolve(rel);
              if (f.existsSync()) f.deleteSync();
            }
          }
        },
        remoteDeleter: (t) async => remoteCalls.addAll(t),
        nowMs: () => now,
      );
    });
    tearDown(() => env.tearDown());

    Future<FileEntry> entryOf(String id) async =>
        FileEntry((await env.items.getItem(id))!);
    Future<FolderEntry> folderEntry(String id) async =>
        FolderEntry((await env.items.getFolder(id))!);

    test(
      'un archivo a la papelera: sale de la cuadrícula, NO se borra nada',
      () async {
        await env.addCloudItem('a');
        await env.addCloudItem('b');
        await trash.trash([await entryOf('a')]);
        expect((await env.items.getItemsByFolder(null)).map((i) => i.id), [
          'b',
        ]);
        // Archivo local, miniatura y copia de Drive siguen ahí.
        expect(
          AppPaths.resolve(AppPaths.vaultRelativePath('a')).existsSync(),
          isTrue,
        );
        expect(
          AppPaths.resolve(AppPaths.thumbRelativePath('a')).existsSync(),
          isTrue,
        );
        expect(env.cloud.names, contains('a.vault'));
        expect(remoteCalls, isEmpty);
        expect(cleaned, isEmpty);
        final list = await trash.list();
        expect(list.single.id, 'a');
        expect(list.single.isFolder, isFalse);
        expect(await trash.count(), 1);
      },
    );

    test(
      'una carpeta arrastra subcarpetas y archivos, con una sola raíz',
      () async {
        await env.addFolder('f1');
        await env.addFolder('f2', parent: 'f1');
        await env.addCloudItem('a', folderId: 'f1');
        await env.addCloudItem('b', folderId: 'f2');
        await env.addCloudItem('c'); // fuera
        await trash.trash([await folderEntry('f1')]);
        expect(await env.items.getFoldersByParent(null), isEmpty);
        expect(await env.items.getItemsByFolder('f1'), isEmpty);
        expect((await env.items.getItemsByFolder(null)).map((i) => i.id), [
          'c',
        ]);
        final list = await trash.list();
        expect(list.length, 1);
        expect(list.single.id, 'f1');
        expect(list.single.isFolder, isTrue);
        expect(list.single.itemCount, 2);
        expect(list.single.bytes, 2 * 100 * 1024);
      },
    );

    test('restaurar devuelve todo a su sitio', () async {
      await env.addFolder('f1');
      await env.addFolder('f2', parent: 'f1');
      await env.addCloudItem('a', folderId: 'f1');
      await env.addCloudItem('b', folderId: 'f2');
      await trash.trash([await folderEntry('f1')]);
      expect(await trash.restore('f1'), isTrue);
      expect((await env.items.getFoldersByParent(null)).map((f) => f.id), [
        'f1',
      ]);
      expect((await env.items.getFoldersByParent('f1')).map((f) => f.id), [
        'f2',
      ]);
      expect((await env.items.getItemsByFolder('f2')).map((i) => i.id), ['b']);
      expect(await trash.count(), 0);
      expect(await trash.restore('f1'), isFalse); // ya no está
    });

    test(
      'restaurar un archivo cuya carpeta se eliminó o está en la papelera: va a la raíz',
      () async {
        await env.addFolder('f1');
        await env.addCloudItem('a', folderId: 'f1');
        await trash.trash([await entryOf('a')]);
        // Luego se manda a la papelera la carpeta (que ya está vacía de vivos).
        await trash.trash([await folderEntry('f1')]);
        expect(await trash.restore('a'), isTrue);
        final a = (await env.items.getItem('a'))!;
        expect(a.folderId, isNull);
        expect((await env.items.getItemsByFolder(null)).map((i) => i.id), [
          'a',
        ]);
        // La carpeta sigue en la papelera con su propia raíz.
        expect((await trash.list()).single.id, 'f1');
      },
    );

    test('lo que ya estaba en la papelera conserva su propia raíz', () async {
      await env.addFolder('f1');
      await env.addCloudItem('a', folderId: 'f1');
      await env.addCloudItem('b', folderId: 'f1');
      await trash.trash([await entryOf('a')]);
      now += 5 * _day;
      await trash.trash([await folderEntry('f1')]);
      final list = await trash.list();
      expect(list.map((e) => e.id).toSet(), {'a', 'f1'});
      expect(list.firstWhere((e) => e.id == 'f1').itemCount, 1); // solo b
    });

    test(
      'dentro de 30 días NO se vacía; al cumplirse sí, con delete_remote',
      () async {
        final item = await env.addCloudItem('a');
        await env.addCloudItem('b');
        await trash.trash([await entryOf('a')]);
        now += 29 * _day;
        expect(await trash.purgeExpired(), 0);
        expect(remoteCalls, isEmpty);
        expect(await trash.count(), 1);
        now += 1 * _day;
        expect(await trash.purgeExpired(), 1);
        expect(await trash.count(), 0);
        expect(await env.items.getItem('a'), isNull);
        expect(await env.items.getItem('b'), isNotNull); // el otro no se toca
        expect(cleaned, ['a']);
        expect(
          AppPaths.resolve(AppPaths.vaultRelativePath('a')).existsSync(),
          isFalse,
        );
        expect(remoteCalls.single.itemId, 'a');
        expect(remoteCalls.single.driveFileId, item.driveFileId);
        // Idempotente.
        expect(await trash.purgeExpired(), 0);
        expect(remoteCalls.length, 1);
      },
    );

    test('vencer una carpeta borra todo su contenido y el de Drive', () async {
      await env.addFolder('f1');
      final a = await env.addCloudItem('a', folderId: 'f1');
      final b = await env.addCloudItem('b', folderId: 'f1');
      await trash.trash([await folderEntry('f1')]);
      now += 31 * _day;
      expect(await trash.purgeExpired(), 2);
      expect(await env.items.getFolder('f1'), isNull);
      expect(remoteCalls.map((t) => t.driveFileId).toSet(), {
        a.driveFileId,
        b.driveFileId,
      });
      expect(cleaned.toSet(), {'a', 'b'});
    });

    test('daysLeft cuenta hacia atrás', () async {
      await env.addCloudItem('a');
      await trash.trash([await entryOf('a')]);
      final e = (await trash.list()).single;
      expect(trash.daysLeft(e), 30);
      now += 10 * _day;
      expect(trash.daysLeft(e), 20);
      now += 25 * _day;
      expect(trash.daysLeft(e), 0);
    });

    test('eliminar definitivamente y vaciar todo', () async {
      await env.addCloudItem('a');
      await env.addCloudItem('b');
      await env.addCloudItem('c');
      await trash.trash([await entryOf('a'), await entryOf('b')]);
      expect(await trash.deleteForever(['a']), 1);
      expect(await env.items.getItem('a'), isNull);
      expect(remoteCalls.map((t) => t.itemId), ['a']);
      expect(await trash.emptyAll(), 1);
      expect(await env.items.getItem('b'), isNull);
      expect(await env.items.getItem('c'), isNotNull);
    });

    test('en la papelera NO se purga de la caché, pero el resto sí', () async {
      await env.addCloudItem('a');
      await env.addCloudItem('b');
      await trash.trash([await entryOf('a')]);
      final evicted = await env.cache.enforce(maxBytes: 0);
      expect(evicted, ['b']);
      expect(
        AppPaths.resolve(AppPaths.vaultRelativePath('a')).existsSync(),
        isTrue,
      );
      expect(
        AppPaths.resolve(AppPaths.vaultRelativePath('b')).existsSync(),
        isFalse,
      );
    });

    test('lo de la papelera no es candidato a borrar su original', () async {
      await env.addCloudItem('a');
      await env.addCloudItem('b');
      await trash.trash([await entryOf('a')]);
      final all = await env.items.getItemsBySyncStatus(SyncStatus.enNube);
      final live = await env.items.getItemsBySyncStatus(
        SyncStatus.enNube,
        includeTrashed: false,
      );
      expect(all.map((i) => i.id).toSet(), {'a', 'b'});
      expect(live.map((i) => i.id), ['b']);
    });

    test(
      'el snapshot de la BD refleja la papelera (marca de cambios)',
      () async {
        var changes = 0;
        final old = VaultDataRepository.onDataChanged;
        VaultDataRepository.onDataChanged = () => changes++;
        addTearDown(() => VaultDataRepository.onDataChanged = old);
        await env.addCloudItem('a');
        final before = changes;
        await trash.trash([await entryOf('a')]);
        await trash.restore('a');
        expect(changes, greaterThanOrEqualTo(before + 2));
      },
    );
  });
}
