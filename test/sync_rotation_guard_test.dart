// C2/A1/M4/M7 (D61, rotación de la DEK paso 5): la sincronización respeta la
// rotación. Ningún snapshot ni respaldo publica algo que rompa un conjunto.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/crypto/key_rotation_store.dart';
import 'package:vault/data/rotation/rotation_guard.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';

import 'support/fake_cloud.dart';
import 'support/fakes.dart';

class _Guard implements RotationGuard {
  @override
  bool active = false;
  @override
  bool freezeMeta = false;
  @override
  int fromGen = 1;
  @override
  int toGen = 2;
}

/// Nube que ejecuta [beforeUpload] justo antes de cada subida de archivo.
class _HookCloud extends FakeCloudStorage {
  Future<void> Function(String name)? beforeUpload;

  @override
  Future<CloudFile> uploadFile({
    required File file,
    required String name,
    String? replaceFileId,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) async {
    await beforeUpload?.call(name);
    return super.uploadFile(
      file: file,
      name: name,
      replaceFileId: replaceFileId,
      onProgress: onProgress,
      cancel: cancel,
    );
  }
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late VaultSession session;
  late VaultDatabase vdb;
  late VaultDataRepository items;
  late SyncQueueRepository queue;
  late _HookCloud cloud;
  late SyncPreferences prefs;
  late _Guard guard;
  late SyncService sync;
  var keyGen = 1;
  SnapshotCopy Function(File f)? copyOf;
  String? recoveryJson;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rot_guard');
    await AppPaths.init(baseDir: tmp);
    session = VaultSession.create()
      ..open(
        await KeyHierarchy.fromDek(
          Uint8List.fromList(List.generate(32, (i) => i + 3)),
        ),
      );
    vdb = VaultDatabase.forTesting(
      session: session,
      dbPath: p.join(tmp.path, 'db', 'g.db'),
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
    );
    items = VaultDataRepository(dbProvider: () => vdb.database);
    queue = SyncQueueRepository(dbProvider: () => vdb.database);
    cloud = _HookCloud();
    prefs = SyncPreferences(InMemorySecureStore());
    guard = _Guard();
    keyGen = 1;
    copyOf = null;
    recoveryJson = null;
    sync = SyncService(
      cloud: cloud,
      queue: queue,
      items: items,
      network: FakeNetworkMonitor(),
      prefs: prefs,
      isUnlocked: () => session.isUnlocked,
      resolvePath: AppPaths.resolve,
      recoveryBackupProvider: () async => recoveryJson,
      snapshotProvider: () async {
        final f = File(p.join(tmp.path, 'snap.bin'))
          ..writeAsBytesSync([1, 2, 3, 4, 5]);
        return copyOf?.call(f) ?? SnapshotCopy(f, dbGen: 1);
      },
      random: Random(1),
      scheduleWakeups: false,
      rotation: guard,
      currentKeyGen: () async => keyGen,
    );
  });

  tearDown(() async {
    sync.dispose();
    await vdb.close();
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<VaultItemModel> addItem(String id, {int gen = 1}) async {
    final rel = AppPaths.vaultRelativePath(id, gen: gen);
    AppPaths.resolve(rel).writeAsBytesSync(List.generate(3000, (i) => i & 255));
    await items.insertItem(
      VaultItemModel(
        keyGen: gen,
        id: id,
        name: 'x.jpg',
        encryptedPath: rel,
        fileSize: 3000,
        mimeType: 'image/jpeg',
        createdAt: '2026-01-01T00:00:00',
      ),
    );
    return (await items.getItem(id))!;
  }

  group('snapshot (C2)', () {
    test('gen 1: mismo nombre de siempre', () async {
      await prefs.markDirty(1);
      await sync.run(manual: true);
      expect(cloud.byName('vault_db.snapshot'), isNotNull);
    });

    test('el nombre sale de la generación de la copia', () async {
      copyOf = (f) => SnapshotCopy(f, dbGen: 2, minKeyGen: 2, maxKeyGen: 2);
      await prefs.markDirty(1);
      await sync.run(manual: true);
      expect(cloud.byName('vault_db.k2.snapshot'), isNotNull);
      expect(cloud.byName('vault_db.snapshot'), isNull);
    });

    test('copia con filas de varias generaciones: se niega', () async {
      copyOf = (f) => SnapshotCopy(f, dbGen: 1, minKeyGen: 1, maxKeyGen: 2);
      await prefs.markDirty(1);
      await sync.run(manual: true);
      expect(cloud.names, isEmpty);
      final jobs = await queue.all();
      expect(jobs.single.kind, SyncJobKind.dbSnapshot);
      expect(jobs.single.state, SyncJobState.error);
      // La marca "sucio" persiste: no se pierde ningún cambio.
      expect(await prefs.getDirtyAt(), isNotNull);
    });

    test(
      'conjunto congelado: no se encola, no se sube, no se pierde',
      () async {
        await queue.enqueue(
          SyncQueueRepository.noItem,
          SyncJobKind.dbSnapshot,
          now: 0,
        );
        guard
          ..active = true
          ..freezeMeta = true;
        await prefs.markDirty(1);
        await sync.run(manual: true);
        expect(cloud.names, isEmpty);
        expect(
          await queue.all(),
          isEmpty,
          reason: 'el trabajo viejo se descarta',
        );
        expect(await prefs.getDirtyAt(), isNotNull);

        // Flush al bloquear: tampoco.
        await sync.flushSnapshotBeforeLock();
        expect(sync.snapshotFlushInFlight, isFalse);
        expect(cloud.names, isEmpty);

        // Tras el corte vuelve a publicarse.
        guard.freezeMeta = false;
        await sync.run(manual: true);
        expect(cloud.byName('vault_db.snapshot'), isNotNull);
      },
    );
  });

  group('respaldo de recuperación', () {
    test(
      'lleva la generación vigente en el nombre (S-04 por nombre)',
      () async {
        recoveryJson =
            (await KeyRecoveryService(kdfParams: fastKdf).createBackup(
              List.filled(32, 1),
              RecoveryCode.generate(),
            )).toJsonString();
        // Un respaldo gen 1 previo (otro nombre) NO se toca.
        await cloud.uploadBytes(
          bytes: Uint8List.fromList([1]),
          name: 'recovery_backup.json',
        );
        keyGen = 2;
        await sync.run(manual: true);
        expect(cloud.byName('recovery_backup.k2.json'), isNotNull);
        expect(cloud.byName('recovery_backup.json'), isNotNull);
      },
    );

    test('congelado: no se sube', () async {
      recoveryJson = '{}';
      guard
        ..active = true
        ..freezeMeta = true;
      await sync.run(manual: true);
      expect(cloud.names, isEmpty);
    });
  });

  group('archivos', () {
    test('gen 2 se sube con su nombre .k2', () async {
      await addItem('a', gen: 2);
      await sync.run(manual: true);
      expect(cloud.byName('a.k2.vault'), isNotNull);
      expect(cloud.byName('a.vault'), isNull);
      final a = (await items.getItem('a'))!;
      expect(a.syncStatus, SyncStatus.enNube);
      expect(a.driveFileId, cloud.byName('a.k2.vault')!.id);
    });

    test('congelado: un archivo de la generación vieja NO se sube', () async {
      await addItem('b');
      guard
        ..active = true
        ..freezeMeta = true;
      await sync.run(manual: true);
      expect(cloud.names, isEmpty);
      expect((await items.getItem('b'))!.syncStatus, SyncStatus.error);
    });

    test(
      'M4: si la fila cambia durante la subida, no se registra ni se borra',
      () async {
        await addItem('c');
        cloud.beforeUpload = (name) async {
          if (name != 'c.vault') return;
          // La rotación re-cifra el item justo ahora.
          final rel = AppPaths.vaultRelativePath('c', gen: 2);
          AppPaths.resolve(rel).writeAsBytesSync([9, 9, 9]);
          await (await vdb.database).update('vault_items', {
            'keyGen': 2,
            'encryptedPath': rel,
          }, where: "id = 'c'");
        };
        // Solo una pasada del trabajo gen 1.
        await queue.enqueue('c', SyncJobKind.file, now: 0);
        await sync.run(manual: true);
        cloud.beforeUpload = null;
        final c = (await items.getItem('c'))!;
        expect(c.keyGen, 2);
        // Lo subido de la gen 1 sigue en Drive (no se borró nada)...
        expect(cloud.byName('c.vault'), isNotNull);
        // ...y no se registró en la fila nueva.
        expect(c.driveFileId == cloud.byName('c.vault')!.id, isFalse);
      },
    );

    test(
      'M4: archivo local ausente porque la fila cambió: no es error',
      () async {
        final d = await addItem('d');
        await queue.enqueue('d', SyncJobKind.file, now: 0);
        AppPaths.resolve(d.encryptedPath).deleteSync();
        final rel = AppPaths.vaultRelativePath('d', gen: 2);
        AppPaths.resolve(rel).writeAsBytesSync([5, 5]);
        await (await vdb.database).update('vault_items', {
          'keyGen': 2,
          'encryptedPath': rel,
        }, where: "id = 'd'");
        // El trabajo viejo se da por hecho y el nuevo sube el .k2.
        await sync.run(manual: true);
        expect((await items.getItem('d'))!.syncStatus, SyncStatus.enNube);
        expect(cloud.byName('d.k2.vault'), isNotNull);
      },
    );
  });

  test('borrado remoto: todas las generaciones y la cuarentena', () async {
    keyGen = 2;
    for (final n in [
      'e.vault',
      'e.thumb',
      'e.k2.vault',
      'e.k2.thumb',
      'lost_e.k1.vault',
      'otro.vault',
    ]) {
      await cloud.uploadBytes(bytes: Uint8List.fromList([1]), name: n);
    }
    await sync.enqueueRemoteDelete('e');
    await sync.run(manual: true);
    expect(cloud.names.toList(), ['otro.vault']);
  });

  test('StoreRotationGuard sigue al registro y sus fases', () async {
    final store = RotationKeyStore(InMemorySecureStore());
    final g = StoreRotationGuard(store);
    expect((g.active, g.freezeMeta, g.fromGen, g.toGen), (false, false, 1, 1));
    RotationRecord rec(RotationPhase p, [RotationPhase? resume]) =>
        RotationRecord(
          id: 'r',
          fromGen: 1,
          toGen: 2,
          phase: p,
          reason: RotationReason.newCode,
          oldKeyCheck: 'a',
          newKeyCheck: 'b',
          accountEmail: 'x@y',
          startedAt: 0,
          updatedAt: 0,
          resumePhase: resume,
        );
    for (final (p, frozen) in [
      (RotationPhase.prepared, false),
      (RotationPhase.confirmed, false),
      (RotationPhase.freezing, true),
      (RotationPhase.reencrypting, true),
      (RotationPhase.uploadingBackup, true),
      (RotationPhase.deletingOldCloud, false),
      (RotationPhase.finalizingLocal, false),
    ]) {
      await store.save(rec(p));
      expect(g.active, isTrue);
      expect(g.freezeMeta, frozen, reason: '$p');
      expect((g.fromGen, g.toGen), (1, 2));
    }
    // Bloqueada: manda la fase a la que vuelve.
    await store.save(rec(RotationPhase.blockedQuota, RotationPhase.uploading));
    expect(g.freezeMeta, isTrue);
    // Ida y vuelta del JSON.
    final r = rec(RotationPhase.blockedSignIn, RotationPhase.freezing);
    final back = RotationRecord.decode(r.encode());
    expect(back.phase, RotationPhase.blockedSignIn);
    expect(back.effectivePhase, RotationPhase.freezing);
    expect(back.isCancellable, isTrue);
    expect(() => RotationRecord.decode('{"v":9}'), throwsFormatException);
    await store.clearAll();
    expect(g.active, isFalse);
  });

  test('A1: con rotación, cloudVerifier siempre false', () async {
    final f = await addItem('v');
    await sync.run(manual: true);
    final verified = (await items.getItem('v'))!;
    expect(await sync.cloudVerifier(verified), isTrue);
    guard.active = true;
    expect(await sync.cloudVerifier(verified), isFalse);
    expect(f.id, 'v');
  });
}
