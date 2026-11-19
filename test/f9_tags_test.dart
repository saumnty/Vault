// Fase 9 (v2): etiquetas, filtros y búsqueda. BD v9 incremental.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' show Sqflite;
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/data/trash/trash_repository.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/features/vault/models/browser_entry.dart';

import 'support/f6_env.dart';

bool _kind(KindFilter k, VaultItemModel item) {
  final fk = fileKindOf(item);
  return switch (k) {
    KindFilter.photo => fk == FileKind.image,
    KindFilter.video => fk == FileKind.video,
    KindFilter.file => fk != FileKind.image && fk != FileKind.video,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'BD v8 -> v9 conserva los datos y agrega las tablas de etiquetas',
    () async {
      // v10 (rotación de la DEK) llegó después; el paso v8 -> v9 sigue igual.
      expect(VaultSchema.version, greaterThanOrEqualTo(9));
      final dir = await Directory.systemTemp.createTemp('tags_up');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v8.db');
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.execute(
        'CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
        'parentId TEXT, createdAt TEXT NOT NULL, '
        'isOffline INTEGER NOT NULL DEFAULT 0, deletedAt INTEGER, trashRoot TEXT)',
      );
      await raw.insert('folders', {'id': 'f', 'name': 'C', 'createdAt': 'x'});
      await raw.execute('PRAGMA user_version = 8');
      await raw.close();
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 9,
          onUpgrade: (d, o, n) => VaultSchema.upgrade(d, o, n),
        ),
      );
      expect((await db.query('folders')).single['id'], 'f');
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((r) => r['name']).toSet();
      expect(tables, containsAll(['tags', 'item_tags']));
      expect(
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')),
        9,
      );
      await VaultSchema.createTagTables(db); // idempotente
      await db.close();
    },
  );

  group('etiquetas y búsqueda', () {
    late F6Env env;
    late TagRepository tags;

    setUp(() async {
      env = F6Env();
      await env.setUp();
      tags = TagRepository(dbProvider: () => env.vdb.database);
    });
    tearDown(() => env.tearDown());

    test('crear, listar, renombrar y borrar', () async {
      final a = await tags.create('  Vacaciones  ');
      await tags.create('Familia');
      expect((await tags.list()).map((t) => t.name), ['Familia', 'Vacaciones']);
      await tags.rename(a.id, 'Viajes');
      expect((await tags.list()).map((t) => t.name), ['Familia', 'Viajes']);
      await tags.delete(a.id);
      expect((await tags.list()).map((t) => t.name), ['Familia']);
    });

    test(
      'nombre único sin distinguir mayúsculas; inválidos rechazados',
      () async {
        final a = await tags.create('Familia');
        await expectLater(
          tags.create('familia'),
          throwsA(isA<DuplicateTagException>()),
        );
        await tags.create('Otra');
        await expectLater(
          tags.rename(a.id, 'OTRA'),
          throwsA(isA<DuplicateTagException>()),
        );
        await tags.rename(a.id, 'FAMILIA'); // el mismo, cambiando mayúsculas
        await expectLater(
          tags.create('   '),
          throwsA(isA<InvalidTagNameException>()),
        );
        await expectLater(
          tags.create('x' * (kTagNameMax + 1)),
          throwsA(isA<InvalidTagNameException>()),
        );
      },
    );

    test(
      'asignar a varios, quitar, y borrar etiqueta no borra archivos',
      () async {
        await env.addCloudItem('a');
        await env.addCloudItem('b');
        final t = await tags.create('Playa');
        await tags.addTag(['a', 'b'], t.id);
        await tags.addTag(['a'], t.id); // idempotente
        expect((await tags.tagsOfItem('a')).map((x) => x.name), ['Playa']);
        expect((await tags.list()).single.itemCount, 2);
        await tags.removeTag(['b'], t.id);
        expect((await tags.list()).single.itemCount, 1);
        final map = await tags.tagsOfItems(['a', 'b']);
        expect(map.keys, ['a']);
        await tags.delete(t.id);
        expect(await env.items.getItem('a'), isNotNull);
        expect(await tags.tagsOfItem('a'), isEmpty);
      },
    );

    test('búsqueda por nombre (sin mayúsculas, con % literal)', () async {
      await env.addCloudItem('a', name: 'Playa Norte.jpg');
      await env.addCloudItem('b', name: 'Cumple 100%.jpg');
      await env.addCloudItem('c', name: 'Otro.jpg');
      expect(
        (await tags.search(const ItemFilter(text: 'playa'))).map((i) => i.id),
        ['a'],
      );
      expect(
        (await tags.search(const ItemFilter(text: '100%'))).map((i) => i.id),
        ['b'],
      );
      // El % NO es comodín.
      expect(await tags.search(const ItemFilter(text: '%')), hasLength(1));
      expect(await tags.search(const ItemFilter(text: '_')), isEmpty);
    });

    test('etiquetas: el archivo debe tener TODAS', () async {
      await env.addCloudItem('a');
      await env.addCloudItem('b');
      final x = await tags.create('X');
      final y = await tags.create('Y');
      await tags.addTag(['a', 'b'], x.id);
      await tags.addTag(['a'], y.id);
      expect(
        (await tags.search(
          ItemFilter(tagIds: {x.id}),
        )).map((i) => i.id).toSet(),
        {'a', 'b'},
      );
      expect(
        (await tags.search(ItemFilter(tagIds: {x.id, y.id}))).map((i) => i.id),
        ['a'],
      );
    });

    test('tipo: foto, video, archivo', () async {
      await env.addCloudItem('a', name: 'f.jpg', mime: 'image/jpeg');
      await env.addCloudItem('b', name: 'v.mp4', mime: 'video/mp4');
      await env.addCloudItem('c', name: 'd.pdf', mime: 'application/pdf');
      Future<Set<String>> kind(KindFilter k) async => (await tags.search(
        ItemFilter(kind: k),
        kindMatcher: (i) => _kind(k, i),
      )).map((i) => i.id).toSet();
      expect(await kind(KindFilter.photo), {'a'});
      expect(await kind(KindFilter.video), {'b'});
      expect(await kind(KindFilter.file), {'c'});
    });

    test('rango de fechas inclusivo en ambos extremos', () async {
      await env.addCloudItem('a', createdAt: '2026-03-01T00:00:00');
      await env.addCloudItem('b', createdAt: '2026-03-10T23:59:59');
      await env.addCloudItem('c', createdAt: '2026-03-11T00:00:00');
      await env.addCloudItem('d', createdAt: '2026-02-28T23:59:59');
      Future<Set<String>> ids(ItemFilter f) async =>
          (await tags.search(f)).map((i) => i.id).toSet();
      final from = DateTime(2026, 3, 1);
      final to = DateTime(2026, 3, 10);
      expect(await ids(ItemFilter(from: from, to: to)), {'a', 'b'});
      expect(await ids(ItemFilter(from: from)), {'a', 'b', 'c'});
      expect(await ids(ItemFilter(to: to)), {'a', 'b', 'd'});
    });

    test('todo combinado: texto + etiqueta + tipo + fechas', () async {
      await env.addCloudItem(
        'a',
        name: 'Playa.jpg',
        createdAt: '2026-03-05T10:00:00',
      );
      await env.addCloudItem(
        'b',
        name: 'Playa.mp4',
        mime: 'video/mp4',
        createdAt: '2026-03-05T10:00:00',
      );
      await env.addCloudItem(
        'c',
        name: 'Playa vieja.jpg',
        createdAt: '2025-01-01T10:00:00',
      );
      final t = await tags.create('Viaje');
      await tags.addTag(['a', 'b', 'c'], t.id);
      final r = await tags.search(
        ItemFilter(
          text: 'playa',
          tagIds: {t.id},
          kind: KindFilter.photo,
          from: DateTime(2026, 1, 1),
        ),
        kindMatcher: (i) => _kind(KindFilter.photo, i),
      );
      expect(r.map((i) => i.id), ['a']);
    });

    test('busca en todas las carpetas y NO incluye la papelera', () async {
      await env.addFolder('f1');
      await env.addCloudItem('a', folderId: 'f1', name: 'Uno.jpg');
      await env.addCloudItem('b', name: 'Dos.jpg');
      final trash = TrashRepository(dbProvider: () => env.vdb.database);
      await trash.trashItem('b', now: 1);
      expect((await tags.search(const ItemFilter())).map((i) => i.id), ['a']);
      final t = await tags.create('T');
      await tags.addTag(['a', 'b'], t.id);
      expect((await tags.list()).single.itemCount, 1); // b en la papelera
    });

    test(
      'borrar el archivo (directo o definitivo) limpia sus etiquetas',
      () async {
        await env.addCloudItem('a');
        await env.addCloudItem('b');
        await env.addCloudItem('c');
        final t = await tags.create('T');
        await tags.addTag(['a', 'b', 'c'], t.id);
        await env.items.deleteItem('a');
        final trash = TrashRepository(dbProvider: () => env.vdb.database);
        await trash.trashItem('b', now: 1);
        await trash.deleteRows('b');
        final db = await env.vdb.database;
        final left = await db.query('item_tags');
        expect(left.map((r) => r['itemId']), ['c']);
      },
    );

    test('las etiquetas viajan en el snapshot (misma BD cifrada)', () async {
      // El snapshot es la propia BD: las tablas existen y tienen datos.
      final t = await tags.create('Snap');
      await env.addCloudItem('a');
      await tags.addTag(['a'], t.id);
      final db = await env.vdb.database;
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((r) => r['name']).toSet();
      expect(tables, containsAll(['tags', 'item_tags']));
      expect((await db.query('tags')).single['name'], 'Snap');
    });
  });
}
