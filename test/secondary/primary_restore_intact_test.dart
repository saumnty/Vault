// Fase 8, paso 9 (DISENO_SENUELO §0 G1/G2, §11.2-10): crear, usar, cambiar
// el PIN y eliminar la bóveda adicional deja la PRINCIPAL byte a byte igual
// (disco, almacén seguro y Drive con sus revisiones) y restaurable con su
// código en un teléfono limpio, sin ningún rastro de la adicional.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/primary_gates.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/slot_guarded_cloud.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/sync/sync_service.dart';

import '../support/f9_env.dart';

const _alt = '482913';

void main() {
  late PhoneA a;
  PhoneB? b;

  setUp(() async {
    a = PhoneA();
    await a.setUp();
    await a.addFolder('f1', 'Vacaciones');
    await a.addItem('i1', 'Atardecer.jpg', realThumb: true);
    await a.addItem('i2', 'Familia.jpg', folderId: 'f1', realThumb: true);
    await a.addItem('i3', 'Doc.pdf', thumb: false);
    await a.syncAll();
  });

  tearDown(() async {
    await b?.tearDown();
    b = null;
    await a.tearDown();
  });

  /// Drive: nombre → [md5 actual, …md5 de cada revisión].
  Map<String, List<String>> cloudState() {
    final out = <String, List<String>>{};
    for (final n in a.cloud.names.toSet()) {
      out[n] = [
        for (final v in a.cloud.allVersionsOf(n))
          crypto.md5.convert(v).toString(),
      ]..sort();
    }
    return out;
  }

  Map<String, String> files() {
    final out = <String, String>{};
    for (final f in a.dir.listSync(recursive: true).whereType<File>()) {
      final rel = p.relative(f.path, from: a.dir.path).replaceAll('\\', '/');
      if (rel == 'alt' || rel.startsWith('alt/')) continue;
      // La BD se compara por filas (abrirla puede tocar su cabecera/WAL).
      if (rel.startsWith('db/')) continue;
      out[rel] = crypto.sha256.convert(f.readAsBytesSync()).toString();
    }
    return out;
  }

  Map<String, String> store() => {
    for (final e in a.store.data.entries)
      if (!e.key.startsWith('vault.v1.alt.') &&
          e.key != 'vault.v1.pin_attempts')
        e.key: e.value,
  };

  Future<String> rows() async {
    final db = await a.vdb.database;
    final buf = StringBuffer();
    for (final t in ['vault_items', 'folders', 'tags', 'item_tags']) {
      buf.writeln(jsonEncode(await db.query(t, orderBy: 'rowid')));
    }
    return buf.toString();
  }

  Future<void> useSecondary() async {
    expect(
      await a.auth.createSecondaryVault(primaryPin: '123456', newPin: _alt),
      isTrue,
    );
    a.auth.lock();
    expect(await a.auth.unlockWithPin(_alt), isTrue);
    expect(a.session.slot, VaultSlot.secondary);
    // Contenido de la secundaria: BD y un archivo cifrado con SUS llaves.
    final sdb = VaultDatabase.forTesting(
      session: a.session,
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
      markerStore: a.store,
      slot: VaultSlot.secondary,
    );
    final repo = VaultDataRepository(dbProvider: () => sdb.database);
    final enc = await CryptoService().encryptBytes(
      List.generate(5000, (i) => Random(i).nextInt(256)),
      a.session.filesKey!,
    );
    await VaultPaths.secondary.resolve('vault/s1.vault').writeAsBytes(enc);
    await repo.insertItem(
      VaultItemModel(
        keyGen: 1,
        id: 's1',
        name: 'Señuelo.jpg',
        encryptedPath: 'vault/s1.vault',
        fileSize: 5000,
        mimeType: 'image/jpeg',
        createdAt: '2026-02-02T00:00:00',
      ),
    );
    // La sincronización (con sus compuertas y la nube con guarda, como en la
    // app) no hace NADA con la secundaria abierta.
    final gated = SyncService(
      cloud: SlotGuardedCloudStorage(a.cloud, session: a.session),
      queue: a.queue,
      items: a.items,
      network: a.net,
      prefs: a.prefs,
      isUnlocked: PrimaryGates.unlocked(a.session),
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: a.auth.exportRecoveryBackup,
      snapshotProvider: a.vdb.exportEncryptedSnapshot,
      nowMs: () => a.now,
      scheduleWakeups: false,
    );
    await gated.run(manual: true);
    await gated.flushSnapshotBeforeLock();
    gated.dispose();
    await sdb.close();
    a.auth.lock();
    expect(await a.auth.unlockWithPin('123456'), isTrue);
    expect(
      await a.auth.changeSecondaryPin(
        primaryPin: '123456',
        currentAltPin: _alt,
        newAltPin: '739164',
      ),
      ChangeSecondaryPinResult.changed,
    );
  }

  test('la principal queda byte a byte igual (disco, almacén, Drive y sus '
      'revisiones, filas)', () async {
    final c0 = cloudState();
    final f0 = files();
    final s0 = store();
    final r0 = await rows();
    final uploads0 = a.cloud.uploadCalls;

    await useSecondary();
    expect(cloudState(), c0, reason: 'Drive');
    expect(a.cloud.uploadCalls, uploads0);
    expect(files(), f0, reason: 'disco');
    expect(store(), s0, reason: 'almacén');
    expect(await rows(), r0, reason: 'filas');
    expect(
      a.cloud.names.any((n) => n.contains('alt') || n.contains('s1')),
      isFalse,
    );

    expect(await a.auth.deleteSecondaryVault('123456'), isTrue);
    expect(cloudState(), c0);
    expect(files(), f0);
    expect(store(), s0);
    expect(await rows(), r0);
  });

  test('restaurar la principal en un teléfono limpio (con la adicional aún '
      'en el original): todo vuelve y no hay rastro de la adicional', () async {
    await useSecondary();
    a.auth.lock();
    expect(await a.auth.unlockWithPin('123456'), isTrue);
    final passwordA = a.passwordA;
    final phone = b = PhoneB();
    await phone.setUp(a.cloud, expectedPassword: passwordA);
    expect(await phone.service.probe(), RestoreProbeResult.found);
    expect(await phone.service.verifyCode(a.recoveryCode), isTrue);
    final r = await phone.service.restore(newPin: '654321');
    expect(r.items, 3);
    expect(r.lostItems, 0);
    final vdb = phone.openDb();
    addTearDown(vdb.close);
    final repo = VaultDataRepository(dbProvider: () => vdb.database);
    final all = await repo.getAllItems();
    expect(all.map((i) => i.id).toSet(), {'i1', 'i2', 'i3'});
    // Ni rastro de la adicional.
    expect(VaultPaths.secondary.exists, isFalse);
    for (final k in AuthController.allAltKeys) {
      expect(phone.store.data.containsKey(k), isFalse);
    }
    expect(await phone.auth.hasSecondaryVault(), isFalse);
    expect(await phone.auth.secondaryStatus(), SecondaryVaultStatus.none);
    phone.auth.lock();
    expect(await phone.auth.unlockWithPin('739164'), isFalse);
    expect(await phone.auth.unlockWithPin(_alt), isFalse);
    expect(await phone.auth.unlockWithPin('654321'), isTrue);
    expect(phone.session.slot, VaultSlot.primary);
  });
}
