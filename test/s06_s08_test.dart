// Regresión S-06 (PIN mínimo de 6 dígitos) y S-08 (rangos fijos de Argon2id
// leídos de fuentes externas). Ver docs/REPORTE.md y docs/DECISIONES.md.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/kdf.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/crypto/wrapped_key.dart';
import 'package:vault/core/session/vault_session.dart';

import 'support/fakes.dart';

AuthController _controller(InMemorySecureStore storage) => AuthController(
  storage: storage,
  biometricStore: FakeBiometricKeyStore(),
  kdfParams: fastKdf,
  session: VaultSession.create(),
);

Map<String, dynamic> _kdf({int m = 19456, int t = 2, int p = 1}) => {
  'alg': 'argon2id',
  'v': 0x13,
  'm': m,
  't': t,
  'p': p,
};

void main() {
  group('S-06: PIN nuevo de al menos 6 dígitos', () {
    test('createVault rechaza 4 y 5 dígitos y acepta 6', () async {
      final store = InMemorySecureStore();
      final c = _controller(store);
      expect(AuthController.minNewPinLength, 6);
      for (final weak in ['1234', '12345']) {
        expect(() => c.createVault(weak), throwsArgumentError);
      }
      expect(await c.hasVault(), isFalse);
      await c.createVault('123456');
      expect(await c.hasVault(), isTrue);
    });

    test(
      'changePin rechaza un PIN nuevo corto y no toca la envoltura',
      () async {
        final store = InMemorySecureStore();
        final c = _controller(store);
        await c.createVault('123456');
        final before = await store.read(AuthController.pinEnvelopeKey);
        expect(
          () => c.changePin(oldPin: '123456', newPin: '9876'),
          throwsArgumentError,
        );
        expect(
          () => c.changePin(oldPin: '123456', newPin: '98765'),
          throwsArgumentError,
        );
        expect(await store.read(AuthController.pinEnvelopeKey), before);
        expect(await c.changePin(oldPin: '123456', newPin: '987654'), isTrue);
      },
    );

    test('restoreFromRecovery rechaza un PIN nuevo corto', () async {
      final c = _controller(InMemorySecureStore());
      final created = await c.createVault('123456');
      final other = _controller(InMemorySecureStore());
      expect(
        () => other.restoreFromRecovery(
          recoveryCode: created.recoveryCode,
          recoveryBackupJson: created.recoveryBackupJson,
          newPin: '1234',
        ),
        throwsArgumentError,
      );
    });

    test(
      'una bóveda antigua con PIN de 4 dígitos sigue desbloqueando',
      () async {
        final store = InMemorySecureStore();
        final c = _controller(store);
        await c.createVault('123456');
        // Simula una envoltura creada antes de S-06 con un PIN de 4 dígitos.
        final dek = c.session.keys.dekBytes();
        final legacy = await WrappedKey.wrap(
          dek: dek,
          secret: utf8.encode('2468'),
          purpose: WrapPurpose.pin,
          kdf: fastKdf,
        );
        await store.write(AuthController.pinEnvelopeKey, legacy.encode());
        c.lock();
        expect(await _controller(store).unlockWithPin('2468'), isTrue);
      },
    );
  });

  group('S-08: rangos fijos de Argon2id', () {
    test('producción y parámetros válidos pasan', () {
      expect(Argon2Params.fromJson(_kdf()), Argon2Params.production);
      expect(
        Argon2Params.fromJson(_kdf(m: 256 * 1024, t: 10, p: 4)).memoryKiB,
        256 * 1024,
      );
    });

    test('fuera de rango: error claro (FormatException)', () {
      final bad = <Map<String, dynamic>>[
        _kdf(m: 256 * 1024 + 1),
        _kdf(m: 1024 * 1024), // 1 GiB: antes se aceptaba
        _kdf(m: 4), // muy poca memoria
        _kdf(t: 0),
        _kdf(t: 11),
        _kdf(t: 16), // antes se aceptaba
        _kdf(p: 0),
        _kdf(p: 5),
        _kdf(p: 8), // antes se aceptaba
        _kdf(m: 8, p: 2), // m < 8·p
      ];
      for (final json in bad) {
        expect(
          () => Argon2Params.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'mensaje',
              contains('fuera de rango'),
            ),
          ),
          reason: '$json',
        );
      }
    });

    test('tipos inválidos o algoritmo distinto', () {
      expect(
        () => Argon2Params.fromJson({..._kdf(), 'm': '19456'}),
        throwsFormatException,
      );
      expect(
        () => Argon2Params.fromJson({..._kdf(), 'alg': 'argon2i'}),
        throwsFormatException,
      );
      expect(
        () => Argon2Params.fromJson({..._kdf(), 'v': 0x10}),
        throwsFormatException,
      );
    });

    test('un respaldo de Drive con parámetros hostiles se rechaza al leerlo, '
        'antes de derivar nada', () async {
      final c = _controller(InMemorySecureStore());
      final created = await c.createVault('123456');
      final json =
          jsonDecode(created.recoveryBackupJson) as Map<String, dynamic>;

      Map<String, dynamic> withKdf(Map<String, dynamic> kdf) {
        final copy = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
        // La KDF vive dentro de la envoltura del respaldo.
        void patch(Map<String, dynamic> m) {
          for (final e in m.entries.toList()) {
            if (e.key == 'kdf' && e.value is Map) m[e.key] = kdf;
            if (e.value is Map<String, dynamic>) {
              patch(e.value as Map<String, dynamic>);
            }
          }
        }

        patch(copy);
        return copy;
      }

      // Sanidad: el respaldo sin tocar sí se lee.
      expect(
        () => RecoveryBackup.parse(created.recoveryBackupJson),
        returnsNormally,
      );
      for (final hostile in [_kdf(m: 1024 * 1024), _kdf(t: 16), _kdf(p: 8)]) {
        expect(
          () => RecoveryBackup.parse(jsonEncode(withKdf(hostile))),
          throwsFormatException,
        );
        final other = _controller(InMemorySecureStore());
        expect(
          () => other.restoreFromRecovery(
            recoveryCode: created.recoveryCode,
            recoveryBackupJson: jsonEncode(withKdf(hostile)),
            newPin: '123456',
          ),
          throwsFormatException,
        );
        expect(await other.hasVault(), isFalse);
      }
    });
  });
}
