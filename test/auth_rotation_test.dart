// S-11 (rotación de la DEK, paso 6): llaves de la rotación en AuthController.
// Desbloqueo con PIN a mitad (ambas DEK), puente, changePin prohibido (M2),
// limpieza en discard/restore (A3), escrituras perdidas, y que NADA derivado
// del código viejo A envuelva la DEK nueva.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/crypto/wrapped_key.dart';
import 'package:vault/core/crypto/pin_attempt_limiter.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_s04.dart';
import 'package:vault/data/cloud/cloud_names.dart';

import 'support/fake_cloud.dart';
import 'support/fakes.dart';

const _pin = '123456';
const _email = 'yo@example.com';

/// Almacén que recuerda el valor anterior de cada escritura: [dropLast]
/// deshace las últimas N (simula `apply()` de Android: la app murió antes de
/// que llegaran a disco).
class DroppingStore extends InMemorySecureStore {
  final List<(String, String?)> _journal = [];

  @override
  Future<void> write(String key, String value) async {
    _journal.add((key, data[key]));
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    _journal.add((key, data[key]));
    await super.delete(key);
  }

  void dropLast(int n) {
    for (var i = 0; i < n && _journal.isNotEmpty; i++) {
      final (key, old) = _journal.removeLast();
      if (old == null) {
        data.remove(key);
      } else {
        data[key] = old;
      }
    }
  }
}

