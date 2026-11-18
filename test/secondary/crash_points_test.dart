// Fase 8, paso 9 (DISENO_SENUELO §9, §11.2-12): cortes en CADA escritura al
// crear y al eliminar la secundaria, por excepción y por escrituras perdidas
// (apply() de Android). Tras el arranque (reconciliación) el estado siempre
// es coherente y la principal queda intacta y abre.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/restore/vault_bootstrap.dart';

import '../support/rotation_env.dart' show DroppingStore;
import 'support/secondary_env.dart';

/// Lanza en la mutación nº [failAt] (escritura o borrado) contada desde que
/// se arma.
class _CrashingStore extends DroppingStore {
  int? failAt;
  int _n = 0;

  void arm(int k) {
    failAt = k;
    _n = 0;
  }

  void _tick() {
    if (failAt != null && ++_n == failAt) {
      failAt = null;
      throw const FileSystemException('corte simulado');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    _tick();
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    _tick();
    return super.delete(key);
  }
}

void main() {
  /// Invariantes tras un arranque: la principal intacta y abre; la
  /// secundaria o no existe (sin claves ni `alt/`) o existe entera y abre.
  Future<void> expectCoherent(
    SecondaryEnv e,
    Map<String, String> primaryStore,
    Map<String, String> primaryFiles, {
    required String where,
  }) async {
    e.session.clear();
    final auth = e.newAuth();
    expect(
      await VaultBootstrap.decide(
        auth: auth,
        isIOS: false,
        sweepOrphans: false,
      ),
      isTrue,
      reason: where,
    );
    expect(e.nonAltStore(), primaryStore, reason: '$where: almacén principal');
    expect(e.primaryFiles(), primaryFiles, reason: '$where: archivos');
    final hasEnvelope = e.store.data.containsKey(
      AuthController.altPinEnvelopeKey,
    );
    final hasDir = VaultPaths.secondary.exists;
    expect(hasEnvelope, hasDir, reason: '$where: envoltura y alt/ juntas');
    if (!hasEnvelope) {
      expect(
        e.store.data.containsKey(AuthController.altDbCreatedKey),
        isFalse,
        reason: where,
      );
    }
    expect(await auth.unlockWithPin(pinPrimary), isTrue, reason: where);
    auth.lock();
    expect(await auth.unlockWithPin(pinSecondary), hasEnvelope, reason: where);
    auth.lock();
  }

  group('crear', () {
    test('corte (excepción) en cada mutación del almacén', () async {
      for (var k = 1; k < 40; k++) {
        final store = _CrashingStore();
        final e = SecondaryEnv(store: store);
        await e.setUp();
        try {
          expect(await e.unlock(pinPrimary), isTrue);
          final ps = e.nonAltStore();
          final pf = e.primaryFiles();
          store.arm(k);
          var finished = false;
          try {
            finished = await e.auth.createSecondaryVault(
              primaryPin: pinPrimary,
              newPin: pinSecondary,
            );
          } on FileSystemException {
            finished = false;
          }
          store.failAt = null;
          await expectCoherent(e, ps, pf, where: 'crear k=$k');
          if (finished) break; // ya no hay más mutaciones que cortar
        } finally {
          await e.tearDown();
        }
      }
    });

    // Mutaciones desde el desbloqueo previo: 2 del desbloqueo + 4 de crear
    // (contador, reset, marca C1, envoltura). Más atrás ya es createVault.
    test('escrituras perdidas: deshacer las últimas n tras crear', () async {
      for (var n = 1; n <= 6; n++) {
        final e = SecondaryEnv();
        await e.setUp();
        try {
          expect(await e.unlock(pinPrimary), isTrue);
          final ps = e.nonAltStore();
          final pf = e.primaryFiles();
          await e.createSecondary();
          e.store.dropLast(n);
          await expectCoherent(e, ps, pf, where: 'crear dropLast($n)');
        } finally {
          await e.tearDown();
        }
      }
    });
  });

  group('eliminar', () {
    test('corte (excepción) en cada mutación del almacén', () async {
      for (var k = 1; k < 40; k++) {
        final store = _CrashingStore();
        final e = SecondaryEnv(store: store);
        await e.setUp();
        try {
          await e.createSecondary();
          store.data[AuthController.altDbCreatedKey] = 'true';
          VaultPaths.secondary.dbDir.createSync(recursive: true);
          File(VaultPaths.secondary.dbFilePath).writeAsStringSync('bd');
          final ps = e.nonAltStore();
          final pf = e.primaryFiles();
          store.arm(k);
          var finished = false;
          try {
            finished = await e.auth.deleteSecondaryVault(pinPrimary);
          } on FileSystemException {
            finished = false;
          }
          store.failAt = null;
          await expectCoherent(e, ps, pf, where: 'eliminar k=$k');
          if (finished) {
            expect(VaultPaths.secondary.exists, isFalse);
            break;
          }
        } finally {
          await e.tearDown();
        }
      }
    });

    // 4 de eliminar + 4 de crear (más atrás ya es createVault).
    test('escrituras perdidas: deshacer las últimas n tras eliminar', () async {
      for (var n = 1; n <= 8; n++) {
        final e = SecondaryEnv();
        await e.setUp();
        try {
          await e.createSecondary();
          final ps = e.nonAltStore();
          final pf = e.primaryFiles();
          expect(await e.auth.deleteSecondaryVault(pinPrimary), isTrue);
          e.store.dropLast(n);
          await expectCoherent(e, ps, pf, where: 'eliminar dropLast($n)');
          // Tras el arranque, la que "volvió" sin alt/ se descarta.
          expect(VaultPaths.secondary.exists, isFalse);
        } finally {
          await e.tearDown();
        }
      }
    });
  });

  test(
    'cambiar el PIN secundario: una escritura perdida deja el PIN viejo',
    () async {
      final e = SecondaryEnv();
      await e.setUp();
      addTearDown(e.tearDown);
      await e.createSecondary();
      expect(
        await e.auth.changeSecondaryPin(
          primaryPin: pinPrimary,
          currentAltPin: pinSecondary,
          newAltPin: '739164',
        ),
        ChangeSecondaryPinResult.changed,
      );
      // Deshacer justo la escritura de la envoltura (y las del contador).
      e.store.dropLast(3);
      final auth = e.newAuth()..lock(); // arranque: sesión bloqueada
      final oldOk = await auth.unlockWithPin(pinSecondary);
      auth.lock();
      final newOk = await auth.unlockWithPin('739164');
      expect(oldOk || newOk, isTrue, reason: 'siempre abre con uno de los dos');
      expect(oldOk && newOk, isFalse);
    },
  );
}
