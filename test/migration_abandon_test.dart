// D76 (cambio de cuenta atascado, parte A paso 2): «Cancelar y quedarme en
// la cuenta actual» (`abandonStayOnCurrent`), el cambio interrumpido en cada
// fase, `resume()` sin errores silenciosos y el orden de la apertura. Solo
// nubes falsas: «pruebas» = la cuenta de pruebas del iPhone (vaciada) y
// «principal» = la cuenta buena.
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/sync/cloud_verification_service.dart';
import 'package:vault/features/vault/unlock_sequence.dart';

import 'support/verification_env.dart';

void main() {
  late VerifyEnv env;

  setUp(() async {
    env = VerifyEnv();
    await env.setUp();
  });

  tearDown(() async => env.tearDown());

  /// Deja un cambio de cuenta guardado en [phase] (desde «pruebas»). Para
  /// `uploading` y siguientes, con las referencias ya reiniciadas.
  Future<void> stuckAt(MigrationPhase phase, {String? newEmail}) async {
    await env.repo.begin(
      oldEmail: pruebas,
      neededBytes: 1,
      downloadTotal: 0,
      now: 1,
    );
    final afterReset =
        phase == MigrationPhase.uploading ||
        phase == MigrationPhase.finalizing ||
        phase == MigrationPhase.askDeleteOld;
    if (afterReset) {
      final local = {for (final i in await env.a.items.getAllItems()) i.id};
      await env.repo.resetForUpload(localItemIds: local, now: 2);
    }
    await env.repo.update(phase: phase, newEmail: newEmail, now: 3);
  }

  Future<void> expectAllInPrincipal() async {
    final p = env.cloud.account(principal);
    final tag = await env.tagger.current();
    for (final id in ['i1', 'i2', 'i3']) {
      final i = (await env.a.items.getItem(id))!;
      expect(i.syncStatus, SyncStatus.enNube, reason: id);
      expect(i.driveFileId, p.byName('$id.vault')!.id, reason: id);
      expect(i.cloudAccountTag, tag, reason: id);
    }
    expect(p.byName('recovery_backup.json'), isNotNull);
    expect(p.byName('vault_db.snapshot'), isNotNull);
  }

  group('el caso del iPhone', () {
    test('signInNew (selector cancelado) + sesión en la principal por fuera '
        '-> Cancelar y quedarme -> verificación -> todo en la principal', () async {
      await env.seed();
      final s = env.migration();
      env.cloud.signInQueue.clear(); // el usuario cancela el selector
      await s.start(await s.plan());
      expect((await env.repo.load())!.phase, MigrationPhase.signInNew);
      expect(env.sync.pausedForMigration, isTrue);
      // Inicio de sesión con la principal por la hoja (fuera del flujo).
      env.cloud.signInQueue.add(principal);
      await env.cloud.signIn();
      env.empty(pruebas);
      final before = await env.a.items.getAllItems();

      await s.abandonStayOnCurrent();
      expect(await env.repo.load(), isNull);
      expect(await env.repo.hasSavedRefs(), isFalse);
      expect(env.sync.pausedForMigration, isFalse);
      expect(env.cache.suspended, isFalse);
      // Nada se borró ni se restauró: las filas siguen, sin comprobar.
      final after = await env.a.items.getAllItems();
      expect(after.length, before.length);
      for (final i in after) {
        expect(i.cloudAccountTag, isNull);
      }
      // La verificación (lanzada por onAbandoned) re-sube a la principal.
      await env.idle();
      for (var k = 0; k < 100 && env.verifier.isRunning; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(env.verifier.last.value?.outcome, CloudVerificationOutcome.done);
      await env.settle();
      await expectAllInPrincipal();
      expect(env.destructiveCalls, 0);
      // Nunca se pidió otra cuenta.
      expect(env.cloud.currentAccountEmail, principal);
    });
  });

  group('abandonStayOnCurrent', () {
    test('sin sesión: pide iniciar sesión y no toca nada', () async {
      await env.seed();
      await stuckAt(MigrationPhase.signInNew);
      await env.cloud.signOut();
      final s = env.migration();
      await s.refresh();
      await expectLater(
        s.abandonStayOnCurrent(),
        throwsA(isA<MigrationException>()),
      );
      expect((await env.repo.load())!.phase, MigrationPhase.signInNew);
      expect(env.sync.pausedForMigration, isTrue);
    });

    test('en la cuenta ANTERIOR tras resetForUpload: restaura sus '
        'referencias (como cancelar) sin pedir ninguna cuenta', () async {
      await env.seed();
      final refs = {
        for (final i in await env.a.items.getAllItems()) i.id: i.driveFileId,
      };
      await stuckAt(MigrationPhase.uploading, newEmail: principal);
      final s = env.migration(wireVerification: false);
      final calls = env.cloud.signInCalls;
      await s.abandonStayOnCurrent();
      expect(env.cloud.signInCalls, calls);
      expect(await env.repo.load(), isNull);
      for (final i in await env.a.items.getAllItems()) {
        expect(i.driveFileId, refs[i.id]);
        expect(i.cloudAccountTag, isNull); // restauradas, sin comprobar
      }
    });

    test('en OTRA cuenta tras resetForUpload: conserva las referencias '
        'actuales (de la nueva) y NO restaura las de la anterior', () async {
      await env.seed();
      await stuckAt(MigrationPhase.uploading, newEmail: principal);
      await env.switchTo(principal);
      // Las fotos ya se subieron a la principal antes del corte.
      env.sync.pausedForMigration = false;
      await env.sync.run(manual: true, force: true);
      final uploaded = {
        for (final i in await env.a.items.getAllItems()) i.id: i.driveFileId,
      };
      final s = env.migration(wireVerification: false);
      await s.abandonStayOnCurrent();
      expect(await env.repo.hasSavedRefs(), isFalse);
      final p = env.cloud.account(principal);
      for (final i in await env.a.items.getAllItems()) {
        expect(i.driveFileId, uploaded[i.id]);
        expect(i.driveFileId, p.byName('${i.id}.vault')!.id);
        expect(i.cloudAccountTag, await env.tagger.current());
      }
    });

    test('fase desconocida: no ejecuta nada; Cancelar y quedarme la cierra', () async {
      await env.seed();
      final db = await env.a.vdb.database;
      await db.insert('migration_state', {
        'id': 1,
        'phase': 'fase_futura',
        'oldEmail': pruebas,
        'startedAt': 1,
        'updatedAt': 1,
      });
      final s = env.migration(wireVerification: false);
      await s.refresh();
      expect(s.status.value.phase, MigrationPhase.unknown);
      final uploads = env.cloud.account(pruebas).uploadCalls;
      await s.resume();
      expect(env.cloud.account(pruebas).uploadCalls, uploads);
      expect((await env.repo.load())!.lastError, contains('desconocido'));
      await env.switchTo(principal);
      await s.abandonStayOnCurrent();
      expect(await env.repo.load(), isNull);
    });
  });

  group('interrumpido en cada fase -> Cancelar y quedarme en la principal', () {
    for (final phase in [
      MigrationPhase.downloading,
      MigrationPhase.signInNew,
      MigrationPhase.checkingNew,
      MigrationPhase.uploading,
      MigrationPhase.finalizing,
      MigrationPhase.askDeleteOld,
      MigrationPhase.blockedOtherVault,
      MigrationPhase.blockedQuota,
    ]) {
      test(phase.name, () async {
        await env.seed();
        await stuckAt(phase, newEmail: principal);
        await env.switchTo(principal);
        env.empty(pruebas);
        final s = env.migration(wireVerification: false);
        await s.refresh();
        expect(env.sync.pausedForMigration, isTrue);
        await s.abandonStayOnCurrent();
        expect(await env.repo.load(), isNull);
        expect((await env.a.items.getAllItems()).length, 3);
        final r = await env.verifyAndSettle();
        expect(r.outcome, CloudVerificationOutcome.done);
        await expectAllInPrincipal();
        expect(env.destructiveCalls, 0);
      });
    }
  });

  group('resume sin errores silenciosos', () {
    test('un error que no es de la nube deja lastError y un log', () async {
      DiagnosticsBuffer.instance.clear();
      await env.seed();
      await stuckAt(MigrationPhase.checkingNew, newEmail: principal);
      await env.switchTo(principal);
      final s = env.migration(
        backup: () async => throw const FormatException('x'),
        wireVerification: false,
      );
      await s.resume();
      final st = (await env.repo.load())!;
      expect(st.phase, MigrationPhase.checkingNew);
      expect(st.lastError, contains('error inesperado'));
      expect(s.isRunning, isFalse);
      expect(
        DiagnosticsBuffer.instance.export(),
        contains('Cambio de cuenta detenido por un error'),
      );
      expect(DiagnosticsBuffer.instance.export().contains('@'), isFalse);
    });
  });

  group('apertura (onUnlocked)', () {
    test('un paso que falla no impide los siguientes; con la sesión '
        'cambiada se para', () async {
      final ran = <String>[];
      await runUnlockSteps([
        UnlockStep('a', () async => ran.add('a')),
        UnlockStep('falla', () async => throw StateError('x')),
        UnlockStep('b', () async => ran.add('b')),
      ]);
      expect(ran, ['a', 'b']);
      var valid = true;
      ran.clear();
      await runUnlockSteps(stillValid: () => valid, [
        UnlockStep('a', () async {
          ran.add('a');
          valid = false;
        }),
        UnlockStep('b', () async => ran.add('b')),
      ]);
      expect(ran, ['a']);
    });

    test('migración en la BD y caché por encima del límite: aunque un paso '
        'anterior falle, la guarda se aplica ANTES y no se purga nada', () async {
      await env.seed();
      await stuckAt(MigrationPhase.signInNew);
      final s = env.migration(wireVerification: false); // arranque en frío
      expect(env.cache.suspended, isFalse);
      List<String>? purged;
      await runUnlockSteps([
        UnlockStep('temporales', () async => throw StateError('falla')),
        UnlockStep('migración', () async {
          await s.refresh();
        }),
        UnlockStep('caché', () async {
          purged = await env.cache.enforce(maxBytes: 0);
        }),
      ]);
      expect(env.cache.suspended, isTrue);
      expect(env.sync.pausedForMigration, isTrue);
      expect(purged, isEmpty);
      expect((await env.a.items.getAllItems()).length, 3);
    });
  });
}
