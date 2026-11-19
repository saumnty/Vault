// Fase 9 (v2): hoja de etiquetas de la selección múltiple.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/features/vault/models/browser_entry.dart';
import 'package:vault/features/vault/vault_browser_controller.dart';
import 'package:vault/features/vault/widgets/tags_sheet.dart';

import '../support/f6_env.dart';
import '../support/ui_helpers.dart';

void main() {
  late F6Env env;
  late TagRepository tags;
  late VaultBrowserController controller;
  late TagModel viajes;
  late TagModel trabajo;

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> open(WidgetTester t) async {
    late List<BrowserEntry> targets;
    await t.runAsync(() async {
      env = F6Env();
      await env.setUp();
      tags = TagRepository(dbProvider: () => env.vdb.database);
      await env.addCloudItem('a', name: 'a.jpg');
      await env.addCloudItem('b', name: 'b.jpg');
      viajes = await tags.create('Viajes');
      trabajo = await tags.create('Trabajo');
      // Viajes en los dos; Trabajo solo en 'a'.
      await tags.addTag(['a', 'b'], viajes.id);
      await tags.addTag(['a'], trabajo.id);
      targets = [
        FileEntry((await env.items.getItem('a'))!),
        FileEntry((await env.items.getItem('b'))!),
      ];
      controller = VaultBrowserController(
        services: fakeServices(env.items, tags: tags),
        folderId: null,
      );
    });
    addTearDown(() => t.runAsync(env.tearDown));
    addTearDown(controller.dispose);
    usePhoneSize(t);
    await t.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTagsSheet(
              context,
              controller: controller,
              targets: targets,
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await t.tap(find.text('abrir'));
    await settle(t);
  }

  bool checked(WidgetTester t, String id) => t
      .widget<Checkbox>(
        find.descendant(
          of: find.byKey(ValueKey('tag-row-$id')),
          matching: find.byType(Checkbox),
        ),
      )
      .value!;

  Future<Set<String>> tagsOf(WidgetTester t, String item) async {
    final list = await t.runAsync(() => tags.tagsOfItem(item));
    return {for (final x in list!) x.name};
  }

  testWidgets('marca solo lo que TODOS los archivos tienen', (t) async {
    await open(t);
    expect(find.text('Etiquetas'), findsOneWidget);
    expect(checked(t, viajes.id), isTrue);
    expect(checked(t, trabajo.id), isFalse);
  });

  testWidgets('marcar asigna a todos y desmarcar quita de todos', (t) async {
    await open(t);
    await t.tap(find.byKey(ValueKey('tag-row-${trabajo.id}')));
    await settle(t);
    expect(checked(t, trabajo.id), isTrue);
    expect(await tagsOf(t, 'b'), {'Viajes', 'Trabajo'});
    await t.tap(find.byKey(ValueKey('tag-row-${viajes.id}')));
    await settle(t);
    expect(checked(t, viajes.id), isFalse);
    expect(await tagsOf(t, 'a'), {'Trabajo'});
    expect(await tagsOf(t, 'b'), {'Trabajo'});
  });

  testWidgets('crear una etiqueta nueva la asigna a la selección', (t) async {
    await open(t);
    await t.enterText(find.byKey(const ValueKey('new-tag-field')), 'Familia');
    await t.tap(find.text('Crear'));
    await settle(t);
    expect(find.text('Familia'), findsWidgets);
    expect(await tagsOf(t, 'a'), contains('Familia'));
    expect(await tagsOf(t, 'b'), contains('Familia'));
  });

  testWidgets('nombre duplicado: reutiliza la existente y la asigna', (
    t,
  ) async {
    await open(t);
    await t.enterText(find.byKey(const ValueKey('new-tag-field')), 'trabajo');
    await t.tap(find.text('Crear'));
    await settle(t);
    final all = await t.runAsync(() => tags.list());
    expect(all!.length, 2);
    expect(await tagsOf(t, 'b'), contains('Trabajo'));
    expect(checked(t, trabajo.id), isTrue);
  });

  testWidgets('nombre vacío o demasiado largo muestra un error claro', (
    t,
  ) async {
    await open(t);
    await t.tap(find.text('Crear'));
    await settle(t);
    expect(find.text('Escribe un nombre para la etiqueta'), findsOneWidget);
    await t.enterText(
      find.byKey(const ValueKey('new-tag-field')),
      'x' * (kTagNameMax + 1),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('tags-sheet-error')), findsNothing);
    await t.tap(find.text('Crear'));
    await settle(t);
    expect(find.textContaining('demasiado largo'), findsOneWidget);
    final all = await t.runAsync(() => tags.list());
    expect(all!.length, 2);
  });
}
