// Fase 1, pendientes (D72-D74): contador de avance a partir de lo ya
// persistido, borrado de la cuenta de Google anterior (M7) y limpieza manual
// de generaciones abandonadas (M11).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_names.dart';
import 'package:vault/data/rotation/key_rotation_service.dart';
import 'package:vault/data/rotation/rotation_repository.dart';

import '../support/multi_account_cloud.dart';
import '../support/rotation_env.dart';

const _current = 'santy@example.com';
const _old = 'vieja@example.com';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('Contador de avance (D72)', () {
    late RotationPhone phone;

    setUp(() async {
      phone = RotationPhone();
      await phone.create();
      await phone.seedVault();
    });
    tearDown(() => phone.dispose());

    test('sin rotación no hay avance', () async {
      await phone.service.refreshProgress();
      expect(phone.service.progress.value, isNull);
      expect(await phone.repo.progress(), isNull);
    });

    test('re-cifrado: cuenta los items ya en la generación nueva; subida: '
        'los ya en la nube; al terminar se apaga', () async {
      final b = await phone.startAndConfirm();
      final seen = <RotationProgress?>[];
      RotationProgress? atUpload;
      phone.crash = (p) {
        if (p == RotationCrashPoint.itemDone) {
          seen.add(phone.service.progress.value);
        }
        if (p == RotationCrashPoint.uploadingVerified) {
          atUpload = phone.service.progress.value;
        }
      };
      await phone.service.resume();
      expect(seen, isNotEmpty);
      final dones = [for (final p in seen) p!.done];
      expect(dones, [...dones]..sort(), reason: 'nunca retrocede');
      expect(seen.every((p) => p!.total == 4), isTrue);
      expect(dones.last, lessThanOrEqualTo(4));
      expect(atUpload, const RotationProgress(done: 4, uploaded: 4, total: 4));
      expect(await phone.record(), isNull);
      expect(phone.service.progress.value, isNull);
      expect(await phone.canRestoreWith(b), isTrue);
    });

    test('lo muestra de la BD aunque la app se reinicie a mitad (sin estado '
        'nuevo)', () async {
      await phone.startAndConfirm();
      var n = 0;
      phone.crash = (p) {
        if (p == RotationCrashPoint.itemDone && ++n == 2) {
          throw SimulatedCrash(p);
        }
      };
      await expectLater(
        phone.service.resume(),
        throwsA(isA<SimulatedCrash>()),
      );
      await phone.restart();
      await phone.service.refreshProgress();
      final p = phone.service.progress.value!;
      expect(p.total, 4);
      expect(p.done, 2);
      expect(p.uploaded, lessThanOrEqualTo(p.done));
    });

    test('items quitados o altas durante la rotación ajustan el total', () async {
      await phone.startAndConfirm();
      var fired = false;
      phone.crash = (p) {
        if (p == RotationCrashPoint.beforeReencrypting && !fired) {
          fired = true;
          throw SimulatedCrash(p);
        }
      };
      await expectLater(
        phone.service.resume(),
        throwsA(isA<SimulatedCrash>()),
      );
      final db = await phone.vdb.database;
      await db.delete('item_tags', where: 'itemId = ?', whereArgs: ['i3']);
      await db.delete('vault_items', where: 'id = ?', whereArgs: ['i3']);
      final p = (await phone.repo.progress())!;
      expect(p.total, 3);
      expect(p.done, 0);
    });
  });

  group('Cuenta anterior (M7, D72)', () {
    late MultiAccountCloud cloud;
    late RotationPhone phone;

    setUp(() async {
      cloud = MultiAccountCloud(_current);
      phone = RotationPhone(cloud: cloud);
      await phone.create();
      await phone.seedVault();
      await phone.prefs.setOldAccountKept(_old);
      final old = cloud.account(_old);
      await old.uploadBytes(bytes: _b('x'), name: CloudNames.recoveryBackup);
      await old.uploadBytes(bytes: _b('x'), name: CloudNames.dbSnapshot);
      await old.uploadBytes(bytes: _b('x'), name: 'i1.vault');
      await old.uploadBytes(bytes: _b('x'), name: 'ajeno.txt');
    });
    tearDown(() => phone.dispose());

    Set<String> namesOf(String email) => cloud.account(email).names.toSet();

    test('borra solo lo de Vault de la cuenta anterior, vuelve a la actual y '
        'no toca la actual', () async {
      final before = namesOf(_current);
      cloud.signInQueue.addAll([_old, _current]);
      expect(await phone.service.deleteOldAccountData(), 3);
      expect(namesOf(_old), {'ajeno.txt'});
      expect(namesOf(_current), before);
      expect(cloud.currentAccountEmail, _current);
      expect(await phone.prefs.getOldAccountKept(), isNull);
      expect(phone.sync.pausedForMigration, isFalse);
      // Ya no hay nada que ofrecer.
      expect((await phone.service.plan()).oldAccountKept, isNull);
    });

    test('si eliges otra cuenta (o la actual) no borra NADA y vuelve a la '
        'actual', () async {
      final before = namesOf(_current);
      cloud.signInQueue.addAll(['otra@example.com', _current]);
      await expectLater(
        phone.service.deleteOldAccountData(),
        throwsA(isA<RotationException>()),
      );
      expect(namesOf('otra@example.com'), isEmpty);
      expect(namesOf(_old).length, 4);
      expect(namesOf(_current), before);
      expect(cloud.currentAccountEmail, _current);
      expect(await phone.prefs.getOldAccountKept(), _old);

      cloud.signInQueue.add(_current);
      await expectLater(
        phone.service.deleteOldAccountData(),
        throwsA(isA<RotationException>()),
      );
      expect(namesOf(_current), before);
      expect(namesOf(_old).length, 4);
      expect(phone.sync.pausedForMigration, isFalse);
    });

    test('si la cuenta anterior es la actual: se niega (nunca borra la '
        'actual) y el plan no lo ofrece', () async {
      await phone.prefs.setOldAccountKept(_current);
      final before = namesOf(_current);
      await expectLater(
        phone.service.deleteOldAccountData(),
        throwsA(isA<RotationException>()),
      );
      expect(cloud.signOutCalls, 0);
      expect(namesOf(_current), before);
      expect((await phone.service.plan()).oldAccountKept, isNull);
    });

    test('sin cuenta anterior guardada: se niega', () async {
      await phone.prefs.clearOldAccountKept();
      await expectLater(
        phone.service.deleteOldAccountData(),
        throwsA(isA<RotationException>()),
      );
      expect(cloud.signOutCalls, 0);
    });

    test('nunca durante una rotación', () async {
      await phone.startAndConfirm();
      await expectLater(
        phone.service.deleteOldAccountData(),
        throwsA(isA<RotationException>()),
      );
      expect(cloud.signOutCalls, 0);
      expect(namesOf(_old).length, 4);
    });

    test('con la bóveda bloqueada: se niega', () async {
      phone.auth.lock();
      await expectLater(
        phone.service.deleteOldAccountData(),
        throwsA(isA<RotationException>()),
      );
      expect(cloud.signOutCalls, 0);
    });
  });

  group('Limpieza de generaciones abandonadas (M11, D73)', () {
    late RotationPhone phone;

    setUp(() async {
      phone = RotationPhone();
      await phone.create();
      await phone.seedVault();
    });
    tearDown(() => phone.dispose());

    Future<void> put(String name) =>
        phone.cloud.uploadBytes(bytes: _b('x'), name: name);

    test('gen vigente 1: borra lo de gen mayor SIN respaldo; deja la '
        'respaldada, la cuarentena, lo ajeno y lo vigente', () async {
      await put('i1.k3.vault');
      await put('i1.k3.thumb');
      await put(CloudNames.dbSnapshotFor(3));
      await put('i2.k4.vault'); // gen 4 CON respaldo: otra rama, se respeta
      await put(CloudNames.recoveryBackupFor(4));
      await put(CloudNames.quarantine('i3', 5));
      await put('ajeno.txt');
      final keep = phone.cloud.names.toSet()
        ..removeAll(['i1.k3.vault', 'i1.k3.thumb', 'vault_db.k3.snapshot']);

      final scan = await phone.service.scanLeftovers();
      expect(scan.cloudAbandoned, 3);
      expect(scan.cloudStale, 0);
      expect(scan.cloudBytes, 3);
      expect(scan.localFiles, 0);
      // La vista previa no borra nada.
      expect(phone.cloud.names, contains('i1.k3.vault'));

      final r = await phone.service.cleanLeftovers();
      expect(r.cloudAbandoned, 3);
      expect(phone.cloud.names.toSet(), keep);
      expect((await phone.service.scanLeftovers()).isEmpty, isTrue);
    });

    test('nunca mientras hay rotación (ni en la vista previa)', () async {
      await put('i1.k3.vault');
      await phone.startAndConfirm();
      await expectLater(
        phone.service.scanLeftovers(),
        throwsA(isA<RotationException>()),
      );
      await expectLater(
        phone.service.cleanLeftovers(),
        throwsA(isA<RotationException>()),
      );
      expect(phone.cloud.names, contains('i1.k3.vault'));
    });

    test('con la bóveda bloqueada o sin sesión de Google: se niega', () async {
      await put('i1.k3.vault');
      phone.cloud.email = null;
      await expectLater(
        phone.service.cleanLeftovers(),
        throwsA(isA<RotationException>()),
      );
      phone.cloud.email = 'test@example.com';
      phone.auth.lock();
      await expectLater(
        phone.service.cleanLeftovers(),
        throwsA(isA<RotationException>()),
      );
      expect(phone.cloud.names, contains('i1.k3.vault'));
    });

    test('tras rotar (gen 2): borra restos de la gen 1 en Drive y en el '
        'teléfono, con la guarda; el código nuevo sigue restaurando', () async {
      final b = await phone.startAndConfirm();
      await phone.service.resume();
      expect(await phone.record(), isNull);
      // Restos: en Drive (gen 1) y en el teléfono (gen 1 de un item gen 2).
      await put('i1.vault');
      await put(CloudNames.recoveryBackup);
      final stale = File(
        AppPaths.resolve(AppPaths.vaultRelativePath('i1')).path,
      )..writeAsBytesSync([1, 2, 3]);
      final currentLocal = AppPaths.resolve(
        AppPaths.vaultRelativePath('i1', gen: 2),
      );
      expect(currentLocal.existsSync(), isTrue);

      final scan = await phone.service.scanLeftovers();
      expect(scan.cloudStale, 2);
      expect(scan.localFiles, 1);

      final r = await phone.service.cleanLeftovers();
      expect(r.staleSkipped, isFalse);
      expect(r.cloudFiles, 2);
      expect(r.localFiles, 1);
      expect(stale.existsSync(), isFalse);
      expect(currentLocal.existsSync(), isTrue);
      expect(phone.cloud.byName('i1.vault'), isNull);
      expect(phone.cloud.byName(CloudNames.recoveryBackupFor(2)), isNotNull);
      await phone.expectAllItemsOpen();
      expect(await phone.canRestoreWith(b), isTrue);
    });

    test('guarda del barrido: si el conjunto vigente no está completo en '
        'Drive no borra lo de gen menor (sí lo abandonado)', () async {
      final b = await phone.startAndConfirm();
      await phone.service.resume();
      await put('i1.vault');
      await put('i1.k7.vault');
      final snap = phone.cloud.byName(CloudNames.dbSnapshotFor(2))!;
      await phone.cloud.delete(snap.id);

      final r = await phone.service.cleanLeftovers();
      expect(r.staleSkipped, isTrue);
      expect(r.cloudStale, 0);
      expect(r.cloudAbandoned, 1);
      expect(phone.cloud.byName('i1.vault'), isNotNull);
      expect(phone.cloud.byName('i1.k7.vault'), isNull);
      expect(b, isNotEmpty);
    });

    test('un archivo local sin fila de item no se toca', () async {
      final orphan = File(
        AppPaths.resolve(AppPaths.vaultRelativePath('huerfano', gen: 3)).path,
      )..writeAsBytesSync([9]);
      final scan = await phone.service.scanLeftovers();
      expect(scan.localFiles, 0);
      await phone.service.cleanLeftovers();
      expect(orphan.existsSync(), isTrue);
    });
  });
}
