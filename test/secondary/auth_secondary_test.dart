// Fase 8, paso 6 (DISENO_SENUELO §3, §6.10, §8, §9): llaves de la bóveda
// secundaria en AuthController, desbloqueo con dos derivaciones en paralelo,
// límite de intentos único (C1), A2/reauthPrimary, crear / cambiar PIN /
// eliminar y la reconciliación del arranque.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/argon2_backend.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/kdf.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/pin_attempt_limiter.dart';
import 'package:vault/core/crypto/wrapped_key.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/vault_bootstrap.dart';

import '../support/fakes.dart';
import '../support/rotation_env.dart' show DroppingStore, fakeCipherOpener;

const _pinP = '111111';
const _pinS = '482913';

/// Argon2 que cuenta derivaciones (y concurrencia) y puede esperar.
class _CountingArgon2 implements Argon2Backend {
  int calls = 0;
  int active = 0;
  int maxActive = 0;
  Duration delay = Duration.zero;
  Completer<void>? hold;

  @override
  String get name => 'counting';

  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      final h = hold;
      if (h != null) await h.future;
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return await const DartArgon2Backend().derive(
        secret: secret,
        salt: salt,
        params: params,
      );
    } finally {
      active--;
    }
  }
}

/// Almacén que falla al escribir/borrar/leer claves concretas.
class _FaultyStore extends DroppingStore {
  String? failWrite;
  String? failDelete;
  String? failRead;

  @override
  Future<void> write(String key, String value) async {
    if (key == failWrite) throw const FileSystemException('fallo simulado');
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (key == failDelete) throw const FileSystemException('fallo simulado');
    return super.delete(key);
  }

  @override
  Future<String?> read(String key) async {
    if (key == failRead) throw const FileSystemException('fallo simulado');
    return super.read(key);
  }
}

