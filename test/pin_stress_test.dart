import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/argon2_backend.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/kdf.dart';
import 'package:vault/core/crypto/pin_attempt_limiter.dart';
import 'package:vault/core/session/vault_session.dart';

import 'support/fakes.dart';

// Investigación del "PIN incorrecto" con el PIN correcto visto una vez en el
// emulador: estrés de desbloqueos (reinicios simulados, misma instancia,
// biometría, lock entre medias), invariantes del almacenamiento y carreras.

const _pin = '123456';

/// Parámetros reducidos para la variante con isolate real.
const _isolateKdf = Argon2Params(memoryKiB: 256, iterations: 1, parallelism: 1);

/// Lo que NUNCA debe cambiar al desbloquear, bloquear o tocar la biometría.
class _Stored {
  _Stored(InMemorySecureStore s)
    : pinEnvelope = s.data[AuthController.pinEnvelopeKey]!,
      recovery = s.data[AuthController.recoveryBackupKey]!,
      keyCheck = s.data[AuthController.keyCheckKey]!;

  final String pinEnvelope;
  final String recovery;
  final String keyCheck;

  String get pinSalt => jsonDecode(pinEnvelope)['salt'] as String;
  String get pinCt => jsonDecode(pinEnvelope)['ct'] as String;
  String get recoverySalt => jsonDecode(recovery)['salt'] as String;

  void expectSame(_Stored other, String when) {
    expect(other.pinSalt, pinSalt, reason: 'salt del PIN cambió: $when');
    expect(other.pinCt, pinCt, reason: 'DEK envuelta cambió: $when');
    expect(other.pinEnvelope, pinEnvelope, reason: 'envoltura cambió: $when');
    expect(other.recovery, recovery, reason: 'recuperación cambió: $when');
    expect(other.recoverySalt, recoverySalt, reason: when);
    expect(other.keyCheck, keyCheck, reason: 'key_check cambió: $when');
  }
}

/// Cuenta derivaciones (y deja ver las concurrentes).
class _CountingBackend implements Argon2Backend {
  _CountingBackend(this.inner);
  final Argon2Backend inner;
  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  Completer<void>? gate;

  @override
  String get name => 'contador(${inner.name})';

  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final g = gate;
      if (g != null) await g.future;
      return await inner.derive(secret: secret, salt: salt, params: params);
    } finally {
      inFlight--;
    }
  }
}

/// Primario "nativo" que estropea su entrada (pone el secreto a cero) y
/// luego falla: simula un fallo nativo→Dart a mitad de camino.
class _ZeroingBrokenBackend implements Argon2Backend {
  int calls = 0;
  @override
  String get name => 'nativo-roto';
  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    calls++;
    await Future<void>.delayed(Duration.zero);
    secret.fillRange(0, secret.length, 0);
    throw StateError('libsodium no cargó');
  }
}

