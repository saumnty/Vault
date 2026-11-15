import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/features/onboarding/onboarding_flow.dart';
import 'package:vault/features/onboarding/restore_flow.dart';
import 'package:vault/features/onboarding/widgets/recovery_code_field.dart';

import '../support/fakes.dart';
import '../support/scripted_restore.dart';
import '../support/ui_helpers.dart';

const _typed = 'abcd efgh-jkmn pqrs tuvw xyz2';

Future<void> _digits(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.bySemanticsLabel('Dígito $d'));
    await tester.pump();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Elige un PIN y lo confirma en las dos pantallas de PIN.
Future<void> _pickPin(WidgetTester tester, String pin) async {
  await _digits(tester, pin);
  await _settle(tester);
  expect(find.text('Confirma tu PIN'), findsOneWidget);
  await _digits(tester, pin);
  await _settle(tester);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('restore-code-field')),
    text,
  );
  await tester.pump();
}

Future<AuthController> _auth() async => AuthController(
  storage: InMemorySecureStore(),
  biometricStore: FakeBiometricKeyStore(),
  kdfParams: fastKdf,
  session: VaultSession.create(),
);

class _Harness {
  _Harness(this.svc);
  final ScriptedRestoreService svc;
  RestoreResult? restored;
  int createNew = 0;
  int backs = 0;

  Widget flow({RestoreStep step = RestoreStep.start}) => testApp(
    Scaffold(
      body: SafeArea(
        child: RestoreFlow(
          service: svc,
          initialStep: step,
          onRestored: (r) => restored = r,
          onCreateNew: () => createNew++,
          onBack: () => backs++,
        ),
      ),
    ),
  );
}