void main() {
  sqfliteFfiInit();
  late Directory base;
  late _FaultyStore store;
  late FakeBiometricKeyStore bio;
  late FakeClock clock;
  late VaultSession session;
  late AuthController auth;
  late _CountingArgon2 argon;
  late String code;

  AuthController newAuth() => AuthController(
    storage: store,
    biometricStore: bio,
    kdfParams: fastKdf,
    session: session,
    clock: clock.call,
    excludeFromBackup: (_) async {},
  );

  setUp(() async {
    base = await Directory.systemTemp.createTemp('auth_alt');
    await AppPaths.init(baseDir: base);
    store = _FaultyStore();
    bio = FakeBiometricKeyStore();
    clock = FakeClock();
    session = VaultSession.create();
    argon = _CountingArgon2();
    Argon2Backend.current = argon;
    auth = newAuth();
    code = (await auth.createVault(_pinP)).recoveryCode;
  });

  tearDown(() async {
    Argon2Backend.current = null;
    AppPaths.resetForTesting();
    try {
      await base.delete(recursive: true);
    } catch (_) {}
  });

  Map<String, String> nonAlt() => {
    for (final e in store.data.entries)
      if (!e.key.startsWith('vault.v1.alt.')) e.key: e.value,
  };

  Future<int> failures() =>
      PinAttemptLimiter(store, clock: clock.call).failures();

  Future<void> createAlt({bool disableBio = false}) async {
    expect(
      await auth.createSecondaryVault(
        primaryPin: _pinP,
        newPin: _pinS,
        disableBiometrics: disableBio,
      ),
      isTrue,
    );
  }

  Future<bool> unlock(String pin) async {
    auth.lock();
    return auth.unlockWithPin(pin);
  }

  group('G1: sin secundaria', () {
    test(
      'el desbloqueo es el de siempre: UNA derivación, sin claves alt',
      () async {
        auth.lock();
        final before = Map.of(store.data);
        argon.calls = 0;
        expect(await auth.unlockWithPin(_pinP), isTrue);
        expect(argon.calls, 1);
        expect(session.slot, VaultSlot.primary);
        expect(store.data.keys.where((k) => k.contains('.alt.')), isEmpty);
        expect(store.data, before);
        // Incorrecto: también una sola.
        auth.lock();
        argon.calls = 0;
        expect(await auth.unlockWithPin('999999'), isFalse);
        expect(argon.calls, 1);
      },
    );

    test('el arranque no escribe nada ni crea alt/', () async {
      final before = Map.of(store.data);
      await auth.reconcileSecondaryAtStartup(primaryExists: true);
      expect(store.data, before);
      expect(VaultPaths.secondary.exists, isFalse);
      expect(await auth.secondaryStatus(), SecondaryVaultStatus.none);
      expect(await auth.hasSecondaryVault(), isFalse);
    });
  });

  group('crear', () {
    test('exige el PIN principal y la principal abierta; envoltura altPin con '
        'los parámetros de la principal; alt/ creado; sin marca C1', () async {
      expect(
        await auth.createSecondaryVault(primaryPin: '000000', newPin: _pinS),
        isFalse,
      );
      expect(store.data.containsKey(AuthController.altPinEnvelopeKey), isFalse);
      await createAlt();
      final raw = store.data[AuthController.altPinEnvelopeKey]!;
      final alt = WrappedKey.decode(raw, expectedPurpose: WrapPurpose.altPin);
      final prim = WrappedKey.decode(
        store.data[AuthController.pinEnvelopeKey]!,
        expectedPurpose: WrapPurpose.pin,
      );
      expect(alt.kdf, prim.kdf);
      expect(
        () => WrappedKey.decode(raw, expectedPurpose: WrapPurpose.pin),
        throwsFormatException,
      );
      expect(VaultPaths.secondary.exists, isTrue);
      expect(store.data.containsKey(AuthController.altDbCreatedKey), isFalse);
      expect(await auth.secondaryStatus(), SecondaryVaultStatus.active);
      // Una segunda vez: ya existe.
      await expectLater(
        auth.createSecondaryVault(primaryPin: _pinP, newPin: '739164'),
        throwsA(isA<SecondaryVaultException>()),
      );
      // Bloqueada: no.
      auth.lock();
      await expectLater(
        auth.createSecondaryVault(primaryPin: _pinP, newPin: '739164'),
        throwsStateError,
      );
    });

    test(
      'reglas del PIN (en memoria contra el principal), sin escribir nada',
      () async {
        final before = Map.of(store.data);
        for (final (pin, reason) in [
          (_pinP, PinNotAllowedReason.collision),
          ('111112', PinNotAllowedReason.tooClose),
        ]) {
          await expectLater(
            auth.createSecondaryVault(primaryPin: _pinP, newPin: pin),
            throwsA(
              isA<PinNotAllowedException>().having(
                (e) => e.reason,
                'reason',
                reason,
              ),
            ),
          );
        }
        expect(store.data, before);
        expect(VaultPaths.secondary.exists, isFalse);
        expect(
          PinNotAllowedException.message,
          'Ese PIN no está disponible. Elige otro.',
        );
      },
    );

    test('M6: con un PIN principal heredado de 4 dígitos, el secundario no '
        'puede empezar por él', () async {
      // Envoltura heredada de 4 dígitos (antes de S-06) para la misma DEK.
      final dek = session.keys.dekBytes();
      final legacy = await WrappedKey.wrap(
        dek: dek,
        secret: utf8.encode('1234'),
        purpose: WrapPurpose.pin,
        kdf: fastKdf,
      );
      store.data[AuthController.pinEnvelopeKey] = legacy.encode();
      await expectLater(
        auth.createSecondaryVault(primaryPin: '1234', newPin: '123456'),
        throwsA(
          isA<PinNotAllowedException>().having(
            (e) => e.reason,
            'r',
            PinNotAllowedReason.prefix,
          ),
        ),
      );
      expect(
        await auth.createSecondaryVault(primaryPin: '1234', newPin: '512346'),
        isTrue,
      );
    });

    test('prohibido con una rotación registrada', () async {
      await auth.prepareRotation(_pinP, toGen: 2, accountEmail: 'a@b.c');
      await expectLater(
        auth.createSecondaryVault(primaryPin: _pinP, newPin: _pinS),
        throwsA(isA<RotationInProgressException>()),
      );
    });

    test('M5: la biometría se apaga ANTES de escribir la envoltura (corte '
        'entre medias: biometría apagada y sin secundaria)', () async {
      await auth.enableBiometricUnlock();
      expect(await auth.isBiometricUnlockEnabled(), isTrue);
      store.failWrite = AuthController.altPinEnvelopeKey;
      await expectLater(
        auth.createSecondaryVault(
          primaryPin: _pinP,
          newPin: _pinS,
          disableBiometrics: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await auth.isBiometricUnlockEnabled(), isFalse);
      expect(store.data.containsKey(AuthController.altPinEnvelopeKey), isFalse);
      expect(VaultPaths.secondary.exists, isTrue); // restos
      store.failWrite = null;
      await auth.reconcileSecondaryAtStartup(primaryExists: true);
      expect(VaultPaths.secondary.exists, isFalse); // fila 2
      expect(await unlock(_pinP), isTrue);
    });

    test('escritura de la envoltura perdida (apply): no hay secundaria y el '
        'arranque limpia alt/', () async {
      await createAlt();
      store.dropLast(1); // la envoltura no llegó a disco
      expect(store.data.containsKey(AuthController.altPinEnvelopeKey), isFalse);
      await auth.reconcileSecondaryAtStartup(primaryExists: true);
      expect(VaultPaths.secondary.exists, isFalse);
      expect(await unlock(_pinS), isFalse);
      expect(await unlock(_pinP), isTrue);
    });
  });

  group('desbloqueo', () {
    test('cada PIN abre SU bóveda; uno incorrecto, ninguna', () async {
      await createAlt();
      expect(await unlock(_pinP), isTrue);
      expect(session.slot, VaultSlot.primary);
      final primaryCheck = session.keys.keyCheck;
      expect(await unlock(_pinS), isTrue);
      expect(session.slot, VaultSlot.secondary);
      expect(session.keys.keyCheck, isNot(primaryCheck));
      expect(session.currentGen, 1);
      expect(await unlock('999999'), isFalse);
      expect(session.isUnlocked, isFalse);
    });

    test('dos derivaciones SIEMPRE y en paralelo: el tiempo no depende de '
        'cuál acierta', () async {
      await createAlt();
      argon.delay = const Duration(milliseconds: 200);
      final times = <String, int>{};
      for (final (name, pin) in [
        ('principal', _pinP),
        ('secundaria', _pinS),
        ('incorrecto', '999999'),
      ]) {
        auth.lock();
        argon.calls = 0;
        argon.maxActive = 0;
        final sw = Stopwatch()..start();
        await auth.unlockWithPin(pin);
        times[name] = sw.elapsedMilliseconds;
        expect(argon.calls, 2, reason: name);
        expect(argon.maxActive, 2, reason: '$name: en paralelo');
      }
      for (final t in times.values) {
        expect(t, greaterThanOrEqualTo(200));
        expect(t, lessThan(390), reason: 'paralelo (no 2 × 200 ms): $times');
      }
    });

    test('G6/M3: envoltura alt ilegible o con otros parámetros: "Dañada", la '
        'principal abre con UNA derivación', () async {
      await createAlt();
      final good = store.data[AuthController.altPinEnvelopeKey]!;
      for (final bad in [
        'basura',
        (await WrappedKey.wrap(
          dek: List.filled(32, 7),
          secret: utf8.encode(_pinS),
          purpose: WrapPurpose.altPin,
          kdf: const Argon2Params(
            memoryKiB: 128,
            iterations: 2,
            parallelism: 1,
          ),
        )).encode(),
      ]) {
        store.data[AuthController.altPinEnvelopeKey] = bad;
        expect(await auth.secondaryStatus(), SecondaryVaultStatus.damaged);
        auth.lock();
        argon.calls = 0;
        expect(await auth.unlockWithPin(_pinP), isTrue);
        expect(argon.calls, 1);
        expect(await unlock(_pinS), isFalse);
      }
      store.data[AuthController.altPinEnvelopeKey] = good;
      expect(await unlock(_pinS), isTrue);
    });

    test('envolturas intercambiadas: ninguna abre y la principal no se rompe '
        'al restaurarlas', () async {
      await createAlt();
      final p0 = store.data[AuthController.pinEnvelopeKey]!;
      final a0 = store.data[AuthController.altPinEnvelopeKey]!;
      store.data[AuthController.pinEnvelopeKey] = a0;
      store.data[AuthController.altPinEnvelopeKey] = p0;
      auth.lock();
      await expectLater(
        auth.unlockWithPin(_pinS),
        throwsFormatException, // la "principal" no es una envoltura de PIN
      );
      store.data[AuthController.pinEnvelopeKey] = p0;
      store.data[AuthController.altPinEnvelopeKey] = a0;
      expect(await unlock(_pinP), isTrue);
    });
  });

  group('C1: un solo contador; la secundaria no lo pone a cero', () {
    test('4 fallos + secundaria no evitan la espera; tras ella la secundaria '
        'tampoco la quita; la principal sí', () async {
      await createAlt();
      auth.lock();
      for (var i = 0; i < 4; i++) {
        expect(await auth.unlockWithPin('99999$i'), isFalse);
      }
      expect(await failures(), 4);
      expect(await auth.unlockWithPin(_pinS), isTrue);
      expect(await failures(), 4, reason: 'no se pone a cero');
      expect(await auth.pinLockoutRemaining(), isNull);
      auth.lock();
      expect(await auth.unlockWithPin('999990'), isFalse);
      expect(await failures(), 5);
      expect(await auth.pinLockoutRemaining(), isNotNull);
      await expectLater(
        auth.unlockWithPin(_pinS),
        throwsA(isA<PinLockedOutException>()),
      );
      clock.advance(const Duration(seconds: 31));
      expect(await auth.unlockWithPin(_pinS), isTrue);
      expect(await failures(), 5, reason: 'la espera ya cumplida, sin reset');
      auth.lock();
      expect(await auth.unlockWithPin('999990'), isFalse);
      expect(await failures(), 6);
      expect(
        (await auth.pinLockoutRemaining())!.inSeconds,
        greaterThan(31),
        reason: 'escala a 60 s como sin secundaria',
      );
      clock.advance(const Duration(minutes: 2));
      expect(await unlock(_pinP), isTrue);
      expect(await failures(), 0);
    });

    test(
      'la secundaria 20 veces seguidas no bloquea ni cambia el contador',
      () async {
        await createAlt();
        for (var i = 0; i < 20; i++) {
          expect(await unlock(_pinS), isTrue);
        }
        expect(await failures(), 0);
        expect(await auth.pinLockoutRemaining(), isNull);
      },
    );

    test(
      'matar la app durante la derivación de la secundaria deja el +1',
      () async {
        await createAlt();
        auth.lock();
        argon.hold = Completer<void>();
        final running = auth.unlockWithPin(_pinS);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(await failures(), 1, reason: 'contado antes de derivar');
        argon.hold!.complete();
        argon.hold = null;
        expect(await running, isTrue);
        expect(await failures(), 0);
      },
    );
  });

  group('A2: con sesión abierta nunca se cambia de bóveda', () {
    test(
      'PIN de la otra bóveda = "incorrecto"; misma sesión y época',
      () async {
        await createAlt();
        expect(await unlock(_pinP), isTrue);
        var epoch = session.epoch;
        expect(await auth.unlockWithPin(_pinS), isFalse);
        expect(session.slot, VaultSlot.primary);
        expect(session.epoch, epoch);
        expect(await auth.unlockWithPin(_pinP), isTrue);
        expect(session.slot, VaultSlot.primary);

        expect(await unlock(_pinS), isTrue);
        epoch = session.epoch;
        expect(await auth.unlockWithPin(_pinP), isFalse);
        expect(session.slot, VaultSlot.secondary);
        expect(session.epoch, epoch);
      },
    );

    test('reauthPrimary: solo la principal abierta; el PIN secundario es '
        'incorrecto', () async {
      await createAlt();
      expect(await unlock(_pinP), isTrue);
      expect(await auth.reauthPrimary(_pinP), isTrue);
      expect(await auth.reauthPrimary(_pinS), isFalse);
      expect(session.slot, VaultSlot.primary);
      expect(await unlock(_pinS), isTrue);
      await expectLater(auth.reauthPrimary(_pinP), throwsStateError);
      expect(session.slot, VaultSlot.secondary);
    });

    test(
      'operaciones de la principal con la secundaria abierta: StateError',
      () async {
        await createAlt();
        expect(await unlock(_pinS), isTrue);
        final ops = <Future<Object?> Function()>[
          () => auth.changePin(oldPin: _pinP, newPin: '777777'),
          () => auth.regenerateRecoveryCode(_pinP),
          () => auth.prepareRotation(_pinP, toGen: 2, accountEmail: 'a@b.c'),
          auth.enableBiometricUnlock,
          () => auth.verifyLocalRecoveryCode(code),
          () => auth.createSecondaryVault(primaryPin: _pinP, newPin: '739164'),
          () => auth.changeSecondaryPin(
            primaryPin: _pinP,
            currentAltPin: _pinS,
            newAltPin: '739164',
          ),
          () => auth.deleteSecondaryVault(_pinP),
          auth.switchPrimary,
          auth.finishRotation,
          auth.enterReencrypting,
        ];
        final before = Map.of(store.data);
        for (final op in ops) {
          await expectLater(op(), throwsStateError);
        }
        expect(store.data, before);
      },
    );
  });

  group('aislamiento de llaves', () {
    test('archivos y BD de una no abren con las llaves de la otra', () async {
      await createAlt();
      expect(await unlock(_pinP), isTrue);
      final kp = await KeyHierarchy.fromDek(session.keys.dekBytes());
      expect(await unlock(_pinS), isTrue);
      final ks = session.keys;
      expect(session.filesKeyFor(1, VaultSlot.primary), isNull);
      final c = CryptoService();
      final enc = await c.encryptBytes(utf8.encode('secreto'), ks.files);
      await expectLater(c.decryptBytes(enc, kp.files), throwsA(anything));
      final encP = await c.encryptBytes(utf8.encode('secreto'), kp.thumbs);
      await expectLater(c.decryptBytes(encP, ks.thumbs), throwsA(anything));
      // BD de la secundaria (SQLCipher simulado): la llave de la principal no
      // la abre.
      final vdb = VaultDatabase.forTesting(
        session: session,
        opener: fakeCipherOpener,
        useSqlCipher: true,
        markerStore: store,
        slot: VaultSlot.secondary,
      );
      await vdb.database;
      await vdb.close();
      expect(store.data[AuthController.altDbCreatedKey], 'true');
      await expectLater(
        fakeCipherOpener(
          VaultPaths.secondary.dbFilePath,
          password: VaultDatabase.passwordFor(kp),
          options: OpenDatabaseOptions(),
        ),
        throwsA(anything),
      );
      expect(File(VaultPaths.primary.dbFilePath).existsSync(), isFalse);
    });
  });

  group('la principal queda intacta', () {
    test('crear, usar, cambiar el PIN y eliminar la secundaria no cambian ni '
        'una clave de la principal ni sus carpetas', () async {
      Directory(AppPaths.vaultDir.path).createSync(recursive: true);
      File(p.join(AppPaths.vaultDir.path, 'x.vault')).writeAsStringSync('c');
      final before = nonAlt();
      final listing = [
        for (final e in AppPaths.baseDir.listSync(recursive: true))
          if (!e.path.contains('${Platform.pathSeparator}alt')) e.path,
      ]..sort();
      await createAlt();
      expect(await unlock(_pinS), isTrue);
      expect(await unlock(_pinP), isTrue);
      expect(
        await auth.changeSecondaryPin(
          primaryPin: _pinP,
          currentAltPin: _pinS,
          newAltPin: '739164',
        ),
        ChangeSecondaryPinResult.changed,
      );
      expect(await auth.deleteSecondaryVault(_pinP), isTrue);
      expect(nonAlt(), before);
      expect(
        [
          for (final e in AppPaths.baseDir.listSync(recursive: true))
            if (!e.path.contains('${Platform.pathSeparator}alt')) e.path,
        ]..sort(),
        listing,
      );
    });

    test('abrir la secundaria con una rotación de la principal en curso no '
        'toca su registro', () async {
      await createAlt();
      expect(await unlock(_pinP), isTrue);
      await auth.prepareRotation(_pinP, toGen: 2, accountEmail: 'a@b.c');
      final rec = store.data[RotationKeyStore.recordKey];
      final aux = {for (final k in RotationKeyStore.allKeys) k: store.data[k]};
      expect(await unlock(_pinS), isTrue);
      expect(store.data[RotationKeyStore.recordKey], rec);
      expect({for (final k in RotationKeyStore.allKeys) k: store.data[k]}, aux);
      expect((await auth.rotationRecord())!.phase, RotationPhase.prepared);
    });

    test(
      'discardLocalKeys, la consolidación de una restauración y la '
      'limpieza A3 de la rotación no tocan alt.* (lo reconcilia el arranque)',
      () async {
        await createAlt();
        final alt = {
          for (final k in AuthController.allAltKeys)
            if (store.data[k] != null) k: store.data[k],
        };
        await auth.rotationStore.clearAll();
        await auth.rotationStore.sweepOrphans();
        await auth.discardLocalKeys();
        expect({
          for (final k in AuthController.allAltKeys)
            if (store.data[k] != null) k: store.data[k],
        }, alt);
        // Sin principal, el arranque se lleva la secundaria (fila 1).
        expect(
          await VaultBootstrap.decide(
            auth: auth,
            isIOS: false,
            sweepOrphans: false,
          ),
          isFalse,
        );
        for (final k in AuthController.allAltKeys) {
          expect(store.data.containsKey(k), isFalse);
        }
        expect(VaultPaths.secondary.exists, isFalse);
      },
    );
  });

  group('cambiar el PIN', () {
    test(
      'changePin de la principal igual al secundario: rechazo neutro',
      () async {
        await createAlt();
        final before = store.data[AuthController.pinEnvelopeKey];
        await expectLater(
          auth.changePin(oldPin: _pinP, newPin: _pinS),
          throwsA(isA<PinNotAllowedException>()),
        );
        expect(store.data[AuthController.pinEnvelopeKey], before);
        expect(await auth.changePin(oldPin: _pinP, newPin: '222222'), isTrue);
        expect(await unlock(_pinS), isTrue, reason: 'la secundaria sigue');
      },
    );

    test('changeSecondaryPin: desde la principal, cuenta intentos y la misma '
        'DEK', () async {
      await createAlt();
      expect(await unlock(_pinS), isTrue);
      final check = session.keys.keyCheck;
      expect(await unlock(_pinP), isTrue);
      expect(
        await auth.changeSecondaryPin(
          primaryPin: '000000',
          currentAltPin: _pinS,
          newAltPin: '739164',
        ),
        ChangeSecondaryPinResult.wrongPrimaryPin,
      );
      expect(
        await auth.changeSecondaryPin(
          primaryPin: _pinP,
          currentAltPin: '000000',
          newAltPin: '739164',
        ),
        ChangeSecondaryPinResult.wrongSecondaryPin,
      );
      expect(await failures(), 1, reason: 'el secundario incorrecto cuenta');
      await expectLater(
        auth.changeSecondaryPin(
          primaryPin: _pinP,
          currentAltPin: _pinS,
          newAltPin: _pinP,
        ),
        throwsA(isA<PinNotAllowedException>()),
      );
      expect(
        await auth.changeSecondaryPin(
          primaryPin: _pinP,
          currentAltPin: _pinS,
          newAltPin: '739164',
        ),
        ChangeSecondaryPinResult.changed,
      );
      expect(await unlock(_pinS), isFalse);
      expect(await unlock('739164'), isTrue);
      expect(session.keys.keyCheck, check);
    });
  });

  group('eliminar', () {
    test('PIN principal; envoltura primero; después marca y alt/', () async {
      await createAlt();
      store.data[AuthController.altDbCreatedKey] = 'true';
      expect(await auth.deleteSecondaryVault('000000'), isFalse);
      expect(VaultPaths.secondary.exists, isTrue);
      expect(await auth.deleteSecondaryVault(_pinP), isTrue);
      for (final k in AuthController.allAltKeys) {
        expect(store.data.containsKey(k), isFalse);
      }
      expect(VaultPaths.secondary.exists, isFalse);
      expect(await unlock(_pinS), isFalse);
      expect(await auth.secondaryStatus(), SecondaryVaultStatus.none);
    });

    test('corte tras borrar la envoltura (falla la marca): el arranque se '
        'lleva alt/', () async {
      await createAlt();
      store.data[AuthController.altDbCreatedKey] = 'true';
      store.failDelete = AuthController.altDbCreatedKey;
      await expectLater(
        auth.deleteSecondaryVault(_pinP),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.data.containsKey(AuthController.altPinEnvelopeKey), isFalse);
      store.failDelete = null;
      await auth.reconcileSecondaryAtStartup(primaryExists: true);
      expect(VaultPaths.secondary.exists, isFalse);
      expect(store.data.containsKey(AuthController.altDbCreatedKey), isFalse);
    });

    test('borrados perdidos (apply) tras eliminar: la envoltura vuelve sin '
        'alt/ y el arranque la quita (fila 3)', () async {
      await createAlt();
      expect(await auth.deleteSecondaryVault(_pinP), isTrue);
      store.dropLast(2);
      expect(store.data.containsKey(AuthController.altPinEnvelopeKey), isTrue);
      await auth.reconcileSecondaryAtStartup(primaryExists: true);
      expect(store.data.containsKey(AuthController.altPinEnvelopeKey), isFalse);
      expect(await unlock(_pinS), isFalse);
    });
  });

  group('arranque: los 5 estados', () {
    test('fila 4: marca C1 sin BD = Dañada; no se borra nada', () async {
      await createAlt();
      store.data[AuthController.altDbCreatedKey] = 'true';
      final keep = File(p.join(VaultPaths.secondary.vaultDir.path, 'k.vault'))
        ..writeAsStringSync('cifrado');
      await auth.reconcileSecondaryAtStartup(primaryExists: true);
      expect(keep.existsSync(), isTrue);
      expect(await auth.secondaryStatus(), SecondaryVaultStatus.damaged);
      // Crear encima de una Dañada: rechazado, nada borrado.
      expect(await unlock(_pinP), isTrue);
      await expectLater(
        auth.createSecondaryVault(primaryPin: _pinP, newPin: '739164'),
        throwsA(isA<SecondaryVaultException>()),
      );
      expect(keep.existsSync(), isTrue);
    });

    test('fila 5: envoltura ilegible con alt/: Dañada, nada borrado', () async {
      await createAlt();
      store.data[AuthController.altPinEnvelopeKey] = 'basura';
      await auth.reconcileSecondaryAtStartup(primaryExists: true);
      expect(VaultPaths.secondary.exists, isTrue);
      expect(store.data[AuthController.altPinEnvelopeKey], 'basura');
    });

    test(
      'M4: un ERROR del almacén al leer no borra nada y no impide arrancar',
      () async {
        await createAlt();
        store.failRead = AuthController.altPinEnvelopeKey;
        await expectLater(
          auth.reconcileSecondaryAtStartup(primaryExists: false),
          throwsA(isA<FileSystemException>()),
        );
        expect(VaultPaths.secondary.exists, isTrue);
        expect(await VaultBootstrap.decide(auth: auth, isIOS: false), isTrue);
        expect(VaultPaths.secondary.exists, isTrue);
        store.failRead = null;
        // Y el desbloqueo de la principal no depende de esa lectura.
        store.failRead = AuthController.altPinEnvelopeKey;
        expect(await unlock(_pinP), isTrue);
        store.failRead = null;
      },
    );

    test('iOS reinstalación: sin BD principal se descartan las llaves de las '
        'dos y alt/', () async {
      await createAlt();
      // Sin BD principal en disco (y sin restos de rotación).
      expect(await VaultBootstrap.decide(auth: auth, isIOS: true), isFalse);
      expect(store.data.containsKey(AuthController.pinEnvelopeKey), isFalse);
      for (final k in AuthController.allAltKeys) {
        expect(store.data.containsKey(k), isFalse);
      }
      expect(VaultPaths.secondary.exists, isFalse);
    });
  });
}
