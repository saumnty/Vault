import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/theme/app_spacing.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/vault_services.dart';
import 'package:vault/features/vault/widgets/file_tile.dart';
import 'package:vault/features/vault/widgets/folder_tile.dart';
import 'package:vault/features/vault/widgets/swipe_action_row.dart';
import 'package:vault/features/vault/widgets/sync_status_icon.dart';
import 'package:vault/features/vault/widgets/thumbnail_view.dart';
import 'package:vault/shared/widgets/shimmer.dart';

import '../support/ui_helpers.dart';

FakeVaultRepository _repo() => FakeVaultRepository(
  folders: [fakeFolder('d1', 'Viajes'), fakeFolder('d2', 'Documentos')],
  items: [
    for (var i = 1; i <= 6; i++)
      fakeItem('$i', status: SyncStatus.values[i - 1]),
  ],
);

Future<void> _open(
  WidgetTester tester,
  FakeVaultRepository repo, {
  ServiceCalls? calls,
  ThumbnailLoader? thumbs,
  int columns = AppGrid.defaultColumns,
}) async {
  usePhoneSize(tester);
  await tester.pumpWidget(
    testApp(
      HomeVaultScreen(
        currentFolderName: 'Mi Bóveda',
        services: fakeServices(repo, calls: calls, thumbnails: thumbs),
        initialColumns: columns,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Mantiene el hilo vivo: shimmer es infinito, así que no se usa settle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Pellizco con eventos pequeños, como un gesto real.
Future<void> _pinch(
  WidgetTester tester,
  Offset center, {
  required double from,
  required double to,
}) async {
  final a = await tester.startGesture(center - Offset(from / 2, 0));
  final b = await tester.startGesture(center + Offset(from / 2, 0));
  final steps = ((to - from).abs() / 4).ceil();
  final dir = to > from ? 1.0 : -1.0;
  for (var i = 0; i < steps; i++) {
    await a.moveBy(Offset(-2 * dir, 0));
    await b.moveBy(Offset(2 * dir, 0));
  }
  await a.up();
  await b.up();
  await tester.pump();
}

void main() {
  testWidgets('renderiza carpetas y archivos falsos en cuadrícula de 3', (
    tester,
  ) async {
    await _open(tester, _repo());
    expect(find.byType(FolderTile), findsNWidgets(2));
    expect(find.byType(FileTile), findsNWidgets(6));
    expect(find.text('Viajes'), findsOneWidget);
    expect(find.text('IMG_1.jpg'), findsOneWidget);
  });

  testWidgets('cada estado de sincronización tiene su ícono y etiqueta', (
    tester,
  ) async {
    await _open(tester, _repo());
    expect(find.byType(SyncStatusIcon), findsNWidgets(6));
    for (final s in SyncStatus.values) {
      expect(
        find.bySemanticsLabel(RegExp(syncStatusLabel(s))),
        findsWidgets,
        reason: s.name,
      );
    }
    // subiendo muestra anillo de progreso
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets(
    'selección múltiple: mantener presiona, tocar suma, cerrar limpia',
    (tester) async {
      await _open(tester, _repo());
      expect(find.text('seleccionados'), findsNothing);

      await tester.longPress(find.text('IMG_1.jpg'));
      await _settle(tester);
      expect(find.text('1 seleccionado'), findsOneWidget);

      await tester.tap(find.text('IMG_2.jpg'));
      await tester.tap(find.text('Viajes'));
      await _settle(tester);
      expect(find.text('3 seleccionados'), findsOneWidget);

      // Tocar uno ya seleccionado lo quita.
      await tester.tap(find.text('IMG_2.jpg'));
      await _settle(tester);
      expect(find.text('2 seleccionados'), findsOneWidget);

      await tester.tap(find.byTooltip('Seleccionar todo'));
      await _settle(tester);
      expect(find.text('8 seleccionados'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancelar selección'));
      await _settle(tester);
      expect(find.textContaining('seleccionado'), findsNothing);
    },
  );

  testWidgets('eliminar la selección pide confirmación y limpia archivos', (
    tester,
  ) async {
    final calls = ServiceCalls();
    final repo = _repo();
    await _open(tester, repo, calls: calls);
    await tester.longPress(find.text('IMG_1.jpg'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Eliminar'));
    await _settle(tester);
    expect(find.text('¿Eliminar 1 elemento?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await _settle(tester);
    await _settle(tester);
    expect(repo.items.length, 5);
    expect(calls.cleaned.single, ['1']);
    expect(find.text('IMG_1.jpg'), findsNothing);
  });

  testWidgets('pellizco de dos dedos cambia el número de columnas', (
    tester,
  ) async {
    await _open(tester, _repo());
    int columns() => tester
        .widget<SliverGrid>(find.byType(SliverGrid))
        .gridDelegate
        .let(
          (d) =>
              (d as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount,
        );

    expect(columns(), 3);
    final center = tester.getCenter(find.byType(CustomScrollView));

    // Alejar dedos (acercar): menos columnas.
    await _pinch(tester, center, from: 80, to: 108);
    expect(columns(), 2);

    // Juntar dedos: más columnas.
    await _pinch(tester, center, from: 200, to: 156);
    expect(columns(), 3);
  });

  testWidgets('el botón de vista alterna cuadrícula y lista (1 columna)', (
    tester,
  ) async {
    await _open(tester, _repo());
    await tester.tap(find.byTooltip('Ver como lista'));
    await _settle(tester);
    expect(find.byType(SliverGrid), findsNothing);
    expect(find.byType(SwipeActionRow), findsNWidgets(8));
    await tester.tap(find.byTooltip('Ver como cuadrícula'));
    await _settle(tester);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('deslizar una fila revela mover, sin conexión y eliminar', (
    tester,
  ) async {
    final calls = ServiceCalls();
    await _open(tester, _repo(), calls: calls, columns: 1);
    expect(find.text('Eliminar'), findsNothing);

    await tester.drag(find.text('IMG_1.jpg'), const Offset(-300, 0));
    await _settle(tester);
    expect(find.text('Mover'), findsOneWidget);
    expect(find.text('Sin conexión'), findsOneWidget);
    expect(find.text('Eliminar'), findsOneWidget);

    await tester.tap(find.text('Sin conexión'));
    await _settle(tester);
    expect(calls.offline, ['1']);
  });

  testWidgets('pull-to-refresh dispara la sincronización', (tester) async {
    final calls = ServiceCalls();
    await _open(tester, _repo(), calls: calls);
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 400),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(calls.syncs, 1);
  });

  testWidgets('búsqueda filtra por nombre y muestra "sin resultados"', (
    tester,
  ) async {
    await _open(tester, _repo());
    await tester.tap(find.byTooltip('Buscar'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'IMG_3');
    await _settle(tester);
    expect(find.byType(FileTile), findsOneWidget);
    expect(find.byType(FolderTile), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await _settle(tester);
    expect(find.text('Sin resultados'), findsOneWidget);

    await tester.tap(find.byTooltip('Cerrar búsqueda'));
    await _settle(tester);
    expect(find.byType(FileTile), findsNWidgets(6));
  });

  testWidgets('carpeta vacía muestra el estado vacío con mensaje útil', (
    tester,
  ) async {
    await _open(tester, FakeVaultRepository());
    expect(find.text('Tu bóveda está vacía'), findsOneWidget);
    expect(find.textContaining('Toca +'), findsOneWidget);
  });

  testWidgets(
    'skeleton con shimmer mientras carga la miniatura y luego imagen',
    (tester) async {
      final png = await tester.runAsync(
        () => makeThumbPng(Colors.indigo, Colors.pink),
      );
      final completer = Completer<void>();
      await _open(
        tester,
        FakeVaultRepository(items: [fakeItem('1')]),
        thumbs: (item) => completer.future.then((_) => MemoryImage(png!)),
      );
      expect(find.byType(Shimmer), findsWidgets);
      expect(find.byType(Image), findsNothing);

      completer.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ThumbnailView), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets('FAB expandible muestra las tres acciones', (tester) async {
    final calls = ServiceCalls();
    await _open(tester, _repo(), calls: calls);
    expect(find.text('Importar archivo'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Añadir'));
    await _settle(tester);
    expect(find.text('Nueva carpeta'), findsOneWidget);
    expect(find.text('Importar archivo'), findsOneWidget);
    expect(find.text('Importar desde galería'), findsOneWidget);

    await tester.tap(find.text('Importar archivo'));
    await _settle(tester);
    expect(find.text('Importar al Vault'), findsOneWidget);
    await tester.tap(find.text('Cifrar y conservar original'));
    await _settle(tester);
    await _settle(tester);
    expect(calls.imports, 1);
  });

  testWidgets('crear carpeta nueva desde el FAB', (tester) async {
    final repo = _repo();
    await _open(tester, repo);
    await tester.tap(find.bySemanticsLabel('Añadir'));
    await _settle(tester);
    await tester.tap(find.text('Nueva carpeta'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Fotos 2026');
    await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
    await _settle(tester);
    await _settle(tester);
    expect(repo.folders.map((f) => f.name), contains('Fotos 2026'));
    expect(find.text('Fotos 2026'), findsOneWidget);
  });
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
