import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/shared/widgets/empty_state.dart';

import '../support/ui_helpers.dart';

void main() {
  testWidgets('EmptyState muestra título, mensaje y acción', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: EmptyState(
            title: 'Tu bóveda está vacía',
            message: 'Toca + para importar.',
            actionLabel: 'Importar archivo',
            onAction: () => pressed++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Tu bóveda está vacía'), findsOneWidget);
    expect(find.text('Toca + para importar.'), findsOneWidget);
    // Ilustración hecha con CustomPaint (sin assets).
    expect(
      find.descendant(
        of: find.byType(EmptyState),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is EmptyIllustrationPainter,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Importar archivo'));
    expect(pressed, 1);
  });

  testWidgets('la variante de búsqueda usa otra ilustración', (tester) async {
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: EmptyState(
            kind: EmptyKind.search,
            title: 'Sin resultados',
            message: 'Prueba con otro nombre.',
          ),
        ),
      ),
    );
    await tester.pump();
    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is EmptyIllustrationPainter,
      ),
    );
    expect((paint.painter! as EmptyIllustrationPainter).kind, EmptyKind.search);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('el estado vacío se lee como un solo bloque semántico', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: EmptyState(title: 'Vacío', message: 'Importa algo.'),
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Vacío. Importa algo.'), findsOneWidget);
    handle.dispose();
  });
}