void main() {
  late InMemorySecureStore storage;
  late FakeBiometricKeyStore bio;
  late FakeClock clock;

  AuthController controller({Argon2Params kdf = fastKdf}) => AuthController(
    storage: storage,
    biometricStore: bio,
    kdfParams: kdf,
    clock: clock.call,
    session: VaultSession.create(),
  );

  Future<int> failures() => PinAttemptLimiter(storage).failures();

  setUp(() {
    storage = InMemorySecureStore();
    bio = FakeBiometricKeyStore();
    clock = FakeClock();
  });

  tearDown(() => Argon2Backend.current = null);

  /// 50 desbloqueos alternando reinicio de app / misma instancia, biometría
  /// (activar, desbloquear, desactivar) y lock() entre medias.
  Future<void> stress({required Argon2Params kdf}) async {
    var c = controller(kdf: kdf);
    await c.createVault(_pin);
    final dek = c.session.keys.dekBytes();
    final ref = _Stored(storage);

    for (var i = 0; i < 50; i++) {
      final restart = i.isEven;
      if (restart) {
        c.lock();
        c = controller(kdf: kdf); // "cerrar y reabrir la app"
      } else {
        c.lock(); // misma instancia
      }
      expect(c.isUnlocked, isFalse);
      expect(
        await c.unlockWithPin(_pin),
        isTrue,
        reason: 'desbloqueo $i (reinicio=$restart) dio PIN incorrecto',
      );
      expect(c.session.keys.dekBytes(), dek, reason: 'DEK distinta en $i');
      expect(await failures(), 0, reason: 'contador sucio en $i');
      ref.expectSame(_Stored(storage), 'desbloqueo PIN $i');

      switch (i % 5) {
        case 0:
          await c.enableBiometricUnlock();
          ref.expectSame(_Stored(storage), 'activar biometría $i');
        case 1:
          c.lock();
          if (await c.isBiometricUnlockEnabled()) {
            expect(await c.unlockWithBiometrics(), isTrue);
            expect(c.session.keys.dekBytes(), dek);
          } else {
            expect(await c.unlockWithPin(_pin), isTrue);
          }
          ref.expectSame(_Stored(storage), 'desbloqueo biometría $i');
        case 2:
          await c.disableBiometricUnlock();
          ref.expectSame(_Stored(storage), 'desactivar biometría $i');
        case 3:
          // Un PIN incorrecto entre medias no altera nada y el correcto
          // vuelve a abrir.
          c.lock();
          expect(await c.unlockWithPin('000000'), isFalse);
          expect(await failures(), 1);
          expect(await c.unlockWithPin(_pin), isTrue);
          expect(await failures(), 0);
          ref.expectSame(_Stored(storage), 'fallo + acierto $i');
        default:
          c.lock();
          c.lock(); // lock doble: idempotente
      }
    }
    ref.expectSame(_Stored(storage), 'final');
  }

  group('estrés de desbloqueo (50 veces)', () {
    test('Argon2 rápido en el mismo isolate', () => stress(kdf: fastKdf));

    test(
      'backend en isolate real (parámetros reducidos)',
      () async {
        Argon2Backend.current = const IsolateDartArgon2Backend();
        await stress(kdf: _isolateKdf);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'fallback nativo→isolate con primario que estropea su entrada',
      () async {
        final broken = _ZeroingBrokenBackend();
        Argon2Backend.current = FallbackArgon2Backend(
          primary: broken,
          fallback: const IsolateDartArgon2Backend(),
        );
        await stress(kdf: _isolateKdf);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  group('carreras en AuthController', () {
    test('doble envío con el mismo PIN: una sola derivación, '
        'ambos true, contador a 0 y llaves vivas', () async {
      final counting = _CountingBackend(const DartArgon2Backend());
      final c = controller();
      await c.createVault(_pin);
      c.lock();
      Argon2Backend.current = counting;

      final a = c.unlockWithPin(_pin); // auto-envío del 6.º dígito
      final b = c.unlockWithPin(_pin); // botón Continuar
      expect(await Future.wait([a, b]), [true, true]);
      expect(counting.calls, 1, reason: 'el duplicado no debe derivar');
      expect(await failures(), 0);
      final keys = c.session.keys;
      expect(keys.isDestroyed, isFalse);
    });

    test('desbloqueo repetido con la sesión ya abierta no destruye las '
        'llaves que otros servicios ya usan', () async {
      final c = controller();
      await c.createVault(_pin);
      final filesKey = c.session.filesKey!;
      final keys = c.session.keys;
      expect(await c.unlockWithPin(_pin), isTrue);
      await c.enableBiometricUnlock();
      expect(await c.unlockWithBiometrics(), isTrue);
      expect(keys.isDestroyed, isFalse);
      expect(identical(c.session.keys, keys), isTrue);
      expect((await filesKey.extractBytes()).length, 32);
    });

    test('PIN + biometría a la vez: ambos abren la misma DEK', () async {
      final c = controller();
      await c.createVault(_pin);
      final dek = c.session.keys.dekBytes();
      await c.enableBiometricUnlock();
      c.lock();
      final r = await Future.wait([
        c.unlockWithPin(_pin),
        c.unlockWithBiometrics(),
      ]);
      expect(r, [true, true]);
      expect(c.session.keys.dekBytes(), dek);
      expect(c.session.keys.isDestroyed, isFalse);
      expect(await failures(), 0);
    });

    test('5 PIN incorrectos concurrentes cuentan 5 fallos y bloquean '
        '(sin actualizaciones perdidas)', () async {
      final c = controller();
      await c.createVault(_pin);
      c.lock();
      final results = await Future.wait([
        for (var i = 0; i < 5; i++) c.unlockWithPin('00000$i'),
      ]);
      expect(results, everyElement(isFalse));
      expect(await failures(), 5);
      await expectLater(
        c.unlockWithPin(_pin),
        throwsA(isA<PinLockedOutException>()),
      );
    });

    test('incorrecto y correcto concurrentes: resultados exactos y '
        'contador coherente', () async {
      final c = controller();
      await c.createVault(_pin);
      c.lock();
      final r = await Future.wait([
        c.unlockWithPin('999999'),
        c.unlockWithPin(_pin),
      ]);
      expect(r, [false, true]);
      expect(await failures(), 0);
      expect(c.isUnlocked, isTrue);
    });

    test('un unlock nunca corre mientras otro está en vuelo', () async {
      final counting = _CountingBackend(const DartArgon2Backend());
      final c = controller();
      await c.createVault(_pin);
      c.lock();
      Argon2Backend.current = counting;
      counting.gate = Completer<void>();
      final a = c.unlockWithPin('111111');
      final b = c.unlockWithPin(_pin);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(counting.inFlight, 1, reason: 'el segundo debe esperar turno');
      counting.gate!.complete();
      expect(await Future.wait([a, b]), [false, true]);
      expect(counting.maxInFlight, 1);
      expect(await failures(), 0);
    });

    test('lock() con un unlock en vuelo: no corrompe nada y el '
        'siguiente desbloqueo funciona', () async {
      final c = controller();
      await c.createVault(_pin);
      final dek = c.session.keys.dekBytes();
      final ref = _Stored(storage);
      c.lock();
      final pending = c.unlockWithPin(_pin);
      final cancelled = expectLater(
        pending,
        throwsA(isA<UnlockCancelledException>()),
      );
      c.lock();
      // F7: el lock cancela el unlock en vuelo; la sesión NO se abre sola.
      await cancelled;
      expect(c.isUnlocked, isFalse);
      c.lock();
      expect(await c.unlockWithPin(_pin), isTrue);
      expect(c.session.keys.dekBytes(), dek);
      ref.expectSame(_Stored(storage), 'lock en vuelo');
    });

    test('sin envoltura guardada no es "PIN incorrecto" (StateError) y no '
        'cuenta intento', () async {
      final c = controller();
      await expectLater(c.unlockWithPin(_pin), throwsStateError);
      expect(await failures(), 0);
    });
  });

  group('Argon2id: concurrencia y buffers', () {
    test('derivaciones concurrentes en isolate no cruzan resultados', () async {
      const backend = IsolateDartArgon2Backend();
      final inputs = [
        for (var i = 0; i < 12; i++)
          (
            Uint8List.fromList(utf8.encode('${100000 + i}')),
            Uint8List.fromList(List.generate(16, (j) => (i * 31 + j) & 0xff)),
          ),
      ];
      final expected = [
        for (final (s, n) in inputs)
          await const DartArgon2Backend().derive(
            secret: s,
            salt: n,
            params: _isolateKdf,
          ),
      ];
      final got = await Future.wait([
        for (final (s, n) in inputs)
          backend.derive(secret: s, salt: n, params: _isolateKdf),
      ]);
      for (var i = 0; i < inputs.length; i++) {
        expect(got[i], expected[i], reason: 'resultado cruzado en $i');
      }
    });

    test('deriveKey concurrente con el mismo buffer de entrada: el buffer '
        'del llamador no se pone a cero y todas coinciden', () async {
      Argon2Backend.current = const IsolateDartArgon2Backend();
      final secret = utf8.encode(_pin);
      final salt = List<int>.generate(16, (i) => i);
      final keys = await Future.wait([
        for (var i = 0; i < 8; i++) _isolateKdf.deriveKey(secret, salt),
      ]);
      expect(secret, utf8.encode(_pin));
      final first = await keys.first.extractBytes();
      for (final k in keys) {
        expect(await k.extractBytes(), first);
      }
    });

    test('fallback: si el primario estropea el secreto y falla, el '
        'respaldo deriva con el secreto original', () async {
      final secret = Uint8List.fromList(utf8.encode(_pin));
      final salt = Uint8List(16);
      final expected = await const DartArgon2Backend().derive(
        secret: secret,
        salt: salt,
        params: fastKdf,
      );
      final fb = FallbackArgon2Backend(
        primary: _ZeroingBrokenBackend(),
        fallback: const DartArgon2Backend(),
      );
      final got = await fb.derive(secret: secret, salt: salt, params: fastKdf);
      expect(got, expected);
      expect(secret, utf8.encode(_pin), reason: 'el llamador no se toca');
      expect(fb.lastUsed, 'dart');
    });

    test('fallback concurrente: varias llamadas a la vez mientras el '
        'primario se rompe dan todas el mismo resultado', () async {
      final salt = Uint8List(16);
      final expected = await const DartArgon2Backend().derive(
        secret: Uint8List.fromList(utf8.encode(_pin)),
        salt: salt,
        params: fastKdf,
      );
      final fb = FallbackArgon2Backend(
        primary: _ZeroingBrokenBackend(),
        fallback: const IsolateDartArgon2Backend(),
      );
      final got = await Future.wait([
        for (var i = 0; i < 6; i++)
          fb.derive(
            secret: Uint8List.fromList(utf8.encode(_pin)),
            salt: salt,
            params: fastKdf,
          ),
      ]);
      for (final g in got) {
        expect(g, expected);
      }
    });
  });

  group('salt y DEK envuelta solo cambian donde deben', () {
    test('createVault con bóveda existente falla sin tocar nada', () async {
      final c = controller();
      await c.createVault(_pin);
      final ref = _Stored(storage);
      await expectLater(c.createVault('654321'), throwsStateError);
      await expectLater(controller().createVault(_pin), throwsStateError);
      ref.expectSame(_Stored(storage), 'createVault repetido');
      expect(await controller().unlockWithPin(_pin), isTrue);
    });

    test('changePin: salt nuevo SOLO en la envoltura del PIN; la DEK y la '
        'recuperación no cambian', () async {
      final c = controller();
      await c.createVault(_pin);
      final dek = c.session.keys.dekBytes();
      final ref = _Stored(storage);

      expect(await c.changePin(oldPin: '000000', newPin: '246800'), isFalse);
      ref.expectSame(_Stored(storage), 'changePin con PIN viejo malo');

      expect(await c.changePin(oldPin: _pin, newPin: '246800'), isTrue);
      final after = _Stored(storage);
      expect(after.pinSalt, isNot(ref.pinSalt));
      expect(after.recovery, ref.recovery);
      expect(after.keyCheck, ref.keyCheck);
      final r = controller();
      expect(await r.unlockWithPin('246800'), isTrue);
      expect(r.session.keys.dekBytes(), dek);
    });

    test(
      'restore: misma DEK, nueva envoltura del PIN, misma recuperación',
      () async {
        final c = controller();
        final created = await c.createVault(_pin);
        final dek = c.session.keys.dekBytes();
        final ref = _Stored(storage);
        c.lock();
        expect(
          await controller().restoreFromRecovery(
            recoveryCode: created.recoveryCode,
            recoveryBackupJson: created.recoveryBackupJson,
            newPin: _pin,
          ),
          isTrue,
        );
        final after = _Stored(storage);
        expect(after.pinSalt, isNot(ref.pinSalt));
        expect(after.recovery, ref.recovery);
        expect(after.keyCheck, ref.keyCheck);
        final r = controller();
        expect(await r.unlockWithPin(_pin), isTrue);
        expect(r.session.keys.dekBytes(), dek);
      },
    );
  });
}
