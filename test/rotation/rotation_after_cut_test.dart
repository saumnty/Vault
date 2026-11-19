// Rotación de la DEK, paso 10b (§10.2-10/11 y §10.3): después del corte
// (borrado del conjunto viejo por lista, limpieza final) y escenarios.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_names.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/restore/vault_bootstrap.dart';
import 'package:vault/data/rotation/key_rotation_service.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/sync_preferences.dart';

import '../support/fakes.dart';
import '../support/rotation_env.dart';

void main() {
  late RotationPhone phone;
  late KeyHierarchy oldKeys;

  setUp(() async {
    phone = RotationPhone();
    await phone.create();
    await phone.seedVault();
    oldKeys = await KeyHierarchy.fromDek(phone.session.keys.dekBytes());
  });
  tearDown(() => phone.dispose());

  /// Estado final tras terminar la rotación a la generación [gen].
  Future<void> expectFinished(
    String codeB, {
    int gen = 2,
    Set<String> lost = const {},
  }) async {
    expect(await phone.record(), isNull, reason: 'el registro se borra');
    final all = await phone.items.getAllItems();
    expect(all.map((i) => i.keyGen).toSet(), {gen});
    // En Drive solo queda la generación nueva (y la cuarentena, M6).
    for (final n in phone.cloud.names) {
      final info = CloudNames.parse(n);
      expect(info, isNotNull, reason: n);
      if (info!.kind == CloudNameKind.quarantine) continue;
      expect(info.gen, gen, reason: 'queda $n');
      expect(info.kind, isNot(CloudNameKind.bridgeBackup));
    }
    expect(phone.cloud.byName(CloudNames.recoveryBackupFor(gen)), isNotNull);
    expect(phone.cloud.byName(CloudNames.dbSnapshotFor(gen)), isNotNull);
    expect(await phone.auth.currentKeyGen(), gen);
    expect(phone.session.currentGen, gen);
    await phone.expectAllItemsOpen(lost: lost);
    // Tablas y triggers de la rotación, vacíos; sin restos locales.
    expect(await phone.repo.load(), isNull);
    expect(await phone.repo.oldFiles(), isEmpty);
    final db = await phone.vdb.database;
    expect(
      await db.rawQuery("SELECT name FROM sqlite_master WHERE type='trigger'"),
      isEmpty,
    );
    expect(
      phone.store.data.keys.where((k) => k.startsWith('vault.v1.rotation')),
      isEmpty,
    );
    expect(
      Directory(
        AppPaths.dbDir.path,
      ).listSync().where((e) => RegExp(r'\.k\d+(\.tmp)?$').hasMatch(e.path)),
      isEmpty,
    );
    for (final f in AppPaths.vaultDir.listSync().whereType<File>()) {
      expect(f.path, contains('.k$gen.'), reason: 'resto local ${f.path}');
    }
    // §8: el código nuevo restaura; el viejo YA NO.
    expect(await phone.canRestoreWith(codeB, lost: lost), isTrue);
    expect(await phone.canRestoreWith(phone.codeA), isFalse);
  }

  test(
    'rotación completa: B restaura, A falla, nada abre con la vieja',
    () async {
      await phone.auth.enableBiometricUnlock();
      final b = await phone.startAndConfirm();
      await phone.service.resume();
      expect(phone.service.status.value.finished, isTrue);
      expect(phone.service.status.value.offerBiometric, isTrue);
      await expectFinished(b);
      await phone.expectNoOldKeyMaterial(oldKeys, phone.codeA);
      // Restaurado con B: Papelera y etiquetas intactas.
      expect(
        await phone.canRestoreWith(
          b,
          inspect: (db) async {
            final i4 = (await db.query(
              'vault_items',
              where: "id = 'i4'",
            )).single;
            expect(i4['deletedAt'], isNotNull);
            expect((await db.query('item_tags')).single['itemId'], 'i1');
            expect(await db.query('rotation_state'), isEmpty);
          },
        ),
        isTrue,
      );
      // Tras reiniciar: una sola llave, se puede cambiar el PIN y reactivar
      // la biometría.
      await phone.restart();
      expect(phone.session.keyring!.isDual, isFalse);
      expect(
        await phone.auth.changePin(oldPin: rotationPin, newPin: '999999'),
        isTrue,
      );
      await phone.auth.enableBiometricUnlock();
      expect(await phone.auth.isBiometricUnlockEnabled(), isTrue);
    },
  );

  // Tabla §8 en el instante del corte simulado: (A, B).
  const table = {
    RotationCrashPoint.afterCut: (true, true),
    RotationCrashPoint.oldBackupDeleted: (false, true),
    RotationCrashPoint.bridgeDeleted: (false, true),
    RotationCrashPoint.oldSnapshotDeleted: (false, true),
    RotationCrashPoint.blobDeleted: (false, true),
    RotationCrashPoint.finalizeSwept: (false, true),
    RotationCrashPoint.finalizeBeforeRecord: (false, true),
  };

  for (final MapEntry(key: point, value: (aWorks, bWorks)) in table.entries) {
    for (final drop in [0, 1]) {
      test(
        'corte en ${point.name}${drop > 0 ? ' (+escritura perdida)' : ''}',
        () async {
          final b = await phone.startAndConfirm();
          var fired = false;
          phone.crash = (p) {
            if (p == point && !fired) {
              fired = true;
              throw SimulatedCrash(p);
            }
          };
          await expectLater(
            phone.service.resume(),
            throwsA(isA<SimulatedCrash>()),
          );
          expect(await phone.canRestoreWith(phone.codeA), aWorks);
          expect(await phone.canRestoreWith(b), bWorks);
          phone.store.dropLast(drop);
          phone.crash = null;
          await phone.restart();
          await phone.service.resume();
          await expectFinished(b);
        },
      );
    }
  }

  test(
    'A5 tras el corte: otro dispositivo usa el conjunto viejo: no borra',
    () async {
      phone.stopAtCut = true;
      final b = await phone.startAndConfirm();
      await phone.service.resume();
      expect((await phone.record())!.phase, RotationPhase.deletingOldCloud);
      phone.stopAtCut = false;
      // Otro teléfono (restaurado con A) sube su snapshot.
      final s = phone.cloud.byName(CloudNames.dbSnapshot)!;
      phone.cloud.corruptContent(s.id);
      final before = phone.cloud.names.toSet();
      await phone.service.resume();
      final rec = (await phone.record())!;
      expect(rec.phase, RotationPhase.blockedCorrupt);
      expect(rec.resumePhase, RotationPhase.deletingOldCloud);
      expect(phone.cloud.names.toSet(), before, reason: 'no se borra nada');
      expect(await phone.canRestoreWith(b), isTrue);
    },
  );

  test('M6: el dañado queda en cuarentena (renombrado, no borrado)', () async {
    final i3 = (await phone.items.getItem('i3'))!;
    final f = AppPaths.resolve(i3.encryptedPath);
    f.writeAsBytesSync(f.readAsBytesSync()..[40] ^= 1);
    phone.cloud.corruptContent(i3.driveFileId!);
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    expect(await phone.service.skipCorruptItems(), 1);
    await phone.service.resume();
    await expectFinished(b, lost: {'i3'});
    expect(phone.cloud.byName('i3.vault'), isNull);
    expect(phone.cloud.byName(CloudNames.quarantine('i3', 1)), isNotNull);
    await phone.expectNoOldKeyMaterial(
      oldKeys,
      phone.codeA,
      allowQuarantine: true,
    );
  });

  test('segunda rotación seguida (gen 2 → 3)', () async {
    final b2 = await phone.startAndConfirm();
    await phone.service.resume();
    await expectFinished(b2);
    final keys2 = await KeyHierarchy.fromDek(phone.session.keys.dekBytes());
    await phone.sync.run(manual: true); // snapshot limpio de la gen 2
    final b3 = await phone.startAndConfirm();
    expect((await phone.record())!.toGen, 3);
    await phone.service.resume();
    await expectFinished(b3, gen: 3);
    expect(await phone.canRestoreWith(b2), isFalse);
    await phone.expectNoOldKeyMaterial(keys2, b2);
    await phone.expectNoOldKeyMaterial(oldKeys, phone.codeA);
  });

  test(
    'A3: reinstalación a mitad (Keychain conservado) no reanuda nada ajeno',
    () async {
      final b = await phone.startAndConfirm();
      phone.crash = (p) {
        if (p == RotationCrashPoint.itemDone) throw SimulatedCrash(p);
      };
      await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
      phone.crash = null;
      // iOS: desinstalar borra los archivos, no el Keychain.
      phone.sync.cancel();
      phone.auth.lock();
      await phone.vdb.close();
      for (final e in phone.dir.listSync()) {
        e.deleteSync(recursive: true);
      }
      await AppPaths.init(baseDir: phone.dir);
      final s = VaultSession.create();
      final auth = AuthController(
        storage: phone.store,
        biometricStore: phone.bio,
        kdfParams: fastKdf,
        session: s,
      );
      expect(
        await VaultBootstrap.decide(
          auth: auth,
          isIOS: true,
          sweepOrphans: false,
        ),
        isFalse,
      );
      expect(
        phone.store.data.keys.where(
          (k) =>
              k.startsWith('vault.v1.rotation') ||
              k == AuthController.keyGenKey,
        ),
        isEmpty,
        reason: 'A3: la rotación ajena se descarta con las llaves',
      );
      // Restaurar con B (vía puente) en esta instalación: queda en gen 1 y sin
      // ninguna rotación pendiente.
      final r = RestoreService(
        cloud: phone.cloud,
        auth: auth,
        prefs: SyncPreferences(phone.store),
        opener: fakeCipherOpener,
        dbPath: VaultDatabase.defaultDbPath,
        parallelism: 1,
      );
      expect(await r.probe(), RestoreProbeResult.found);
      expect(await r.verifyCode(b), isTrue);
      expect(r.lastMatch!.viaBridge, isTrue);
      await r.restore(newPin: '654321');
      expect(await auth.rotationRecord(), isNull);
      expect(await auth.currentKeyGen(), 1);
      r.dispose();
      auth.lock();
    },
  );

  test('sin red tras el corte: espera y luego termina', () async {
    phone.stopAtCut = true;
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    phone.stopAtCut = false;
    phone.net.kind = NetworkKind.none;
    await phone.service.resume();
    expect((await phone.record())!.phase, RotationPhase.deletingOldCloud);
    phone.net.kind = NetworkKind.wifi;
    await phone.service.resume();
    await expectFinished(b);
  });

  test('bloqueo a mitad del borrado: se pausa y reanuda', () async {
    final b = await phone.startAndConfirm();
    phone.crash = (p) {
      if (p == RotationCrashPoint.oldSnapshotDeleted) {
        phone.service.pause();
      }
    };
    await phone.service.resume();
    expect((await phone.record())!.phase, RotationPhase.deletingOldCloud);
    phone.crash = null;
    await phone.restart();
    await phone.service.resume();
    await expectFinished(b);
  });

  test('el teléfono restaurado en gen 2 no tiene nada que barrer', () async {
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    await expectFinished(b);
    // Un resto de otra rama más nueva no se toca.
    await phone.cloud.uploadBytes(
      bytes: Uint8List.fromList([1]),
      name: CloudNames.recoveryBackupFor(5),
    );
    await phone.prefs.setGenerationSweepPending(true);
    await phone.sync.run(manual: true);
    expect(phone.cloud.byName(CloudNames.recoveryBackupFor(5)), isNotNull);
  });
}
