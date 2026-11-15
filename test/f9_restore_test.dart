import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';

import 'support/f9_env.dart';
import 'support/fakes.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

VaultDataRepository _repo(VaultDatabase vdb) =>
    VaultDataRepository(dbProvider: () => vdb.database);

/// Crea el teléfono A con carpetas, items, miniaturas y todo subido.
Future<PhoneA> _phoneA({bool sync = true}) async {
  final a = PhoneA();
  await a.setUp();
  await a.addFolder('f1', 'Vacaciones');
  await a.addFolder('f2', 'Playa', parent: 'f1');
  await a.addItem('i1', 'Atardecer.jpg');
  await a.addItem('i2', 'Familia.jpg', folderId: 'f1');
  await a.addItem('i3', 'Olas.jpg', folderId: 'f2', plainSize: 3 * 1024 * 1024);
  await a.addItem('i4', 'Sin miniatura.pdf', thumb: false);
  await a.items.renameItem('i1', 'Atardecer rojo.jpg');
  if (sync) await a.syncAll();
  return a;
}

const _wrong = 'ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2';

void main() {
  late PhoneA a;
  late PhoneB b;

  tearDown(() async {
    await b.tearDown();
    await a.tearDown();
  });

  Future<PhoneB> newB({
    DateTime Function()? clock,
    int parallelism = 2,
    InMemorySecureStore? store,
    String? expected,
  }) async {
    final phone = PhoneB(clock: clock, store: store);
    await phone.setUp(
      a.cloud,
      expectedPassword: expected ?? a.passwordA,
      parallelism: parallelism,
    );
    return phone;
  }

  Future<void> reachCode(PhoneB phone) async {
    expect(await phone.service.probe(), RestoreProbeResult.found);
  }

  Future<void> verified(PhoneB phone) async {
    await reachCode(phone);
    expect(await phone.service.verifyCode(a.recoveryCode), isTrue);
  }

  group('restauración feliz', () {
    test('misma DEK, items, carpetas y miniaturas; todo en_nube', () async {
      a = await _phoneA();
      expect(a.cloud.byName('vault_db.snapshot'), isNotNull);
      b = await newB();
      await verified(b);

      final stages = <RestoreStage>[];
      final result = await b.service.restore(
        newPin: '654321',
        onProgress: (pr) => stages.add(pr.stage),
      );
      expect(result.items, 4);
      expect(result.folders, 2);
      expect(result.lostItems, 0);
      expect(result.thumbnails, 3);
      expect(stages, containsAll(RestoreStage.values));

      expect(b.auth.isUnlocked, isTrue);
      expect(b.session.keys.keyCheck, a.session.keys.keyCheck);

      final vdb = b.openDb();
      addTearDown(vdb.close);
      final repo = _repo(vdb);
      final all = [
        ...await repo.getItemsByFolder(null),
        ...await repo.getItemsByFolder('f1'),
        ...await repo.getItemsByFolder('f2'),
      ];
      expect(all.map((i) => i.id).toSet(), {'i1', 'i2', 'i3', 'i4'});
      expect(all.firstWhere((i) => i.id == 'i1').name, 'Atardecer rojo.jpg');
      for (final i in all) {
        expect(i.syncStatus, SyncStatus.enNube);
        expect(i.driveFileId, isNotNull);
        expect(i.cloudMd5, isNotNull);
        expect(AppPaths.isAbsolutePath(i.encryptedPath), isFalse);
      }
      expect((await repo.getFolder('f2'))!.parentId, 'f1');
      expect(await repo.getBreadcrumbs('f2'), hasLength(2));

      for (final id in ['i1', 'i2', 'i3']) {
        final f = AppPaths.resolve(AppPaths.thumbRelativePath(id));
        expect(await f.readAsBytes(), a.thumbs[id]);
      }
      expect(
        AppPaths.resolve(AppPaths.thumbRelativePath('i4')).existsSync(),
        isFalse,
      );
      expect(AppPaths.vaultDir.listSync(), isEmpty);
      expect(RestoreService.stagingDir.existsSync(), isFalse);

      // El PIN nuevo desbloquea tras bloquear; el viejo no.
      b.auth.lock();
      final b2 = b.newAuth();
      expect(await b2.unlockWithPin('1234'), isFalse);
      expect(await b2.unlockWithPin('654321'), isTrue);
      expect(b2.session.keys.keyCheck, a.session.keys.keyCheck);

      expect(
        await b.auth.exportRecoveryBackup(),
        utf8.decode(a.cloud.bytesOf('recovery_backup.json')!),
      );
      expect(await b.auth.isBiometricUnlockEnabled(), isFalse);
    });

    test(
      'abrir un archivo descarga de Drive y verifica MD5; sync no re-sube',
      () async {
        a = await _phoneA();
        b = await newB();
        await reachCode(b);
        // Tolerante: minúsculas.
        expect(
          await b.service.verifyCode(a.recoveryCode.toLowerCase()),
          isTrue,
        );
        await b.service.restore(newPin: '2468');
        final uploadsBefore = a.cloud.uploadedNames.length;

        final vdb = b.openDb();
        addTearDown(vdb.close);
        final repo = _repo(vdb);
        final fetcher = VaultFileFetcher(
          cloud: a.cloud,
          items: repo,
          resolvePath: AppPaths.resolve,
        );
        final item = (await repo.getItem('i3'))!;
        final file = await fetcher.ensureLocal(item);
        expect(await md5OfFile(file), item.cloudMd5);
        expect(
          md5OfBytes(await file.readAsBytes()),
          a.cloud.byName('i3.vault')!.md5Checksum,
        );
        expect((await repo.getItem('i3'))!.syncStatus, SyncStatus.enCache);

        final sync = SyncService(
          cloud: a.cloud,
          queue: SyncQueueRepository(dbProvider: () => vdb.database),
          items: repo,
          network: a.net,
          prefs: b.prefs,
          isUnlocked: () => b.session.isUnlocked,
          resolvePath: AppPaths.resolve,
          recoveryBackupProvider: b.auth.exportRecoveryBackup,
          snapshotProvider: vdb.exportEncryptedSnapshot,
          nowMs: () => 9000001,
          scheduleWakeups: false,
        );
        addTearDown(sync.dispose);
        await sync.run(manual: true);
        expect(a.cloud.uploadedNames.length, uploadsBefore);
      },
    );

    test('items perdidos: sin driveFileId o sin copia en Drive', () async {
      a = await _phoneA();
      await a.addItem('lost1', 'Nunca subida.jpg', thumb: false);
      a.cloud.remove(a.cloud.byName('i2.vault')!.id);
      await a.queue.enqueue(
        'gone',
        SyncJobKind.deleteRemote,
        now: 1,
        payload: '{"file":"x"}',
      );
      await a.queue.enqueue('lost1', SyncJobKind.file, now: 1);
      await a.republishSnapshot();

      b = await newB();
      await verified(b);
      final r = await b.service.restore(newPin: '1357');
      expect(r.lostItems, 2);
      expect(r.items, 3);

      final vdb = b.openDb();
      addTearDown(vdb.close);
      final repo = _repo(vdb);
      expect((await repo.getItem('lost1'))!.syncStatus, SyncStatus.error);
      expect((await repo.getItem('i2'))!.syncStatus, SyncStatus.error);
      expect((await repo.getItem('i1'))!.syncStatus, SyncStatus.enNube);
      final q = await SyncQueueRepository(dbProvider: () => vdb.database).all();
      expect(q.map((j) => j.kind), [SyncJobKind.deleteRemote]);
      expect(q.single.state, SyncJobState.pendiente);
    });

    test('miniatura ausente en Drive: se quita la ruta, no se rompe', () async {
      a = await _phoneA();
      a.cloud.remove(a.cloud.byName('i1.thumb')!.id);
      b = await newB();
      await verified(b);
      final r = await b.service.restore(newPin: '1357');
      expect(r.missingThumbnails, 1); // i1 (i4 nunca tuvo miniatura)
      final vdb = b.openDb();
      addTearDown(vdb.close);
      final i1 = (await _repo(vdb).getItem('i1'))!;
      expect(i1.thumbPath, isNull);
      expect(i1.thumbDriveFileId, isNull);
    });

    test('tras restaurar no hay nada "sucio" ni respaldo por re-subir', () async {
      a = await _phoneA();
      b = await newB();
      await verified(b);
      await b.service.restore(newPin: '1357');
      expect(await b.prefs.getDirtyAt(), isNull);
      expect(await b.prefs.getSnapshotAt(), 9000000);
      expect(await b.prefs.getRecoveryUploadedSha(), isNotEmpty);
    });
  });

  group('sin respaldo / respaldo inválido', () {
    test('cuenta vacía y solo snapshot: noBackup, sin tocar nada', () async {
      a = PhoneA();
      await a.setUp();
      b = await newB();
      expect(await b.service.probe(), RestoreProbeResult.noBackup);
      await a.cloud.uploadBytes(bytes: _b('x'), name: 'vault_db.snapshot');
      expect(await b.service.probe(), RestoreProbeResult.noBackup);
      expect(b.vaultKeys, isEmpty);
      expect(RestoreService.stagingDir.existsSync(), isFalse);
    });

    test('solo llaves, sin snapshot: incompleto', () async {
      a = PhoneA();
      await a.setUp();
      await a.sync.run(manual: true);
      expect(a.cloud.byName('recovery_backup.json'), isNotNull);
      expect(a.cloud.byName('vault_db.snapshot'), isNull);
      b = await newB();
      expect(await b.service.probe(), RestoreProbeResult.incomplete);
    });

    test('respaldo ilegible o con envoltura del PIN: rechazado', () async {
      a = PhoneA();
      await a.setUp();
      final meta = await a.cloud.uploadBytes(
        bytes: _b('no es json'),
        name: 'recovery_backup.json',
      );
      b = await newB();
      expect(await b.service.probe(), RestoreProbeResult.invalid);

      final pinEnv =
          jsonDecode(a.store.data[AuthController.pinEnvelopeKey]!) as Map;
      final fake = jsonEncode({'type': 'vault.recovery-backup', ...pinEnv});
      await a.cloud.uploadBytes(
        bytes: _b(fake),
        name: 'recovery_backup.json',
        replaceFileId: meta.id,
      );
      expect(await b.service.probe(), RestoreProbeResult.invalid);
      await expectLater(
        b.auth.verifyRecoveryCode(
          recoveryCode: a.recoveryCode,
          recoveryBackupJson: fake,
        ),
        throwsFormatException,
      );
    });
  });

  group('código incorrecto', () {
    test(
      'error, nada escrito, intentos persistidos y límite creciente',
      () async {
        a = await _phoneA();
        var now = DateTime(2026, 1, 1, 12);
        final store = InMemorySecureStore();
        b = await newB(clock: () => now, store: store);
        await reachCode(b);

        for (var i = 0; i < 4; i++) {
          expect(await b.service.verifyCode(_wrong), isFalse);
        }
        expect(b.vaultKeys, isEmpty);
        expect(await b.auth.hasVault(), isFalse);
        expect(File(b.dbPath).existsSync(), isFalse);
        expect(AppPaths.thumbsDir.listSync(), isEmpty);
        expect(b.auth.isUnlocked, isFalse);

        // 5.º fallo: 30 s de espera; el siguiente intento ni se evalúa.
        expect(await b.service.verifyCode(_wrong), isFalse);
        await expectLater(
          b.service.verifyCode(a.recoveryCode),
          throwsA(isA<PinLockedOutException>()),
        );
        expect(await b.service.lockoutRemaining(), isNotNull);

        // Persistido: otro controlador sobre el mismo almacén sigue bloqueado.
        final again = b.newAuth();
        expect(await again.restoreLockoutRemaining(), isNotNull);

        now = now.add(const Duration(seconds: 31));
        expect(await b.service.verifyCode(a.recoveryCode), isTrue);
        expect(await again.restoreLockoutRemaining(), isNull);
        expect(
          store.data.containsKey(AuthController.restoreAttemptsKey),
          isFalse,
        );
      },
    );

    test('el límite del código es independiente del del PIN', () async {
      a = await _phoneA();
      b = await newB();
      await reachCode(b);
      for (var i = 0; i < 5; i++) {
        await b.service.verifyCode(_wrong);
      }
      expect(await b.auth.pinLockoutRemaining(), isNull);
    });

    test('formato inválido no cuenta intento ni deriva', () async {
      a = await _phoneA();
      b = await newB();
      await reachCode(b);
      expect(await b.service.verifyCode('ABCD-EFGH'), isFalse);
      expect(
        await b.service.verifyCode('0000-0000-0000-0000-0000-0000'),
        isFalse,
      );
      expect(
        b.store.data.containsKey(AuthController.restoreAttemptsKey),
        isFalse,
      );
    });

    test('el código no queda en el almacén local', () async {
      a = await _phoneA();
      b = await newB();
      await verified(b);
      await b.service.restore(newPin: '1357');
      final plainCode = a.recoveryCode.replaceAll('-', '');
      for (final v in b.store.data.values) {
        expect(v.contains(plainCode), isFalse);
      }
    });
  });

  group('rollback y reanudación', () {
    test('snapshot que no abre con esta llave: error y nada local', () async {
      a = await _phoneA();
      b = await newB(expected: "x'${'00' * 32}'");
      await verified(b);
      await expectLater(
        b.service.restore(newPin: '1357'),
        throwsA(isA<RestoreCorruptException>()),
      );
      await _expectNothingLocal(b);
      expect(b.seenPasswords.single, matches(RegExp(r"^x'[0-9a-f]{64}'$")));
    });

    test('snapshot corrupto en Drive: error claro y nada local', () async {
      a = await _phoneA();
      final snap = a.cloud.byName('vault_db.snapshot')!;
      await a.cloud.uploadBytes(
        bytes: Uint8List.fromList(List<int>.filled(4096, 7)),
        name: 'vault_db.snapshot',
        replaceFileId: snap.id,
      );
      b = await newB();
      await verified(b);
      await expectLater(
        b.service.restore(newPin: '1357'),
        throwsA(
          isA<RestoreCorruptException>().having(
            (e) => e.message,
            'mensaje',
            contains('dañado o no corresponde'),
          ),
        ),
      );
      await _expectNothingLocal(b);
    });

    test('corte de red a mitad: sin estado a medias y reanudable', () async {
      a = await _phoneA();
      b = await newB(parallelism: 1);
      await verified(b);
      var calls = 0;
      a.cloud.failure = (op) {
        if (op != 'bytes') return null;
        calls++;
        return calls == 3 ? const CloudNoNetworkException() : null;
      };
      await expectLater(
        b.service.restore(newPin: '1357'),
        throwsA(isA<CloudNoNetworkException>()),
      );
      await _expectNothingLocal(b);
      final staged = Directory(
        p.join(RestoreService.stagingDir.path, 'thumbs'),
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.thumb'));
      expect(staged, isNotEmpty);

      var downloads = 0;
      a.cloud.failure = (op) {
        if (op == 'bytes') downloads++;
        return null;
      };
      final r = await b.service.restore(newPin: '1357');
      expect(r.items, 4);
      // Reintento: la BD y solo las miniaturas que faltaban (de 3).
      expect(downloads, lessThan(1 + 3));
      expect(b.auth.isUnlocked, isTrue);
      expect(RestoreService.stagingDir.existsSync(), isFalse);
    });

    test('falla al consolidar las llaves: se deshace todo y se reintenta',
        () async {
      a = await _phoneA();
      final flaky = FlakyStore();
      b = await newB(store: flaky);
      await verified(b);
      flaky.failKey = AuthController.pinEnvelopeKey;
      await expectLater(
        b.service.restore(newPin: '1357'),
        throwsA(isA<StateError>()),
      );
      await _expectNothingLocal(b);

      final r = await b.service.restore(newPin: '1357');
      expect(r.items, 4);
      expect(b.auth.isUnlocked, isTrue);
    });

    test('ya hay bóveda local: no se restaura encima', () async {
      a = await _phoneA();
      b = await newB();
      await verified(b);
      await b.auth.createVault('1111');
      await expectLater(
        b.service.restore(newPin: '1357'),
        throwsA(isA<StateError>()),
      );
    });

    test('sweepOrphans limpia BD y miniaturas sueltas sin bóveda', () async {
      a = PhoneA();
      await a.setUp();
      b = await newB();
      File(b.dbPath)
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      AppPaths.resolve(AppPaths.thumbRelativePath('zz')).writeAsBytesSync([1]);
      await RestoreService.sweepOrphans(dbPath: b.dbPath);
      expect(File(b.dbPath).existsSync(), isFalse);
      expect(AppPaths.thumbsDir.listSync(), isEmpty);
    });
  });

  group('seguridad', () {
    test("la BD se abre con x'hex' derivado de la DEK", () async {
      a = await _phoneA();
      b = await newB();
      await verified(b);
      await b.service.restore(newPin: '1357');
      final keys = await KeyHierarchy.fromDek(a.session.keys.dekBytes());
      expect(b.seenPasswords, [VaultDatabase.passwordFor(keys)]);
    });

    test('lo que sale a Drive no revela nombres ni el código', () async {
      a = await _phoneA();
      for (final n in a.cloud.names) {
        expect(
          n,
          matches(
            RegExp(
              r'^(i\d\.(vault|thumb)|recovery_backup\.json|vault_db\.snapshot)$',
            ),
          ),
        );
      }
      final backup = utf8.decode(a.cloud.bytesOf('recovery_backup.json')!);
      assertRecoveryBackupSafe(backup);
      expect(backup.contains(a.recoveryCode.replaceAll('-', '')), isFalse);
      // Los .vault y miniaturas cifrados no contienen los nombres.
      for (final name in ['i1.vault', 'i3.vault', 'i1.thumb']) {
        final text = latin1.decode(a.cloud.bytesOf(name)!);
        expect(text.contains('Atardecer'), isFalse);
      }
    });
  });
}

Future<void> _expectNothingLocal(PhoneB b) async {
  expect(b.vaultKeys, isEmpty);
  expect(await b.auth.hasVault(), isFalse);
  expect(b.session.isUnlocked, isFalse);
  expect(File(b.dbPath).existsSync(), isFalse);
  expect(AppPaths.thumbsDir.listSync(), isEmpty);
  expect(AppPaths.vaultDir.listSync(), isEmpty);
}
