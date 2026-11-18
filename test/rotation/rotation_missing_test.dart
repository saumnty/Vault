// Rotación de la DEK: archivos SIN NINGUNA copia ("Continuar sin ellos",
// D64). Un item cuya fila existe pero cuyo `.vault` no está ni en el
// teléfono ni en Drive (o solo queda una copia local que no abre) no debe
// atascar la rotación: el usuario ve cuáles son y elige quitarlos o
// reintentar. Con cortes simulados como el resto de pruebas de la rotación.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_names.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/rotation/key_rotation_service.dart';

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

  Future<RotationRecord?> record() => phone.record();

  /// Deja [id] sin ninguna copia: sin `.vault` local y sin copia en Drive.
  Future<void> loseEverywhere(String id) async {
    final i = (await phone.items.getItem(id))!;
    final f = AppPaths.resolve(i.encryptedPath);
    if (f.existsSync()) f.deleteSync();
    await phone.cloud.delete(i.driveFileId!);
  }

  /// La rotación está parada esperando decisión sobre archivos con problema.
  Future<void> expectBlockedOnProblems() async {
    final rec = (await record())!;
    expect(rec.phase, RotationPhase.blockedCorrupt);
    expect(rec.resumePhase, RotationPhase.reencrypting);
  }

  /// Estado final (gen [gen]): sin rastro de [gone] en ningún lado.
  Future<void> expectFinishedWithout(
    String codeB,
    Set<String> gone, {
    int gen = 2,
    Set<String> lost = const {},
  }) async {
    expect(await record(), isNull);
    final all = await phone.items.getAllItems();
    expect(all.map((i) => i.keyGen).toSet(), {gen});
    for (final id in gone) {
      expect(await phone.items.getItem(id), isNull, reason: id);
      for (final n in phone.cloud.names) {
        expect(n.contains(id), isFalse, reason: 'queda $n en Drive');
      }
      for (final dir in [AppPaths.vaultDir, AppPaths.thumbsDir]) {
        for (final f in dir.listSync().whereType<File>()) {
          expect(f.path.contains(id), isFalse, reason: 'queda ${f.path}');
        }
      }
    }
    final db = await phone.vdb.database;
    final tagged = {
      for (final r in await db.query('item_tags')) r['itemId'] as String,
    };
    expect(tagged.intersection(gone), isEmpty);
    expect(
      (await db.query('sync_queue')).where((r) => gone.contains(r['itemId'])),
      isEmpty,
    );
    expect(await phone.repo.load(), isNull);
    await phone.expectAllItemsOpen(lost: lost);
    expect(await phone.canRestoreWith(codeB, lost: lost), isTrue);
    expect(await phone.canRestoreWith(phone.codeA), isFalse);
  }

  test('sin ninguna copia: lista con su nombre, "Continuar sin ellos" lo '
      'quita de todo y la rotación termina', () async {
    await loseEverywhere('i1'); // en carpeta, con etiqueta y miniatura
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    await expectBlockedOnProblems();
    final probs = phone.service.problems.value!;
    expect(probs.missing.map((p) => (p.id, p.name)), [('i1', 'i1.jpg')]);
    expect(probs.damaged, isEmpty);
    // El nombre nunca va al registro (que alimenta el Diagnóstico).
    final rec = (await record())!;
    expect(rec.lastError, '1 archivo(s) sin ninguna copia');
    expect(rec.lastError, isNot(contains('i1')));
    // Hasta decidir, nada se tocó: A sigue restaurando el conjunto viejo.
    expect(await phone.items.getItem('i1'), isNotNull);
    expect(phone.cloud.byName('i1.thumb'), isNotNull);
    expect(await phone.canRestoreWith(phone.codeA, lost: {'i1'}), isTrue);

    expect(await phone.service.dropMissingItems(), 1);
    expect(await phone.items.getItem('i1'), isNull);
    expect((await record())!.phase, RotationPhase.reencrypting);
    expect(phone.service.problems.value, isNull);
    // La miniatura vieja de Drive NO se borra antes del corte.
    expect(phone.cloud.byName('i1.thumb'), isNotNull);

    await phone.service.resume();
    await expectFinishedWithout(b, {'i1'});
    await phone.expectNoOldKeyMaterial(oldKeys, phone.codeA);
  });

  test('"Reintentar": si la copia aparece, se re-cifra y se queda', () async {
    final i1 = (await phone.items.getItem('i1'))!;
    final local = AppPaths.resolve(i1.encryptedPath);
    final saved = local.readAsBytesSync();
    await loseEverywhere('i1');
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    await expectBlockedOnProblems();
    local.writeAsBytesSync(saved); // la copia vuelve (p. ej. otra fuente)
    await phone.service.retry();
    expect(await record(), isNull);
    expect((await phone.items.getItem('i1'))!.keyGen, 2);
    await phone.expectAllItemsOpen();
    expect(await phone.canRestoreWith(b), isTrue);
  });

  test('dañado (con copia) y sin copia a la vez: cada botón resuelve lo '
      'suyo', () async {
    await loseEverywhere('i1');
    final i3 = (await phone.items.getItem('i3'))!;
    final f = AppPaths.resolve(i3.encryptedPath);
    f.writeAsBytesSync(f.readAsBytesSync()..[40] ^= 1);
    phone.cloud.corruptContent(i3.driveFileId!);
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    await expectBlockedOnProblems();
    var probs = phone.service.problems.value!;
    expect(probs.missing.map((p) => p.id), ['i1']);
    expect(probs.damaged.map((p) => p.id), ['i3']);
    expect(
      (await record())!.lastError,
      '1 archivo(s) sin ninguna copia y 1 archivo(s) dañado(s)',
    );

    // "Continuar sin ellos" no toca el dañado.
    expect(await phone.service.dropMissingItems(), 1);
    expect(await phone.items.getItem('i3'), isNotNull);
    await phone.service.resume();
    await expectBlockedOnProblems();
    probs = phone.service.problems.value!;
    expect(probs.missing, isEmpty);
    expect(probs.damaged.map((p) => p.id), ['i3']);

    // "Omitir los dañados" no quita nada: cuarentena (M6).
    expect(await phone.service.skipCorruptItems(), 1);
    await phone.service.resume();
    await expectFinishedWithout(b, {'i1'}, lost: {'i3'});
    expect(phone.cloud.byName(CloudNames.quarantine('i3', 1)), isNotNull);
  });

  test('copia local que no abre y nada en Drive: "sin ninguna copia" y se '
      'borra también el archivo local', () async {
    final i4 = (await phone.items.getItem('i4'))!; // en la Papelera
    final f = AppPaths.resolve(i4.encryptedPath);
    f.writeAsBytesSync(f.readAsBytesSync()..[40] ^= 1);
    await phone.cloud.delete(i4.driveFileId!);
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    await expectBlockedOnProblems();
    expect(phone.service.problems.value!.missing.map((p) => p.id), ['i4']);
    expect(await phone.service.dropMissingItems(), 1);
    expect(f.existsSync(), isFalse);
    await phone.service.resume();
    await expectFinishedWithout(b, {'i4'});
  });

  test('sin driveFileId pero su .vault SÍ está en Drive: se trata como '
      'dañado (cuarentena), nunca se quita', () async {
    final i1 = (await phone.items.getItem('i1'))!;
    AppPaths.resolve(i1.encryptedPath).deleteSync();
    final db = await phone.vdb.database;
    await db.update(
      'vault_items',
      {'driveFileId': null},
      where: 'id = ?',
      whereArgs: ['i1'],
    );
    await phone.startAndConfirm();
    await phone.service.resume();
    await expectBlockedOnProblems();
    final probs = phone.service.problems.value!;
    expect(probs.missing, isEmpty);
    expect(probs.damaged.map((p) => p.id), ['i1']);
    expect(await phone.service.dropMissingItems(), 0);
    expect(await phone.items.getItem('i1'), isNotNull);
  });

  for (final drop in [0, 1]) {
    test(
      'corte tras quitar el primero de dos${drop > 0 ? ' (+escritura '
                'perdida)' : ''}: al reabrir se recalcula la lista y termina',
      () async {
        await loseEverywhere('i1');
        await loseEverywhere('i3');
        final b = await phone.startAndConfirm();
        await phone.service.resume();
        await expectBlockedOnProblems();
        expect(phone.service.problems.value!.missing, hasLength(2));
        var fired = false;
        phone.crash = (p) {
          if (p == RotationCrashPoint.missingDropped && !fired) {
            fired = true;
            throw SimulatedCrash(p);
          }
        };
        await expectLater(
          phone.service.dropMissingItems(),
          throwsA(isA<SimulatedCrash>()),
        );
        phone.crash = null;
        phone.store.dropLast(drop);
        await phone.restart();
        if (drop == 0) {
          await expectBlockedOnProblems();
          // Tras reiniciar la lista no está en memoria: se recalcula.
          expect(phone.service.problems.value, isNull);
        } else {
          // Se perdió la escritura del bloqueo: el registro dice
          // `reencrypting`; al reanudar se vuelve a detectar y a parar.
          expect((await record())!.phase, RotationPhase.reencrypting);
          await phone.service.resume();
          await expectBlockedOnProblems();
        }
        final probs = await phone.service.loadProblems();
        expect(probs.missing, hasLength(1));
        expect(probs.damaged, isEmpty);
        expect(await phone.service.dropMissingItems(), 1);
        await phone.service.resume();
        await expectFinishedWithout(b, {'i1', 'i3'});
      },
    );
  }

  test('un perdido de una rotación anterior no atasca la siguiente: la '
      'hoja previa lo cuenta y se puede continuar sin él', () async {
    final i3 = (await phone.items.getItem('i3'))!;
    final f = AppPaths.resolve(i3.encryptedPath);
    f.writeAsBytesSync(f.readAsBytesSync()..[40] ^= 1);
    phone.cloud.corruptContent(i3.driveFileId!);
    await phone.startAndConfirm();
    await phone.service.resume();
    expect(await phone.service.skipCorruptItems(), 1);
    await phone.service.resume();
    expect(await record(), isNull);
    final lost = (await phone.items.getItem('i3'))!;
    expect(lost.syncStatus, SyncStatus.error);
    await phone.sync.run(manual: true);

    // Antes: el item en `error` sin copia frenaba `confirmed` para siempre.
    final plan = await phone.service.plan();
    expect(plan.noCopyItems, 1);
    expect(plan.pendingUploads, 0);
    final b3 = await phone.startAndConfirm();
    await phone.service.resume();
    await expectBlockedOnProblems();
    expect(phone.service.problems.value!.missing.map((p) => p.id), ['i3']);
    expect(await phone.service.dropMissingItems(), 1);
    await phone.service.resume();
    expect(await record(), isNull);
    expect(await phone.items.getItem('i3'), isNull);
    expect(await phone.auth.currentKeyGen(), 3);
    await phone.expectAllItemsOpen();
    expect(await phone.canRestoreWith(b3), isTrue);
  });

  test('sin bloqueo en reencrypting, "Continuar sin ellos" no hace nada', () {
    expect(phone.service.dropMissingItems(), throwsA(isA<RotationException>()));
  });
}
