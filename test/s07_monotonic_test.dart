// Regresión S-07: el retraso del PIN y del código de restauración también
// depende de un reloj monotónico; adelantar la hora de pared no quita la
// espera. Con el código anterior los casos "hora adelantada" fallan.
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/pin_attempt_limiter.dart';
import 'package:vault/core/session/vault_session.dart';

import 'support/fakes.dart';

class FakeMono implements MonotonicClock {
  int elapsedMs = 1000000;
  int boot = 7;
  bool available = true;
  @override
  Future<MonotonicReading?> read() async =>
      available ? MonotonicReading(elapsedMs: elapsedMs, boot: boot) : null;
}

void main() {
  late InMemorySecureStore store;
  late FakeClock clock;
  late FakeMono mono;

  PinAttemptLimiter limiter({String key = PinAttemptLimiter.storageKey}) =>
      PinAttemptLimiter(store, clock: clock.call, monotonic: mono, key: key);

  void realTime(Duration d) {
    clock.advance(d);
    mono.elapsedMs += d.inMilliseconds;
  }

  setUp(() {
    store = InMemorySecureStore();
    clock = FakeClock();
    mono = FakeMono();
  });

  Future<PinAttemptLimiter> lockedAt5() async {
    final l = limiter();
    for (var i = 0; i < 5; i++) {
      await l.registerFailure();
    }
    expect(await l.remainingLockout(), const Duration(seconds: 30));
    return l;
  }

  test('adelantar la hora de pared NO quita la espera', () async {
    final l = await lockedAt5();
    clock.advance(const Duration(days: 365)); // el monotónico no se mueve
    expect(await l.remainingLockout(), const Duration(seconds: 30));
    await expectLater(
      l.ensureNotLocked(),
      throwsA(isA<PinLockedOutException>()),
    );
  });

  test('el tiempo real transcurrido sí cuenta (ambos relojes)', () async {
    final l = await lockedAt5();
    realTime(const Duration(seconds: 10));
    expect(await l.remainingLockout(), const Duration(seconds: 20));
    realTime(const Duration(seconds: 21));
    expect(await l.remainingLockout(), isNull);
  });

  test(
    'hora adelantada + solo parte del tiempo real: manda el monotónico',
    () async {
      final l = await lockedAt5();
      clock.advance(const Duration(hours: 5));
      mono.elapsedMs += 12000;
      expect(await l.remainingLockout(), const Duration(seconds: 18));
    },
  );

  test(
    'hora atrasada: la espera queda acotada al nivel (no bloqueo eterno)',
    () async {
      final l = await lockedAt5();
      clock.advance(const Duration(days: -365));
      expect((await l.remainingLockout())!.inSeconds, lessThanOrEqualTo(30));
      // Al volver la hora de pared al presente, con el tiempo real cumplido, se libera.
      clock.advance(const Duration(days: 365, seconds: 31));
      mono.elapsedMs += 31000;
      expect(await l.remainingLockout(), isNull);
    },
  );

  test('reinicio: solo se abona el tiempo desde el arranque, aunque la hora '
      'de pared se adelante', () async {
    final l = await lockedAt5();
    // Reinicia (otro boot, el monotónico empieza de cero) y adelanta la hora.
    mono.boot = 8;
    mono.elapsedMs = 5000;
    clock.advance(const Duration(days: 30));
    expect(await l.remainingLockout(), const Duration(seconds: 25));
    mono.elapsedMs = 31000;
    expect(await l.remainingLockout(), isNull);
  });

  test(
    'reinicio detectado también por monotónico que baja (iOS: boot=-1)',
    () async {
      mono.boot = -1;
      final l = await lockedAt5();
      mono.elapsedMs = 2000; // menor que al bloquear
      clock.advance(const Duration(days: 2));
      expect(await l.remainingLockout(), const Duration(seconds: 28));
    },
  );

  test(
    'sin reloj monotónico se comporta como antes (solo hora de pared)',
    () async {
      mono.available = false;
      final l = await lockedAt5();
      clock.advance(const Duration(seconds: 31));
      expect(await l.remainingLockout(), isNull);
    },
  );

  test(
    'el estado persiste: otra instancia (app reabierta) lo respeta',
    () async {
      await lockedAt5();
      clock.advance(const Duration(days: 1));
      expect(await limiter().remainingLockout(), const Duration(seconds: 30));
    },
  );

  test('resetear (acierto) limpia el bloqueo', () async {
    final l = await lockedAt5();
    await l.reset();
    expect(await l.remainingLockout(), isNull);
    expect(await l.failures(), 0);
  });

  test('integración: AuthController con hora adelantada sigue bloqueado '
      '(PIN y código de restauración)', () async {
    final c = AuthController(
      storage: store,
      biometricStore: FakeBiometricKeyStore(),
      kdfParams: fastKdf,
      clock: clock.call,
      monotonic: mono,
      session: VaultSession.create(),
    );
    await c.createVault('123456');
    c.lock();
    for (var i = 0; i < 5; i++) {
      expect(await c.unlockWithPin('000000'), isFalse);
    }
    clock.advance(const Duration(days: 30));
    await expectLater(
      c.unlockWithPin('123456'),
      throwsA(isA<PinLockedOutException>()),
    );
    expect(await c.pinLockoutRemaining(), const Duration(seconds: 30));
    mono.elapsedMs += 31000;
    expect(await c.unlockWithPin('123456'), isTrue);
  });
}
