// D75 (cambio de cuenta atascado, parte A paso 3): «Verificar copia en la
// nube». Solo nubes falsas (`MultiAccountCloud`): «pruebas» hace de la cuenta
// de pruebas del iPhone (vaciada) y «principal» de la cuenta buena.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/logging/diagnostics_buffer.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/sync/cloud_verification_service.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/sync_service.dart';

import 'support/f9_env.dart';
import 'support/verification_env.dart';

void main() {
  late VerifyEnv env;

  setUp(() async {
    env = VerifyEnv();
    await env.setUp();
  });

  tearDown(() async => env.tearDown());

  Future<void> nullTags() async {
    final db = await env.a.vdb.database;
    await db.update('vault_items', {
      'cloudAccountTag': null,
      'thumbAccountTag': null,
    });
  }

  group('el caso del iPhone', () {
    test('en_nube de la cuenta de pruebas (vaciada) verificado en la '
        'principal: pendiente -> re-subida con tag de la principal -> '
        'restaurar en limpio da found', () async {
      await env.seed();
      final tagPruebas = await env.tagger.current();
      expect(tagPruebas, isNotNull);
      for (final id in ['i1', 'i2', 'i3']) {
        expect((await env.a.items.getItem(id))!.cloudAccountTag, tagPruebas);
      }
      // La sesión acaba en la principal por fuera del flujo, la de pruebas
      // se vacía y la principal solo tiene un índice suelto (los ~120 KB).
      await env.switchTo(principal);
      env.empty(pruebas);
      await env.cloud.account(principal).uploadBytes(
        bytes: Uint8List(1000),
        name: CloudNames.dbSnapshot,
      );
      expect(await env.verifier.needsVerification(), isTrue);
      // Un evento de diagnóstico persistido (parte B) no debe viajar.
      final dbA = await env.a.vdb.database;
      await dbA.insert('diag_events', {
        'at': 1,
        'level': 'debug',
        'category': 'sync',
        'message': 'x',
      });
      final saltA = (await dbA.query('vault_meta')).single['value'];

      final r = await env.verifyAndSettle();
      expect(r.outcome, CloudVerificationOutcome.done);
      expect(r.reupload, 3);
      expect(r.noCopy, 0);
      expect(r.backupQueued, isTrue);
      expect(r.snapshotQueued, isTrue);
      expect(r.accountEmail, principal);
      expect(env.destructiveCalls, 0);

      final tag = await env.tagger.current();
      final p = env.cloud.account(principal);
      expect(
        p.names.toSet(),
        containsAll([
          'i1.vault',
          'i2.vault',
          'i3.vault',
          'i1.thumb',
          'i2.thumb',
          'i3.thumb',
          'recovery_backup.json',
          'vault_db.snapshot',
        ]),
      );
      for (final id in ['i1', 'i2', 'i3']) {
        final item = (await env.a.items.getItem(id))!;
        expect(item.syncStatus, SyncStatus.enNube, reason: id);
        expect(item.driveFileId, p.byName('$id.vault')!.id);
        expect(item.cloudAccountTag, tag);
        expect(item.thumbAccountTag, tag);
      }
      expect(await env.a.prefs.getRecoveryUploadedTag(), tag);
      expect(await env.a.prefs.getSnapshotUploadedTag(), tag);
      expect(await env.verifier.needsVerification(), isFalse);

      // Restaurar en un teléfono limpio con la principal.
      final b = PhoneB();
      await b.setUp(p, expectedPassword: env.a.passwordA);
      addTearDown(b.tearDown);
      expect(await b.service.probe(), RestoreProbeResult.found);
      expect(await b.service.verifyCode(env.a.recoveryCode), isTrue);
      final res = await b.service.restore(newPin: '654321');
      expect(res.items, 3);
      expect(res.lostItems, 0);
      final vdb = b.openDb();
      addTearDown(vdb.close);
      final repo = VaultDataRepository(dbProvider: () => vdb.database);
      for (final id in ['i1', 'i2', 'i3']) {
        final i = (await repo.getItem(id))!;
        expect(i.syncStatus, SyncStatus.enNube);
        // D75: tras restaurar, sin comprobar hasta el primer desbloqueo.
        expect(i.cloudAccountTag, isNull);
      }
      final dbB = await vdb.database;
      expect(await dbB.query('diag_events'), isEmpty);
      // La sal viaja: con la misma cuenta, el mismo tag.
      expect((await dbB.query('vault_meta')).single['value'], saltA);
    });

    test('tras actualizar a v11 (tags NULL) con todo presente: solo fija los '
        'tags, no sube nada', () async {
      await env.seed();
      await nullTags();
      expect(await env.verifier.needsVerification(), isTrue);
      final acc = env.cloud.account(pruebas);
      final before = acc.uploadedNames.length;
      final r = await env.verifier.verify();
      await env.idle();
      expect(r.outcome, CloudVerificationOutcome.done);
      expect(r.checked, 3);
      expect(r.reupload, 0);
      expect(r.backupQueued, isFalse);
      // Solo el índice (con los tags nuevos); ningún archivo ni respaldo.
      expect(acc.uploadedNames.skip(before).toSet(), {CloudNames.dbSnapshot});
      final tag = await env.tagger.current();
      for (final id in ['i1', 'i2', 'i3']) {
        final i = (await env.a.items.getItem(id))!;
        expect(i.cloudAccountTag, tag);
        expect(i.thumbAccountTag, tag);
      }
      expect(await env.verifier.needsVerification(), isFalse);
      expect(env.destructiveCalls, 0);
    });
  });

  group('casos por archivo', () {
    test('mismo id con MD5 distinto y copia local: se re-sube (reemplazo, '
        'sin borrar)', () async {
      await env.seed();
      final acc = env.cloud.account(pruebas);
      final id1 = acc.byName('i1.vault')!.id;
      acc.corruptContent(id1);
      final r = await env.verifyAndSettle();
      expect(r.reupload, 1);
      expect(r.checked, 2);
      final item = (await env.a.items.getItem('i1'))!;
      expect(item.syncStatus, SyncStatus.enNube);
      expect(item.driveFileId, id1); // mismo archivo, contenido reemplazado
      expect(
        acc.byName('i1.vault')!.md5Checksum,
        await md5OfFile(AppPaths.resolve(item.encryptedPath)),
      );
      expect(env.destructiveCalls, 0);
    });

    test('reparable por nombre: otro id con mismo nombre, tamaño y MD5 se '
        'adopta sin subir nada', () async {
      await env.seed();
      final acc = env.cloud.account(pruebas);
      final real = acc.byName('i2.vault')!;
      await env.a.items.setDriveFileId('i2', 'id-que-no-existe');
      final before = acc.uploadedNames.length;
      final r = await env.verifier.verify();
      await env.idle();
      expect(r.repaired, 1);
      expect(r.reupload, 0);
      expect(
        acc.uploadedNames.skip(before).where((n) => n.startsWith('i')),
        isEmpty,
      );
      final item = (await env.a.items.getItem('i2'))!;
      expect(item.driveFileId, real.id);
      expect(item.cloudAccountTag, await env.tagger.current());
    });

    test('nombre correcto pero MD5 distinto: NO se adopta; se re-sube', () async {
      await env.seed();
      final acc = env.cloud.account(pruebas);
      final real = acc.byName('i3.vault')!;
      acc.corruptContent(real.id);
      await env.a.items.setDriveFileId('i3', 'id-que-no-existe');
      final r = await env.verifyAndSettle();
      expect(r.repaired, 0);
      expect(r.reupload, 1);
      final item = (await env.a.items.getItem('i3'))!;
      expect(item.syncStatus, SyncStatus.enNube);
      expect(
        acc.byName('i3.vault')!.md5Checksum,
        await md5OfFile(AppPaths.resolve(item.encryptedPath)),
      );
      expect(env.destructiveCalls, 0);
    });

    test('sin copia en ningún sitio: error, la fila NO se borra', () async {
      await env.seed();
      AppPaths.resolve(AppPaths.vaultRelativePath('i1')).deleteSync();
      final acc = env.cloud.account(pruebas);
      acc.remove(acc.byName('i1.vault')!.id);
      final r = await env.verifyAndSettle();
      expect(r.noCopy, 1);
      expect(r.summary, contains('1 sin copia en ninguna parte'));
      final item = await env.a.items.getItem('i1');
      expect(item, isNotNull);
      expect(item!.syncStatus, SyncStatus.error);
      expect(item.cloudAccountTag, isNull);
      expect((await env.a.items.getAllItems()).length, 3);
      // No vuelve a pedirse para siempre.
      expect(await env.verifier.needsVerification(), isFalse);
    });

    test('miniaturas: falta en la nube con copia local -> se re-sube; sin '
        'copia en ningún sitio -> se olvida para regenerarla', () async {
      await env.seed();
      final acc = env.cloud.account(pruebas);
      acc.remove(acc.byName('i1.thumb')!.id);
      acc.remove(acc.byName('i2.thumb')!.id);
      AppPaths.resolve(AppPaths.thumbRelativePath('i2')).deleteSync();
      final r = await env.verifyAndSettle();
      expect(r.thumbsReupload, 2);
      final i1 = (await env.a.items.getItem('i1'))!;
      expect(i1.thumbDriveFileId, acc.byName('i1.thumb')!.id);
      expect(i1.thumbAccountTag, await env.tagger.current());
      final i2 = (await env.a.items.getItem('i2'))!;
      expect(i2.thumbPath, isNull);
      expect(i2.thumbDriveFileId, isNull);
      expect(
        (await env.a.items.getItemsMissingThumb()).map((i) => i.id),
        contains('i2'),
      );
      expect(env.destructiveCalls, 0);
    });

    test('la Papelera también se verifica (y se re-sube)', () async {
      await env.seed();
      final db = await env.a.vdb.database;
      await db.update('vault_items', {
        'deletedAt': 1,
        'trashRoot': 'i1',
      }, where: "id = 'i1'");
      await env.switchTo(principal);
      final r = await env.verifyAndSettle();
      expect(r.reupload, 3);
      expect(env.cloud.account(principal).byName('i1.vault'), isNotNull);
    });
  });

  group('respaldo e índice', () {
    test('respaldo y snapshot ausentes: se suben', () async {
      await env.seed();
      final acc = env.cloud.account(pruebas);
      acc.remove(acc.byName('recovery_backup.json')!.id);
      acc.remove(acc.byName('vault_db.snapshot')!.id);
      final r = await env.verifyAndSettle();
      expect(r.backupQueued, isTrue);
      expect(r.snapshotQueued, isTrue);
      expect(acc.byName('recovery_backup.json'), isNotNull);
      expect(acc.byName('vault_db.snapshot'), isNotNull);
      expect(
        utf8.decode(acc.bytesOf('recovery_backup.json')!),
        await env.a.auth.exportRecoveryBackup(),
      );
    });

    test('respaldo de OTRA bóveda con el mismo nombre: se detiene sin subir '
        'ni cambiar nada, y la sincronización no lo reemplaza', () async {
      await env.seed();
      await env.switchTo(principal);
      final p = env.cloud.account(principal);
      final foreign = Uint8List.fromList(
        utf8.encode('{"type":"recovery","otra":"boveda"}'),
      );
      await p.uploadBytes(bytes: foreign, name: 'recovery_backup.json');
      final rowsBefore = [
        for (final i in await env.a.items.getAllItems())
          (i.id, i.syncStatus, i.driveFileId, i.cloudAccountTag),
      ];
      final uploads = p.uploadedNames.length;
      final r = await env.verifyAndSettle();
      expect(r.outcome, CloudVerificationOutcome.blockedOtherVault);
      expect(r.summary, contains('OTRA bóveda'));
      final rowsAfter = [
        for (final i in await env.a.items.getAllItems())
          (i.id, i.syncStatus, i.driveFileId, i.cloudAccountTag),
      ];
      expect(rowsAfter, rowsBefore);
      expect(p.bytesOf('recovery_backup.json'), foreign);
      // Ni el respaldo ni nada de la verificación se subió a esa cuenta.
      expect(
        p.uploadedNames.skip(uploads).where((n) => n.startsWith('recovery')),
        isEmpty,
      );
      expect(env.destructiveCalls, 0);
    });
  });

  group('precondiciones', () {
    test('sin sesión: no toca nada', () async {
      await env.seed();
      await nullTags();
      await env.cloud.signOut();
      final r = await env.verifier.verify();
      expect(r.outcome, CloudVerificationOutcome.noSession);
      expect(
        (await env.a.items.getAllItems()).every(
          (i) => i.cloudAccountTag == null,
        ),
        isTrue,
      );
      expect(env.sync.pausedForVerification, isFalse);
    });

    test('con migración, rotación, bloqueada o sin red: no corre', () async {
      await env.seed();
      await nullTags();
      env.migrationActive = true;
      expect(
        (await env.verifier.verify()).outcome,
        CloudVerificationOutcome.migrationActive,
      );
      env.migrationActive = false;
      env.rotationActive = true;
      expect(
        (await env.verifier.verify()).outcome,
        CloudVerificationOutcome.rotationActive,
      );
      env.rotationActive = false;
      env.ticket = () => null; // la adicional abierta o bloqueada
      expect(
        (await env.verifier.verify()).outcome,
        CloudVerificationOutcome.locked,
      );
      env.ticket = null;
      env.a.net.kind = NetworkKind.none;
      expect(
        (await env.verifier.verify()).outcome,
        CloudVerificationOutcome.offline,
      );
      env.a.net.kind = NetworkKind.wifi;
      await env.idle();
      expect(
        (await env.a.items.getAllItems()).every(
          (i) => i.cloudAccountTag == null,
        ),
        isTrue,
      );
      expect(env.sync.pausedForVerification, isFalse);
    });

    test('la pausa se pone al LANZARLA (antes del primer await) y la '
        'sincronización normal no corre mientras dura', () async {
      await env.seed();
      await nullTags();
      final future = env.verifier.verify();
      expect(env.sync.pausedForVerification, isTrue);
      final before = env.cloud.account(pruebas).uploadCalls;
      await env.sync.run(manual: true); // sin force: no hace nada
      expect(env.cloud.account(pruebas).uploadCalls, before);
      await future;
      expect(env.sync.pausedForVerification, isFalse);
    });

    test('bloqueo a mitad (tras el listado): para sin escribir nada', () async {
      await env.seed();
      await nullTags();
      env.cloud.account(pruebas).failure = (op) {
        if (op == 'list') env.a.auth.lock();
        return null;
      };
      final r = await env.verifier.verify();
      expect(r.outcome, CloudVerificationOutcome.locked);
      env.cloud.account(pruebas).failure = null;
      expect(await env.a.auth.unlockWithPin('123456'), isTrue);
      expect(
        (await env.a.items.getAllItems()).every(
          (i) => i.cloudAccountTag == null,
        ),
        isTrue,
      );
      expect(env.sync.pausedForVerification, isFalse);
    });
  });

  group('guardas ligadas a los tags', () {
    test('la caché no purga con tags nulos ni de otra cuenta; sí tras '
        'verificar', () async {
      await env.seed();
      await nullTags();
      expect(await env.cache.enforce(maxBytes: 0), isEmpty);
      expect((await env.cache.stats()).unverifiedCount, 3);
      // Tag de otra cuenta.
      final otherTag = await env.tagOf(principal);
      final db = await env.a.vdb.database;
      await db.update('vault_items', {'cloudAccountTag': otherTag});
      expect(await env.cache.enforce(maxBytes: 0), isEmpty);
      // Sin sesión: nada.
      await env.cloud.signOut();
      expect(await env.cache.enforce(maxBytes: 0), isEmpty);
      await env.switchTo(pruebas);
      await env.verifier.verify();
      await env.idle();
      expect(
        (await env.cache.enforce(maxBytes: 0)).toSet(),
        {'i1', 'i2', 'i3'},
      );
      // Purgar no borra nada en la nube.
      expect(env.destructiveCalls, 0);
    });

    test('borrar originales (cloudVerifier) exige el tag de la cuenta '
        'actual', () async {
      await env.seed();
      final i1 = (await env.a.items.getItem('i1'))!;
      expect(await env.sync.cloudVerifier(i1), isTrue);
      await nullTags();
      expect(await env.sync.cloudVerifier(i1), isFalse);
      await env.verifier.verify();
      await env.idle();
      expect(await env.sync.cloudVerifier(i1), isTrue);
      await env.switchTo(principal); // otra cuenta: el id no es de ella
      expect(await env.sync.cloudVerifier(i1), isFalse);
    });

    test('el snapshot al bloquear no se sube con un cambio de cuenta, con '
        'una verificación ni a una cuenta distinta de la última', () async {
      await env.seed();
      await env.a.prefs.markDirty(env.a.now);
      final acc = env.cloud.account(pruebas);
      final n0 = acc.uploadCalls;
      env.sync.pausedForMigration = true;
      await env.sync.flushSnapshotBeforeLock();
      env.sync.pausedForMigration = false;
      env.sync.pausedForVerification = true;
      await env.sync.flushSnapshotBeforeLock();
      env.sync.pausedForVerification = false;
      expect(acc.uploadCalls, n0);
      // Otra cuenta (el último snapshot fue a «pruebas»).
      await env.switchTo(principal);
      final p = env.cloud.account(principal);
      await env.sync.flushSnapshotBeforeLock();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(p.byName(CloudNames.dbSnapshot), isNull);
      // En la misma cuenta sí (comportamiento de siempre).
      await env.switchTo(pruebas);
      await env.sync.flushSnapshotBeforeLock();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(acc.uploadCalls, greaterThan(n0));
    });

    test('si la cuenta cambia durante una subida, no se registra (y se '
        'repite en la cuenta nueva)', () async {
      await env.a.addItem('i1', 'Uno.jpg', realThumb: true, plainSize: 400000);
      final acc = env.cloud.account(pruebas);
      acc.chunkDelay = const Duration(milliseconds: 5);
      final run = env.sync.run(manual: true);
      // A mitad de la primera subida, la sesión pasa a la principal.
      for (var i = 0; i < 200 && acc.uploadCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await env.switchTo(principal);
      await run;
      acc.chunkDelay = Duration.zero;
      final item = (await env.a.items.getItem('i1'))!;
      expect(item.cloudAccountTag, isNot(await env.tagOf(pruebas)));
      await env.settle();
      final after = (await env.a.items.getItem('i1'))!;
      expect(after.syncStatus, SyncStatus.enNube);
      expect(after.cloudAccountTag, await env.tagger.current());
      expect(
        after.driveFileId,
        env.cloud.account(principal).byName('i1.vault')!.id,
      );
    });

    test('el respaldo de llaves se vuelve a subir al cambiar de cuenta '
        'aunque nadie llame a signOut', () async {
      await env.seed();
      await env.switchTo(principal);
      await env.settle();
      expect(
        env.cloud.account(principal).byName('recovery_backup.json'),
        isNotNull,
      );
    });
  });

  test('el diagnóstico solo lleva conteos (sin correos, ids ni tags)', () async {
    DiagnosticsBuffer.instance.clear();
    await env.seed();
    await env.switchTo(principal);
    final tag = (await env.tagger.current())!;
    await env.verifyAndSettle();
    final text = DiagnosticsBuffer.instance.export();
    expect(text, contains('Verificación: done'));
    expect(text.contains('principal'), isFalse);
    expect(text.contains('pruebas'), isFalse);
    expect(text.contains('@'), isFalse);
    expect(text.contains(tag), isFalse);
    expect(text.contains('i1.vault'), isFalse);
  });
}