void main() {
  late DroppingStore store;
  late FakeBiometricKeyStore bio;
  late AuthController auth;
  late String codeA;

  AuthController fresh() => AuthController(
    storage: store,
    biometricStore: bio,
    kdfParams: fastKdf,
    session: VaultSession.create(),
  );

  Uint8List dekOf(KeyHierarchy k) => k.dekBytes();

  setUp(() async {
    store = DroppingStore();
    bio = FakeBiometricKeyStore();
    auth = fresh();
    codeA = (await auth.createVault(_pin)).recoveryCode;
  });

  tearDown(() => auth.lock());

  Future<String> prepare([AuthController? a]) async => (await (a ?? auth)
      .prepareRotation(_pin, toGen: 2, accountEmail: _email))!;

  /// Lleva la rotación hasta `reencrypting` (como haría el servicio).
  Future<String> toReencrypting() async {
    final b = await prepare();
    expect(await auth.confirmRotationCode(b), isTrue);
    final rec = (await auth.rotationRecord())!;
    await auth.rotationStore.save(rec.copyWith(phase: RotationPhase.freezing));
    await auth.enterReencrypting();
    return b;
  }

  Future<void> setPhase(AuthController a, RotationPhase p) async {
    final rec = (await a.rotationRecord())!;
    await a.rotationStore.save(rec.copyWith(phase: p));
  }

  group('preparar', () {
    test('PIN incorrecto: null, cuenta intento, no escribe nada', () async {
      final before = Map.of(store.data);
      expect(
        await auth.prepareRotation('000000', toGen: 2, accountEmail: _email),
        isNull,
      );
      final attempts = jsonDecode(store.data[PinAttemptLimiter.storageKey]!);
      expect(attempts['failures'], 1);
      expect(
        store.data.keys.where((k) => k.startsWith('vault.v1.rotation')),
        isEmpty,
      );
      expect(
        store.data[AuthController.pinEnvelopeKey],
        before[AuthController.pinEnvelopeKey],
      );
    });

    test(
      'crea DEK nueva, código B y sus envolturas; la sesión sigue en gen 1',
      () async {
        final oldCheck = auth.session.keys.keyCheck;
        final b = await prepare();
        expect(RecoveryCode.normalize(b), isNotNull);
        expect(b, isNot(codeA));
        final rec = (await auth.rotationRecord())!;
        expect(rec.phase, RotationPhase.prepared);
        expect((rec.fromGen, rec.toGen), (1, 2));
        expect(rec.oldKeyCheck, oldCheck);
        expect(rec.newKeyCheck, isNot(oldCheck));
        expect(store.data[RotationKeyStore.nextPinEnvelopeKey], isNotNull);
        expect(store.data[RotationKeyStore.nextRecoveryBackupKey], isNotNull);
        // La envoltura principal, el respaldo local y la sesión no cambian.
        expect(auth.session.currentGen, 1);
        expect(auth.session.keys.keyCheck, oldCheck);
        expect(auth.hasNextKeys, isTrue);
        // Lo nuevo sigue cifrándose con la vieja.
        expect(auth.session.keyring!.isDual, isFalse);
      },
    );

    test('no se puede preparar dos veces ni con toGen inválido', () async {
      await expectLater(
        auth.prepareRotation(_pin, toGen: 1, accountEmail: _email),
        throwsArgumentError,
      );
      await prepare();
      await expectLater(prepare(), throwsA(isA<RotationInProgressException>()));
    });

    test('corte antes de escribir el registro: los restos se barren', () async {
      await prepare();
      store.dropLast(2); // se pierden el borrado del puente y el registro
      expect(store.data[RotationKeyStore.recordKey], isNull);
      expect(store.data[RotationKeyStore.nextPinEnvelopeKey], isNotNull);
      auth.lock();
      auth = fresh();
      expect(await auth.unlockWithPin(_pin), isTrue);
      expect(await auth.rotationRecord(), isNull);
      expect(
        store.data.keys.where((k) => k.startsWith('vault.v1.rotation')),
        isEmpty,
      );
      expect(auth.session.currentGen, 1);
    });
  });

  group('confirmar el código y el puente (A2)', () {
    test('código equivocado: false; el correcto crea el puente', () async {
      final b = await prepare();
      expect(await auth.confirmRotationCode(codeA), isFalse);
      expect((await auth.rotationRecord())!.phase, RotationPhase.prepared);
      final dekOld = dekOf(auth.session.keys);
      expect(await auth.confirmRotationCode(b), isTrue);
      expect((await auth.rotationRecord())!.phase, RotationPhase.confirmed);
      final bridge = RecoveryBackup.parse((await auth.pendingBridgeBackup())!);
      final svc = KeyRecoveryService(kdfParams: fastKdf);
      // El puente da la DEK VIEJA con B, y nada con A.
      expect(await svc.recoverDek(b, bridge), dekOld);
      expect(await svc.recoverDek(codeA, bridge), isNull);
      // Idempotente.
      expect(await auth.confirmRotationCode(b), isTrue);
    });

    test(
      'M1: otro código nuevo solo en prepared; el anterior deja de valer',
      () async {
        final b1 = await prepare();
        final b2 = (await auth.regenerateNextRecoveryCode(_pin))!;
        expect(b2, isNot(b1));
        expect(await auth.confirmRotationCode(b1), isFalse);
        expect(await auth.confirmRotationCode(b2), isTrue);
        await expectLater(
          auth.regenerateNextRecoveryCode(_pin),
          throwsA(isA<RotationInProgressException>()),
        );
      },
    );

    test('el puente se sube con el patrón S-04', () async {
      final b = await prepare();
      await auth.confirmRotationCode(b);
      final json = (await auth.pendingBridgeBackup())!;
      final cloud = FakeCloudStorage();
      final name = CloudNames.bridgeBackup(1);
      // Restos de intentos anteriores con el mismo nombre.
      final old1 = await cloud.uploadBytes(
        bytes: Uint8List.fromList([1]),
        name: name,
      );
      await cloud.uploadBytes(bytes: Uint8List.fromList([2]), name: name);
      final other = await cloud.uploadBytes(
        bytes: Uint8List.fromList([3]),
        name: 'recovery_backup.json',
      );
      final bytes = Uint8List.fromList(utf8.encode(json));

      // Verificación fallida: lo recién creado se borra y lo anterior queda.
      cloud.corruptNextBytesUpload = true;
      await expectLater(
        uploadBytesReplacingByName(cloud, name: name, bytes: bytes),
        throwsA(isA<CloudUploadMismatchException>()),
      );
      expect(cloud.names.where((n) => n == name).length, 2);

      final up = await uploadBytesReplacingByName(
        cloud,
        name: name,
        bytes: bytes,
      );
      expect(cloud.names.where((n) => n == name).length, 1);
      expect(cloud.byName(name)!.id, up.id);
      expect(cloud.allVersionsOf(name), [bytes], reason: 'sin revisiones');
      expect(cloud.byName('recovery_backup.json')!.id, other.id);
      expect(up.id, isNot(old1.id));
      await auth.bridgeBackupUploaded();
      expect(await auth.pendingBridgeBackup(), isNull);
    });
  });

  group('desbloqueo a mitad de rotación', () {
    test('hasta freezing: sesión con la vieja y la nueva en memoria', () async {
      final b = await prepare();
      await auth.confirmRotationCode(b);
      for (final p in [
        RotationPhase.prepared,
        RotationPhase.confirmed,
        RotationPhase.freezing,
      ]) {
        await setPhase(auth, p);
        auth.lock();
        expect(auth.hasNextKeys, isFalse, reason: 'lock la destruye');
        auth = fresh();
        expect(await auth.unlockWithPin(_pin), isTrue);
        expect(auth.session.keyring!.isDual, isFalse, reason: '$p');
        expect(auth.session.currentGen, 1);
        expect(auth.hasNextKeys, isTrue, reason: '$p');
      }
    });

    test(
      'con el PIN se obtienen AMBAS DEK (reencrypting..switchingLocal)',
      () async {
        await toReencrypting();
        final oldCheck = (await auth.rotationRecord())!.oldKeyCheck;
        final newCheck = (await auth.rotationRecord())!.newKeyCheck;
        for (final p in [
          RotationPhase.reencrypting,
          RotationPhase.uploading,
          RotationPhase.rekeyingDb,
          RotationPhase.switchingLocal,
        ]) {
          await setPhase(auth, p);
          auth.lock();
          auth = fresh();
          expect(await auth.unlockWithPin(_pin), isTrue);
          final ring = auth.session.keyring!;
          expect(ring.isDual, isTrue, reason: '$p');
          expect(ring.currentGen, 2);
          expect(ring.current.keyCheck, newCheck);
          expect(ring.previousGen, 1);
          expect(ring.previous!.keyCheck, oldCheck);
          expect(auth.session.filesKeyFor(1), isNotNull);
          expect(auth.session.filesKeyFor(2), isNotNull);
          expect(auth.session.dbCandidates.map((c) => c.$1), [1, 2]);
        }
      },
    );

    test(
      'el segundo Argon2id no cuenta intento; un PIN malo cuenta uno',
      () async {
        await toReencrypting();
        auth.lock();
        auth = fresh();
        expect(await auth.unlockWithPin('000000'), isFalse);
        expect(
          jsonDecode(store.data[PinAttemptLimiter.storageKey]!)['failures'],
          1,
        );
        expect(await auth.unlockWithPin(_pin), isTrue);
        expect(await auth.pinLockoutRemaining(), isNull);
        expect(auth.session.keyring!.isDual, isTrue);
      },
    );

    test('pasar a reencrypting apaga la biometría y la recuerda', () async {
      await auth.enableBiometricUnlock();
      final b = await prepare();
      await auth.confirmRotationCode(b);
      await setPhase(auth, RotationPhase.freezing);
      await auth.enterReencrypting();
      expect(await auth.isBiometricUnlockEnabled(), isFalse);
      expect(bio.stored, isNull, reason: 'el archivo guardaba la DEK vieja');
      expect((await auth.rotationRecord())!.biometricWasEnabled, isTrue);
      expect(auth.session.keyring!.isDual, isTrue);
      await expectLater(
        auth.enableBiometricUnlock(),
        throwsA(isA<RotationInProgressException>()),
      );
    });

    test('sin la DEK nueva en memoria no se pasa a reencrypting', () async {
      await auth.enableBiometricUnlock();
      final b = await prepare();
      await auth.confirmRotationCode(b);
      await setPhase(auth, RotationPhase.freezing);
      auth.lock();
      auth = fresh();
      expect(await auth.unlockWithBiometrics(), isTrue); // sin PIN
      expect(auth.hasNextKeys, isFalse);
      await expectLater(
        auth.enterReencrypting(),
        throwsA(isA<RotationInProgressException>()),
      );
    });

    test(
      'falta next_pin_envelope en reencrypting: blockedCorrupt, abre la vieja',
      () async {
        await toReencrypting();
        store.data.remove(RotationKeyStore.nextPinEnvelopeKey);
        auth.lock();
        auth = fresh();
        expect(await auth.unlockWithPin(_pin), isTrue);
        final rec = (await auth.rotationRecord())!;
        expect(rec.phase, RotationPhase.blockedCorrupt);
        expect(rec.resumePhase, RotationPhase.reencrypting);
        expect(auth.session.keyring!.isDual, isFalse);
        expect(auth.session.currentGen, 1);
      },
    );

    test(
      'registro que no es de esta bóveda: blockedForeign y abre igual',
      () async {
        await prepare();
        final rec = (await auth.rotationRecord())!;
        await auth.rotationStore.save(
          RotationRecord(
            id: rec.id,
            fromGen: 1,
            toGen: 2,
            phase: RotationPhase.uploading,
            reason: rec.reason,
            oldKeyCheck: 'otra',
            newKeyCheck: 'otra-más',
            accountEmail: _email,
            startedAt: 0,
            updatedAt: 0,
          ),
        );
        auth.lock();
        auth = fresh();
        expect(await auth.unlockWithPin(_pin), isTrue);
        final after = (await auth.rotationRecord())!;
        expect(after.phase, RotationPhase.blockedForeign);
        expect(after.resumePhase, RotationPhase.uploading);
        expect(auth.session.currentGen, 1);
      },
    );
  });

  group('cambio de la envoltura principal (switchingLocal)', () {
    test('el PIN pasa a dar la DEK nueva; la vieja desaparece', () async {
      final b = await toReencrypting();
      final dekNew = dekOf(auth.session.keys);
      final newCheck = auth.session.keys.keyCheck;
      await expectLater(
        auth.switchPrimary(),
        throwsA(isA<RotationInProgressException>()),
        reason: 'solo en switchingLocal',
      );
      await setPhase(auth, RotationPhase.switchingLocal);
      await auth.switchPrimary();
      await auth.switchPrimary(); // idempotente
      expect(auth.session.keyring!.isDual, isFalse);
      expect(auth.session.currentGen, 2);
      expect(await auth.currentKeyGen(), 2);
      expect(store.data[AuthController.keyCheckKey], newCheck);
      expect(store.data[RotationKeyStore.nextPinEnvelopeKey], isNull);
      expect(store.data[RotationKeyStore.nextRecoveryBackupKey], isNull);
      // El respaldo local es el de B.
      final local = RecoveryBackup.parse(
        store.data[AuthController.recoveryBackupKey]!,
      );
      final svc = KeyRecoveryService(kdfParams: fastKdf);
      expect(await svc.recoverDek(b, local), dekNew);
      expect(await svc.recoverDek(codeA, local), isNull);
      // Reabrir con el PIN: una sola generación, la nueva.
      auth.lock();
      auth = fresh();
      expect(await auth.unlockWithPin(_pin), isTrue);
      expect(auth.session.keyring!.isDual, isFalse);
      expect(auth.session.currentGen, 2);
      expect(auth.session.keys.keyCheck, newCheck);
    });

    test(
      'escrituras perdidas en switchingLocal: el PIN sigue abriendo',
      () async {
        await toReencrypting();
        await setPhase(auth, RotationPhase.switchingLocal);
        await auth.switchPrimary();
        // Se pierden los dos borrados y la escritura de pin_envelope.
        store.dropLast(3);
        auth.lock();
        auth = fresh();
        expect(await auth.unlockWithPin(_pin), isTrue);
        // La vieja + next_pin_envelope: dos llaves; se repite el cambio.
        expect(auth.session.keyring!.isDual, isTrue);
        await auth.switchPrimary();
        auth.lock();
        auth = fresh();
        expect(await auth.unlockWithPin(_pin), isTrue);
        expect(auth.session.currentGen, 2);
        expect(auth.session.keyring!.isDual, isFalse);
      },
    );
  });

  group('operaciones prohibidas durante la rotación', () {
    test('M2: changePin lanza y no cuenta intento', () async {
      await prepare();
      store.data.remove(PinAttemptLimiter.storageKey);
      await expectLater(
        auth.changePin(oldPin: _pin, newPin: '654321'),
        throwsA(isA<RotationInProgressException>()),
      );
      expect(store.data[PinAttemptLimiter.storageKey], isNull);
      // El PIN no cambió.
      auth.lock();
      auth = fresh();
      expect(await auth.unlockWithPin(_pin), isTrue);
    });

    test('regenerar el código "ligero" tampoco', () async {
      await prepare();
      await expectLater(
        auth.regenerateRecoveryCode(_pin),
        throwsA(isA<RotationInProgressException>()),
      );
    });

    test('cancelar solo hasta freezing', () async {
      await toReencrypting();
      await expectLater(
        auth.abandonRotation(),
        throwsA(isA<RotationInProgressException>()),
      );
    });

    test('cancelar en prepared borra todo lo de la rotación', () async {
      await prepare();
      await auth.abandonRotation();
      expect(
        store.data.keys.where((k) => k.startsWith('vault.v1.rotation')),
        isEmpty,
      );
      expect(auth.hasNextKeys, isFalse);
      await auth.changePin(oldPin: _pin, newPin: '654321');
    });
  });

  group('A3: limpieza de las claves de rotación', () {
    test('discardLocalKeys borra registro, envolturas y generación', () async {
      await toReencrypting();
      store.data[AuthController.keyGenKey] = '2';
      await auth.discardLocalKeys();
      expect(
        store.data.keys.where(
          (k) => k.startsWith('vault.v1.rotation') || k == 'vault.v1.key_gen',
        ),
        isEmpty,
      );
    });

    test('restaurar no hereda una rotación y escribe la generación', () async {
      await toReencrypting();
      final backup = store.data[AuthController.recoveryBackupKey]!;
      auth.lock();
      // Reinstalación: el Keychain conserva la rotación pero no la bóveda.
      store.data.remove(AuthController.pinEnvelopeKey);
      auth = fresh();
      expect(
        await auth.restoreFromRecovery(
          recoveryCode: codeA,
          recoveryBackupJson: backup,
          newPin: '654321',
        ),
        isTrue,
      );
      expect(await auth.rotationRecord(), isNull);
      expect(
        store.data.keys.where((k) => k.startsWith('vault.v1.rotation')),
        isEmpty,
      );
      expect(await auth.currentKeyGen(), 1);
      // Con la generación de un respaldo kN.
      auth.lock();
      store.data.remove(AuthController.pinEnvelopeKey);
      auth = fresh();
      final cand = (await auth.verifyRecoveryCode(
        recoveryCode: codeA,
        recoveryBackupJson: backup,
      ))!;
      await auth.commitRestore(cand, '654321', keyGen: 3);
      expect(await auth.currentKeyGen(), 3);
      expect(auth.session.currentGen, 3);
    });

    test('crear una bóveda borra restos de rotación del Keychain', () async {
      await prepare();
      auth.lock();
      store.data.remove(AuthController.pinEnvelopeKey);
      store.data[AuthController.keyGenKey] = '4';
      auth = fresh();
      await auth.createVault(_pin);
      expect(await auth.rotationRecord(), isNull);
      expect(await auth.currentKeyGen(), 1);
    });
  });

  test('NADA derivado del código viejo A envuelve la DEK nueva', () async {
    final b = await toReencrypting();
    final dekNew = dekOf(auth.session.keys);
    final svc = KeyRecoveryService(kdfParams: fastKdf);
    var openedWithA = 0;
    var openedNewWithB = 0;
    for (final entry in store.data.entries) {
      RecoveryBackup? backup;
      try {
        backup = RecoveryBackup.parse(entry.value);
      } on FormatException {
        backup = null;
      }
      if (backup != null) {
        final withA = await svc.recoverDek(codeA, backup);
        if (withA != null) {
          openedWithA++;
          expect(withA, isNot(dekNew), reason: entry.key);
        }
        final withB = await svc.recoverDek(b, backup);
        if (withB != null && _eq(withB, dekNew)) openedNewWithB++;
      }
      // Ninguna envoltura (de cualquier propósito) abre con A.
      for (final purpose in WrapPurpose.values) {
        try {
          final w = WrappedKey.decode(entry.value, expectedPurpose: purpose);
          final norm = RecoveryCode.normalize(codeA)!;
          final d = await w.unwrap(utf8.encode(norm));
          if (d != null) expect(d, isNot(dekNew), reason: entry.key);
        } on FormatException {
          // no es una envoltura de ese propósito
        }
      }
    }
    // A solo abre el respaldo local viejo (DEK vieja) hasta el cambio.
    expect(openedWithA, 1);
    expect(openedNewWithB, 1); // next_recovery_backup
  });
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
