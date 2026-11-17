// D61 (rotación de la DEK, paso 9): restauración con VARIAS generaciones de
// llave en Drive, respaldo puente, aviso M8 y barrido de generaciones viejas.
//
// "SQLCipher" de pruebas: cada snapshot lleva una tabla `_fake_key` con la
// llave que lo abre; el opener la compara.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_names.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/restore/generation_sweeper.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';

import 'support/f9_env.dart';
import 'support/fake_cloud.dart';
import 'support/fakes.dart';

Future<Database> _markerOpener(
  String path, {
  String? password,
  required OpenDatabaseOptions options,
}) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: options);
  try {
    final rows = await db.query('_fake_key');
    if (rows.isEmpty || rows.first['k'] != password) throw Exception('x');
    return db;
  } catch (_) {
    await db.close();
    throw Exception('file is not a database');
  }
}

/// Nube que anota el orden de los borrados.
class _RecordingCloud extends FakeCloudStorage {
  final deleted = <String>[];
  @override
  Future<void> delete(String fileId) async {
    final f = (await list()).firstWhere((x) => x.id == fileId);
    deleted.add(f.name);
    await super.delete(fileId);
  }
}

void main() {
  late PhoneA a;
  late Directory bDir;
  late InMemorySecureStore bStore;
  late VaultSession bSession;
  late AuthController bAuth;
  late RestoreService svc;
  late KeyHierarchy k2;
  late String codeB;

  final recovery = KeyRecoveryService(kdfParams: fastKdf);

  /// Copia de la BD de A con la llave [password] marcada y, opcionalmente,
  /// todas las filas pasadas a la generación [gen] (con sus blobs en Drive).
  Future<Uint8List> snapshotBytes(String password, {int gen = 1}) async {
    final copy = (await a.vdb.exportEncryptedSnapshot()).file;
    final db = await databaseFactoryFfi.openDatabase(copy.path);
    await db.execute('CREATE TABLE _fake_key (k TEXT)');
    await db.insert('_fake_key', {'k': password});
    if (gen > 1) {
      for (final r in await db.query('vault_items')) {
        final id = r['id'] as String;
        final blob = Uint8List.fromList(utf8.encode('k$gen-$id'));
        await a.cloud.uploadBytes(
          bytes: blob,
          name: CloudNames.file(id, gen: gen),
        );
        final thumb = r['thumbPath'] != null;
        if (thumb) {
          await a.cloud.uploadBytes(
            bytes: Uint8List.fromList(utf8.encode('t$gen-$id')),
            name: CloudNames.thumb(id, gen: gen),
          );
        }
        await db.update(
          'vault_items',
          {
            'keyGen': gen,
            'encryptedPath': AppPaths.vaultRelativePath(id, gen: gen),
            'thumbPath': thumb
                ? AppPaths.thumbRelativePath(id, gen: gen)
                : null,
            'thumbFileId': null,
            'cloudMd5': a.cloud
                .byName(CloudNames.file(id, gen: gen))!
                .md5Checksum,
            'cloudSize': blob.length,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
    await db.close();
    final bytes = await copy.readAsBytes();
    await copy.delete();
    return bytes;
  }

  Future<void> put(String name, List<int> bytes) =>
      a.cloud.uploadBytes(bytes: Uint8List.fromList(bytes), name: name);

  /// Drive con el conjunto 1 (código A) y, según los flags, el puente y el
  /// conjunto 2 (código B), como en cada momento de una rotación.
  Future<void> seed({required bool bridge, required bool set2}) async {
    a = PhoneA();
    await a.setUp();
    await a.addItem('i1', 'Uno.jpg');
    await a.addItem('i2', 'Dos.jpg', thumb: false);
    await a.syncAll();
    // El snapshot gen 1 "real" se reemplaza por uno con marcador de llave.
    final s1 = a.cloud.byName(CloudNames.dbSnapshot)!;
    a.cloud.remove(s1.id);
    await put(CloudNames.dbSnapshot, await snapshotBytes(a.passwordA));
    final dek2 = Uint8List.fromList(List.generate(32, (i) => 99 - i));
    k2 = await KeyHierarchy.fromDek(dek2);
    codeB = RecoveryCode.generate();
    if (bridge) {
      final b = await recovery.createBackup(a.session.keys.dekBytes(), codeB);
      await put(CloudNames.bridgeBackup(1), utf8.encode(b.toJsonString()));
    }
    if (set2) {
      await put(
        CloudNames.dbSnapshotFor(2),
        await snapshotBytes(VaultDatabase.passwordFor(k2), gen: 2),
      );
      final b2 = await recovery.createBackup(dek2, codeB);
      await put(
        CloudNames.recoveryBackupFor(2),
        utf8.encode(b2.toJsonString()),
      );
    }
  }

  Future<void> newB() async {
    sqfliteFfiInit();
    bDir = await Directory.systemTemp.createTemp('gen_b');
    await AppPaths.init(baseDir: bDir);
    bStore = InMemorySecureStore();
    bSession = VaultSession.create();
    bAuth = AuthController(
      storage: bStore,
      biometricStore: FakeBiometricKeyStore(),
      kdfParams: fastKdf,
      session: bSession,
    );
    svc = RestoreService(
      cloud: a.cloud,
      auth: bAuth,
      prefs: SyncPreferences(bStore),
      opener: _markerOpener,
      dbPath: p.join(bDir.path, 'db', VaultSchema.dbFileName),
      parallelism: 1,
    );
  }

  tearDown(() async {
    svc.dispose();
    bAuth.lock();
    AppPaths.resetForTesting();
    try {
      await bDir.delete(recursive: true);
    } catch (_) {}
    await a.tearDown();
  });

  Future<VaultDataRepository> restoredRepo() async {
    final vdb = VaultDatabase.forTesting(
      session: bSession,
      dbPath: p.join(bDir.path, 'db', VaultSchema.dbFileName),
      opener: (path, {password, required options}) =>
          databaseFactoryFfi.openDatabase(path, options: options),
    );
    addTearDown(vdb.close);
    return VaultDataRepository(dbProvider: () => vdb.database);
  }

  int failures() {
    final raw = bStore.data[AuthController.restoreAttemptsKey];
    return raw == null ? 0 : jsonDecode(raw)['failures'] as int;
  }

  test('tras el corte: el código nuevo abre la gen 2 (no el puente)', () async {
    await seed(bridge: true, set2: true);
    await newB();
    expect(await svc.probe(), RestoreProbeResult.found);
    expect(await svc.verifyCode(codeB), isTrue);
    final m = svc.lastMatch!;
    expect((m.gen, m.viaBridge, m.latestGen), (2, false, 2));
    expect(m.olderThanLatest, isFalse);
    final r = await svc.restore(newPin: '654321');
    expect(r.items, 2);
    expect(r.lostItems, 0);
    expect(await bAuth.currentKeyGen(), 2);
    expect(bSession.currentGen, 2);
    expect(bSession.keys.keyCheck, k2.keyCheck);
    final repo = await restoredRepo();
    final all = await repo.getAllItems();
    expect(all.map((i) => i.keyGen).toSet(), {2});
    final i1 = all.firstWhere((i) => i.id == 'i1');
    expect(i1.thumbPath, AppPaths.thumbRelativePath('i1', gen: 2));
    expect(AppPaths.resolve(i1.thumbPath!).readAsStringSync(), 't2-i1');
    expect(await SyncPreferences(bStore).getGenerationSweepPending(), isTrue);
  });

  test('M8: el código VIEJO con un conjunto más nuevo avisa', () async {
    await seed(bridge: true, set2: true);
    await newB();
    await svc.probe();
    expect(await svc.verifyCode(a.recoveryCode), isTrue);
    final m = svc.lastMatch!;
    expect((m.gen, m.viaBridge), (1, false));
    expect(m.olderThanLatest, isTrue);
    await svc.restore(newPin: '654321');
    expect(await bAuth.currentKeyGen(), 1);
    expect(await SyncPreferences(bStore).getGenerationSweepPending(), isFalse);
  });

  test(
    'antes del corte: el código nuevo abre el conjunto viejo vía puente',
    () async {
      await seed(bridge: true, set2: false);
      await newB();
      expect(await svc.probe(), RestoreProbeResult.found);
      expect(await svc.verifyCode(codeB), isTrue);
      final m = svc.lastMatch!;
      expect((m.gen, m.viaBridge), (1, true));
      expect(m.olderThanLatest, isTrue, reason: 'aviso del puente');
      final r = await svc.restore(newPin: '654321');
      expect(r.items, 2);
      expect(bSession.keys.keyCheck, a.session.keys.keyCheck);
      expect(await bAuth.currentKeyGen(), 1);
      // El respaldo local (código B) se subirá en lugar del de A.
      expect(await SyncPreferences(bStore).getRecoveryUploadedSha(), '');
      // Con el código viejo también (el conjunto 1 sigue completo).
    },
  );

  test(
    'código incorrecto: false y UN solo intento aunque haya varios',
    () async {
      await seed(bridge: true, set2: true);
      await newB();
      await svc.probe();
      expect(await svc.verifyCode('ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2'), isFalse);
      expect(failures(), 1);
    },
  );

  test('M1: duplicados con el mismo nombre se prueban todos', () async {
    await seed(bridge: false, set2: true);
    // Un segundo `recovery_backup.k2.json` con OTRO código (más reciente).
    final other = await recovery.createBackup(
      List.filled(32, 5),
      RecoveryCode.generate(),
    );
    await put(
      CloudNames.recoveryBackupFor(2),
      utf8.encode(other.toJsonString()),
    );
    await newB();
    await svc.probe();
    expect(await svc.verifyCode(codeB), isTrue);
    expect(svc.lastMatch!.gen, 2);
    expect(failures(), 0);
  });

  test('respaldos inválidos o sin snapshot', () async {
    await seed(bridge: false, set2: false);
    a.cloud.remove(a.cloud.byName(CloudNames.dbSnapshot)!.id);
    await newB();
    expect(await svc.probe(), RestoreProbeResult.incomplete);
    a.cloud.remove(a.cloud.byName(CloudNames.recoveryBackup)!.id);
    await put(CloudNames.recoveryBackupFor(3), utf8.encode('{"no":1}'));
    expect(await svc.probe(), RestoreProbeResult.invalid);
    a.cloud.remove(a.cloud.byName(CloudNames.recoveryBackupFor(3))!.id);
    expect(await svc.probe(), RestoreProbeResult.noBackup);
  });

  group('barrido de generaciones viejas', () {
    late _RecordingCloud cloud;
    late String local;

    setUp(() async {
      // Sin teléfono A: solo la nube.
      a = PhoneA();
      await a.setUp();
      await newB();
      cloud = _RecordingCloud();
      local = (await recovery.createBackup(
        List.filled(32, 7),
        RecoveryCode.generate(),
      )).toJsonString();
      for (final n in [
        '3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69.vault',
        '3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69.thumb',
        CloudNames.dbSnapshot,
        CloudNames.recoveryBackup,
        CloudNames.bridgeBackup(1),
        '3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69.k2.vault',
        CloudNames.dbSnapshotFor(2),
        'lost_3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69.k1.vault',
        CloudNames.recoveryBackupFor(3), // otra rama, más nueva
        'otra-cosa.txt',
      ]) {
        await cloud.uploadBytes(bytes: Uint8List.fromList([1]), name: n);
      }
    });

    test(
      'guarda: sin el respaldo propio de la gen vigente no borra nada',
      () async {
        final r = await GenerationSweeper(
          cloud: cloud,
        ).sweep(currentGen: 2, localRecoveryBackupJson: local);
        expect(r, SweepResult.guardFailed);
        expect(cloud.deleted, isEmpty);
      },
    );

    test('borra por lista la gen 1 (respaldos primero) y nada más', () async {
      await cloud.uploadBytes(
        bytes: Uint8List.fromList(utf8.encode(local)),
        name: CloudNames.recoveryBackupFor(2),
      );
      final r = await GenerationSweeper(
        cloud: cloud,
      ).sweep(currentGen: 2, localRecoveryBackupJson: local);
      expect(r, SweepResult.done);
      expect(cloud.deleted.take(2).toSet(), {
        CloudNames.recoveryBackup,
        CloudNames.bridgeBackup(1),
      });
      expect(cloud.deleted[2], CloudNames.dbSnapshot);
      expect(cloud.names.toSet(), {
        '3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69.k2.vault',
        CloudNames.dbSnapshotFor(2),
        CloudNames.recoveryBackupFor(2),
        'lost_3f2b8c1e-9d4a-4b6f-8a7c-1e2d3c4b5a69.k1.vault',
        CloudNames.recoveryBackupFor(3),
        'otra-cosa.txt',
      });
    });
  });

  test('un snapshot con generación fuera de rango es corrupto', () async {
    await seed(bridge: false, set2: false);
    final s = a.cloud.byName(CloudNames.dbSnapshot)!;
    a.cloud.remove(s.id);
    final bytes = await snapshotBytes(a.passwordA);
    final f = File(p.join(a.dir.path, 'bad.db'))..writeAsBytesSync(bytes);
    final db = await databaseFactoryFfi.openDatabase(f.path);
    await db.update('vault_items', {'keyGen': 0});
    await db.close();
    await put(CloudNames.dbSnapshot, f.readAsBytesSync());
    await newB();
    await svc.probe();
    expect(await svc.verifyCode(a.recoveryCode), isTrue);
    await expectLater(
      svc.restore(newPin: '654321'),
      throwsA(isA<RestoreCorruptException>()),
    );
  });
}
