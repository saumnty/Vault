import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/folder_model.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';

// NOTA: estas pruebas usan SQLite normal (sqflite_common_ffi). El cifrado
// SQLCipher real solo se puede probar en dispositivo/emulador
// (integration_test/vault_database_sqlcipher_test.dart).

Future<Database> _ffiOpener(String path, OpenDatabaseOptions options) =>
    databaseFactoryFfi.openDatabase(path, options: options);

Future<KeyHierarchy> _keys(int seed) => KeyHierarchy.fromDek(
  Uint8List.fromList(List.generate(32, (i) => i + seed)),
);

VaultItemModel _item(
  String id, {
  String? folderId,
  bool offline = false,
  SyncStatus status = SyncStatus.pendiente,
}) => VaultItemModel(
  id: id,
  name: 'n$id',
  folderId: folderId,
  encryptedPath: AppPaths.vaultRelativePath(id),
  fileSize: 10,
  mimeType: 'image/jpeg',
  createdAt: '2026-01-01T00:00:00',
  isOffline: offline,
  syncStatus: status,
);

FolderModel _folder(String id, {String? parent, bool offline = false}) =>
    FolderModel(
      id: id,
      name: 'f$id',
      parentId: parent,
      createdAt: '2026-01-01T00:00:00',
      isOffline: offline,
    );

