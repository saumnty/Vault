import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/widgets/breadcrumb_bar.dart';

import '../support/ui_helpers.dart';

void main() {
  testWidgets('BreadcrumbBar muestra la ruta y avisa de la migaja pulsada', (
    tester,
  ) async {
    Crumb? tapped;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: BreadcrumbBar(
            crumbs: const [
              Crumb(id: null, label: 'Mi Bóveda'),
              Crumb(id: 'a', label: 'Viajes'),
              Crumb(id: 'b', label: '2025'),
            ],
            onTap: (c) => tapped = c,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Mi Bóveda'), findsOneWidget);
    expect(find.text('Viajes'), findsOneWidget);
    expect(find.text('2025'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));

    await tester.tap(find.text('Viajes'));
    expect(tapped?.id, 'a');
    tapped = null;
    // La actual no es pulsable.
    await tester.tap(find.text('2025'));
    expect(tapped, isNull);

    // Semántica en español.
    expect(find.bySemanticsLabel('Ir a Mi Bóveda'), findsOneWidget);
    expect(find.bySemanticsLabel('Carpeta actual: 2025'), findsOneWidget);
  });

  testWidgets('las migajas miden al menos 44 px de alto', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: BreadcrumbBar(
            crumbs: const [
              Crumb(id: null, label: 'Mi Bóveda'),
              Crumb(id: 'a', label: 'X'),
            ],
            onTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    final size = tester.getSize(
      find.ancestor(of: find.text('Mi Bóveda'), matching: find.byType(InkWell)),
    );
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.width, greaterThanOrEqualTo(44));
  });

  testWidgets(
    'en una subcarpeta la barra usa getBreadcrumbs y permite volver',
    (tester) async {
      usePhoneSize(tester);
      final repo = FakeVaultRepository(
        folders: [
          fakeFolder('a', 'Viajes'),
          fakeFolder('b', '2025', parentId: 'a'),
        ],
      );
      final services = fakeServices(repo);
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(currentFolderName: 'Mi Bóveda', services: services),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // En la raíz no hay migas (solo título).
      expect(find.byType(BreadcrumbBar), findsNothing);

      await tester.tap(find.text('Viajes'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('2025'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      // Pila: Mi Bóveda > Viajes > 2025.
      expect(find.byType(BreadcrumbBar), findsOneWidget);
      final bar = find.byType(BreadcrumbBar);
      expect(
        find.descendant(of: bar, matching: find.text('Mi Bóveda')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('Viajes')),
        findsOneWidget,
      );

      // Tocar "Mi Bóveda" vuelve a la raíz.
      await tester.tap(
        find.descendant(of: bar, matching: find.text('Mi Bóveda')),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BreadcrumbBar), findsNothing);
      expect(find.text('Viajes'), findsOneWidget);
    },
  );
}
