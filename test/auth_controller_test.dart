import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/crypto/pin_attempt_limiter.dart';
import 'package:vault/core/crypto/wrapped_key.dart';
import 'package:vault/core/session/vault_session.dart';

import 'support/fakes.dart';

const pin = '123456';

void main() {
  late InMemorySecureStore storage;
  late FakeBiometricKeyStore biometrics;
  late FakeClock clock;

  /// Nueva instancia del controlador sobre el MISMO almacenamiento:
  /// equivale a cerrar y volver a abrir la app.
  AuthController newController({InMemorySecureStore? on}) => AuthController(
    storage: on ?? storage,
    biometricStore: biometrics,
    kdfParams: fastKdf,
    clock: clock.call,
    session: VaultSession.create(),
  );

  setUp(() {
    storage = InMemorySecureStore();
    biometrics = FakeBiometricKeyStore();
    clock = FakeClock();
  });

  group('Creación y DEK', () {
    test(
      'la DEK es de 256 bits, única por bóveda y estable al reabrir',
      () async {
        final a = newController();
        expect(await a.hasVault(), isFalse);
        await a.createVault(pin);
        expect(await a.hasVault(), isTrue);
        expect(a.isUnlocked, isTrue);
        final dek = a.session.keys.dekBytes();
        expect(dek.length, 32);

        // Reabrir: misma DEK.
        a.lock();
        expect(a.isUnlocked, isFalse);
        final b = newController();
        expect(await b.unlockWithPin(pin), isTrue);
        expect(b.session.keys.dekBytes(), dek);

        // Otra bóveda (otro dispositivo) → otra DEK.
        final other = newController(on: InMemorySecureStore());
        await other.createVault(pin);
        expect(other.session.keys.dekBytes(), isNot(equals(dek)));
      },
    );

    test(
      'no se puede crear dos veces (la DEK se genera una sola vez)',
      () async {
        final c = newController();
        await c.createVault(pin);
        await expectLater(c.createVault('999999'), throwsStateError);
      },
    );

    test('el código se muestra en grupos y se normaliza al derivar', () async {
      final result = await newController().createVault(pin);
      expect(
        result.recoveryCode,
        matches(RegExp(r'^([A-HJKMNP-Z2-9]{4}-){5}[A-HJKMNP-Z2-9]{4}$')),
      );
      expect(RecoveryCode.normalize(result.recoveryCode)!.length, 24);
      expect(
        RecoveryCode.normalize(
          ' ${result.recoveryCode.toLowerCase().replaceAll('-', ' ')} ',
        ),
        RecoveryCode.normalize(result.recoveryCode),
      );
      expect(RecoveryCode.normalize('ABCD'), isNull);
      expect(RecoveryCode.normalize('O' * 24), isNull); // 'O' es ambiguo
    });

    test('rechaza PIN demasiado corto', () async {
      await expectLater(newController().createVault('12'), throwsArgumentError);
    });
  });

  group('PIN', () {
    test('PIN correcto desbloquea, incorrecto no', () async {
      final c = newController();
      await c.createVault(pin);
      c.lock();
      expect(await c.unlockWithPin('000000'), isFalse);
      expect(c.isUnlocked, isFalse);
      expect(await c.unlockWithPin(pin), isTrue);
      expect(c.isUnlocked, isTrue);
    });

    test('lock() destruye las llaves en memoria', () async {
      final c = newController();
      await c.createVault(pin);
      final keys = c.session.keys;
      c.lock();
      expect(keys.isDestroyed, isTrue);
      expect(() => keys.dekBytes(), throwsStateError);
      expect(() => c.session.keys, throwsStateError);
    });

    test(
      'cambiar PIN conserva la DEK y los datos previos siguen descifrando',
      () async {
        final c = newController();
        await c.createVault(pin);
        final dek = c.session.keys.dekBytes();
        final crypto = CryptoService();

        // Datos cifrados ANTES del cambio de PIN con la subllave "files".
        final box = await crypto.encryptData('secreto', c.session.keys.files);
        final tmp = await Directory.systemTemp.createTemp('vault_test');
        addTearDown(() => tmp.delete(recursive: true));
        final plain = File('${tmp.path}/a.bin')
          ..writeAsBytesSync(List<int>.generate(3000, (i) => i % 256));
        final enc = File('${tmp.path}/a.vault');
        await crypto.encryptFile(plain, enc, c.session.keys.files);
        final envelopeBefore = storage.data[AuthController.pinEnvelopeKey];

        expect(await c.changePin(oldPin: 'malo00', newPin: '654321'), isFalse);
        expect(await c.changePin(oldPin: pin, newPin: '654321'), isTrue);
        final envelopeAfter = storage.data[AuthController.pinEnvelopeKey]!;
        expect(envelopeAfter, isNot(envelopeBefore));
        // Salt nuevo.
        expect(
          jsonDecode(envelopeAfter)['salt'],
          isNot(jsonDecode(envelopeBefore!)['salt']),
        );

        final reopened = newController();
        expect(await reopened.unlockWithPin(pin), isFalse);
        expect(await reopened.unlockWithPin('654321'), isTrue);
        expect(reopened.session.keys.dekBytes(), dek);
        expect(
          await crypto.decryptData(box, reopened.session.keys.files),
          'secreto',
        );
        final out = File('${tmp.path}/a.out');
        await crypto.decryptFile(enc, out, reopened.session.keys.files);
        expect(out.readAsBytesSync(), plain.readAsBytesSync());
      },
    );
  });

  group('Recuperación', () {
    test('código correcto devuelve la misma DEK (teléfono nuevo)', () async {
      final c = newController();
      final result = await c.createVault(pin);
      final dek = c.session.keys.dekBytes();

      final newPhone = newController(on: InMemorySecureStore());
      expect(
        await newPhone.restoreFromRecovery(
          // Como lo teclearía un usuario: minúsculas y espacios.
          recoveryCode: result.recoveryCode.toLowerCase().replaceAll('-', ' '),
          recoveryBackupJson: result.recoveryBackupJson,
          newPin: '4321',
        ),
        isTrue,
      );
      expect(newPhone.session.keys.dekBytes(), dek);

      // El PIN nuevo funciona tras reabrir.
      newPhone.lock();
      expect(await newPhone.unlockWithPin('4321'), isTrue);
      expect(newPhone.session.keys.dekBytes(), dek);
    });

    test('código incorrecto falla y no toca el estado', () async {
      final c = newController();
      final result = await c.createVault(pin);
      final wrongCode = RecoveryCode.generate();
      final fresh = InMemorySecureStore();
      final newPhone = newController(on: fresh);
      expect(
        await newPhone.restoreFromRecovery(
          recoveryCode: wrongCode,
          recoveryBackupJson: result.recoveryBackupJson,
          newPin: '4321',
        ),
        isFalse,
      );
      expect(newPhone.isUnlocked, isFalse);
      expect(fresh.data, isEmpty);
      // Formato inválido también devuelve false.
      expect(
        await newPhone.restoreFromRecovery(
          recoveryCode: 'no-es-un-codigo',
          recoveryBackupJson: result.recoveryBackupJson,
          newPin: '4321',
        ),
        isFalse,
      );
    });

    test('respaldo mal formado lanza FormatException', () async {
      final c = newController();
      await c.createVault(pin);
      await expectLater(
        c.restoreFromRecovery(
          recoveryCode: RecoveryCode.generate(),
          recoveryBackupJson: '{"type":"otro"}',
          newPin: '4321',
        ),
        throwsFormatException,
      );
      // La envoltura del PIN no se acepta como respaldo.
      expect(
        () => RecoveryBackup.parse(
          jsonEncode({
            'type': RecoveryBackup.type,
            ...jsonDecode(storage.data[AuthController.pinEnvelopeKey]!),
          }),
        ),
        throwsFormatException,
      );
    });

    test(
      'olvidé el PIN: restaurar en el mismo teléfono con el respaldo local',
      () async {
        final c = newController();
        final result = await c.createVault(pin);
        final dek = c.session.keys.dekBytes();
        c.lock();
        final local = await c.exportRecoveryBackup();
        expect(local, result.recoveryBackupJson);
        expect(
          await c.restoreFromRecovery(
            recoveryCode: result.recoveryCode,
            recoveryBackupJson: local!,
            newPin: '7777',
          ),
          isTrue,
        );
        expect(c.session.keys.dekBytes(), dek);
        c.lock();
        expect(await c.unlockWithPin(pin), isFalse);
        expect(await c.unlockWithPin('7777'), isTrue);
      },
    );

    test('el respaldo NO contiene la DEK ni la envoltura del PIN', () async {
      final c = newController();
      final result = await c.createVault(pin);
      final dek = c.session.keys.dekBytes();
      final backupJson = result.recoveryBackupJson;
      final backup = jsonDecode(backupJson) as Map<String, dynamic>;

      expect(backup.keys.toSet(), {
        'type',
        'v',
        'purpose',
        'kdf',
        'salt',
        'nonce',
        'ct',
        'mac',
      });
      expect(backup['purpose'], 'recovery');

      // Ni la DEK (en base64, hex o como secuencia de bytes en algún campo)...
      expect(backupJson.contains(base64Encode(dek)), isFalse);
      final hex = dek.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(backupJson.toLowerCase().contains(hex), isFalse);
      for (final field in ['salt', 'nonce', 'ct', 'mac']) {
        final bytes = base64Decode(backup[field] as String);
        expect(_containsSublist(bytes, dek), isFalse, reason: field);
      }
      // ...ni las subllaves...
      for (final k in [
        c.session.keys.files,
        c.session.keys.thumbs,
        c.session.keys.sqlcipher,
      ]) {
        expect(backupJson.contains(base64Encode(k.bytes)), isFalse);
      }
      // ...ni nada de la envoltura del PIN.
      final pinEnv =
          jsonDecode(storage.data[AuthController.pinEnvelopeKey]!)
              as Map<String, dynamic>;
      for (final field in ['salt', 'nonce', 'ct', 'mac']) {
        expect(
          backupJson.contains(pinEnv[field] as String),
          isFalse,
          reason: field,
        );
      }
      // El respaldo solo se abre con el código, nunca con el PIN.
      final wrapped = WrappedKey.fromJson(
        backup,
        expectedPurpose: WrapPurpose.recovery,
      );
      expect(await wrapped.unwrap(utf8.encode(pin)), isNull);
      expect(
        await wrapped.unwrap(
          utf8.encode(RecoveryCode.normalize(result.recoveryCode)!),
        ),
        dek,
      );
    });
  });

  group('Subllaves HKDF', () {
    test('distintas entre sí y deterministas', () async {
      final dek = randomBytes(32);
      final h1 = await KeyHierarchy.fromDek(dek);
      final h2 = await KeyHierarchy.fromDek(dek);
      final subkeys = [h1.sqlcipher.bytes, h1.files.bytes, h1.thumbs.bytes];
      for (final k in subkeys) {
        expect(k.length, 32);
        expect(k, isNot(equals(dek)));
      }
      expect(subkeys.map(base64Encode).toSet().length, 3);
      expect(h2.sqlcipher.bytes, h1.sqlcipher.bytes);
      expect(h2.files.bytes, h1.files.bytes);
      expect(h2.thumbs.bytes, h1.thumbs.bytes);
      expect(h2.keyCheck, h1.keyCheck);

      final h3 = await KeyHierarchy.fromDek(randomBytes(32));
      expect(h3.files.bytes, isNot(equals(h1.files.bytes)));
    });

    test('coinciden con HKDF-SHA256 (RFC 5869) calculado a mano', () async {
      final dek = randomBytes(32);
      final h = await KeyHierarchy.fromDek(dek);
      final hmac = Hmac.sha256();
      // Extract: PRK = HMAC(salt = 0^32, IKM = DEK)
      final prk = await hmac.calculateMac(
        dek,
        secretKey: SecretKey(List<int>.filled(32, 0)),
      );
      Future<List<int>> expand(String info) async => (await hmac.calculateMac([
        ...utf8.encode(info),
        1,
      ], secretKey: SecretKey(prk.bytes))).bytes;
      expect(h.sqlcipher.bytes, await expand('sqlcipher'));
      expect(h.files.bytes, await expand('files'));
      expect(h.thumbs.bytes, await expand('thumbs'));
    });
  });

  group('Retraso tras PIN incorrecto', () {
    test('5 fallos bloquean 30 s, persiste al reabrir y luego crece', () async {
      final c = newController();
      await c.createVault(pin);
      c.lock();

      for (var i = 0; i < 4; i++) {
        expect(await c.unlockWithPin('000000'), isFalse);
      }
      expect(await c.pinLockoutRemaining(), isNull);
      expect(await c.unlockWithPin('000000'), isFalse); // 5º fallo
      expect(await c.pinLockoutRemaining(), const Duration(seconds: 30));

      // Nueva instancia (app reabierta): sigue bloqueado, incluso con el PIN
      // correcto.
      final reopened = newController();
      clock.advance(const Duration(seconds: 29));
      await expectLater(
        reopened.unlockWithPin(pin),
        throwsA(isA<PinLockedOutException>()),
      );
      await expectLater(
        reopened.changePin(oldPin: pin, newPin: '1111'),
        throwsA(isA<PinLockedOutException>()),
      );

      // Pasado el plazo se puede volver a intentar; otro fallo → 60 s.
      clock.advance(const Duration(seconds: 2));
      expect(await reopened.pinLockoutRemaining(), isNull);
      expect(await reopened.unlockWithPin('000000'), isFalse);
      expect(await reopened.pinLockoutRemaining(), const Duration(seconds: 60));

      // Acertar resetea el contador.
      clock.advance(const Duration(seconds: 61));
      expect(await reopened.unlockWithPin(pin), isTrue);
      expect(await PinAttemptLimiter(storage, clock: clock.call).failures(), 0);
      reopened.lock();
      expect(await reopened.unlockWithPin('000000'), isFalse);
      expect(await reopened.pinLockoutRemaining(), isNull);
    });

    test('escalado y tope', () {
      expect(PinAttemptLimiter.delayForFailures(4), Duration.zero);
      expect(
        PinAttemptLimiter.delayForFailures(5),
        const Duration(seconds: 30),
      );
      expect(
        PinAttemptLimiter.delayForFailures(6),
        const Duration(seconds: 60),
      );
      expect(PinAttemptLimiter.delayForFailures(7), const Duration(minutes: 2));
      expect(PinAttemptLimiter.delayForFailures(8), const Duration(minutes: 5));
      expect(PinAttemptLimiter.delayForFailures(50), const Duration(hours: 1));
    });

    test('si el reloj se atrasa, la espera no supera la del nivel', () async {
      final limiter = PinAttemptLimiter(storage, clock: clock.call);
      for (var i = 0; i < 5; i++) {
        await limiter.registerFailure();
      }
      clock.advance(const Duration(days: -365));
      expect(await limiter.remainingLockout(), const Duration(seconds: 30));
    });

    test('estado corrupto falla cerrado', () async {
      storage.data[PinAttemptLimiter.storageKey] = 'basura';
      final limiter = PinAttemptLimiter(storage, clock: clock.call);
      expect(await limiter.remainingLockout(), isNotNull);
    });
  });

  group('Biometría', () {
    test(
      'activar, bloquear y desbloquear con biometría da la misma DEK',
      () async {
        final c = newController();
        await c.createVault(pin);
        final dek = c.session.keys.dekBytes();
        expect(await c.isBiometricUnlockEnabled(), isFalse);
        expect(await c.unlockWithBiometrics(), isFalse);

        await c.enableBiometricUnlock();
        expect(await c.isBiometricUnlockEnabled(), isTrue);
        expect(biometrics.stored, dek);

        final reopened = newController();
        expect(await reopened.unlockWithBiometrics(), isTrue);
        expect(reopened.session.keys.dekBytes(), dek);
      },
    );

    test('cancelar lanza BiometricCancelledException y no desactiva', () async {
      final c = newController();
      await c.createVault(pin);
      await c.enableBiometricUnlock();
      c.lock();
      biometrics.cancelNext = true;
      await expectLater(
        c.unlockWithBiometrics(),
        throwsA(isA<BiometricCancelledException>()),
      );
      expect(await c.isBiometricUnlockEnabled(), isTrue);
    });

    test('llave invalidada por el SO o ajena → false y se desactiva', () async {
      final c = newController();
      await c.createVault(pin);
      await c.enableBiometricUnlock();
      c.lock();

      biometrics.invalidate();
      expect(await c.unlockWithBiometrics(), isFalse);
      expect(await c.isBiometricUnlockEnabled(), isFalse);

      // DEK de otra bóveda en el almacén biométrico: se rechaza por key_check.
      expect(await c.unlockWithPin(pin), isTrue);
      await c.enableBiometricUnlock();
      c.lock();
      biometrics.stored = randomBytes(32);
      expect(await c.unlockWithBiometrics(), isFalse);
      expect(c.isUnlocked, isFalse);
    });

    test('activar requiere sesión abierta y biometría disponible', () async {
      final c = newController();
      await c.createVault(pin);
      c.lock();
      await expectLater(c.enableBiometricUnlock(), throwsStateError);
      expect(await c.unlockWithPin(pin), isTrue);
      biometrics.available = BiometricAvailability.notEnrolled;
      await expectLater(c.enableBiometricUnlock(), throwsStateError);
    });

    test('restaurar desde recuperación descarta la copia biométrica', () async {
      final c = newController();
      final result = await c.createVault(pin);
      await c.enableBiometricUnlock();
      await c.restoreFromRecovery(
        recoveryCode: result.recoveryCode,
        recoveryBackupJson: result.recoveryBackupJson,
        newPin: '2468',
      );
      expect(await c.isBiometricUnlockEnabled(), isFalse);
      expect(biometrics.stored, isNull);
    });
  });
}

bool _containsSublist(List<int> haystack, List<int> needle) {
  // Basta con buscar una ventana de 8 bytes de la DEK.
  final probe = Uint8List.fromList(needle.sublist(0, 8));
  for (var i = 0; i + probe.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < probe.length; j++) {
      if (haystack[i + j] != probe[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
