// Fase 9 (v2): botón de filtros, chips activos y acción de etiquetas en la
// pantalla principal.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/features/vault/home_vault_screen.dart';

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

  Future<void> boot(WidgetTester t, {bool withTags = true}) async {
    await t.runAsync(() async {
      env = F6Env();
      await env.setUp();
      tags = TagRepository(dbProvider: () => env.vdb.database);
      await env.addFolder('f1');
      await env.addCloudItem('a', name: 'playa.jpg');
      await env.addCloudItem('b', name: 'monte.jpg', folderId: 'f1');
      viajes = await tags.create('Viajes');
      await tags.addTag(['b'], viajes.id);
    });
    addTearDown(() => t.runAsync(env.tearDown));
    usePhoneSize(t);
    await t.pumpWidget(
      testApp(
        HomeVaultScreen(
          currentFolderName: 'Mi Bóveda',
          services: fakeServices(env.items, tags: withTags ? tags : null),
        ),
      ),
    );
    await settle(t);
  }

  testWidgets('sin servicio de etiquetas no hay botón de filtros', (t) async {
    await boot(t, withTags: false);
    expect(find.byTooltip('Filtros'), findsNothing);
  });

  testWidgets('filtrar por etiqueta: resultados globales, chip y limpiar', (
    t,
  ) async {
    await boot(t);
    expect(find.byTooltip('Filtros'), findsOneWidget);
    expect(find.byKey(const ValueKey('active-filters')), findsNothing);
    await t.tap(find.byTooltip('Filtros'));
    await settle(t);
    await t.tap(find.text('Viajes'));
    await t.pump();
    await t.tap(find.text('Aplicar'));
    await settle(t);
    expect(find.text('Resultados en toda la bóveda'), findsOneWidget);
    expect(find.byKey(const ValueKey('active-filters')), findsOneWidget);
    expect(find.byKey(ValueKey('chip-tag-${viajes.id}')), findsOneWidget);
    // 'b' vive en una subcarpeta y aparece igualmente.
    expect(find.textContaining('monte'), findsWidgets);
    expect(find.textContaining('playa'), findsNothing);
    // Quitar el chip vuelve a la carpeta.
    await t.tap(find.byTooltip('Quitar filtro Viajes'));
    await settle(t);
    expect(find.byKey(const ValueKey('active-filters')), findsNothing);
    expect(find.text('Mi Bóveda'), findsOneWidget);
  });

  testWidgets('sin coincidencias: estado vacío y "Limpiar" con 2 filtros', (
    t,
  ) async {
    await boot(t);
    await t.tap(find.byTooltip('Filtros'));
    await settle(t);
    await t.tap(find.text('Viajes'));
    await t.tap(find.byKey(const ValueKey('kind-video')));
    await t.pump();
    await t.tap(find.text('Aplicar'));
    await settle(t);
    expect(find.text('Nada coincide con los filtros'), findsOneWidget);
    expect(find.byKey(const ValueKey('chip-clear')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('chip-clear')));
    await settle(t);
    expect(find.byKey(const ValueKey('active-filters')), findsNothing);
    expect(find.text('Nada coincide con los filtros'), findsNothing);
  });

  testWidgets('selección: acción Etiquetas solo con archivos', (t) async {
    await boot(t);
    // Carpeta sola: sin acción.
    await t.longPress(find.textContaining('Carpeta f1'));
    await settle(t);
    expect(find.byTooltip('Etiquetas'), findsNothing);
    await t.tap(find.byTooltip('Cancelar selección'));
    await settle(t);
    // Un archivo: aparece y abre la hoja.
    await t.longPress(find.textContaining('playa'));
    await settle(t);
    expect(find.byTooltip('Etiquetas'), findsOneWidget);
    await t.tap(find.byTooltip('Etiquetas'));
    await settle(t);
    expect(find.text('Viajes'), findsWidgets);
    expect(find.text('Nueva etiqueta'), findsWidgets);
  });
}
