// D78 (cambio de cuenta atascado, parte B, punto 4): «Sincronizar ahora» y
// «Cerrar sesión» sin fallos silenciosos (`SyncRunOutcome`, guardas
// comunes), la migración comprueba la cuenta antes de cada ronda y el
// selector de Google tiene plazo y salida. Solo nubes falsas.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/cloud/guarded_sign_in.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/features/sync/sync_cloud_button.dart';
import 'package:vault/features/sync/sync_sheet.dart';

import 'support/fake_cloud.dart';
import 'support/verification_env.dart';

/// Nube cuyo `signIn` nunca termina hasta que la prueba lo decide.
class _HangingCloud extends FakeCloudStorage {
  _HangingCloud() : super(email: null);
  final Completer<CloudAccount> gate = Completer();
  @override
  Future<CloudAccount> signIn() => gate.future;
}

bool _logged(String text) =>
    DiagnosticsBuffer.instance.entries.any((e) => e.message.contains(text));

void main() {
  late VerifyEnv env;

  setUp(() async {
    DiagnosticsBuffer.instance.clear();
    env = VerifyEnv();
    await env.setUp();
  });

  tearDown(() async => env.tearDown());

  group('SyncService.run devuelve el motivo (nunca en silencio)', () {
    test('pausa por cambio de cuenta, verificación y mantenimiento', () async {
      await env.seed(n: 1);
      for (final (set, reason) in [
        (
          (bool v) => env.sync.pausedForMigration = v,
          SyncPauseReason.migration,
        ),
        (
          (bool v) => env.sync.pausedForVerification = v,
          SyncPauseReason.verification,
        ),
        (
          (bool v) => env.sync.pausedForAccountCleanup = v,
          SyncPauseReason.rotationMaintenance,
        ),
      ]) {
        set(true);
        expect(env.sync.pauseReason, reason);
        expect(env.sync.summary.value.pauseReason, reason);
        final o = await env.sync.run(manual: true);
        expect(o.kind, SyncRunKind.paused, reason: reason.name);
        expect(o.pauseReason, reason);
        expect(syncRunMessage(o), startsWith('En pausa: '));
        expect(_logged('Sincronización no iniciada: paused (${reason.name})'),
            isTrue);
        // El cambio de cuenta manda: con force sí corre.
        if (reason == SyncPauseReason.migration) {
          expect(
            (await env.sync.run(manual: true, force: true)).kind,
            SyncRunKind.completed,
          );
        }
        set(false);
        expect(env.sync.pauseReason, isNull);
      }
      expect(
        syncRunMessage(
          const SyncRunOutcome(
            SyncRunKind.paused,
            pauseReason: SyncPauseReason.migration,
          ),
        ),
        'En pausa: hay un cambio de cuenta sin terminar.',
      );
    });

    test('sin sesión, sin red, solo Wi-Fi y completada', () async {
      await env.seed(n: 1);
      expect((await env.sync.run(manual: true)).kind, SyncRunKind.completed);
      env.a.net.kind = NetworkKind.none;
      expect((await env.sync.run(manual: true)).kind, SyncRunKind.offline);
      env.a.net.kind = NetworkKind.mobile;
      await env.a.prefs.setWifiOnly(true);
      expect((await env.sync.run(manual: true)).kind, SyncRunKind.waitingWifi);
      env.a.net.kind = NetworkKind.wifi;
      await env.cloud.signOut();
      final o = await env.sync.run(manual: true);
      expect(o.kind, SyncRunKind.noAccount);
      expect(syncRunMessage(o), contains('inicia sesión'));
    });

    test('ya en curso: lo dice (y «Detener» es la salida)', () async {
      await env.a.addItem('x1', 'X.jpg');
      final first = env.sync.run(manual: true);
      final second = await env.sync.run(manual: true);
      expect(second.kind, SyncRunKind.alreadyRunning);
      expect(syncRunMessage(second), 'Ya hay una sincronización en curso.');
      env.sync.stop();
      await first;
      expect(_logged('Sincronización detenida a mano'), isTrue);
    });

    test('bloqueada u otra bóveda abierta', () async {
      final locked = SyncService(
        cloud: env.cloud,
        queue: env.a.queue,
        items: env.a.items,
        network: env.a.net,
        prefs: env.a.prefs,
        isUnlocked: () => false,
        resolvePath: AppPaths.resolve,
        recoveryBackupProvider: () async => null,
        snapshotProvider: () async => throw UnimplementedError(),
        scheduleWakeups: false,
      );
      addTearDown(locked.dispose);
      expect((await locked.run()).kind, SyncRunKind.locked);
      final other = SyncService(
        cloud: env.cloud,
        queue: env.a.queue,
        items: env.a.items,
        network: env.a.net,
        prefs: env.a.prefs,
        isUnlocked: () => false,
        isOtherVaultOpen: () => true,
        resolvePath: AppPaths.resolve,
        recoveryBackupProvider: () async => null,
        snapshotProvider: () async => throw UnimplementedError(),
        scheduleWakeups: false,
      );
      addTearDown(other.dispose);
      final o = await other.run(manual: true);
      expect(o.kind, SyncRunKind.otherVault);
      // Mensaje neutro (D70): nada de «bóveda adicional».
      expect(syncRunMessage(o), 'No disponible en este momento.');
    });

    test('las pasadas automáticas bloqueadas no repiten el mismo evento', () async {
      env.sync.pausedForMigration = true;
      DiagnosticsBuffer.instance.clear();
      for (var i = 0; i < 5; i++) {
        await env.sync.run();
      }
      final n = DiagnosticsBuffer.instance.entries
          .where((e) => e.message.startsWith('Sincronización no iniciada'))
          .length;
      expect(n, 1);
    });
  });

  group('Iniciar / cerrar sesión: mismas guardas', () {
    test('con un cambio de cuenta no se cierra ni se inicia sesión', () async {
      env.sync.pausedForMigration = true;
      expect(env.sync.accountActionBlock(), isNotNull);
      await expectLater(
        env.sync.signOut(),
        throwsA(isA<SyncAccountActionBlockedException>()),
      );
      expect(env.cloud.currentAccountEmail, pruebas);
      await env.cloud.signOut();
      env.cloud.signInQueue.add(principal);
      await expectLater(
        env.sync.signIn(),
        throwsA(isA<SyncAccountActionBlockedException>()),
      );
      expect(env.cloud.currentAccountEmail, isNull);
      expect(_logged('Cierre de sesión bloqueado'), isTrue);
      expect(_logged('Inicio de sesión bloqueado'), isTrue);
    });

    test('verificación y mantenimiento también bloquean; sin guarda, sí', () async {
      env.sync.pausedForVerification = true;
      expect(env.sync.accountActionBlock()!.reason, SyncPauseReason.verification);
      env.sync.pausedForVerification = false;
      env.sync.pausedForAccountCleanup = true;
      expect(
        env.sync.accountActionBlock()!.reason,
        SyncPauseReason.rotationMaintenance,
      );
      env.sync.pausedForAccountCleanup = false;
      expect(env.sync.accountActionBlock(), isNull);
      await env.sync.signOut();
      expect(env.cloud.currentAccountEmail, isNull);
      expect(_logged('Sesión de Google cerrada'), isTrue);
    });

    test('selector cancelado: mensaje y evento (no vuelve en silencio)', () async {
      await env.cloud.signOut();
      env.cloud.signInQueue.clear();
      await env.sync.signIn();
      expect(env.sync.summary.value.lastMessage, contains('Usar otra cuenta'));
      expect(_logged('Selector de Google cancelado'), isTrue);
    });
  });

  group('«al día» solo si de verdad lo está', () {
    test('items pendientes en vault_items sin cola no dan «al día»', () async {
      await env.a.addItem('p1', 'P.jpg'); // pendiente, nunca reconciliado
      await env.sync.refreshCounts();
      final s = env.sync.summary.value;
      expect(s.counts.total, 0);
      expect(s.cloud.localOnly, 1);
      expect(s.upToDate, isFalse);
      expect(syncSummaryLabel(s), 'Sincronización: 1 pendientes');
      expect(syncPhaseText(s), isNot('Todo está al día.'));
    });

    test('items sin comprobar en la cuenta o con pausa no dan «al día»', () async {
      await env.seed(n: 2);
      await env.sync.refreshCounts();
      // Recién subidos con el tag de esta cuenta: al día.
      expect(env.sync.summary.value.upToDate, isTrue);
      expect(syncSummaryLabel(env.sync.summary.value), 'Sincronización: al día');
      final db = await env.a.vdb.database;
      await db.update('vault_items', {'cloudAccountTag': null});
      await env.sync.refreshCounts();
      final s = env.sync.summary.value;
      expect(s.cloud.unverified, 2);
      expect(s.upToDate, isFalse);
      expect(syncSummaryLabel(s), 'Sincronización: 2 sin comprobar');
      await db.update('vault_items', {
        'cloudAccountTag': await env.tagger.current(),
      });
      env.sync.pausedForMigration = true;
      await env.sync.refreshCounts();
      expect(env.sync.summary.value.upToDate, isFalse);
      expect(syncSummaryLabel(env.sync.summary.value), contains('en pausa'));
      expect(syncPhaseText(env.sync.summary.value), startsWith('En pausa'));
    });
  });

  group('Selector de Google con plazo (GuardedSignIn)', () {
    test('no responde: libera la espera; el resultado tardío se ignora', () async {
      final cloud = _HangingCloud();
      final gate = GuardedSignIn(timeout: const Duration(milliseconds: 50));
      await expectLater(
        gate.signIn(cloud),
        throwsA(isA<CloudSignInTimeoutException>()),
      );
      expect(gate.inProgress, isFalse);
      expect(_logged('Selector de Google sin respuesta'), isTrue);
      cloud.gate.complete(const CloudAccount(email: 'tarde@example.com'));
      await Future<void>.delayed(Duration.zero);
      expect(_logged('Selector de Google respondió tarde: se ignora'), isTrue);
    });

    test('abandon() libera en el acto', () async {
      final cloud = _HangingCloud();
      final gate = GuardedSignIn();
      final f = gate.signIn(cloud);
      expect(gate.inProgress, isTrue);
      gate.abandon();
      await expectLater(f, throwsA(isA<CloudSignInCancelledException>()));
      expect(gate.inProgress, isFalse);
    });
  });

  group('Cambio de cuenta: cuenta comprobada y selector con plazo', () {
    MigrationRepository repo() => env.repo;

    test('la sesión cambia durante la descarga: pausa, 0 «ausentes»', () async {
      await env.seed();
      // i1 no está en el teléfono: habría que bajarlo de la cuenta anterior.
      final i1 = (await env.a.items.getItem('i1'))!;
      AppPaths.resolve(i1.encryptedPath).deleteSync();
      await repo().begin(
        oldEmail: pruebas,
        neededBytes: 1,
        downloadTotal: 1000,
        now: 1,
      );
      await env.switchTo(principal); // la sesión cambió por fuera
      final s = env.migration(wireVerification: false);
      DiagnosticsBuffer.instance.clear();
      await s.resume();
      final st = (await repo().load())!;
      expect(st.phase, MigrationPhase.downloading);
      expect(st.lastError, contains('sesión de Google cambió'));
      expect(_logged('ausente'), isFalse);
      expect(File(AppPaths.resolve(i1.encryptedPath).path).existsSync(),
          isFalse);
      expect(s.isRunning, isFalse);
      expect(env.destructiveCalls, 0);
    });

    test('la sesión cambia durante la subida: pausa, 0 subidas a la otra', () async {
      await env.seed();
      await repo().begin(
        oldEmail: pruebas,
        neededBytes: 1,
        downloadTotal: 0,
        now: 1,
      );
      final local = {for (final i in await env.a.items.getAllItems()) i.id};
      await repo().resetForUpload(localItemIds: local, now: 2);
      await repo().update(
        phase: MigrationPhase.uploading,
        newEmail: principal,
        now: 3,
      );
      await env.switchTo('otra@example.com');
      final s = env.migration(wireVerification: false);
      await s.refresh();
      await s.resume();
      final st = (await repo().load())!;
      expect(st.phase, MigrationPhase.uploading);
      expect(st.lastError, contains('sesión de Google cambió'));
      for (final e in ['otra@example.com', principal]) {
        expect(
          env.cloud.account(e).names.where((n) => n.endsWith('.vault')),
          isEmpty,
          reason: e,
        );
      }
    });

    test('selector que nunca responde: libera, mensaje, resultado tardío '
        'ignorado; «ya en curso» lo dice', () async {
      await env.seed(n: 1);
      await repo().begin(
        oldEmail: pruebas,
        neededBytes: 1,
        downloadTotal: 0,
        now: 1,
      );
      await repo().update(phase: MigrationPhase.signInNew, now: 2);
      final hang = env.cloud.hangNext = Completer<String>();
      final s = env.migration(
        wireVerification: false,
        signInTimeout: const Duration(milliseconds: 200),
      );
      await s.refresh();
      final run = s.resume();
      for (var i = 0; i < 50 && !s.isRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Mientras corre, «Reanudar» ya no vuelve en silencio.
      await expectLater(s.resume(), throwsA(isA<MigrationException>()));
      await run;
      expect(s.isRunning, isFalse);
      final st = (await repo().load())!;
      expect(st.phase, MigrationPhase.signInNew);
      expect(st.lastError, contains('no respondió'));
      hang.complete(principal); // respuesta tardía
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await repo().load())!.phase, MigrationPhase.signInNew);
    });

    test('«Pausar» libera un selector colgado en el acto', () async {
      await env.seed(n: 1);
      await repo().begin(
        oldEmail: pruebas,
        neededBytes: 1,
        downloadTotal: 0,
        now: 1,
      );
      await repo().update(phase: MigrationPhase.signInNew, now: 2);
      env.cloud.hangNext = Completer<String>();
      final s = env.migration(wireVerification: false);
      await s.refresh();
      final run = s.resume();
      for (var i = 0; i < 50 && env.cloud.signInCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      s.pause();
      await run.timeout(const Duration(seconds: 2));
      expect(s.isRunning, isFalse);
      expect((await repo().load())!.phase, MigrationPhase.signInNew);
    });

    test('Borrar datos de la anterior con el selector cancelado: mensaje '
        'propio, nada borrado y de vuelta en la nueva', () async {
      await env.seed(n: 1);
      await repo().begin(
        oldEmail: pruebas,
        neededBytes: 1,
        downloadTotal: 0,
        now: 1,
      );
      await repo().update(
        phase: MigrationPhase.askDeleteOld,
        newEmail: principal,
        now: 2,
      );
      await env.switchTo(principal);
      final s = env.migration(wireVerification: false);
      await s.refresh();
      final before = env.cloud.account(pruebas).count;
      env.cloud.cancelNext = 1;
      env.cloud.signInQueue.add(principal);
      await expectLater(
        s.deleteOldAccountData(),
        throwsA(
          isA<MigrationException>().having(
            (e) => e.message,
            'message',
            contains('no se borró nada'),
          ),
        ),
      );
      expect(env.cloud.account(pruebas).count, before);
      expect(env.cloud.currentAccountEmail, principal);
      expect((await repo().load())!.phase, MigrationPhase.askDeleteOld);
    });
  });
}
