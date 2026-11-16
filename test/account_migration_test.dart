// Cambio de cuenta de Google con migración (ronda iOS 1, tarea 2).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/migration/account_migration_service.dart';
import 'package:vault/data/migration/migration_repository.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';

import 'support/f9_env.dart';
import 'support/multi_account_cloud.dart';

const old = 'vieja@example.com';
const nueva = 'nueva@example.com';

void main() {
  late PhoneA a;
  late MultiAccountCloud cloud;
  late bool cacheSuspended;

  setUp(() async {
    cloud = MultiAccountCloud(old);
    a = PhoneA()..cloud = cloud;
    await a.setUp();
    cacheSuspended = false;
  });

  tearDown(() async {
    // Deja terminar la sincronización que se dispara al acabar el cambio.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await a.tearDown();
  });

  /// Bóveda con 3 items (miniaturas reales) subidos a la cuenta vieja.
  Future<void> seed() async {
    await a.addItem('i1', 'Uno.jpg', realThumb: true);
    await a.addItem('i2', 'Dos.jpg', realThumb: true, plainSize: 90000);
    await a.addItem('i3', 'Tres.jpg', realThumb: true);
    await a.syncAll();
  }

  /// Quita del teléfono el `.vault` y la miniatura de [id] (como la purga
  /// LRU): solo quedan en la cuenta vieja.
  void dropLocal(String id) {
    AppPaths.resolve(AppPaths.vaultRelativePath(id)).deleteSync();
    AppPaths.resolve(AppPaths.thumbRelativePath(id)).deleteSync();
  }

  AccountMigrationService service({
    int? freeBytes,
    int maxUploadRounds = 40,
    MigrationRepository? repo,
  }) {
    final fetcher = VaultFileFetcher(
      cloud: cloud,
      items: a.items,
      resolvePath: AppPaths.resolve,
    );
    return AccountMigrationService(
      cloud: cloud,
      items: a.items,
      migration: repo ?? MigrationRepository(dbProvider: () => a.vdb.database),
      queue: a.queue,
      sync: a.sync,
      fetcher: fetcher,
      network: a.net,
      prefs: a.prefs,
      recoveryBackupProvider: a.auth.exportRecoveryBackup,
      resolvePath: AppPaths.resolve,
      setCachePurgeSuspended: (v) => cacheSuspended = v,
      freeSpace: () async => freeBytes,
      nowMs: () => a.now,
      maxUploadRounds: maxUploadRounds,
    );
  }

  Future<MigrationState?> state() =>
      MigrationRepository(dbProvider: () => a.vdb.database).load();

  Future<void> begin(AccountMigrationService s) async {
    await s.start(await s.plan());
  }

  group('flujo feliz', () {
    test('baja lo que falta, sube todo a la cuenta nueva y verifica', () async {
      await seed();
      dropLocal('i2');
      final oldNames = cloud.account(old).names.toSet();
      cloud.signInQueue.add(nueva);
      final s = service();
      final plan = await s.plan();
      expect(plan.itemCount, 3);
      expect(plan.oldEmail, old);
      expect(plan.bytesToDownload, greaterThan(90000));
      expect(plan.thumbsToDownload, 1);
      expect(plan.uploadBytes, greaterThan(plan.bytesToDownload));

      await begin(s);

      final st = (await state())!;
      expect(st.phase, MigrationPhase.askDeleteOld);
      expect(st.newEmail, nueva);
      expect(cloud.currentAccountEmail, nueva);
      // Lo bajado quedó en el teléfono.
      expect(
        AppPaths.resolve(AppPaths.vaultRelativePath('i2')).existsSync(),
        isTrue,
      );
      expect(
        AppPaths.resolve(AppPaths.thumbRelativePath('i2')).existsSync(),
        isTrue,
      );
      // La cuenta nueva tiene todo, incluido respaldo y snapshot.
      final n = cloud.account(nueva);
      expect(n.names.toSet(), {
        'i1.vault',
        'i2.vault',
        'i3.vault',
        'i1.thumb',
        'i2.thumb',
        'i3.thumb',
        'recovery_backup.json',
        'vault_db.snapshot',
      });
      // Cada item quedó en_nube con la referencia de la cuenta NUEVA.
      for (final id in ['i1', 'i2', 'i3']) {
        final item = (await a.items.getItem(id))!;
        expect(item.syncStatus, SyncStatus.enNube, reason: id);
        final remote = n.byName('$id.vault')!;
        expect(item.driveFileId, remote.id);
        expect(item.cloudMd5, remote.md5Checksum);
        expect(item.cloudSize, remote.size);
        expect(item.thumbDriveFileId, n.byName('$id.thumb')!.id);
      }
      // La cuenta vieja NO se tocó.
      expect(cloud.account(old).names.toSet(), oldNames);
      // Durante la migración: sync normal en pausa y caché sin purgar.
      expect(a.sync.pausedForMigration, isTrue);
      expect(cacheSuspended, isTrue);
    });

    test('la sincronización normal no corre mientras dura', () async {
      await seed();
      cloud.signInQueue.add(nueva);
      final s = service();
      final running = s.start(await s.plan());
      await a.items.touchLastAccessed('i1');
      final before = cloud.account(old).uploadCalls;
      await a.sync.run(manual: true); // sin force: no hace nada
      expect(cloud.account(old).uploadCalls, before);
      await running;
    });

    test('con la cuenta nueva cargada, borrar la vieja es permanente y '
        'termina', () async {
      await seed();
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      expect((await state())!.phase, MigrationPhase.askDeleteOld);
      // El "selector": primero la vieja (para borrar), luego la nueva.
      cloud.signInQueue.addAll([old, nueva]);
      await s.deleteOldAccountData();
      expect(cloud.account(old).names, isEmpty);
      expect(cloud.account(nueva).names, isNotEmpty);
      expect(await state(), isNull);
      expect(a.sync.pausedForMigration, isFalse);
      expect(cacheSuspended, isFalse);
      expect(cloud.currentAccountEmail, nueva);
    });

    test('conservar los datos de la cuenta vieja los deja intactos', () async {
      await seed();
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      final oldNames = cloud.account(old).names.toSet();
      await s.keepOldAccountData();
      expect(cloud.account(old).names.toSet(), oldNames);
      expect(await state(), isNull);
      expect(a.sync.pausedForMigration, isFalse);
    });

    test('borrar pide la cuenta vieja: otra cuenta no borra nada', () async {
      await seed();
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      final oldNames = cloud.account(old).names.toSet();
      // El usuario elige OTRA cuenta al borrar; se vuelve a la nueva.
      cloud.signInQueue.addAll(['otra@example.com', nueva]);
      await expectLater(
        s.deleteOldAccountData(),
        throwsA(isA<MigrationException>()),
      );
      expect(cloud.account(old).names.toSet(), oldNames);
      expect(cloud.account('otra@example.com').names, isEmpty);
      expect((await state())!.phase, MigrationPhase.askDeleteOld);
    });
  });

  group('cuenta nueva', () {
    test('elegir la MISMA cuenta no continúa; se puede elegir otra', () async {
      await seed();
      cloud.signInQueue.add(old); // misma cuenta
      final s = service();
      await begin(s);
      expect((await state())!.phase, MigrationPhase.signInNew);
      expect(s.status.value.needsAttention, isTrue);
      expect(s.status.value.message, contains('misma cuenta'));
      cloud.signInQueue.add(nueva);
      await s.resume();
      expect((await state())!.phase, MigrationPhase.askDeleteOld);
    });

    test('cancelar el selector deja el flujo esperando la cuenta', () async {
      await seed();
      final s = service(); // signInQueue vacía = el usuario cancela el selector
      await begin(s);
      expect((await state())!.phase, MigrationPhase.signInNew);
      expect(cloud.account(nueva).count, 0);
    });

    test('con OTRA bóveda en la cuenta nueva se detiene y no sobrescribe '
        'nada', () async {
      await seed();
      final other = cloud.account(nueva);
      final foreign = Uint8List.fromList(
        '{"type":"recovery","otra":"boveda"}'.codeUnits,
      );
      await other.uploadBytes(bytes: foreign, name: 'recovery_backup.json');
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      expect((await state())!.phase, MigrationPhase.blockedOtherVault);
      expect(other.names.toList(), ['recovery_backup.json']);
      expect(other.bytesOf('recovery_backup.json'), foreign);
      expect(other.uploadedNames, [
        'recovery_backup.json',
      ]); // solo la preparación
      // Los archivos locales siguen "en_nube" con la cuenta vieja.
      expect((await a.items.getItem('i1'))!.syncStatus, SyncStatus.enNube);
    });

    test('cuota insuficiente: se detiene ANTES de subir', () async {
      await seed();
      cloud.account(nueva).quotaValue = const CloudQuota(
        usedBytes: 999900,
        limitBytes: 1000000,
      );
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      expect((await state())!.phase, MigrationPhase.blockedQuota);
      expect(cloud.account(nueva).count, 0);
      expect((await a.items.getItem('i1'))!.syncStatus, SyncStatus.enNube);
    });

    test('bloqueada por otra bóveda: cancelar vuelve a la cuenta vieja y '
        'todo sigue igual', () async {
      await seed();
      await cloud
          .account(nueva)
          .uploadBytes(
            bytes: Uint8List.fromList([1, 2, 3]),
            name: 'recovery_backup.json',
          );
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      final before = [
        for (final i in await a.items.getAllItems())
          (i.id, i.driveFileId, i.cloudMd5, i.syncStatus),
      ];
      cloud.signInQueue.add(old);
      await s.cancelAndRestore();
      expect(await state(), isNull);
      expect(cloud.currentAccountEmail, old);
      expect(a.sync.pausedForMigration, isFalse);
      expect(cacheSuspended, isFalse);
      expect([
        for (final i in await a.items.getAllItems())
          (i.id, i.driveFileId, i.cloudMd5, i.syncStatus),
      ], before);
    });
  });

  group('red, reanudación y cancelación', () {
    test(
      'sin red al empezar: pausa con mensaje y se reanuda al volver',
      () async {
        await seed();
        dropLocal('i1');
        a.net.set(NetworkKind.none);
        cloud.signInQueue.add(nueva);
        final s = service();
        await begin(s);
        expect((await state())!.phase, MigrationPhase.downloading);
        expect(s.status.value.needsAttention, isTrue);
        expect(s.status.value.message, contains('sin conexión'));
        a.net.set(NetworkKind.wifi);
        await s.resume();
        expect((await state())!.phase, MigrationPhase.askDeleteOld);
        expect(
          AppPaths.resolve(AppPaths.vaultRelativePath('i1')).existsSync(),
          isTrue,
        );
      },
    );

    test('solo Wi-Fi: con datos móviles espera', () async {
      await seed();
      dropLocal('i1');
      a.net.set(NetworkKind.mobile);
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      expect((await state())!.phase, MigrationPhase.downloading);
      expect(s.status.value.message, contains('Wi-Fi'));
    });

    test('corte de red a mitad de la descarga: se pausa y reanuda sin repetir '
        'lo ya bajado', () async {
      await seed();
      dropLocal('i1');
      dropLocal('i2');
      dropLocal('i3');
      var downloads = 0;
      cloud.account(old).failure = (op) {
        if (op == 'bytes') {
          downloads++;
          if (downloads == 3) return const CloudNoNetworkException();
        }
        return null;
      };
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      expect((await state())!.phase, MigrationPhase.downloading);
      final present = [
        for (final id in ['i1', 'i2', 'i3'])
          AppPaths.resolve(AppPaths.vaultRelativePath(id)).existsSync(),
      ];
      expect(present.where((p) => p).length, lessThan(3));
      cloud.account(old).failure = null;
      await s.resume();
      expect((await state())!.phase, MigrationPhase.askDeleteOld);
      for (final id in ['i1', 'i2', 'i3']) {
        expect(
          AppPaths.resolve(AppPaths.vaultRelativePath(id)).existsSync(),
          isTrue,
        );
      }
    });

    test('app matada a mitad de la subida: un servicio NUEVO retoma desde la '
        'BD y termina', () async {
      await seed();
      cloud.signInQueue.add(nueva);
      // La cuenta nueva falla al subir: la subida se detiene en pausa.
      cloud.account(nueva).failure = (op) =>
          op == 'upload' ? const CloudNoNetworkException() : null;
      final s1 = service(maxUploadRounds: 4);
      await begin(s1);
      final paused = (await state())!;
      expect(paused.phase, MigrationPhase.uploading);
      expect(paused.lastError, isNotNull);
      // Items ya reiniciados: pendientes, sin referencias de la cuenta vieja.
      expect((await a.items.getItem('i1'))!.driveFileId, isNull);
      // "Se mata la app": otro servicio sobre la misma BD.
      cloud.account(nueva).failure = null;
      final s2 = service();
      final recovered = await s2.refresh();
      expect(recovered!.phase, MigrationPhase.uploading);
      expect(a.sync.pausedForMigration, isTrue);
      await s2.resume();
      expect((await state())!.phase, MigrationPhase.askDeleteOld);
      for (final id in ['i1', 'i2', 'i3']) {
        expect((await a.items.getItem(id))!.syncStatus, SyncStatus.enNube);
      }
    });

    test('cancelar a mitad de la subida restaura TODO y vuelve a la cuenta '
        'vieja', () async {
      await seed();
      final before = [
        for (final i in await a.items.getAllItems())
          (i.id, i.driveFileId, i.cloudMd5, i.cloudSize, i.thumbDriveFileId),
      ];
      cloud.signInQueue.add(nueva);
      cloud.account(nueva).failure = (op) =>
          op == 'upload' ? const CloudNoNetworkException() : null;
      final s = service(maxUploadRounds: 4);
      await begin(s);
      expect((await state())!.phase, MigrationPhase.uploading);
      expect((await a.items.getItem('i1'))!.driveFileId, isNull);
      cloud.signInQueue.add(old);
      await s.cancelAndRestore();
      expect(await state(), isNull);
      expect(cloud.currentAccountEmail, old);
      expect([
        for (final i in await a.items.getAllItems())
          (i.id, i.driveFileId, i.cloudMd5, i.cloudSize, i.thumbDriveFileId),
      ], before);
      for (final i in await a.items.getAllItems()) {
        expect(
          i.syncStatus == SyncStatus.enNube ||
              i.syncStatus == SyncStatus.enCache,
          isTrue,
          reason: i.id,
        );
      }
      expect(a.sync.pausedForMigration, isFalse);
      expect(cacheSuspended, isFalse);
    });

    test('cancelar pidiendo una cuenta que no es la vieja: avisa y conserva '
        'el estado', () async {
      await seed();
      cloud.signInQueue.add(nueva);
      cloud.account(nueva).quotaValue = const CloudQuota(
        usedBytes: 999900,
        limitBytes: 1000000,
      );
      final s = service();
      await begin(s);
      cloud.signInQueue.add('otra@example.com');
      await expectLater(
        s.cancelAndRestore(),
        throwsA(isA<MigrationException>()),
      );
      expect(await state(), isNotNull);
    });
  });

  group('antes de empezar', () {
    test('sin espacio en el teléfono no arranca', () async {
      await seed();
      dropLocal('i2');
      final s = service(freeBytes: 1000);
      final plan = await s.plan();
      expect(plan.enoughLocalSpace, isFalse);
      expect(plan.freeBytes, 1000);
      await expectLater(s.start(plan), throwsA(isA<MigrationException>()));
      expect(await state(), isNull);
    });

    test('espacio desconocido (null) no bloquea', () async {
      await seed();
      final plan = await service(freeBytes: null).plan();
      expect(plan.enoughLocalSpace, isTrue);
      expect(plan.freeBytes, isNull);
    });

    test('sin sesión no arranca', () async {
      await seed();
      await cloud.signOut();
      final s = service();
      await expectLater(
        s.start(await s.plan()),
        throwsA(isA<MigrationException>()),
      );
    });

    test('no se puede empezar dos veces', () async {
      await seed();
      final s = service();
      final plan = await s.plan();
      await s.start(plan);
      await expectLater(s.start(plan), throwsA(isA<MigrationException>()));
    });

    test('items perdidos (sin copia local ni en la nube) se cuentan y no '
        'bloquean', () async {
      await seed();
      dropLocal('i3');
      await a.items.setDriveFileId('i3', null);
      final plan = await service().plan();
      expect(plan.lostCount, 1);
    });
  });

  test(
    'el estado de una migración a medias no se hereda al restaurar',
    () async {
      // El snapshot trae las tablas, pero la restauración las vacía: ver
      // test de restauración; aquí solo se comprueba que el estado persiste y
      // se puede limpiar.
      await seed();
      cloud.signInQueue.add(nueva);
      final s = service();
      await begin(s);
      final repo = MigrationRepository(dbProvider: () => a.vdb.database);
      expect(await repo.load(), isNotNull);
      expect(await repo.hasSavedRefs(), isTrue);
      await repo.clear();
      expect(await repo.load(), isNull);
      expect(await repo.hasSavedRefs(), isFalse);
    },
  );

  test('un item verificado en la cuenta vieja y con VaultFetchVerification '
      'dañado no frena la migración', () async {
    await seed();
    dropLocal('i2');
    // La cuenta vieja entrega un .vault alterado (MD5 distinto).
    final remote = cloud.account(old).byName('i2.vault')!;
    cloud.account(old).tamper(remote.id);
    cloud.signInQueue.add(nueva);
    final s = service();
    await begin(s);
    expect((await state())!.phase, MigrationPhase.askDeleteOld);
    // i2 no se pudo recuperar: queda en error y NO se subió.
    expect((await a.items.getItem('i2'))!.syncStatus, SyncStatus.error);
    expect(cloud.account(nueva).byName('i2.vault'), isNull);
    expect((await a.items.getItem('i1'))!.syncStatus, SyncStatus.enNube);
  });
}
