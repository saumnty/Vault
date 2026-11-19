// Fase 8, paso 9 (DISENO_SENUELO §11.2-11): una rotación de la DEK de la
// principal en CUALQUIER fase no se altera al abrir la secundaria, la
// secundaria sigue abriendo, y al volver a la principal su sesión es la que
// la rotación espera.
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';

import 'support/secondary_env.dart';

void main() {
  late SecondaryEnv e;

  setUp(() async {
    e = SecondaryEnv();
    await e.setUp();
    await e.createSecondary();
    await e.auth.prepareRotation(
      pinPrimary,
      toGen: 2,
      accountEmail: 'dueno@example.com',
    );
  });
  tearDown(() => e.tearDown());

  Map<String, String?> rotationKeys() => {
    for (final k in RotationKeyStore.allKeys) k: e.store.data[k],
  };

  for (final phase in RotationPhase.values) {
    test(
      'fase ${phase.name}: abrir la secundaria no toca la rotación',
      () async {
        final rec = (await e.auth.rotationRecord())!;
        await e.auth.rotationStore.save(
          rec.copyWith(
            phase: phase,
            resumePhase: phase.isBlocked ? RotationPhase.reencrypting : null,
          ),
        );
        final before = rotationKeys();
        final altBefore = e.store.data[AuthController.altPinEnvelopeKey];

        expect(await e.unlock(pinSecondary), isTrue);
        expect(e.session.slot, VaultSlot.secondary);
        expect(e.session.keyring!.isDual, isFalse);
        expect(e.session.currentGen, 1);
        expect(rotationKeys(), before, reason: 'registro y secretos intactos');
        expect((await e.auth.rotationRecord())!.phase, phase);
        expect(e.store.data[AuthController.altPinEnvelopeKey], altBefore);

        // Operaciones de la rotación con la secundaria abierta: StateError.
        await expectLater(e.auth.enterReencrypting(), throwsStateError);
        await expectLater(e.auth.switchPrimary(), throwsStateError);
        expect(rotationKeys(), before);

        // Volver a la principal: nunca `blockedForeign` (la DEK es la suya).
        expect(await e.unlock(pinPrimary), isTrue);
        expect(e.session.slot, VaultSlot.primary);
        final after = (await e.auth.rotationRecord())!;
        if (phase != RotationPhase.blockedForeign) {
          expect(after.phase, isNot(RotationPhase.blockedForeign));
        }
        if (!phase.isBlocked) expect(after.phase, phase);
      },
    );
  }

  test('con una rotación registrada: crear otra secundaria NO; cambiar su PIN '
      'y eliminarla SÍ (son solo locales)', () async {
    expect(await e.unlock(pinPrimary), isTrue);
    await e.auth.deleteSecondaryVault(pinPrimary);
    await expectLater(
      e.auth.createSecondaryVault(primaryPin: pinPrimary, newPin: '739164'),
      throwsA(isA<RotationInProgressException>()),
    );
    expect((await e.auth.rotationRecord())!.phase, RotationPhase.prepared);
  });

  test('cambiar el PIN de la secundaria durante una rotación', () async {
    expect(await e.unlock(pinPrimary), isTrue);
    final before = rotationKeys();
    expect(
      await e.auth.changeSecondaryPin(
        primaryPin: pinPrimary,
        currentAltPin: pinSecondary,
        newAltPin: '739164',
      ),
      ChangeSecondaryPinResult.changed,
    );
    expect(rotationKeys(), before);
    expect(await e.unlock('739164'), isTrue);
    expect(e.session.slot, VaultSlot.secondary);
  });
}
