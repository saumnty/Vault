// Fase 9 (v2): hoja de filtros.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/data/tags/tag_repository.dart';
import 'package:vault/features/vault/widgets/filter_sheet.dart';

import '../support/f6_env.dart';
import '../support/ui_helpers.dart';

void main() {
  late F6Env env;
  late TagRepository tags;
  ItemFilter? result;
  var closed = false;

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> open(
    WidgetTester t, {
    ItemFilter current = const ItemFilter(text: 'playa'),
    List<String> tagNames = const ['Viajes', 'Trabajo'],
  }) async {
    await t.runAsync(() async {
      env = F6Env();
      await env.setUp();
      tags = TagRepository(dbProvider: () => env.vdb.database);
      for (final n in tagNames) {
        await tags.create(n);
      }
    });
    addTearDown(() => t.runAsync(env.tearDown));
    result = null;
    closed = false;
    usePhoneSize(t);
    await t.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showFilterSheet(
                context,
                tags: tags,
                current: current,
              );
              closed = true;
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await t.tap(find.text('abrir'));
    await settle(t);
  }

  testWidgets('muestra tipo, etiquetas y fechas', (t) async {
    await open(t);
    expect(find.text('Filtros'), findsOneWidget);
    for (final s in ['Todo', 'Fotos', 'Videos', 'Archivos']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('Viajes'), findsOneWidget);
    expect(find.text('Trabajo'), findsOneWidget);
    expect(find.text('Desde'), findsOneWidget);
    expect(find.text('Hasta'), findsOneWidget);
    expect(find.text('Aplicar'), findsOneWidget);
    expect(find.text('Limpiar'), findsOneWidget);
  });

  testWidgets('sin etiquetas muestra el aviso', (t) async {
    await open(t, tagNames: const []);
    expect(find.text('Aún no tienes etiquetas'), findsOneWidget);
  });

  testWidgets('aplica tipo y etiquetas y conserva el texto', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('kind-video')));
    await t.pump();
    await t.tap(find.text('Viajes'));
    await t.tap(find.text('Trabajo'));
    await t.pump();
    await t.tap(find.text('Aplicar'));
    await settle(t);
    expect(closed, isTrue);
    expect(result!.text, 'playa');
    expect(result!.kind, KindFilter.video);
    expect(result!.tagIds.length, 2);
  });

  testWidgets('elegir "Todo" quita el tipo', (t) async {
    await open(t, current: const ItemFilter(kind: KindFilter.photo));
    await t.tap(find.byKey(const ValueKey('kind-all')));
    await t.pump();
    await t.tap(find.text('Aplicar'));
    await settle(t);
    expect(result!.kind, isNull);
  });

  testWidgets('rango de fechas: elegir y quitar', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('date-from')));
    await settle(t);
    await t.tap(find.text('15').first);
    await t.pump();
    await t.tap(find.text('Aceptar'));
    await settle(t);
    final now = DateTime.now();
    expect(
      find.text(formatFilterDate(DateTime(now.year, now.month, 15))),
      findsOneWidget,
    );
    // Quitar el "Desde".
    await t.tap(find.byTooltip('Quitar fecha Desde'));
    await t.pump();
    expect(find.text('Sin definir'), findsNWidgets(2));
    // Elegir de nuevo y aplicar.
    await t.tap(find.byKey(const ValueKey('date-from')));
    await settle(t);
    await t.tap(find.text('15').first);
    await t.pump();
    await t.tap(find.text('Aceptar'));
    await settle(t);
    await t.tap(find.text('Aplicar'));
    await settle(t);
    expect(result!.from, DateTime(now.year, now.month, 15));
    expect(result!.to, isNull);
  });

  testWidgets('Limpiar devuelve el filtro vacío pero conserva el texto', (
    t,
  ) async {
    await open(
      t,
      current: ItemFilter(
        text: 'playa',
        kind: KindFilter.photo,
        tagIds: const {'x'},
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 2, 1),
      ),
    );
    await t.tap(find.text('Limpiar'));
    await settle(t);
    expect(closed, isTrue);
    expect(result!.hasFilters, isFalse);
    expect(result!.text, 'playa');
  });
}
