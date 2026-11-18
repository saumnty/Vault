import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/features/auth/pin_screen.dart';
import 'package:vault/features/auth/widgets/pin_dots.dart';
import 'package:vault/shared/widgets/shake_widget.dart';

import '../support/fakes.dart';
import '../support/ui_helpers.dart';

class _Env {
  _Env() {
    controller = AuthController(
      storage: store,
      biometricStore: bio,
      kdfParams: fastKdf,
      session: VaultSession.create(),
      clock: clock.call,
    );
  }

  final store = InMemorySecureStore();
  final bio = FakeBiometricKeyStore();
  final clock = FakeClock();
  late final AuthController controller;
  int authenticated = 0;

  Widget screen() => testApp(
    PinScreen(
      authController: controller,
      onAuthenticated: () => authenticated++,
    ),
  );
}

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.bySemanticsLabel('Dígito $d'));
    await tester.pump();
  }
}

PinDots _dots(WidgetTester tester) =>
    tester.widget<PinDots>(find.byKey(const ValueKey('pin-dots')));

void main() {
  testWidgets('sin bóveda: pide crear PIN y los puntos se llenan al teclear', (
    tester,
  ) async {
    usePhoneSize(tester);
    final env = _Env();
    await tester.pumpWidget(env.screen());
    await tester.pump();

    expect(find.text('Crea un nuevo PIN'), findsOneWidget);
    expect(_dots(tester).filled, 0);

    await _type(tester, '12');
    expect(_dots(tester).filled, 2);
    await _type(tester, '3');
    expect(_dots(tester).filled, 3);

    await tester.tap(find.bySemanticsLabel('Borrar'));
    await tester.pump();
    expect(_dots(tester).filled, 2);
  });

  testWidgets(
    'crear: Continuar sigue deshabilitado hasta los 6 dígitos (S-06)',
    (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      await tester.pumpWidget(env.screen());
      await tester.pump();

      FilledButton button() =>
          tester.widget<FilledButton>(find.byType(FilledButton));
      await _type(tester, '1234');
      expect(button().onPressed, isNull);
      await _type(tester, '5');
      expect(button().onPressed, isNull);
      // El 6.º dígito envía solo: pasa al paso de confirmación.
      await _type(tester, '6');
      expect(find.text('Confirma tu PIN'), findsOneWidget);
    },
  );

  testWidgets('PIN incorrecto: mensaje, puntos en error y sacudida', (
    tester,
  ) async {
    usePhoneSize(tester);
    final env = _Env();
    await env.controller.createVault('123456');
    env.controller.lock();

    await tester.pumpWidget(env.screen());
    await tester.pump();
    expect(find.text('Ingresa tu PIN maestro'), findsOneWidget);

    await _type(tester, '999999');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('PIN incorrecto'), findsOneWidget);
    expect(_dots(tester).hasError, isTrue);
    expect(tester.widget<ShakeWidget>(find.byType(ShakeWidget)).shakeCount, 1);
    // A mitad de la sacudida los puntos están desplazados horizontalmente.
    final shift = tester
        .widget<Transform>(
          find
              .descendant(
                of: find.byType(ShakeWidget),
                matching: find.byType(Transform),
              )
              .first,
        )
        .transform
        .getTranslation()
        .x;
    expect(shift, isNot(0));

    // Tras la sacudida el PIN se limpia; al teclear se quita el error.
    await tester.pump(const Duration(seconds: 1));
    expect(_dots(tester).filled, 0);
    await _type(tester, '1');
    expect(_dots(tester).hasError, isFalse);
    expect(env.authenticated, 0);
  });

  testWidgets('PIN correcto: puntos de éxito y llama a onAuthenticated', (
    tester,
  ) async {
    usePhoneSize(tester);
    final env = _Env();
    await env.controller.createVault('123456');
    env.controller.lock();

    await tester.pumpWidget(env.screen());
    await tester.pump();
    await _type(tester, '123456');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(_dots(tester).success, isTrue);

    await tester.pump(const Duration(seconds: 1));
    expect(env.authenticated, 1);
  });

  testWidgets('bloqueo: muestra cuenta atrás y deshabilita el teclado', (
    tester,
  ) async {
    usePhoneSize(tester);
    final env = _Env();
    await env.controller.createVault('123456');
    env.controller.lock();
    // Fallos hasta activar el retraso.
    for (var i = 0; i < 6; i++) {
      try {
        await env.controller.unlockWithPin('000000');
      } on PinLockedOutException {
        break;
      }
    }
    final remaining = await env.controller.pinLockoutRemaining();
    expect(remaining, isNotNull);

    await tester.pumpWidget(env.screen());
    await tester.pump();
    final start = remaining!.inSeconds + 1;
    expect(find.text('Demasiados intentos. Espera $start s'), findsOneWidget);

    // El teclado ignora toques mientras dure el bloqueo.
    await tester.tap(find.bySemanticsLabel('Dígito 1'), warnIfMissed: false);
    await tester.pump();
    expect(_dots(tester).filled, 0);

    // La cuenta atrás avanza cada segundo.
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text('Demasiados intentos. Espera ${start - 1} s'),
      findsOneWidget,
    );

    // Al terminar (el reloj avanzó) vuelve a pedir el PIN.
    env.clock.advance(Duration(seconds: start + 1));
    await tester.pump(Duration(seconds: start));
    await tester.pump();
    expect(find.text('Ingresa tu PIN maestro'), findsOneWidget);
  });

  testWidgets(
    'crear bóveda sin onboarding: entra directo (sin hoja de código)',
    (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      await tester.pumpWidget(env.screen());
      await tester.pump();

      await _type(tester, '246800');
      await tester.pump();
      // Paso de confirmación: se pide el mismo PIN otra vez.
      expect(find.text('Confirma tu PIN'), findsOneWidget);
      expect(_dots(tester).filled, 0);
      await _type(tester, '246800');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Código de recuperación'), findsNothing);
      expect(env.authenticated, 1);
      // Sin onboarding no se deja bandera pendiente.
      expect(await env.controller.isOnboardingPending(), isFalse);
    },
  );

  testWidgets('crear bóveda con onVaultCreated: entrega el código y deja la '
      'bandera de onboarding pendiente', (tester) async {
    usePhoneSize(tester);
    final env = _Env();
    VaultCreationResult? created;
    await tester.pumpWidget(
      testApp(
        PinScreen(
          authController: env.controller,
          onAuthenticated: () => env.authenticated++,
          onVaultCreated: (r) => created = r,
        ),
      ),
    );
    await tester.pump();
    await _type(tester, '246800');
    await tester.pump();
    await _type(tester, '246800');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(created, isNotNull);
    expect(created!.recoveryCode.split('-'), hasLength(6));
    expect(env.authenticated, 0); // el onboarding decide cuándo entrar
    expect(await env.controller.isOnboardingPending(), isTrue);
  });

  for (final withSecondary in [false, true]) {
    testWidgets('D69: biometría automática ${withSecondary ? 'NO' : 'sí'} '
        '${withSecondary ? 'con' : 'sin'} bóveda secundaria', (tester) async {
      usePhoneSize(tester);
      final env = _Env();
      await tester.runAsync(() async {
        await env.controller.createVault('123456');
        await env.controller.enableBiometricUnlock();
        env.controller.lock();
      });
      // Basta con que exista la clave de la secundaria.
      if (withSecondary) {
        env.store.data[AuthController.altPinEnvelopeKey] = 'x';
      }
      env.bio.reads = 0;
      await tester.pumpWidget(env.screen());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(env.bio.reads, withSecondary ? 0 : 1);
      await tester.pump(const Duration(seconds: 1)); // animación de entrada
    });
  }
}
