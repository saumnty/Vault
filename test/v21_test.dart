// v2.1: miniaturas de la Papelera (no se purgan) y búsqueda por etiqueta.
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/data/trash/trash_repository.dart';

import 'support/f6_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F6Env env;
  late TagRepository tags;
  late TrashRepository trash;

  setUp(() async {
    env = F6Env();
    await env.setUp();
    tags = TagRepository(dbProvider: () => env.vdb.database);
    trash = TrashRepository(dbProvider: () => env.vdb.database);
  });
  tearDown(() => env.tearDown());

  Future<Set<String>> ids(ItemFilter f) async =>
      (await tags.search(f)).map((i) => i.id).toSet();

  group('Papelera: miniaturas', () {
    test('la entrada de un archivo trae su fila; la carpeta no', () async {
      await env.addFolder('f1');
      await env.addCloudItem('a', name: 'Playa.jpg');
      await env.addCloudItem('b', folderId: 'f1');
      await trash.trashItem('a', now: 10);
      await trash.trashFolder('f1', now: 11);
      final list = await trash.list();
      final file = list.firstWhere((e) => !e.isFolder);
      final folder = list.firstWhere((e) => e.isFolder);
      expect(file.item!.thumbPath, AppPaths.thumbRelativePath('a'));
      expect(folder.item, isNull);
    });

    test('la caché LRU y la papelera no tocan las miniaturas', () async {
      await env.addCloudItem('a', size: 200 * 1024);
      await env.addCloudItem('b', size: 200 * 1024);
      await trash.trashItem('a', now: 10);
      // Presupuesto 0: se purgan los .vault verificados, NUNCA las miniaturas.
      await env.cache.enforce(maxBytes: 0);
      for (final id in ['a', 'b']) {
        expect(
          AppPaths.resolve(AppPaths.thumbRelativePath(id)).existsSync(),
          isTrue,
        );
        expect((await env.items.getItem(id))!.thumbPath, isNotNull);
      }
      // Restaurar conserva la miniatura.
      await trash.restore('a');
      expect((await env.items.getItem('a'))!.thumbPath, isNotNull);
    });
  });

  group('búsqueda por etiqueta', () {
    test('encuentra por nombre de etiqueta y por nombre de archivo', () async {
      await env.addCloudItem('a', name: 'IMG_1.jpg');
      await env.addCloudItem('b', name: 'viaje.jpg');
      await env.addCloudItem('c', name: 'otro.jpg');
      final t = await tags.create('Viaje');
      await tags.addTag(['a'], t.id);
      expect(await ids(const ItemFilter(text: 'viaj')), {'a', 'b'});
      expect(await ids(const ItemFilter(text: 'img')), {'a'});
      expect(await ids(const ItemFilter(text: 'zzz')), isEmpty);
    });

    test('sin distinguir mayúsculas ni acentos (ambos sentidos)', () async {
      await env.addCloudItem('a', name: 'x.jpg');
      await env.addCloudItem('b', name: 'Canción.mp3');
      final t = await tags.create('Cumpleaños Ñandú');
      final u = await tags.create('Música');
      await tags.addTag(['a'], t.id);
      await tags.addTag(['a'], u.id);
      expect(await ids(const ItemFilter(text: 'MUSICA')), {'a'});
      expect(await ids(const ItemFilter(text: 'música')), {'a'});
      expect(await ids(const ItemFilter(text: 'cumpleaños')), {'a'});
      expect(await ids(const ItemFilter(text: 'cancion')), {'b'});
      expect(await ids(const ItemFilter(text: 'CANCIÓN')), {'b'});
      // ñ no es n.
      expect(await ids(const ItemFilter(text: 'cumpleanos')), isEmpty);
    });

    test('se combina con etiquetas, tipo y fechas (Y)', () async {
      await env.addCloudItem(
        'a',
        name: 'a.jpg',
        createdAt: '2026-03-05T10:00:00',
      );
      await env.addCloudItem(
        'b',
        name: 'b.mp4',
        mime: 'video/mp4',
        createdAt: '2026-03-05T10:00:00',
      );
      await env.addCloudItem(
        'c',
        name: 'c.jpg',
        createdAt: '2026-05-05T10:00:00',
      );
      final viaje = await tags.create('Viaje');
      final fam = await tags.create('Familia');
      await tags.addTag(['a', 'b', 'c'], viaje.id);
      await tags.addTag(['a'], fam.id);
      expect(await ids(const ItemFilter(text: 'viaje')), {'a', 'b', 'c'});
      expect(await ids(ItemFilter(text: 'viaje', tagIds: {fam.id})), {'a'});
      expect(
        (await tags.search(
          const ItemFilter(text: 'VIAJE', kind: KindFilter.video),
          kindMatcher: (i) => i.mimeType.startsWith('video/'),
        )).map((i) => i.id),
        ['b'],
      );
      expect(
        await ids(
          ItemFilter(
            text: 'viaje',
            from: DateTime(2026, 3, 1),
            to: DateTime(2026, 3, 31),
          ),
        ),
        {'a', 'b'},
      );
      // La semántica de tagIds no cambia: sigue exigiendo TODAS.
      expect(await ids(ItemFilter(tagIds: {viaje.id, fam.id})), {'a'});
    });

    test('lo que está en la Papelera no aparece', () async {
      await env.addCloudItem('a', name: 'a.jpg');
      await env.addCloudItem('b', name: 'b.jpg');
      final t = await tags.create('Viaje');
      await tags.addTag(['a', 'b'], t.id);
      await trash.trashItem('a', now: 10);
      expect(await ids(const ItemFilter(text: 'viaje')), {'b'});
      expect(await ids(const ItemFilter(text: 'a.jpg')), isEmpty);
    });

    test('archivos sin etiquetas: solo por nombre, sin fallar', () async {
      await env.addCloudItem('a', name: 'Playa.jpg');
      await env.addCloudItem('b', name: 'Monte.jpg');
      await tags.create('Huérfana'); // etiqueta sin archivos
      expect(await ids(const ItemFilter(text: 'playa')), {'a'});
      expect(await ids(const ItemFilter(text: 'huerfana')), isEmpty);
      expect(await ids(const ItemFilter()), {'a', 'b'});
      // Renombrar la etiqueta cambia lo que se encuentra.
      final t = (await tags.list()).first;
      await tags.addTag(['b'], t.id);
      expect(await ids(const ItemFilter(text: 'huerfana')), {'b'});
      await tags.rename(t.id, 'Montaña');
      expect(await ids(const ItemFilter(text: 'huerfana')), isEmpty);
      expect(await ids(const ItemFilter(text: 'montaña')), {'b'});
    });

    test('% y _ no son comodines', () async {
      await env.addCloudItem('a', name: 'Cumple 100%.jpg');
      await env.addCloudItem('b', name: 'z.jpg');
      expect(await ids(const ItemFilter(text: '%')), {'a'});
      expect(await ids(const ItemFilter(text: '_')), isEmpty);
    });
  });
}
