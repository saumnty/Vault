// Rotación de la DEK, paso 10a (§10.2/§10.3): máquina de estados de
// `prepared` hasta el CORTE, con cortes simulados en cada transición.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/data/cloud/cloud_names.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/rotation/item_reencryptor.dart';
import 'package:vault/data/rotation/key_rotation_service.dart';
import 'package:vault/data/sync/network_monitor.dart';

import '../support/rotation_env.dart';

void main() {
  late RotationPhone phone;

  setUp(() async {
    phone = RotationPhone()..stopAtCut = true;
    await phone.create();
    await phone.seedVault();
  });
  tearDown(() => phone.dispose());

  Future<RotationPhase?> phase() async => (await phone.record())?.phase;

  /// Comprobaciones al llegar al corte.
  Future<void> expectAtCut(String codeB) async {
    expect(await phase(), RotationPhase.deletingOldCloud);
    final all = await phone.items.getAllItems();
    expect(all.map((i) => i.keyGen).toSet(), {2});
    for (final i in all) {
      expect(phone.cloud.byName(CloudNames.file(i.id, gen: 2)), isNotNull);
    }
    final names = phone.cloud.names.toSet();
    expect(
      names,
      containsAll([
        CloudNames.recoveryBackup,
        CloudNames.dbSnapshot,
        CloudNames.bridgeBackup(1),
        CloudNames.dbSnapshotFor(2),
        CloudNames.recoveryBackupFor(2),
        'i1.vault',
        'i2.vault',
      ]),
    );
    expect(await phone.auth.currentKeyGen(), 2);
    expect(phone.session.currentGen, 2);
    expect(phone.session.keyring!.isDual, isFalse);
    await phone.expectAllItemsOpen();
    // En el corte valen los dos códigos (§8).
    expect(await phone.canRestoreWith(phone.codeA), isTrue);
    expect(await phone.canRestoreWith(codeB), isTrue);
    // La BD ya no abre con la llave vieja: la copia de seguridad se borró.
    expect(
      Directory(
        AppPaths.dbDir.path,
      ).listSync().where((e) => RegExp(r'\.k\d+(\.tmp)?$').hasMatch(e.path)),
      isEmpty,
    );
  }

  test('camino feliz hasta el corte', () async {
    final b = await phone.startAndConfirm();
    expect(await phone.canRestoreWith(b), isFalse, reason: 'sin puente aún');
    await phone.service.resume();
    await expectAtCut(b);
    // Tras reiniciar, el PIN da solo la llave nueva.
    await phone.restart();
    expect(phone.session.currentGen, 2);
    expect(phone.session.keyring!.isDual, isFalse);
    await phone.expectAllItemsOpen();
  });

  // Tabla §8: ¿B restaura ya en este punto? (A siempre, hasta el corte.)
  const bWorks = {
    RotationCrashPoint.confirmedChecked: false,
    RotationCrashPoint.freezingStateCreated: false,
    RotationCrashPoint.freezingSnapshotUploaded: false,
    RotationCrashPoint.freezingSnapshotRecorded: false,
    RotationCrashPoint.freezingBridgeUploaded: true,
    RotationCrashPoint.freezingOldFilesListed: true,
    RotationCrashPoint.beforeReencrypting: true,
    RotationCrashPoint.itemDone: true,
    RotationCrashPoint.uploadingVerified: true,
    RotationCrashPoint.rekeyDone: true,
    RotationCrashPoint.switchDone: true,
    RotationCrashPoint.snapshotUploaded: true,
    RotationCrashPoint.backupUploaded: true,
  };

  // Los puntos de después del corte están en rotation_after_cut_test.dart.
  for (final point in RotationCrashPoint.values.where(
    (p) => p.index <= RotationCrashPoint.backupUploaded.index,
  )) {
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
          // En el instante del corte, según la tabla del §8.
          expect(await phone.canRestoreWith(phone.codeA), isTrue);
          expect(await phone.canRestoreWith(b), bWorks[point]);
          phone.store.dropLast(drop);
          phone.crash = null;
          await phone.restart();
          // Si se perdió la confirmación (vuelve a `prepared`), el usuario
          // confirma otra vez el MISMO código (nada se subió aún con él).
          if (await phase() == RotationPhase.prepared) {
            expect(await phone.service.confirm(b), isTrue);
          }
          await phone.service.resume();
          await expectAtCut(b);
        },
      );
    }
  }

  for (final step in ReencryptStep.values) {
    test('corte dentro del re-cifrado de un item (${step.name})', () async {
      final b = await phone.startAndConfirm();
      var fired = false;
      phone.itemCrash = (s) {
        if (s == step && !fired) {
          fired = true;
          throw SimulatedCrash(s);
        }
      };
      await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
      expect(await phone.canRestoreWith(phone.codeA), isTrue);
      expect(await phone.canRestoreWith(b), isTrue);
      phone.itemCrash = null;
      await phone.restart();
      await phone.service.resume();
      await expectAtCut(b);
    });
  }

  test('restos de un re-cifrado cortado se barren al reanudar', () async {
    final b = await phone.startAndConfirm();
    phone.crash = (p) {
      if (p == RotationCrashPoint.beforeReencrypting) {
        throw const SimulatedCrash('x');
      }
    };
    await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
    // Lo que dejaría una app muerta a mitad (todo cifrado).
    final stray = AppPaths.resolve(AppPaths.vaultRelativePath('i1', gen: 2));
    stray.writeAsBytesSync([1, 2, 3]);
    final part = File('${stray.path}.part')..writeAsBytesSync([4]);
    final work = Directory('${AppPaths.cacheDir.path}/rotation')
      ..createSync(recursive: true);
    final src = File('${work.path}/i2.src.part')..writeAsBytesSync([5]);
    phone.crash = null;
    await phone.restart();
    await phone.service.resume();
    expect(part.existsSync(), isFalse);
    expect(src.existsSync(), isFalse);
    await expectAtCut(b);
  });

  group('A4: precondiciones', () {
    test('con un archivo sin subir no se congela', () async {
      await phone.addItem('nuevo');
      phone.net.kind = NetworkKind.none; // no puede subirlo
      await phone.startAndConfirm();
      await phone.service.resume();
      expect(await phase(), RotationPhase.confirmed);
      expect(phone.service.status.value.message, isNotNull);
      // Con red, se sube y sigue.
      phone.net.kind = NetworkKind.wifi;
      await phone.service.resume();
      expect(await phase(), RotationPhase.deletingOldCloud);
    });

    test('solo Wi-Fi con datos móviles: espera', () async {
      phone.net.kind = NetworkKind.mobile;
      await phone.startAndConfirm();
      await phone.service.resume();
      expect(await phase(), RotationPhase.confirmed);
    });

    test('otra cuenta de Google: blockedSignIn', () async {
      await phone.startAndConfirm();
      phone.cloud.email = 'otra@example.com';
      await phone.service.resume();
      expect(await phase(), RotationPhase.blockedSignIn);
    });

    test('sin sesión de Google no empieza', () async {
      phone.cloud.email = null;
      await expectLater(
        phone.service.start(rotationPin),
        throwsA(isA<RotationException>()),
      );
    });

    test('con un cambio de cuenta en curso no empieza', () async {
      final s = KeyRotationService(
        auth: phone.auth,
        session: phone.session,
        db: phone.vdb,
        items: phone.items,
        queue: phone.queue,
        sync: phone.sync,
        cloud: phone.cloud,
        network: phone.net,
        prefs: phone.prefs,
        repo: phone.repo,
        reencryptor: phone.reencryptor,
        migrationActive: () async => true,
      );
      await expectLater(
        s.start(rotationPin),
        throwsA(isA<RotationException>()),
      );
    });
  });

  group('cancelar (hasta freezing)', () {
    for (final at in [
      null,
      RotationCrashPoint.confirmedChecked,
      RotationCrashPoint.freezingBridgeUploaded,
      RotationCrashPoint.freezingOldFilesListed,
    ]) {
      test('cancelar ${at?.name ?? 'en confirmed'}: no queda nada', () async {
        final b = await phone.startAndConfirm();
        if (at != null) {
          phone.crash = (p) {
            if (p == at) throw SimulatedCrash(p);
          };
          await expectLater(
            phone.service.resume(),
            throwsA(isA<SimulatedCrash>()),
          );
          phone.crash = null;
        }
        await phone.service.cancel();
        expect(await phone.record(), isNull);
        expect(phone.cloud.byName(CloudNames.bridgeBackup(1)), isNull);
        expect(await phone.repo.load(), isNull);
        expect(await phone.repo.oldFiles(), isEmpty);
        final db = await phone.vdb.database;
        expect(
          await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'trigger'",
          ),
          isEmpty,
        );
        expect(
          phone.store.data.keys.where((k) => k.startsWith('vault.v1.rotation')),
          isEmpty,
        );
        expect(await phone.canRestoreWith(b), isFalse);
        expect(await phone.canRestoreWith(phone.codeA), isTrue);
        // Se puede cambiar el PIN otra vez.
        expect(
          await phone.auth.changePin(oldPin: rotationPin, newPin: '999999'),
          isTrue,
        );
      });
    }

    test('ya re-cifrando no se puede cancelar', () async {
      await phone.startAndConfirm();
      phone.crash = (p) {
        if (p == RotationCrashPoint.itemDone) throw SimulatedCrash(p);
      };
      await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
      await expectLater(
        phone.service.cancel(),
        throwsA(isA<RotationException>()),
      );
    });
  });

  group('guardas', () {
    /// Lleva la rotación hasta justo antes del corte.
    Future<String> untilBeforeCut() async {
      final b = await phone.startAndConfirm();
      phone.crash = (p) {
        if (p == RotationCrashPoint.snapshotUploaded) throw SimulatedCrash(p);
      };
      await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
      phone.crash = null;
      return b;
    }

    test(
      'A5: otro dispositivo sube un archivo viejo: bloquea sin cortar',
      () async {
        final b = await untilBeforeCut();
        await phone.cloud.uploadBytes(
          bytes: Uint8List.fromList([1, 2]),
          name: CloudNames.file('otro', gen: 1),
        );
        await phone.service.resume();
        final rec = (await phone.record())!;
        expect(rec.phase, RotationPhase.blockedCorrupt);
        expect(rec.resumePhase, RotationPhase.uploadingBackup);
        expect(phone.cloud.byName(CloudNames.recoveryBackupFor(2)), isNull);
        expect(await phone.canRestoreWith(phone.codeA), isTrue);
        expect(await phone.canRestoreWith(b), isTrue); // vía puente
      },
    );

    test('A5: el snapshot viejo cambió (otro dispositivo): bloquea', () async {
      await untilBeforeCut();
      final s = phone.cloud.byName(CloudNames.dbSnapshot)!;
      phone.cloud.corruptContent(s.id);
      await phone.service.resume();
      expect(await phase(), RotationPhase.blockedCorrupt);
    });

    test('C1: la cardinalidad no cuadra: bloquea', () async {
      await phone.startAndConfirm();
      phone.crash = (p) {
        if (p == RotationCrashPoint.switchDone) throw SimulatedCrash(p);
      };
      await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
      phone.crash = null;
      await phone.restart();
      final db = await phone.vdb.database;
      await db.rawUpdate(
        'UPDATE rotation_state SET frozenItems = frozenItems + 1',
      );
      await phone.service.resume();
      final rec = (await phone.record())!;
      expect(rec.phase, RotationPhase.blockedCorrupt);
      expect(phone.cloud.byName(CloudNames.dbSnapshotFor(2)), isNull);
    });

    test('A3: la BD es de otra rotación: blockedForeign', () async {
      await phone.startAndConfirm();
      phone.crash = (p) {
        if (p == RotationCrashPoint.switchDone) throw SimulatedCrash(p);
      };
      await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
      phone.crash = null;
      final db = await phone.vdb.database;
      await db.rawUpdate("UPDATE rotation_state SET rotationId = 'otra'");
      await phone.service.resume();
      expect(await phase(), RotationPhase.blockedForeign);
    });

    test('C2: el snapshot viejo no cambia tras congelar', () async {
      final b = await untilBeforeCut();
      final s = phone.cloud.byName(CloudNames.dbSnapshot)!;
      await phone.sync.run(manual: true, force: true);
      await phone.sync.flushSnapshotBeforeLock();
      await phone.service.resume();
      expect(await phase(), RotationPhase.deletingOldCloud);
      final after = phone.cloud.byName(CloudNames.dbSnapshot)!;
      expect(after.id, s.id);
      expect(after.md5Checksum, s.md5Checksum);
      expect(phone.cloud.allVersionsOf(CloudNames.dbSnapshot).length, 1);
      expect(await phone.canRestoreWith(b), isTrue);
    });

    test('A1: durante la rotación no se borran originales', () async {
      await phone.startAndConfirm();
      final i1 = (await phone.items.getItem('i1'))!;
      expect(await phone.sync.cloudVerifier(i1), isFalse);
    });
  });

  test('dañado en las dos copias: blockedCorrupt y "Omitir" (M6)', () async {
    final i3 = (await phone.items.getItem('i3'))!;
    final f = AppPaths.resolve(i3.encryptedPath);
    f.writeAsBytesSync(f.readAsBytesSync()..[40] ^= 1);
    phone.cloud.corruptContent(i3.driveFileId!);
    final b = await phone.startAndConfirm();
    await phone.service.resume();
    final rec = (await phone.record())!;
    expect(rec.phase, RotationPhase.blockedCorrupt);
    expect(rec.resumePhase, RotationPhase.reencrypting);
    expect(await phone.service.skipCorruptItems(), 1);
    expect(await phone.repo.quarantinedItemIds(), {'i3'});
    final lost = (await phone.items.getItem('i3'))!;
    expect(lost.syncStatus, SyncStatus.error);
    expect(lost.keyGen, 2);
    await phone.service.resume();
    expect(await phase(), RotationPhase.deletingOldCloud);
    await phone.expectAllItemsOpen(lost: {'i3'});
    expect(await phone.canRestoreWith(b, lost: {'i3'}), isTrue);
    // El blob viejo del dañado sigue en Drive.
    expect(phone.cloud.byName('i3.vault'), isNotNull);
  });

  test(
    'lo importado durante la rotación nace en la gen nueva y se corta',
    () async {
      final b = await phone.startAndConfirm();
      phone.crash = (p) {
        if (p == RotationCrashPoint.itemDone) throw SimulatedCrash(p);
      };
      await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
      phone.crash = null;
      final n = await phone.addItem('durante');
      expect(n.keyGen, 2);
      expect(n.encryptedPath, AppPaths.vaultRelativePath('durante', gen: 2));
      await phone.service.resume();
      expect(await phase(), RotationPhase.deletingOldCloud);
      expect(await phone.canRestoreWith(b), isTrue);
      expect(phone.cloud.byName(CloudNames.file('durante', gen: 2)), isNotNull);
    },
  );

  test('con huella antes de reencrypting: pide el PIN y sigue', () async {
    await phone.auth.enableBiometricUnlock();
    final b = await phone.startAndConfirm();
    phone.crash = (p) {
      if (p == RotationCrashPoint.freezingOldFilesListed) {
        throw SimulatedCrash(p);
      }
    };
    await expectLater(phone.service.resume(), throwsA(isA<SimulatedCrash>()));
    phone.crash = null;
    await phone.restart(biometric: true);
    await phone.service.resume();
    expect(phone.service.status.value.needsPin, isTrue);
    expect(await phase(), RotationPhase.freezing);
    await phone.restart();
    await phone.service.resume();
    await expectAtCut(b);
    expect((await phone.record())!.biometricWasEnabled, isTrue);
  });

  test('toGen = máximo visto en Drive + 1', () async {
    await phone.cloud.uploadBytes(
      bytes: Uint8List.fromList([1]),
      name: CloudNames.dbSnapshotFor(4),
    );
    expect(await phone.service.nextGeneration(), 5);
  });
}