void main() {
  group('campo del código (lógica)', () {
    test('tolera minúsculas, espacios y guiones', () {
      expect(evaluateRecoveryInput(_typed), CodeFieldState.valid);
      expect(evaluateRecoveryInput(''), CodeFieldState.empty);
      expect(evaluateRecoveryInput('ABCD-EF'), CodeFieldState.incomplete);
      expect(
        evaluateRecoveryInput('ABCD-EFGH-JKMN-PQRS-TUVW-XYZ0'),
        CodeFieldState.invalidChars,
      );
      expect(
        evaluateRecoveryInput('ABCDEFGHJKMNPQRSTUVWXYZ23'),
        CodeFieldState.incomplete, // 25: sobra uno
      );
    });

    test('mensajes en vivo', () {
      expect(recoveryInputHint(''), isNull);
      expect(recoveryInputHint('abcd'), 'Faltan 20 caracteres.');
      expect(
        recoveryInputHint('ABCDEFGHJKMNPQRSTUVWXYZ23'),
        contains('Sobran'),
      );
      expect(recoveryInputHint('0ABC'), contains('no forman parte'));
      expect(recoveryInputHint(_typed), isNull);
    });

    test('el formateador agrupa de 4 en 4 y limita a 24', () {
      const f = RecoveryCodeInputFormatter();
      final out = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: 'abcdefghjkmnpqrstuvwxyz2345678'),
      );
      expect(out.text, 'ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2');
      final partial = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: 'ab cd-ef!'),
      );
      expect(partial.text, 'ABCD-EF');
    });
  });

  group('RestoreFlow', () {
    testWidgets('sin respaldo: mensaje claro y dos salidas', (tester) async {
      usePhoneSize(tester);
      final h = _Harness(
        ScriptedRestoreService()..probeResult = RestoreProbeResult.noBackup,
      );
      await tester.pumpWidget(h.flow());
      expect(find.text('Restaurar tu bóveda'), findsOneWidget);
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);

      expect(
        find.text('No hay respaldo en esta cuenta de Google'),
        findsOneWidget,
      );
      expect(find.text('Usar otra cuenta'), findsOneWidget);
      await tester.tap(find.text('Crear una bóveda nueva'));
      await tester.pump();
      expect(h.createNew, 1);
    });

    testWidgets('respaldo incompleto o inválido tienen su propio mensaje', (
      tester,
    ) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..probeResult = RestoreProbeResult.incomplete;
      final h = _Harness(svc);
      await tester.pumpWidget(h.flow());
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      expect(find.text('El respaldo está incompleto'), findsOneWidget);

      svc.probeResult = RestoreProbeResult.invalid;
      await tester.tap(find.text('Usar otra cuenta'));
      await _settle(tester);
      expect(find.text('El respaldo no es válido'), findsOneWidget);
    });

    testWidgets('error de inicio de sesión se muestra; cancelar no es error', (
      tester,
    ) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..signInError = const CloudSignInFailedException('Falló Google');
      final h = _Harness(svc);
      await tester.pumpWidget(h.flow());
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      expect(find.text('Falló Google'), findsOneWidget);

      svc.signInError = const CloudSignInCancelledException();
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      expect(find.text('Falló Google'), findsNothing);
      expect(find.text('Restaurar tu bóveda'), findsOneWidget);
    });

    testWidgets('código: formato en vivo y validación; correo visible', (
      tester,
    ) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService();
      final h = _Harness(svc);
      await tester.pumpWidget(h.flow());
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      expect(find.text('Tu código de recuperación'), findsOneWidget);
      expect(find.text('persona@example.com'), findsOneWidget);

      FilledButton button() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continuar'),
      );
      expect(button().onPressed, isNull);

      await _type(tester, 'abcd efgh jk');
      expect(find.text('ABCD-EFGH-JK'), findsOneWidget);
      expect(find.text('Faltan 14 caracteres.'), findsOneWidget);
      expect(button().onPressed, isNull);

      await _type(tester, 'ABCD-EFGH-JKMN-PQRS-TUVW-XYZ0');
      expect(find.textContaining('no forman parte'), findsOneWidget);
      expect(button().onPressed, isNull);

      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2'), findsOneWidget);
      expect(button().onPressed, isNotNull);
    });

    testWidgets('código incorrecto: solo "Código incorrecto" y se puede '
        'reintentar', (tester) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService();
      final h = _Harness(svc);
      await tester.pumpWidget(h.flow());
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);

      await _type(tester, 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ');
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);
      expect(find.text('Código incorrecto'), findsOneWidget);
      expect(svc.wrongAttempts, 1);
      expect(svc.restoreCalls, 0);
      expect(find.text('Elige un PIN nuevo'), findsNothing);

      // Al editar desaparece el error.
      await _type(tester, 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZY');
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      expect(find.text('Código incorrecto'), findsNothing);
    });

    testWidgets('límite de intentos: avisa y bloquea el envío', (tester) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..lockout = const Duration(seconds: 29);
      final h = _Harness(svc);
      await tester.pumpWidget(h.flow(step: RestoreStep.code));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      expect(find.textContaining('Demasiados intentos'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Continuar'),
            )
            .onPressed,
        isNull,
      );
      expect(svc.submitted, isEmpty);
      // Dejar que venza el temporizador de espera.
      svc.lockout = null;
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets('camino feliz: código -> PIN dos veces -> progreso -> listo', (
      tester,
    ) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..gate = Completer<void>()
        ..script = const [
          RestoreProgress(RestoreStage.downloadingDb),
          RestoreProgress(RestoreStage.thumbnails, done: 5, total: 12),
        ];
      final h = _Harness(svc);
      await tester.pumpWidget(h.flow());
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);

      expect(find.text('Elige un PIN nuevo'), findsOneWidget);
      await _pickPin(tester, '654321');

      // En curso: etapa y barra determinada.
      expect(find.text('Restaurando tu bóveda'), findsOneWidget);
      expect(find.text('Descargando miniaturas 5 de 12…'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('restore-progress')),
      );
      expect(bar.value, closeTo(5 / 12, 0.001));
      expect(svc.pinUsed, '654321');

      svc.gate!.complete();
      await _settle(tester);
      expect(find.text('Bóveda restaurada'), findsOneWidget);
      expect(find.textContaining('12 archivos y 3 carpetas'), findsOneWidget);
      expect(find.byKey(const ValueKey('restore-lost')), findsNothing);
      await tester.tap(find.text('Continuar'));
      expect(h.restored?.items, 12);
    });

    testWidgets('PIN que no coincide: error y no se descarga nada', (
      tester,
    ) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService();
      await tester.pumpWidget(_Harness(svc).flow(step: RestoreStep.code));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);
      await _digits(tester, '123456');
      await _settle(tester);
      await _digits(tester, '432100');
      await _settle(tester);
      expect(find.text('Los PIN no coinciden'), findsOneWidget);
      expect(svc.restoreCalls, 0);
    });

    testWidgets('archivos perdidos: aviso con la cuenta', (tester) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..result = const RestoreResult(
          items: 9,
          folders: 1,
          thumbnails: 9,
          lostItems: 3,
          adoptedItems: 0,
          missingThumbnails: 0,
        );
      await tester.pumpWidget(_Harness(svc).flow(step: RestoreStep.code));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);
      await _pickPin(tester, '135700');
      await _settle(tester);
      expect(find.text('3 no se pudieron recuperar'), findsOneWidget);
    });

    testWidgets('fallo de red: Reintentar reanuda con el mismo PIN', (
      tester,
    ) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..restoreError = const CloudNoNetworkException();
      await tester.pumpWidget(_Harness(svc).flow(step: RestoreStep.code));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);
      await _pickPin(tester, '135700');

      expect(find.text('No se pudo restaurar'), findsOneWidget);
      expect(find.text('Sin conexión a internet'), findsOneWidget);
      await tester.tap(find.text('Reintentar'));
      await _settle(tester);
      expect(svc.restoreCalls, 2);
      expect(svc.pinUsed, '135700');
      expect(find.text('Bóveda restaurada'), findsOneWidget);
    });

    testWidgets('respaldo dañado: mensaje claro, sin reintentar', (
      tester,
    ) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()
        ..restoreError = const RestoreCorruptException();
      await tester.pumpWidget(_Harness(svc).flow(step: RestoreStep.code));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);
      await _pickPin(tester, '135700');
      expect(
        find.text('El respaldo está dañado o no corresponde a este código.'),
        findsOneWidget,
      );
      expect(find.text('Reintentar'), findsNothing);
      await tester.tap(find.text('Empezar de nuevo'));
      await _settle(tester);
      expect(find.text('Restaurar tu bóveda'), findsOneWidget);
    });

    testWidgets('cancelar a mitad vuelve al código', (tester) async {
      usePhoneSize(tester);
      final svc = ScriptedRestoreService()..gate = Completer<void>();
      await tester.pumpWidget(_Harness(svc).flow(step: RestoreStep.code));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);
      await _pickPin(tester, '135700');
      await tester.tap(find.text('Cancelar'));
      svc.gate!.complete();
      await _settle(tester);
      expect(find.text('Tu código de recuperación'), findsOneWidget);
    });
  });

  group('OnboardingFlow con restauración', () {
    testWidgets('la bienvenida ofrece restaurar solo si hay servicio', (
      tester,
    ) async {
      usePhoneSize(tester);
      final auth = await _auth();
      await tester.pumpWidget(
        testApp(OnboardingFlow(auth: auth, onFinished: () {})),
      );
      await tester.pump();
      expect(find.text('Ya tengo una bóveda (restaurar)'), findsNothing);

      await tester.pumpWidget(
        testApp(
          OnboardingFlow(
            auth: auth,
            onFinished: () {},
            restoreProvider: ScriptedRestoreService.new,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Ya tengo una bóveda (restaurar)'), findsOneWidget);
    });

    testWidgets('restaurar -> biometría -> bóveda (sin paso de Drive)', (
      tester,
    ) async {
      usePhoneSize(tester);
      final auth = await _auth();
      final svc = ScriptedRestoreService();
      var finished = 0;
      var restored = 0;
      await tester.pumpWidget(
        testApp(
          OnboardingFlow(
            auth: auth,
            onFinished: () => finished++,
            restoreProvider: () => svc,
            onVaultRestored: () => restored++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Ya tengo una bóveda (restaurar)'));
      await _settle(tester);
      // Sin indicador de pasos del onboarding de creación.
      expect(find.bySemanticsLabel(RegExp('Paso')), findsNothing);
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      await _type(tester, _typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Continuar'));
      await _settle(tester);
      await _pickPin(tester, '246800');
      await _settle(tester);
      expect(find.text('Bóveda restaurada'), findsOneWidget);
      await tester.tap(find.text('Continuar'));
      await _settle(tester);
      expect(restored, 1);
      // La biometría del teléfono viejo no se traslada: se ofrece de nuevo.
      expect(find.text('Desbloqueo biométrico'), findsOneWidget);
      await tester.tap(find.text('Ahora no'));
      await _settle(tester);
      expect(finished, 1);
    });

    testWidgets('cuenta sin respaldo -> crear una bóveda nueva', (
      tester,
    ) async {
      usePhoneSize(tester);
      final auth = await _auth();
      final svc = ScriptedRestoreService()
        ..probeResult = RestoreProbeResult.noBackup;
      await tester.pumpWidget(
        testApp(
          OnboardingFlow(
            auth: auth,
            onFinished: () {},
            restoreProvider: () => svc,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Ya tengo una bóveda (restaurar)'));
      await _settle(tester);
      await tester.tap(find.text('Iniciar sesión con Google'));
      await _settle(tester);
      await tester.tap(find.text('Crear una bóveda nueva'));
      await _settle(tester);
      expect(find.text('Crea un nuevo PIN'), findsOneWidget);
    });
  });
}
