import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/features/auth/pin_screen.dart';
import 'package:vault/features/vault/home_vault_screen.dart';
import 'package:vault/features/vault/widgets/swipe_action_row.dart';

import '../support/fakes.dart';
import '../support/ui_helpers.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Los IconButton exponen su etiqueta como tooltip semántico (lo leen
/// TalkBack/VoiceOver) además del texto de ayuda visual.
void _expectLabeledButton(WidgetTester tester, String label) {
  final finder = find.byTooltip(label);
  expect(finder, findsOneWidget, reason: label);
  final data = tester.getSemantics(finder).getSemanticsData();
  expect(
    data.tooltip == label || data.label.contains(label),
    isTrue,
    reason: 'sin etiqueta semántica: $label',
  );
}

void main() {
  group('Pantalla de PIN', () {
    Future<void> pump(WidgetTester tester) async {
      usePhoneSize(tester);
      final controller = AuthController(
        storage: InMemorySecureStore(),
        biometricStore: FakeBiometricKeyStore(),
        kdfParams: fastKdf,
        session: VaultSession.create(),
      );
      await tester.pumpWidget(
        testApp(PinScreen(authController: controller, onAuthenticated: () {})),
      );
      await tester.pump();
    }

    testWidgets('teclas con etiqueta y área táctil >= 44', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      for (final d in '0123456789'.split('')) {
        expect(find.bySemanticsLabel('Dígito $d'), findsOneWidget);
      }
      expect(find.bySemanticsLabel('Borrar'), findsOneWidget);
      expect(find.bySemanticsLabel('PIN: 0 de 6 dígitos'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('contraste de texto suficiente', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  group('Bóveda', () {
    final repo = FakeVaultRepository(
      folders: [fakeFolder('d1', 'Viajes')],
      items: [
        fakeItem('1', status: SyncStatus.error),
        fakeItem('2', mime: 'video/mp4', name: 'clip.mp4'),
      ],
    );

    Future<void> pump(WidgetTester tester) async {
      usePhoneSize(tester);
      await tester.pumpWidget(
        testApp(
          HomeVaultScreen(
            currentFolderName: 'Mi Bóveda',
            services: fakeServices(repo),
          ),
        ),
      );
      await _settle(tester);
    }

    testWidgets('celdas con etiqueta en español (tipo, tamaño, estado)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        find.bySemanticsLabel(
          'Imagen IMG_1.jpg, 2,00 MB, Error de sincronización',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Video clip.mp4, 2,00 MB, En la nube'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Carpeta Viajes'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('botones con etiqueta y áreas táctiles >= 44', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      for (final label in ['Buscar', 'Ver como lista']) {
        _expectLabeledButton(tester, label);
      }
      expect(find.bySemanticsLabel('Añadir'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('modo selección: acciones etiquetadas y >= 44', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await tester.longPress(find.text('IMG_1.jpg'));
      await _settle(tester);
      for (final label in [
        'Cancelar selección',
        'Seleccionar todo',
        'Mover',
        'Disponible sin conexión',
        'Eliminar',
      ]) {
        _expectLabeledButton(tester, label);
      }
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets(
      'la fila de lista expone sus acciones como acciones semánticas',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        await tester.tap(find.byTooltip('Ver como lista'));
        await _settle(tester);
        final data = tester
            .getSemantics(find.byType(SwipeActionRow).first)
            .getSemanticsData();
        expect(data.customSemanticsActionIds?.length, greaterThanOrEqualTo(3));
        handle.dispose();
      },
    );
  });
}
