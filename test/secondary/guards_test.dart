// Fase 8, paso 4 (DISENO_SENUELO §4.3): con la bóveda secundaria abierta no
// corre nada de la principal (sync, sin conexión, snapshot, migración,
// rotación) y la nube corta toda operación.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/primary_gates.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/cloud/slot_guarded_cloud.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';

import '../support/f9_env.dart';
import '../support/fake_cloud.dart';
import '../support/settings_support.dart';

Future<KeyHierarchy> _keys(int seed) => KeyHierarchy.fromDek(
  Uint8List.fromList(List.generate(32, (i) => i + seed)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SlotGuardedCloudStorage', () {
    test('con la secundaria abierta TODO lanza CloudSlotException y no '
        'cambia nada; bloqueada o con la principal, pasa', () async {
      final inner = FakeCloudStorage(email: 'dueno@example.com');
      await inner.uploadBytes(
        bytes: Uint8List(3),
        name: 'recovery_backup.json',
      );
      final s = VaultSession.create();
      final cloud = SlotGuardedCloudStorage(inner, session: s);

      // Bloqueada: como siempre (restauración, flush tras bloquear).
      expect(cloud.currentAccountEmail, 'dueno@example.com');
      expect(await cloud.list(), hasLength(1));
      s.open(await _keys(1));
      expect(await cloud.findByName('recovery_backup.json'), isNotNull);
      s.clear();

      s.open(await _keys(2), slot: VaultSlot.secondary);
      expect(cloud.currentAccountEmail, isNull);
      final tmp = File(
        '${(await Directory.systemTemp.createTemp('guard')).path}/f',
      )..writeAsBytesSync([1]);
      final calls = <Future<Object?> Function()>[
        cloud.signIn,
        cloud.signInSilently,
        cloud.signOut,
        cloud.getQuota,
        () => cloud.uploadFile(file: tmp, name: 'x.vault'),
        () => cloud.uploadBytes(bytes: Uint8List(1), name: 'x'),
        () => cloud.getMetadata('1'),
        () => cloud.rename('1', 'y'),
        () => cloud.download('1', File('${tmp.path}.d')),
        () => cloud.downloadBytes('1'),
        () => cloud.delete('1'),
        () => cloud.findByName('recovery_backup.json'),
        cloud.list,
      ];
      for (final c in calls) {
        await expectLater(c(), throwsA(isA<CloudSlotException>()));
      }
      expect(inner.count, 1);
      expect(inner.names, ['recovery_backup.json']);
      expect(inner.email, 'dueno@example.com');
      expect(const CloudSlotException().message, 'No disponible');
    });
  });

  group('compuertas de la principal', () {
    late PhoneA a;
    setUp(() async {
      a = PhoneA();
      await a.setUp();
    });
    tearDown(() async {
      await a.tearDown();
    });

    test(
      'sync, flush del snapshot y "sucio": nada con la secundaria abierta',
      () async {
        await a.addItem('i1', 'Uno.jpg');
        final gated = SyncService(
          cloud: a.cloud,
          queue: a.queue,
          items: a.items,
          network: a.net,
          prefs: a.prefs,
          isUnlocked: PrimaryGates.unlocked(a.session),
          resolvePath: AppPaths.resolve,
          recoveryBackupProvider: a.auth.exportRecoveryBackup,
          snapshotProvider: a.vdb.exportEncryptedSnapshot,
          nowMs: () => a.now,
          random: Random(2),
          scheduleWakeups: false,
        );
        addTearDown(gated.dispose);
        var notified = 0;
        final dataChanged = PrimaryGates.dataChanged(
          a.session,
          () => notified++,
        );
        final dirtyBefore = await a.prefs.getDirtyAt();

        final primaryKeys = await KeyHierarchy.fromDek(
          a.session.keys.dekBytes(),
        );
        a.session.clear();
        a.session.open(await _keys(77), slot: VaultSlot.secondary);
        await gated.run(manual: true);
        await gated.flushSnapshotBeforeLock();
        dataChanged();
        expect(a.cloud.count, 0, reason: 'nada subido');
        expect(a.cloud.uploadCalls, 0);
        expect(notified, 0);
        expect(await a.prefs.getDirtyAt(), dirtyBefore);
        expect(
          PrimaryGates.ticket(a.session)(),
          isNull,
          reason: 'sin ticket de la principal',
        );

        // Con la principal abierta, la misma compuerta deja pasar.
        a.session.clear();
        a.session.open(primaryKeys);
        dataChanged();
        expect(notified, 1);
        expect(PrimaryGates.ticket(a.session)(), isNotNull);
        await gated.run(manual: true);
        expect(a.cloud.count, greaterThan(0));
      },
    );

    test(
      'migración: sin ticket de la principal no lee ni escribe nada',
      () async {
        var loads = 0;
        final svc = AccountMigrationService(
          cloud: a.cloud,
          items: a.items,
          migration: MigrationRepository(
            dbProvider: () {
              loads++;
              return a.vdb.database;
            },
          ),
          queue: a.queue,
          sync: a.sync,
          fetcher: VaultFileFetcher(
            cloud: a.cloud,
            items: a.items,
            resolvePath: AppPaths.resolve,
          ),
          network: a.net,
          prefs: a.prefs,
          recoveryBackupProvider: a.auth.exportRecoveryBackup,
          resolvePath: AppPaths.resolve,
          sessionTicket: PrimaryGates.ticket(a.session),
        );
        a.session.clear();
        a.session.open(await _keys(77), slot: VaultSlot.secondary);
        await svc.resume();
        expect(loads, 0);
        expect(svc.isRunning, isFalse);
      },
    );
  });

  group('instancias y repositorios de la principal', () {
    tearDown(() => VaultSession().clear());

    test('con la secundaria abierta en la sesión de la app lanzan '
        'WrongVaultSlotError sin abrir nada', () async {
      VaultSession().open(await _keys(5), slot: VaultSlot.secondary);
      await expectLater(
        VaultDatabase.instance.database,
        throwsA(isA<WrongVaultSlotError>()),
      );
      await expectLater(
        SyncQueueRepository().counts(),
        throwsA(isA<WrongVaultSlotError>()),
      );
      await expectLater(
        MigrationRepository().load(),
        throwsA(isA<WrongVaultSlotError>()),
      );
      await expectLater(
        VaultDatabase.instance.exportEncryptedSnapshot(),
        throwsA(isA<WrongVaultSlotError>()),
      );
      expect(VaultDatabase.instance.isOpen, isFalse);
    });
  });

  group('rotación', () {
    testWidgets('con la secundaria abierta no avanza ni escribe el registro', (
      tester,
    ) async {
      final e = SettingsTestEnv();
      await tester.runAsync(e.init);
      addTearDown(e.dispose);
      final svc = e.rotationService(network: FakeNetworkMonitor());
      await tester.runAsync(() async {
        await e.auth.unlockWithPin(settingsTestPin);
        await e.auth.prepareRotation(
          settingsTestPin,
          toGen: 2,
          accountEmail: 'santy@example.com',
        );
        final raw = await e.store.read(RotationKeyStore.recordKey);
        e.auth.session.clear();
        e.auth.session.open(await _keys(9), slot: VaultSlot.secondary);
        await svc.resume();
        expect(svc.isRunning, isFalse);
        expect(await e.store.read(RotationKeyStore.recordKey), raw);
      });
    });
  });

  test('CloudSlotException es una CloudException (manejadores de siempre)', () {
    expect(const CloudSlotException(), isA<CloudException>());
    expect(describeSyncError(const CloudSlotException()), isNotEmpty);
  });
}
