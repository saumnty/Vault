import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:_discoveryapis_commons/_discoveryapis_commons.dart'
    show ApiRequestErrorDetail;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vault/core/config/google_config.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/cloud/google_drive_cloud_storage.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/models/vault_item_model.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/repositories/vault_database.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';

import 'support/fake_cloud.dart';
import 'support/fakes.dart';

Future<Database> _ffi(String path, OpenDatabaseOptions options) =>
    databaseFactoryFfi.openDatabase(path, options: options);

Future<KeyHierarchy> _keys() => KeyHierarchy.fromDek(
  Uint8List.fromList(List.generate(32, (i) => i * 3 + 1)),
);

class Env {
  late Directory tmp;
  late VaultSession session;
  late VaultDatabase vdb;
  late VaultDataRepository items;
  late SyncQueueRepository queue;
  late FakeCloudStorage cloud;
  late FakeNetworkMonitor net;
  late InMemorySecureStore store;
  late SyncPreferences prefs;
  late SyncService sync;
  int now = 1000000;
  String? recoveryJson;
  int snapshotsTaken = 0;
  final created = <File>[];

  String get dbPath => p.join(tmp.path, 'db', 'sync.db');

  VaultDatabase newDb() => VaultDatabase.forTesting(
    session: session,
    dbPath: dbPath,
    opener: (path, {password, required options}) => _ffi(path, options),
  );

  SyncService newService({
    int maxAttempts = 5,
    int snapshotEveryUploads = 20,
    SyncQueueRepository? queueOverride,
  }) => SyncService(
    cloud: cloud,
    queue: queueOverride ?? queue,
    items: items,
    network: net,
    prefs: prefs,
    isUnlocked: () => session.isUnlocked,
    resolvePath: AppPaths.resolve,
    recoveryBackupProvider: () async => recoveryJson,
    snapshotProvider: () async {
      snapshotsTaken++;
      final f = File('$dbPath.snapshot');
      await f.writeAsBytes(List.generate(5000, (i) => (i * 7) & 0xff));
      return f;
    },
    nowMs: () => now,
    random: Random(1),
    maxAttempts: maxAttempts,
    snapshotEveryUploads: snapshotEveryUploads,
    scheduleWakeups: false,
  );

  Future<void> setUp() async {
    tmp = await Directory.systemTemp.createTemp('sync_test');
    await AppPaths.init(baseDir: tmp);
    session = VaultSession.create();
    session.open(await _keys());
    vdb = newDb();
    items = VaultDataRepository(dbProvider: () => vdb.database);
    queue = SyncQueueRepository(dbProvider: () => vdb.database);
    cloud = FakeCloudStorage();
    net = FakeNetworkMonitor();
    store = InMemorySecureStore();
    prefs = SyncPreferences(store);
    sync = newService();
  }

  Future<void> tearDown() async {
    sync.dispose();
    await vdb.close();
    AppPaths.resetForTesting();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }

  /// Crea un item con archivo `.vault` de [size] bytes (y miniatura opcional).
  Future<VaultItemModel> addItem(
    String id, {
    int size = 200 * 1024,
    bool thumb = false,
    SyncStatus status = SyncStatus.pendiente,
  }) async {
    final rng = Random(id.hashCode);
    final file = AppPaths.resolve(AppPaths.vaultRelativePath(id));
    await file.writeAsBytes(
      Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256))),
    );
    String? thumbRel;
    if (thumb) {
      thumbRel = AppPaths.thumbRelativePath(id);
      await AppPaths.resolve(
        thumbRel,
      ).writeAsBytes(List.generate(3000, (i) => (i + id.length) & 0xff));
    }
    final item = VaultItemModel(
      id: id,
      name: 'foto $id.jpg',
      encryptedPath: AppPaths.vaultRelativePath(id),
      fileSize: size,
      mimeType: 'image/jpeg',
      createdAt: '2026-01-01T00:00:0${created.length}',
      thumbPath: thumbRel,
      syncStatus: status,
      contentHash: 'abc',
      sourceAssetId: 'asset-$id',
    );
    await items.insertItem(item);
    created.add(file);
    return item;
  }
}