void main() {
  sqfliteFfiInit();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_db_test');
    await AppPaths.init(baseDir: tmp);
  });

  tearDown(() async {
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('AppPaths', () {
    test('rechaza rutas absolutas y que escapan', () {
      for (final bad in [
        '/etc/passwd',
        r'C:\Users\x\a.vault',
        r'\\server\share',
        '../fuera.vault',
        'vault/../../x',
        '',
      ]) {
        expect(
          () => AppPaths.validateRelative(bad),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(AppPaths.validateRelative('vault/a.vault'), 'vault/a.vault');
      expect(AppPaths.validateRelative(r'vault\a.vault'), 'vault/a.vault');
    });

    test('resolve y relative son inversos', () {
      final abs = AppPaths.resolvePath('vault/abc.vault');
      expect(p.isAbsolute(abs), isTrue);
      expect(AppPaths.relative(abs), 'vault/abc.vault');
      expect(
        () => AppPaths.relative(p.join(tmp.parent.path, 'otro')),
        throwsArgumentError,
      );
      expect(AppPaths.vaultDir.existsSync(), isTrue);
      expect(AppPaths.thumbsDir.existsSync(), isTrue);
    });
  });

  group('esquema y repositorio', () {
    late Database db;
    late VaultDataRepository repo;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: VaultSchema.version,
          onCreate: (d, v) => VaultSchema.create(d),
        ),
      );
      repo = VaultDataRepository(dbProvider: () async => db);
    });
    tearDown(() => db.close());

    test('crea tablas, columnas e indices', () async {
      final itemCols = (await db.rawQuery(
        'PRAGMA table_info(vault_items)',
      )).map((r) => r['name']).toSet();
      expect(
        itemCols,
        containsAll([
          'id',
          'name',
          'folderId',
          'encryptedPath',
          'fileSize',
          'mimeType',
          'createdAt',
          'isOffline',
          'isFavorite',
          'driveFileId',
          'syncStatus',
          'thumbPath',
          'lastAccessedAt',
          'contentHash',
          'sourceAssetId',
          'durationMs',
        ]),
      );
      final folderCols = (await db.rawQuery(
        'PRAGMA table_info(folders)',
      )).map((r) => r['name']).toSet();
      expect(folderCols, containsAll(['id', 'parentId', 'isOffline']));
      final idx = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index'",
      )).map((r) => r['name']).toSet();
      expect(idx, containsAll(VaultSchema.indexNames));
    });

    test('SyncStatus: valores, ida y vuelta, default', () {
      expect(SyncStatus.values.map((s) => s.dbValue), [
        'pendiente',
        'subiendo',
        'en_nube',
        'en_cache',
        'sin_conexion',
        'error',
      ]);
      for (final s in SyncStatus.values) {
        expect(SyncStatus.fromDb(s.dbValue), s);
      }
      expect(SyncStatus.fromDb(null), SyncStatus.pendiente);
      expect(() => SyncStatus.fromDb('x'), throwsArgumentError);
    });

    test('syncStatus por defecto en BD es pendiente', () async {
      await db.insert('vault_items', {
        'id': 'z',
        'name': 'z',
        'encryptedPath': 'vault/z.vault',
        'fileSize': 1,
        'createdAt': 'x',
      });
      expect((await repo.getItem('z'))!.syncStatus, SyncStatus.pendiente);
    });

    test('CRUD de items y rechazo de ruta absoluta', () async {
      await repo.insertItem(_item('1'));
      final got = (await repo.getItem('1'))!;
      expect(got.encryptedPath, 'vault/1.vault');
      expect(got.syncStatus, SyncStatus.pendiente);

      await expectLater(
        repo.insertItem(
          const VaultItemModel(
            id: '2',
            name: 'a',
            encryptedPath: '/data/user/0/app/vault/2.vault',
            fileSize: 1,
            mimeType: 'x',
            createdAt: 'x',
          ),
        ),
        throwsArgumentError,
      );
      expect(await repo.getItem('2'), isNull);
      await expectLater(
        repo.setThumbPath('1', '/abs/t.thumb'),
        throwsArgumentError,
      );

      await repo.renameItem('1', 'nuevo');
      await repo.updateSyncStatus('1', SyncStatus.enNube, driveFileId: 'drv1');
      await repo.setThumbPath('1', AppPaths.thumbRelativePath('1'));
      await repo.touchLastAccessed(
        '1',
        at: DateTime.fromMillisecondsSinceEpoch(5000),
      );
      final u = (await repo.getItem('1'))!;
      expect(u.name, 'nuevo');
      expect(u.syncStatus, SyncStatus.enNube);
      expect(u.driveFileId, 'drv1');
      expect(u.thumbPath, 'thumbs/1.thumb');
      expect(u.lastAccessedAt, 5000);

      await expectLater(repo.renameItem('nope', 'x'), throwsStateError);
      await repo.deleteItem('1');
      expect(await repo.getItem('1'), isNull);
    });

    test('listar por carpeta, por syncStatus y mover', () async {
      await repo.createFolder(_folder('A'));
      await repo.createFolder(_folder('B'));
      await repo.insertItem(_item('1', folderId: 'A'));
      await repo.insertItem(
        _item('2', folderId: 'A', status: SyncStatus.enNube),
      );
      await repo.insertItem(_item('3'));
      expect((await repo.getItemsByFolder('A')).map((i) => i.id).toSet(), {
        '1',
        '2',
      });
      expect((await repo.getItemsByFolder(null)).map((i) => i.id), ['3']);
      expect(
        (await repo.getItemsBySyncStatus(SyncStatus.enNube)).map((i) => i.id),
        ['2'],
      );

      await repo.moveItem('1', 'B');
      expect((await repo.getItemsByFolder('B')).single.id, '1');
      await repo.moveItem('1', null);
      expect((await repo.getItem('1'))!.folderId, isNull);
      await expectLater(repo.moveItem('1', 'noexiste'), throwsArgumentError);
    });

    test('offline heredado de carpeta ancestra', () async {
      await repo.createFolder(_folder('root'));
      await repo.createFolder(_folder('mid', parent: 'root'));
      await repo.createFolder(_folder('leaf', parent: 'mid'));
      await repo.createFolder(_folder('other'));
      await repo.insertItem(_item('deep', folderId: 'leaf'));
      await repo.insertItem(_item('own', folderId: 'other', offline: true));
      await repo.insertItem(_item('plain', folderId: 'other'));
      await repo.insertItem(_item('top'));

      expect(await repo.isEffectivelyOffline('deep'), isFalse);
      await repo.setFolderOffline('root', true);
      expect(await repo.isEffectivelyOffline('deep'), isTrue);
      expect(await repo.isEffectivelyOffline('own'), isTrue);
      expect(await repo.isEffectivelyOffline('plain'), isFalse);
      expect(await repo.isEffectivelyOffline('top'), isFalse);
      expect(await repo.isEffectivelyOffline('inexistente'), isFalse);
      expect(await repo.getEffectiveOfflineItemIds(), {'deep', 'own'});

      await repo.setFolderOffline('root', false);
      expect(await repo.isEffectivelyOffline('deep'), isFalse);
    });

    test('breadcrumbs y prevencion de ciclos', () async {
      await repo.createFolder(_folder('a'));
      await repo.createFolder(_folder('b', parent: 'a'));
      await repo.createFolder(_folder('c', parent: 'b'));
      expect((await repo.getBreadcrumbs('c')).map((f) => f.id), [
        'a',
        'b',
        'c',
      ]);
      expect((await repo.getBreadcrumbs('a')).map((f) => f.id), ['a']);
      expect(await repo.getBreadcrumbs('nada'), isEmpty);
      await expectLater(repo.moveFolder('a', 'c'), throwsArgumentError);
      await expectLater(repo.moveFolder('a', 'a'), throwsArgumentError);
      await repo.moveFolder('c', null);
      expect((await repo.getBreadcrumbs('c')).map((f) => f.id), ['c']);
    });

    test('borrado recursivo devuelve ids de items', () async {
      await repo.createFolder(_folder('a'));
      await repo.createFolder(_folder('b', parent: 'a'));
      await repo.createFolder(_folder('keep'));
      await repo.insertItem(_item('i1', folderId: 'a'));
      await repo.insertItem(_item('i2', folderId: 'b'));
      await repo.insertItem(_item('i3', folderId: 'keep'));
      final deleted = await repo.deleteFolderRecursive('a');
      expect(deleted.toSet(), {'i1', 'i2'});
      expect(await repo.getFolder('a'), isNull);
      expect(await repo.getFolder('b'), isNull);
      expect(await repo.getFolder('keep'), isNotNull);
      expect(await repo.getItem('i3'), isNotNull);
      expect(await repo.getItem('i1'), isNull);
    });

    test('LRU: en_cache ordenado por lastAccessedAt', () async {
      await repo.insertItem(_item('o', status: SyncStatus.enCache));
      await repo.insertItem(_item('n', status: SyncStatus.enCache));
      await repo.insertItem(_item('x', status: SyncStatus.enNube));
      await repo.touchLastAccessed(
        'o',
        at: DateTime.fromMillisecondsSinceEpoch(1),
      );
      await repo.touchLastAccessed(
        'n',
        at: DateTime.fromMillisecondsSinceEpoch(9),
      );
      expect((await repo.getCachedItemsLru()).map((i) => i.id), ['o', 'n']);
    });
  });

  group('VaultDatabase (sesion y ciclo de vida)', () {
    late VaultSession session;
    late List<String?> passwords;
    late VaultDatabase vdb;

    setUp(() {
      session = VaultSession.create();
      passwords = [];
      vdb = VaultDatabase.forTesting(
        session: session,
        useSqlCipher: true, // para capturar la contrasena derivada
        dbPath: p.join(tmp.path, 'db', 'test.db'),
        opener: (path, {password, required options}) {
          passwords.add(password);
          return _ffiOpener(path, options);
        },
      );
    });
    tearDown(() async {
      await vdb.close();
    });

    test('no abre sin sesion desbloqueada', () async {
      await expectLater(vdb.database, throwsStateError);
      expect(passwords, isEmpty);
    });

    test('contrasena = hex de la subllave sqlcipher; lock cierra', () async {
      final keys = await _keys(1);
      final expected = keys.sqlcipher.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      session.open(keys);
      final db = await vdb.database;
      expect(db.isOpen, isTrue);
      expect(passwords.single, expected);
      expect(passwords.single!.length, 64);
      expect(identical(await vdb.database, db), isTrue);
      expect(passwords.length, 1);

      session.clear();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(vdb.isOpen, isFalse);
      expect(db.isOpen, isFalse);
      await expectLater(vdb.database, throwsStateError);
    });

    test('con otra llave se reabre', () async {
      session.open(await _keys(1));
      final first = await vdb.database;
      session.open(await _keys(50));
      final second = await vdb.database;
      expect(first.isOpen, isFalse);
      expect(second.isOpen, isTrue);
      expect(passwords.length, 2);
      expect(passwords[0], isNot(passwords[1]));
    });

    test('exportEncryptedSnapshot copia el .db y reabre luego', () async {
      session.open(await _keys(1));
      final repo = VaultDataRepository(dbProvider: () => vdb.database);
      await repo.insertItem(_item('1'));
      final snap = await vdb.exportEncryptedSnapshot();
      expect(snap.existsSync(), isTrue);
      expect(snap.lengthSync(), greaterThan(0));
      expect(vdb.isOpen, isFalse);
      // Reapertura perezosa: los datos persisten.
      expect(await repo.getItem('1'), isNotNull);
      final copy = await databaseFactoryFfi.openDatabase(snap.path);
      expect(await copy.query('vault_items'), hasLength(1));
      await copy.close();
    });
  });
}
