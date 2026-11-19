import 'dart:math';

import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/cache_manager.dart';
import 'package:vault/core/session/session_ticket.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/sync/cloud_account_tag.dart';
import 'package:vault/data/sync/cloud_verification_service.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';

import 'f9_env.dart';
import 'fakes.dart';
import 'multi_account_cloud.dart';

/// Cuentas de los tests (D75): SOLO nubes falsas. «pruebas» hace de la cuenta
/// de pruebas del iPhone (luego vaciada) y «principal» de la cuenta buena.
const pruebas = 'pruebas@example.com';
const principal = 'principal@example.com';

/// Teléfono con bóveda real (llaves, BD sqlite, archivos cifrados), nube de
/// VARIAS cuentas y la sincronización CON tags de cuenta (como la app).
class VerifyEnv {
  late MultiAccountCloud cloud;
  late PhoneA a;
  late CloudAccountTagger tagger;
  late SyncService sync;
  late CloudVerificationService verifier;
  late CacheManager cache;
  bool migrationActive = false;
  bool rotationActive = false;

  /// `null` = sin la guarda de sesión; si no, el ticket que devuelve.
  SessionTicket? Function()? ticket;

  Future<void> setUp({String initial = pruebas}) async {
    cloud = MultiAccountCloud(initial);
    a = PhoneA()..cloud = cloud;
    await a.setUp();
    tagger = CloudAccountTagger(cloud: cloud, dbProvider: () => a.vdb.database);
    sync = SyncService(
      cloud: cloud,
      queue: a.queue,
      items: a.items,
      network: a.net,
      prefs: a.prefs,
      isUnlocked: () => a.session.isUnlocked,
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: a.auth.exportRecoveryBackup,
      snapshotProvider: a.vdb.exportEncryptedSnapshot,
      nowMs: () => a.now,
      random: Random(1),
      scheduleWakeups: false,
      accountTag: tagger.current,
    );
    cache = CacheManager(
      repository: a.items,
      preferences: CachePreferences(InMemorySecureStore()),
      accountTag: tagger.current,
    );
    verifier = CloudVerificationService(
      cloud: cloud,
      items: a.items,
      sync: sync,
      prefs: a.prefs,
      network: a.net,
      tagger: tagger,
      dbProvider: () => a.vdb.database,
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: a.auth.exportRecoveryBackup,
      sessionTicket: () => ticket != null
          ? ticket!()
          : (a.session.isUnlocked ? a.session.ticket() : null),
      rotationActive: () async => rotationActive,
      migrationActive: () async => migrationActive,
      nowMs: () => a.now,
    );
  }

  Future<void> tearDown() async {
    await idle();
    sync.dispose();
    await a.tearDown();
  }

  /// Espera a que termine la sincronización lanzada sin esperar.
  Future<void> idle() async {
    for (var i = 0; i < 400 && sync.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Espera la sincronización en curso y hace una pasada completa más.
  Future<void> settle() async {
    await idle();
    await sync.run(manual: true);
    await idle();
  }

  /// Bóveda con [n] items (miniaturas reales) subidos a la cuenta actual.
  Future<void> seed({int n = 3}) async {
    for (var i = 1; i <= n; i++) {
      await a.addItem('i$i', 'Foto$i.jpg', realThumb: true);
    }
    await sync.run(manual: true);
  }

  /// Cambia la sesión de Google a [email] (como el selector).
  Future<void> switchTo(String email) async {
    cloud.signInQueue.add(email);
    await cloud.signOut();
    await cloud.signIn();
  }

  /// Vacía la cuenta [email] (como la cuenta de pruebas del iPhone).
  void empty(String email) {
    final acc = cloud.account(email);
    for (final f in [...acc.names]) {
      final id = acc.byName(f)!.id;
      acc.remove(id);
    }
  }

  Future<String> tagOf(String email) async {
    final before = cloud.currentAccountEmail;
    await switchTo(email);
    final t = (await tagger.current())!;
    if (before != null) {
      await switchTo(before);
    } else {
      await cloud.signOut();
    }
    return t;
  }

  int get destructiveCalls {
    var n = 0;
    for (final e in [pruebas, principal, 'otra@example.com']) {
      final acc = cloud.account(e);
      n += acc.deleteCalls + acc.renameCalls;
    }
    return n;
  }

  MigrationRepository get repo =>
      MigrationRepository(dbProvider: () => a.vdb.database);

  AccountMigrationService migration({
    Future<String?> Function()? backup,
    bool wireVerification = true,
  }) => AccountMigrationService(
    cloud: cloud,
    items: a.items,
    migration: repo,
    queue: a.queue,
    sync: sync,
    fetcher: VaultFileFetcher(
      cloud: cloud,
      items: a.items,
      resolvePath: AppPaths.resolve,
    ),
    network: a.net,
    prefs: a.prefs,
    recoveryBackupProvider: backup ?? a.auth.exportRecoveryBackup,
    resolvePath: AppPaths.resolve,
    setCachePurgeSuspended: (v) => cache.suspended = v,
    freeSpace: () async => null,
    nowMs: () => a.now,
    onAbandoned: wireVerification
        ? () async {
            await verifier.verify();
          }
        : null,
  );

  Future<CloudVerificationResult> verifyAndSettle() async {
    final r = await verifier.verify();
    await settle();
    return r;
  }
}