void main() {
  sqfliteFfiInit();
  late Env env;

  setUp(() async {
    env = Env();
    await env.setUp();
  });
  tearDown(() => env.tearDown());

  group('subida y verificación', () {
    test(
      'sube .vault y .thumb, verifica tamaño + MD5 y marca en_nube',
      () async {
        await env.addItem('a', thumb: true);
        await env.sync.run();

        final item = (await env.items.getItem('a'))!;
        expect(item.syncStatus, SyncStatus.enNube);
        expect(item.driveFileId, env.cloud.byName('a.vault')!.id);
        expect(item.cloudSize, 200 * 1024);
        expect(item.cloudMd5, env.cloud.byName('a.vault')!.md5Checksum);
        expect(item.thumbDriveFileId, env.cloud.byName('a.thumb')!.id);
        expect(await env.queue.all(), isEmpty);
        // El nombre remoto no revela el nombre real.
        expect(env.cloud.names.any((n) => n.contains('foto')), isFalse);
      },
    );

    test('md5OfFile en streaming coincide con el MD5 de los bytes', () async {
      await env.addItem('m');
      final f = AppPaths.resolve(AppPaths.vaultRelativePath('m'));
      expect(await md5OfFile(f), md5OfBytes(await f.readAsBytes()));
    });

    test(
      'MD5 distinto -> error, reintento con backoff y luego éxito',
      () async {
        await env.addItem('a');
        env.cloud.corruptNextUpload = true;
        await env.sync.run();

        var item = (await env.items.getItem('a'))!;
        expect(item.syncStatus, SyncStatus.pendiente);
        expect(item.driveFileId, isNull);
        var job = (await env.queue.find('a', SyncJobKind.file))!;
        expect(job.attempts, 1);
        expect(job.state, SyncJobState.pendiente);
        expect(job.nextAttemptAt, greaterThan(env.now));
        expect(job.lastError, contains('no coincide'));

        // Aún dentro de la espera: run() normal no lo reintenta.
        await env.sync.run();
        expect(env.cloud.uploadCalls, 1);

        // Pasa el tiempo: reintenta y reemplaza (no duplica).
        env.now = job.nextAttemptAt + 1;
        await env.sync.run();
        item = (await env.items.getItem('a'))!;
        expect(item.syncStatus, SyncStatus.enNube);
        expect(env.cloud.names.where((n) => n == 'a.vault').length, 1);
      },
    );

    test('tamaño distinto -> no se marca en_nube', () async {
      await env.addItem('a');
      env.cloud.truncateNextUpload = true;
      await env.sync.run();
      final item = (await env.items.getItem('a'))!;
      expect(item.syncStatus, isNot(SyncStatus.enNube));
      final job = (await env.queue.find('a', SyncJobKind.file))!;
      expect(job.lastError, contains('no coincide'));
    });

    test('progreso por archivo llega al notifier', () async {
      await env.addItem('a', size: 300 * 1024);
      final seen = <double>[];
      env.sync.progress.addListener(() {
        final v = env.sync.progress.value['a'];
        if (v != null) seen.add(v);
      });
      await env.sync.run();
      expect(seen, isNotEmpty);
      expect(seen.last, closeTo(1.0, 0.001));
      expect(seen.first, lessThan(1.0));
      expect(env.sync.progress.value, isEmpty);
    });
  });

  group('backoff y tope', () {
    test('exponencial con jitter 50-100 % y tope', () {
      final rng = Random(3);
      for (var attempts = 1; attempts <= 12; attempts++) {
        final d = syncBackoff(attempts, rng);
        final exp = min(
          const Duration(minutes: 15).inMilliseconds,
          10000 * pow(2, attempts - 1).toInt(),
        );
        expect(d.inMilliseconds, lessThanOrEqualTo(exp));
        expect(d.inMilliseconds, greaterThanOrEqualTo(exp ~/ 2 - 1));
      }
      expect(
        syncBackoff(50, rng).inMilliseconds,
        lessThanOrEqualTo(const Duration(minutes: 15).inMilliseconds),
      );
    });

    test('tras N fallos pasa a error; reintento manual lo recupera', () async {
      await env.addItem('a');
      env.cloud.failure = (op) =>
          op == 'upload' ? const CloudServerException(503) : null;
      for (var i = 0; i < 5; i++) {
        env.now += 24 * 3600 * 1000;
        await env.sync.run();
      }
      var item = (await env.items.getItem('a'))!;
      expect(item.syncStatus, SyncStatus.error);
      var job = (await env.queue.find('a', SyncJobKind.file))!;
      expect(job.state, SyncJobState.error);
      expect(job.attempts, 5);
      expect(job.lastError, contains('503'));
      expect(env.sync.summary.value.counts.errors, 1);

      // No se reintenta solo.
      final calls = env.cloud.uploadCalls;
      env.now += 24 * 3600 * 1000;
      await env.sync.run(manual: true);
      expect(env.cloud.uploadCalls, calls);

      // Reintento manual tras arreglar la causa.
      env.cloud.failure = null;
      await env.sync.retryErrors(jobId: job.id);
      item = (await env.items.getItem('a'))!;
      expect(item.syncStatus, SyncStatus.enNube);
      expect(await env.queue.all(), isEmpty);
    });

    test('403 de permisos es error inmediato (sin reintentos)', () async {
      await env.addItem('a');
      env.cloud.failure = (op) =>
          op == 'upload' ? const CloudForbiddenException('403') : null;
      await env.sync.run();
      final job = (await env.queue.find('a', SyncJobKind.file))!;
      expect(job.state, SyncJobState.error);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.error);
    });

    test('cuota llena -> error visible y fase quotaFull', () async {
      await env.addItem('a');
      env.cloud.failure = (op) =>
          op == 'upload' ? const CloudQuotaExceededException() : null;
      await env.sync.run();
      expect(env.sync.summary.value.phase, SyncPhase.quotaFull);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.error);
    });
  });

  group('solo Wi-Fi y red', () {
    test('datos móviles + solo Wi-Fi bloquea; Wi-Fi permite', () async {
      await env.addItem('a');
      await env.prefs.setWifiOnly(true);
      env.net.kind = NetworkKind.mobile;
      await env.sync.run();
      expect(env.sync.summary.value.phase, SyncPhase.waitingWifi);
      expect(env.cloud.uploadCalls, 0);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.pendiente);

      env.net.kind = NetworkKind.wifi;
      await env.sync.run();
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
    });

    test('datos móviles con solo Wi-Fi apagado sí sube', () async {
      await env.addItem('a');
      env.net.kind = NetworkKind.mobile;
      await env.sync.setWifiOnly(false); // dispara una ejecución
      while (env.sync.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await env.sync.run();
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
    });

    test('por defecto es solo Wi-Fi y se persiste', () async {
      expect(await env.prefs.getWifiOnly(), isTrue);
      await env.prefs.setWifiOnly(false);
      expect(await SyncPreferences(env.store).getWifiOnly(), isFalse);
    });

    test('sin red -> offline y nada se pierde', () async {
      await env.addItem('a');
      env.net.kind = NetworkKind.none;
      await env.sync.run();
      expect(env.sync.summary.value.phase, SyncPhase.offline);
      expect((await env.queue.all()).length, greaterThan(0));
      env.net.kind = NetworkKind.wifi;
      await env.sync.run();
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
    });

    test('networkKindFrom traduce connectivity_plus', () {
      expect(networkKindFrom([]), NetworkKind.none);
      expect(networkKindFrom([ConnectivityResult.none]), NetworkKind.none);
      expect(networkKindFrom([ConnectivityResult.mobile]), NetworkKind.mobile);
      expect(
        networkKindFrom([ConnectivityResult.mobile, ConnectivityResult.wifi]),
        NetworkKind.wifi,
      );
      expect(networkKindFrom([ConnectivityResult.ethernet]), NetworkKind.wifi);
    });

    test(
      'al volver Wi-Fi se reanuda sola; al pasar a datos se detiene',
      () async {
        await env.addItem('a', size: 400 * 1024);
        env.cloud.chunkDelay = const Duration(milliseconds: 20);
        await env.sync.start();
        final running = env.sync.run();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        env.net.set(NetworkKind.mobile); // wifiOnly por defecto
        await running;
        expect(
          (await env.items.getItem('a'))!.syncStatus,
          SyncStatus.pendiente,
        );
        expect(env.cloud.count, 0);

        env.cloud.chunkDelay = Duration.zero;
        env.net.set(NetworkKind.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
      },
    );
  });

  group('reanudación', () {
    test('items en subiendo vuelven a pendiente tras reinicio', () async {
      await env.addItem('a', status: SyncStatus.subiendo);
      final now = env.now;
      await env.queue.enqueue('a', SyncJobKind.file, now: now);
      final job = (await env.queue.find('a', SyncJobKind.file))!;
      await env.queue.markUploading(job.id);

      // "Reinicio": servicio nuevo sobre la misma BD.
      env.sync.dispose();
      env.sync = env.newService();
      await env.sync.run();
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
      expect(await env.queue.all(), isEmpty);
    });

    test('resetStuck devuelve subiendo a pendiente', () async {
      await env.queue.enqueue('x', SyncJobKind.file, now: 1);
      final j = (await env.queue.find('x', SyncJobKind.file))!;
      await env.queue.markUploading(j.id);
      expect(await env.queue.resetStuck(), 1);
      expect(
        (await env.queue.find('x', SyncJobKind.file))!.state,
        SyncJobState.pendiente,
      );
    });

    test(
      'fallo de red a mitad: queda pendiente sin gastar intentos y se reanuda',
      () async {
        await env.addItem('a', size: 300 * 1024);
        await env.addItem('b', size: 100 * 1024);
        env.cloud.failAfterBytes = 128 * 1024;
        await env.sync.run();
        expect(env.sync.summary.value.phase, SyncPhase.offline);
        final job = (await env.queue.find('a', SyncJobKind.file))!;
        expect(job.state, SyncJobState.pendiente);
        expect(job.attempts, 0);
        expect(
          (await env.items.getItem('a'))!.syncStatus,
          SyncStatus.pendiente,
        );

        await env.sync.run();
        expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
        expect((await env.items.getItem('b'))!.syncStatus, SyncStatus.enNube);
        // Sin duplicados en la nube.
        expect(env.cloud.names.where((n) => n == 'a.vault').length, 1);
      },
    );

    test('sin sesión de Google -> needsSignIn y no sube', () async {
      await env.addItem('a');
      env.cloud.email = null;
      await env.sync.run();
      expect(env.sync.summary.value.phase, SyncPhase.needsSignIn);
      expect(env.cloud.uploadCalls, 0);
    });

    test('401 a mitad -> needsSignIn sin contar intento', () async {
      await env.addItem('a');
      env.cloud.failure = (op) =>
          op == 'upload' ? const CloudNotAuthenticatedException() : null;
      await env.sync.run();
      expect(env.sync.summary.value.phase, SyncPhase.needsSignIn);
      final job = (await env.queue.find('a', SyncJobKind.file))!;
      expect(job.attempts, 0);
      expect(job.state, SyncJobState.pendiente);
    });
  });

  group('worker único y cancelación', () {
    test('dos run() simultáneos: un solo worker', () async {
      await env.addItem('a', size: 300 * 1024);
      await env.addItem('b', size: 300 * 1024);
      env.cloud.chunkDelay = const Duration(milliseconds: 5);
      await Future.wait([env.sync.run(), env.sync.run(), env.sync.run()]);
      expect(env.cloud.maxConcurrentUploads, 1);
      expect(
        env.cloud.uploadedNames.where((n) => n.endsWith('.vault')).length,
        2,
      );
    });

    test('cancel() al bloquear detiene la subida sin perder estado', () async {
      await env.addItem('a', size: 600 * 1024);
      env.cloud.chunkDelay = const Duration(milliseconds: 20);
      final running = env.sync.run();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      env.sync.cancel();
      await running;
      expect(env.cloud.count, 0);
      final item = (await env.items.getItem('a'))!;
      expect(item.syncStatus, SyncStatus.pendiente);
      final job = (await env.queue.find('a', SyncJobKind.file))!;
      expect(job.state, SyncJobState.pendiente);
      expect(job.attempts, 0);

      env.cloud.chunkDelay = Duration.zero;
      await env.sync.run();
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
    });

    test('con la bóveda bloqueada no hace nada', () async {
      await env.addItem('a');
      env.session.clear();
      await env.sync.run();
      expect(env.cloud.uploadCalls, 0);
    });
  });

  group('cola persistente', () {
    test('sobrevive a cerrar y reabrir la BD', () async {
      await env.queue.enqueue('x', SyncJobKind.file, now: 5);
      await env.queue.enqueue('y', SyncJobKind.thumb, now: 6);
      final j = (await env.queue.find('x', SyncJobKind.file))!;
      await env.queue.markPending(
        j.id,
        attempts: 3,
        nextAttemptAt: 99,
        lastError: 'boom',
      );
      await env.vdb.close();

      final vdb2 = env.newDb();
      final q2 = SyncQueueRepository(dbProvider: () => vdb2.database);
      final all = await q2.all();
      expect(all.length, 2);
      final x = all.firstWhere((e) => e.itemId == 'x');
      expect(x.attempts, 3);
      expect(x.nextAttemptAt, 99);
      expect(x.lastError, 'boom');
      // enqueue es idempotente.
      expect(await q2.enqueue('x', SyncJobKind.file, now: 7), isFalse);
      await vdb2.close();
    });

    test('esquema v4 incluye sync_queue', () async {
      final db = await env.vdb.database;
      final cols = await db.rawQuery('PRAGMA table_info(sync_queue)');
      expect(
        cols.map((c) => c['name']),
        containsAll([
          'id',
          'itemId',
          'kind',
          'attempts',
          'nextAttemptAt',
          'lastError',
          'createdAt',
        ]),
      );
      expect(VaultSchema.version, 5);
    });

    test('items borrados mientras están en cola se descartan', () async {
      await env.addItem('a');
      await env.queue.enqueue('a', SyncJobKind.file, now: 1);
      await env.items.deleteItem('a');
      await env.sync.run();
      expect(await env.queue.all(), isEmpty);
    });

    test('archivo local ausente -> error permanente visible', () async {
      await env.addItem('a');
      await AppPaths.resolve(AppPaths.vaultRelativePath('a')).delete();
      await env.sync.run();
      final job = (await env.queue.find('a', SyncJobKind.file))!;
      expect(job.state, SyncJobState.error);
      expect(job.lastError, contains('local'));
    });
  });

  group('cloudVerifier', () {
    test(
      'true solo con en_nube + driveFileId + MD5/tamaño verificados',
      () async {
        final pending = await env.addItem('a');
        expect(await env.sync.cloudVerifier(pending), isFalse); // pendiente

        await env.sync.run();
        final ok = (await env.items.getItem('a'))!;
        expect(await env.sync.cloudVerifier(ok), isTrue);

        // Copia remota alterada -> false.
        env.cloud.tamper(ok.driveFileId!);
        expect(await env.sync.cloudVerifier(ok), isFalse);
      },
    );

    test('false si la copia remota desapareció', () async {
      await env.addItem('a');
      await env.sync.run();
      final ok = (await env.items.getItem('a'))!;
      env.cloud.remove(ok.driveFileId!);
      expect(await env.sync.cloudVerifier(ok), isFalse);
    });

    test('false si la copia local cambió o faltan datos verificados', () async {
      await env.addItem('a');
      await env.sync.run();
      final ok = (await env.items.getItem('a'))!;
      await AppPaths.resolve(
        AppPaths.vaultRelativePath('a'),
      ).writeAsBytes([1, 2, 3]);
      expect(await env.sync.cloudVerifier(ok), isFalse);

      // en_nube fabricado a mano, sin MD5/tamaño: no cuenta.
      await env.addItem('b');
      await env.items.updateSyncStatus(
        'b',
        SyncStatus.enNube,
        driveFileId: 'fake',
      );
      expect(
        await env.sync.cloudVerifier((await env.items.getItem('b'))!),
        isFalse,
      );
    });

    test('false si la red falla', () async {
      await env.addItem('a');
      await env.sync.run();
      final ok = (await env.items.getItem('a'))!;
      env.cloud.failure = (op) => const CloudNoNetworkException();
      expect(await env.sync.cloudVerifier(ok), isFalse);
    });
  });

  group('respaldos', () {
    late Uint8List dek;
    late String code;
    late String backupJson;

    setUp(() async {
      dek = Uint8List.fromList(List.generate(32, (i) => 200 - i * 3));
      final svc = KeyRecoveryService(kdfParams: fastKdf);
      code = svc.generateRecoveryCode();
      backupJson = (await svc.createBackup(dek, code)).toJsonString();
      env.recoveryJson = backupJson;
    });

    test(
      'sube recovery_backup.json una sola vez (y de nuevo si cambia)',
      () async {
        await env.sync.run();
        expect(env.cloud.bytesOf('recovery_backup.json'), isNotNull);
        expect(
          utf8.decode(env.cloud.bytesOf('recovery_backup.json')!),
          backupJson,
        );
        final uploads = env.cloud.uploadedNames
            .where((n) => n == 'recovery_backup.json')
            .length;
        expect(uploads, 1);

        await env.sync.run(); // sin cambios: no re-sube
        expect(
          env.cloud.uploadedNames
              .where((n) => n == 'recovery_backup.json')
              .length,
          1,
        );

        // Cambia el respaldo -> reemplaza el mismo archivo.
        final svc = KeyRecoveryService(kdfParams: fastKdf);
        env.recoveryJson = (await svc.createBackup(
          dek,
          svc.generateRecoveryCode(),
        )).toJsonString();
        await env.sync.run();
        expect(
          env.cloud.names.where((n) => n == 'recovery_backup.json').length,
          1,
        );
        expect(
          utf8.decode(env.cloud.bytesOf('recovery_backup.json')!),
          env.recoveryJson,
        );
      },
    );

    test('el blob no contiene la DEK, subllaves ni el código', () async {
      await env.sync.run();
      final blob = utf8.decode(env.cloud.bytesOf('recovery_backup.json')!);
      final keys = await KeyHierarchy.fromDek(dek);
      String hex(List<int> b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      final secrets = <List<int>>[
        dek,
        keys.sqlcipher.bytes,
        keys.files.bytes,
        keys.thumbs.bytes,
      ];
      for (final s in secrets) {
        expect(blob.contains(base64Encode(s)), isFalse);
        expect(blob.contains(hex(s)), isFalse);
      }
      expect(blob.contains(code), isFalse);
      expect(blob.toLowerCase().contains('pin'), isFalse);
      // Solo los campos esperados de una envoltura.
      final map = jsonDecode(blob) as Map<String, dynamic>;
      expect(map.keys.toSet(), {
        'type',
        'v',
        'purpose',
        'kdf',
        'salt',
        'nonce',
        'ct',
        'mac',
      });
      expect(map['purpose'], 'recovery');
    });

    test(
      'el respaldo de AuthController es seguro de subir y nunca es la envoltura del PIN',
      () async {
        final store = InMemorySecureStore();
        final auth = AuthController(
          storage: store,
          biometricStore: FakeBiometricKeyStore(),
          kdfParams: fastKdf,
          session: VaultSession.create(),
        );
        await auth.createVault('123456');
        final exported = (await auth.exportRecoveryBackup())!;
        expect(() => assertRecoveryBackupSafe(exported), returnsNormally);
        // La envoltura del PIN se rechaza.
        final pinEnvelope = store.data[AuthController.pinEnvelopeKey]!;
        expect(
          () => assertRecoveryBackupSafe(pinEnvelope),
          throwsFormatException,
        );
      },
    );

    test('assertRecoveryBackupSafe rechaza campos extra y basura', () {
      final map = jsonDecode(backupJson) as Map<String, dynamic>;
      map['dek'] = base64Encode(dek);
      expect(() => assertRecoveryBackupSafe(jsonEncode(map)), throwsStateError);
      expect(() => assertRecoveryBackupSafe('no json'), throwsFormatException);
    });

    test('un respaldo no válido nunca se sube (error visible)', () async {
      env.recoveryJson = '{"type":"otra-cosa"}';
      await env.sync.run();
      expect(env.cloud.bytesOf('recovery_backup.json'), isNull);
      final job = (await env.queue.find(
        SyncQueueRepository.noItem,
        SyncJobKind.recoveryBackup,
      ))!;
      expect(job.attempts, greaterThan(0));
    });

    test(
      'snapshot de la BD se sube tras subir archivos, se reemplaza y se borra',
      () async {
        env.recoveryJson = null;
        env.sync.dispose();
        env.sync = env.newService(snapshotEveryUploads: 1);
        await env.addItem('a');
        await env.sync.run();
        final first = env.cloud.byName('vault_db.snapshot')!;
        expect(first.size, 5000);
        expect(File('${env.dbPath}.snapshot').existsSync(), isFalse);

        await env.addItem('b');
        await env.sync.run();
        expect(env.snapshotsTaken, 2);
        final second = env.cloud.byName('vault_db.snapshot')!;
        expect(second.id, first.id); // versión única, sobrescrita
        expect(
          env.cloud.names.where((n) => n == 'vault_db.snapshot').length,
          1,
        );
      },
    );

    test('no hay snapshot si no se subió nada', () async {
      env.recoveryJson = null;
      await env.sync.run();
      expect(env.snapshotsTaken, 0);
    });
  });

  group('cuenta', () {
    test(
      'signOut limpia la cuenta; signIn la restaura y consulta cuota',
      () async {
        await env.sync.start();
        expect(env.sync.summary.value.accountEmail, 'test@example.com');
        await env.sync.signOut();
        expect(env.sync.summary.value.accountEmail, isNull);
        expect(env.sync.summary.value.phase, SyncPhase.needsSignIn);
        await env.sync.signIn();
        expect(env.sync.summary.value.accountEmail, 'test@example.com');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(env.sync.quota.value!.usedBytes, 100);
        expect(env.sync.quota.value!.fraction, closeTo(0.1, 1e-9));
      },
    );

    test('error de inicio de sesión queda como mensaje', () async {
      env.cloud.failure = (op) => op == 'signin'
          ? const CloudSignInFailedException('DEVELOPER_ERROR', code: '10')
          : null;
      await expectLater(
        env.sync.signIn(),
        throwsA(isA<CloudSignInFailedException>()),
      );
      expect(env.sync.summary.value.lastMessage, 'DEVELOPER_ERROR');
    });
  });

  group('mapCloudError', () {
    drive.DetailedApiRequestError err(int status, [String? reason]) =>
        drive.DetailedApiRequestError(
          status,
          'm',
          errors: [if (reason != null) _detail(reason)],
        );

    test('clasifica estados HTTP en errores tipados', () {
      expect(mapCloudError(err(401)), isA<CloudNotAuthenticatedException>());
      expect(
        mapCloudError(err(403, 'storageQuotaExceeded')),
        isA<CloudQuotaExceededException>(),
      );
      final rate = mapCloudError(err(403, 'rateLimitExceeded'));
      expect(rate, isA<CloudForbiddenException>());
      expect((rate as CloudForbiddenException).rateLimited, isTrue);
      final forbidden = mapCloudError(err(403, 'insufficientPermissions'));
      expect((forbidden as CloudForbiddenException).rateLimited, isFalse);
      expect(mapCloudError(err(404)), isA<CloudNotFoundException>());
      expect(mapCloudError(err(429)), isA<CloudForbiddenException>());
      final s = mapCloudError(err(503));
      expect(s, isA<CloudServerException>());
      expect(s.isTransient, isTrue);
      expect(
        mapCloudError(const SocketException('x')),
        isA<CloudNoNetworkException>(),
      );
      expect(mapCloudError(StateError('x')), isA<CloudUnknownException>());
      final dev = mapCloudError(
        PlatformException(code: 'sign_in_failed', message: 'e1.d: 10: '),
      );
      expect(dev, isA<CloudSignInFailedException>());
      expect(dev.message, contains('código 10'));
      expect(
        mapCloudError(PlatformException(code: 'network_error')),
        isA<CloudNoNetworkException>(),
      );
    });
  });

  group('GoogleConfig', () {
    test('clientId solo en iOS y solo si está configurado', () {
      expect(GoogleConfig.clientIdFor(isIOS: false, ios: 'x'), isNull);
      expect(GoogleConfig.clientIdFor(isIOS: true, ios: ''), isNull);
      expect(GoogleConfig.clientIdFor(isIOS: true, ios: 'abc'), 'abc');
    });

    test('serverClientId solo si no está vacío', () {
      expect(GoogleConfig.serverClientIdFor(web: ''), isNull);
      expect(GoogleConfig.serverClientIdFor(web: 'w'), 'w');
    });

    test('por defecto son los IDs públicos del proyecto', () {
      expect(GoogleConfig.iosClientId, endsWith('.apps.googleusercontent.com'));
      expect(GoogleConfig.webClientId, endsWith('.apps.googleusercontent.com'));
    });
  });
}

ApiRequestErrorDetail _detail(String reason) =>
    ApiRequestErrorDetail(reason: reason);
