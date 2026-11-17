// Fase 9 (v2): Ajustes > Etiquetas.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/features/settings/tags_screen.dart';

import '../support/f6_env.dart';
import '../support/ui_helpers.dart';

void main() {
  late F6Env env;
  late TagRepository tags;
  late TagModel viajes;

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> boot(WidgetTester t, {bool seed = true}) async {
    await t.runAsync(() async {
      env = F6Env();
      await env.setUp();
      tags = TagRepository(dbProvider: () => env.vdb.database);
      if (seed) {
        await env.addCloudItem('a', name: 'a.jpg');
        await env.addCloudItem('b', name: 'b.jpg');
        viajes = await tags.create('Viajes');
        await tags.create('Trabajo');
        await tags.addTag(['a', 'b'], viajes.id);
      }
    });
    addTearDown(() => t.runAsync(env.tearDown));
    usePhoneSize(t);
    await t.pumpWidget(testApp(TagsScreen(repository: tags)));
    await settle(t);
  }

  Future<List<String>> names(WidgetTester t) async =>
      (await t.runAsync(() => tags.list()))!.map((x) => x.name).toList();

  testWidgets('lista etiquetas con su número de archivos', (t) async {
    await boot(t);
    expect(find.text('Viajes'), findsOneWidget);
    expect(find.text('2 archivos'), findsOneWidget);
    expect(find.text('Trabajo'), findsOneWidget);
    expect(find.text('0 archivos'), findsOneWidget);
  });

  testWidgets('sin etiquetas: mensaje vacío', (t) async {
    await boot(t, seed: false);
    expect(find.byKey(const ValueKey('tags-empty')), findsOneWidget);
  });

  testWidgets('crear una etiqueta', (t) async {
    await boot(t);
    await t.tap(find.byKey(const ValueKey('create-tag')));
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('tag-name-field')), 'Familia');
    await t.tap(find.text('Crear'));
    await settle(t);
    expect(find.text('Familia'), findsOneWidget);
    expect(await names(t), contains('Familia'));
  });

  testWidgets('crear con nombre duplicado muestra error y no cierra', (
    t,
  ) async {
    await boot(t);
    await t.tap(find.byKey(const ValueKey('create-tag')));
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('tag-name-field')), 'viajes');
    await t.tap(find.text('Crear'));
    await settle(t);
    expect(find.textContaining('Ya existe una etiqueta'), findsOneWidget);
    expect((await names(t)).length, 2);
  });

  testWidgets('crear con nombre vacío muestra error', (t) async {
    await boot(t);
    await t.tap(find.byKey(const ValueKey('create-tag')));
    await settle(t);
    await t.tap(find.text('Crear'));
    await settle(t);
    expect(find.textContaining('no puede estar vacío'), findsOneWidget);
  });

  testWidgets('renombrar y rechazar un nombre duplicado', (t) async {
    await boot(t);
    await t.tap(find.byTooltip('Renombrar Viajes'));
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('tag-name-field')), 'Trabajo');
    await t.tap(find.text('Guardar'));
    await settle(t);
    expect(find.textContaining('Ya existe una etiqueta'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('tag-name-field')), 'Vacaciones');
    await t.tap(find.text('Guardar'));
    await settle(t);
    expect(find.text('Vacaciones'), findsOneWidget);
    expect(find.text('Viajes'), findsNothing);
    expect(await names(t), containsAll(['Vacaciones', 'Trabajo']));
  });

  testWidgets('eliminar pide confirmación y no borra archivos', (t) async {
    await boot(t);
    await t.tap(find.byTooltip('Eliminar Viajes'));
    await settle(t);
    expect(
      find.textContaining('Se quitará de 2 archivos; los archivos no se borran'),
      findsOneWidget,
    );
    // Cancelar: sigue.
    await t.tap(find.text('Cancelar'));
    await settle(t);
    expect(find.text('Viajes'), findsOneWidget);
    // Confirmar.
    await t.tap(find.byTooltip('Eliminar Viajes'));
    await settle(t);
    await t.tap(find.text('Eliminar etiqueta'));
    await settle(t);
    expect(find.text('Viajes'), findsNothing);
    expect(await names(t), ['Trabajo']);
    final items = await t.runAsync(() => env.items.getItemsByFolder(null));
    expect(items!.length, 2);
  });
}
