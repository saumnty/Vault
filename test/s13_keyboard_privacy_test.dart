// S-13: el teclado no debe aprender ni sugerir nombres de carpetas ni
// búsquedas de la bóveda (docs/REPORTE.md, "Revisión de seguridad
// independiente"). Comprueba las propiedades del TextField real.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/features/vault/widgets/search_field.dart';
import 'package:vault/features/vault/widgets/vault_sheets.dart';

void _expectPrivateKeyboard(TextField field) {
  expect(field.autocorrect, isFalse);
  expect(field.enableSuggestions, isFalse);
  expect(field.enableIMEPersonalizedLearning, isFalse);
}

void main() {
  testWidgets('S-13 campo de nombre de carpeta sin aprendizaje del teclado', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NewFolderContent())),
    );
    await tester.pump();

    _expectPrivateKeyboard(tester.widget<TextField>(find.byType(TextField)));
  });

  testWidgets('S-13 campo de búsqueda sin aprendizaje del teclado', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultSearchField(
            controller: controller,
            onChanged: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    _expectPrivateKeyboard(tester.widget<TextField>(find.byType(TextField)));
  });
}
