import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/argon2_backend.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/kdf.dart';
import 'package:vault/core/crypto/pin_attempt_limiter.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/features/auth/pin_screen.dart';
import 'package:vault/features/auth/widgets/pin_dots.dart';

import '../support/fakes.dart';
import '../support/ui_helpers.dart';

// Carreras de la pantalla de PIN: tecleo rápido, dobles toques en Continuar,
// auto-envío + botón, toques durante la derivación y la sacudida, y la
// confirmación del PIN al crear la bóveda.

/// Cuenta derivaciones Argon2id; con [gate] se quedan "derivando".
class _CountingBackend implements Argon2Backend {
  int calls = 0;
  Completer<void>? gate;

  @override
  String get name => 'contador';

  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    calls++;
    final g = gate;
    if (g != null) await g.future;
    return const DartArgon2Backend().derive(
      secret: secret,
      salt: salt,
      params: params,
    );
  }
}

class _Env {
  _Env() {
    controller = newController();
  }

  final store = InMemorySecureStore();
  final bio = FakeBiometricKeyStore()
    ..available = BiometricAvailability.unavailable;
  final clock = FakeClock();
  late final AuthController controller;
  int authenticated = 0;

  AuthController newController() => AuthController(
    storage: store,
    biometricStore: bio,
    kdfParams: fastKdf,
    session: VaultSession.create(),
    clock: clock.call,
  );

  Future<int> failures() => PinAttemptLimiter(store).failures();

  Widget screen() => testApp(
    PinScreen(
      authController: controller,
      onAuthenticated: () => authenticated++,
    ),
  );
}

Finder _digit(String d) => find.bySemanticsLabel('Dígito $d');

/// Teclea sin `pump` entre toques (ráfaga en el mismo frame).
Future<void> _burst(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(_digit(d), warnIfMissed: false);
  }
}

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(_digit(d));
    await tester.pump();
  }
}

/// Deja terminar la derivación (Dart Argon2 usa timers reales).
Future<void> _settleCrypto(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
}

PinDots _dots(WidgetTester tester) =>
    tester.widget<PinDots>(find.byKey(const ValueKey('pin-dots')));

void main() {
  late _CountingBackend counting;

  setUp(() {
    counting = _CountingBackend();
  });
  tearDown(() => Argon2Backend.current = null);

  Future<_Env> envWithVault(String pin) async {
    final env = _Env();
    await env.controller.createVault(pin);
    env.controller.lock();
    Argon2Backend.current = counting; // solo cuenta lo de la pantalla
    return env;
  }

  testWidgets('ráfaga de 8 dígitos: solo cuentan 6, un único envío', (
    tester,
  ) async {
    usePhoneSize(tester);
    final env = await envWithVault('123456');
    await tester.pumpWidget(env.screen());
    await tester.pump();

    await _burst(tester, '12345678');
    await tester.pump();
    expect(_dots(tester).filled, 6);
    await _settleCrypto(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(counting.calls, 1);
    expect(env.authenticated, 1);
    expect(await env.failures(), 0);
  });

  testWidgets('doble toque en Continuar: un único intento', (tester) async {
    usePhoneSize(tester);
    final env = await envWithVault('1234');
    await tester.pumpWidget(env.screen());
    await tester.pump();

    await _type(tester, '1234');
    await tester.tap(find.text('Continuar'));
    await tester.tap(find.text('Continuar'), warnIfMissed: false);
    await _settleCrypto(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(counting.calls, 1);
    expect(env.authenticated, 1);
    expect(await env.failures(), 0);
  });

  testWidgets('auto-envío del 6.º dígito + Continuar en el mismo frame', (
    tester,
  ) async {
    usePhoneSize(tester);
    final env = await envWithVault('123456');
    await tester.pumpWidget(env.screen());
    await tester.pump();

    await _type(tester, '12345');
    await tester.tap(_digit('6')); // auto-envío
    await tester.tap(find.text('Continuar'), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleCrypto(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(counting.calls, 1);
    expect(env.authenticated, 1);
    expect(find.text('PIN incorrecto'), findsNothing);
    expect(await env.failures(), 0);
  });

  testWidgets('toques y teclas durante "Verificando…" se ignoran', (
    tester,
  ) async {
    usePhoneSize(tester);
    final env = await envWithVault('123456');
    counting.gate = Completer<void>();
    await tester.pumpWidget(env.screen());
    await tester.pump();

    await _type(tester, '123456');
    expect(find.text('Verificando…'), findsOneWidget);
    await _burst(tester, '9876');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_dots(tester).filled, 6);
    expect(counting.calls, 1);

    counting.gate!.complete();
    await _settleCrypto(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(counting.calls, 1);
    expect(env.authenticated, 1);
  });

  testWidgets('tras un fallo: toques durante la sacudida se ignoran y el '
      'PIN correcto entra limpio', (tester) async {
    usePhoneSize(tester);
    final env = await envWithVault('123456');
    await tester.pumpWidget(env.screen());
    await tester.pump();

    await _type(tester, '000000');
    await _settleCrypto(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('PIN incorrecto'), findsOneWidget);
    // Durante la sacudida (aún ocupado) nada entra.
    await _burst(tester, '12');
    await tester.pump();
    expect(_dots(tester).filled, 6);

    await tester.pump(const Duration(seconds: 1));
    expect(_dots(tester).filled, 0);
    await _type(tester, '123456');
    await _settleCrypto(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(counting.calls, 2);
    expect(env.authenticated, 1);
    expect(await env.failures(), 0);
  });

  testWidgets('crear: un toque perdido ya no deja la bóveda con otro PIN '
      '(confirmación obligatoria)', (tester) async {
    usePhoneSize(tester);
    final env = _Env();
    await tester.pumpWidget(env.screen());
    await tester.pump();

    // Quería 123456 pero se perdió el "5" y pulsó Continuar.
    await _type(tester, '12346');
    await tester.tap(find.text('Continuar'));
    await tester.pump();
    expect(find.text('Confirma tu PIN'), findsOneWidget);
    expect(_dots(tester).filled, 0);

    // Al confirmar teclea el PIN que cree tener: no coincide.
    await _type(tester, '123456');
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('Los PIN no coinciden. Crea un nuevo PIN'),
      findsOneWidget,
    );
    expect(await env.controller.hasVault(), isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(_dots(tester).filled, 0);

    // Vuelve a empezar: 123456 + confirmación 123456.
    await _type(tester, '1');
    expect(find.text('Crea un nuevo PIN'), findsOneWidget);
    await _type(tester, '23456');
    expect(find.text('Confirma tu PIN'), findsOneWidget);
    await _type(tester, '123456');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Código de recuperación'), findsOneWidget);
    await tester.tap(find.text('Ya lo guardé'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 1));
    expect(env.authenticated, 1);

    // "Reiniciar la app": el PIN que el usuario cree tener funciona.
    final reopened = env.newController();
    final ok = await tester.runAsync(() => reopened.unlockWithPin('123456'));
    expect(ok, isTrue);
  });
}
