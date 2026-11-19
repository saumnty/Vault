// Fase 9 (v2): el controlador con filtros es una búsqueda global.
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/features/vault/models/browser_entry.dart';
import 'package:vault/features/vault/vault_browser_controller.dart';

import 'support/f6_env.dart';
import 'support/ui_helpers.dart';

void main() {
  late F6Env env;
  late TagRepository tags;
  late VaultBrowserController c;
  late TagModel viajes;

  setUp(() async {
    env = F6Env();
    await env.setUp();
    tags = TagRepository(dbProvider: () => env.vdb.database);
    await env.addFolder('f1');
    await env.addCloudItem('a', name: 'playa.jpg');
    await env.addCloudItem(
      'b',
      name: 'clip.mp4',
      mime: 'video/mp4',
      folderId: 'f1',
    );
    await env.addCloudItem('c', name: 'notas.pdf', mime: 'application/pdf');
    viajes = await tags.create('Viajes');
    await tags.addTag(['a', 'b'], viajes.id);
    c = VaultBrowserController(
      services: fakeServices(env.items, tags: tags),
      folderId: null,
    );
    await c.load();
  });

  tearDown(() async {
    c.dispose();
    await env.tearDown();
  });

  List<String> ids() => [
    for (final e in c.entries)
      if (e is FileEntry) e.item.id,
  ];

  test('sin filtros: carpeta actual con carpetas', () {
    expect(c.isFiltering, isFalse);
    expect(c.entries.whereType<FolderEntry>().length, 1);
    expect(ids().toSet(), {'a', 'c'});
  });

  test('con filtros busca en TODAS las carpetas y sin carpetas', () async {
    await c.setFilter(ItemFilter(tagIds: {viajes.id}));
    expect(c.isFiltering, isTrue);
    expect(c.entries.whereType<FolderEntry>(), isEmpty);
    expect(ids().toSet(), {'a', 'b'}); // 'b' vive en f1
  });

  test('tipo + texto de búsqueda se combinan', () async {
    await c.setFilter(const ItemFilter(kind: KindFilter.video));
    expect(ids(), ['b']);
    await c.setFilter(const ItemFilter(kind: KindFilter.file));
    expect(ids(), ['c']);
    await c.setFilter(const ItemFilter(kind: KindFilter.photo));
    c.setQuery('pla');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ids(), ['a']);
    c.setQuery('zzz');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ids(), isEmpty);
  });

  Future<void> settleQuery() =>
      Future<void>.delayed(const Duration(milliseconds: 100));

  test('v2.1: sin filtros, la búsqueda también casa por etiqueta', () async {
    // 'a' está etiquetada «Viajes»; 'c' no; 'b' está en otra carpeta.
    c.setQuery('VIAJÉS'.replaceAll('É', 'E'));
    await settleQuery();
    expect(ids(), ['a']); // solo la carpeta actual
    c.setQuery('viaj');
    await settleQuery();
    expect(ids(), ['a']);
    c.setQuery('notas'); // por nombre, como siempre
    await settleQuery();
    expect(ids(), ['c']);
    c.setQuery('');
    await settleQuery();
    expect(ids().toSet(), {'a', 'c'});
    // Etiquetar 'c' con la búsqueda activa la hace aparecer.
    c.setQuery('viajes');
    await settleQuery();
    await c.setTag(
      [FileEntry((await env.items.getItem('c'))!)],
      viajes.id,
      on: true,
    );
    expect(ids().toSet(), {'a', 'c'});
  });

  test('v2.1: con filtros activos el texto casa por etiqueta (Y)', () async {
    final fam = await tags.create('Familia');
    await tags.addTag(['c'], fam.id);
    await c.setFilter(const ItemFilter(kind: KindFilter.file));
    c.setQuery('familia');
    await settleQuery();
    expect(ids(), ['c']); // tipo archivo Y etiqueta «Familia»
    c.setQuery('viajes');
    await settleQuery();
    expect(ids(), isEmpty); // 'a' y 'b' no son «archivo»
  });

  test('clearFilters vuelve a la carpeta actual', () async {
    await c.setFilter(ItemFilter(tagIds: {viajes.id}));
    await c.clearFilters();
    expect(c.isFiltering, isFalse);
    expect(c.entries.whereType<FolderEntry>().length, 1);
    expect(ids().toSet(), {'a', 'c'});
  });

  test('setTag y tagsOf asignan/quitan y se reflejan en el filtro', () async {
    final entry = FileEntry((await env.items.getItem('c'))!);
    await c.setFilter(ItemFilter(tagIds: {viajes.id}));
    expect(ids().toSet(), {'a', 'b'});
    await c.setTag([entry], viajes.id, on: true);
    expect(ids().toSet(), {'a', 'b', 'c'});
    expect((await c.tagsOf([entry]))['c']!.single.id, viajes.id);
    await c.setTag([entry], viajes.id, on: false);
    expect(ids().toSet(), {'a', 'b'});
  });

  test('setFilter limpia la selección', () async {
    c.selectAll();
    expect(c.isSelecting, isTrue);
    await c.setFilter(ItemFilter(tagIds: {viajes.id}));
    expect(c.isSelecting, isFalse);
  });

  test('sin servicio de etiquetas los filtros no aplican', () async {
    final plain = VaultBrowserController(
      services: fakeServices(env.items),
      folderId: null,
    );
    addTearDown(plain.dispose);
    await plain.setFilter(const ItemFilter(kind: KindFilter.video));
    expect(plain.isFiltering, isFalse);
  });
}
