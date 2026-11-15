import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/cache_manager.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';

import 'support/f6_env.dart';

const int kb = 1024;

void main() {
  late F6Env env;

  setUp(() async {
    env = F6Env();
    await env.setUp();
  });
  tearDown(() => env.tearDown());

  group('descarga desde Drive (VaultFileFetcher)', () {
    test(
      'baja, verifica tamaño+MD5, guarda en vault/ y marca en_cache',
      () async {
        await env.addCloudItem('a', keepLocal: false, lastAccessedAt: 5);
        expect(env.localFile('a').existsSync(), isFalse);
        final item = (await env.items.getItem('a'))!;

        final progress = <int>[];
        final file = await env.fetcher.ensureLocal(
          item,
          onProgress: (got, total) => progress.add(got),
        );

        expect(file.path, env.localFile('a').path);
        expect(file.existsSync(), isTrue);
        expect(File('${file.path}.part').existsSync(), isFalse);
        final after = (await env.items.getItem('a'))!;
        expect(after.syncStatus, SyncStatus.enCache);
        expect(after.lastAccessedAt, env.now); // actualizado
        expect(after.lastAccessedAt, isNot(5));
      },
    );

    test(
      'si ya está local no descarga, solo actualiza lastAccessedAt',
      () async {
        await env.addCloudItem('a', lastAccessedAt: 5);
        final item = (await env.items.getItem('a'))!;
        env.cloud.failure = (op) =>
            op == 'bytes' ? StateError('no debía bajar') : null;
        await env.fetcher.ensureLocal(item);
        expect((await env.items.getItem('a'))!.lastAccessedAt, env.now);
      },
    );

    test(
      'MD5 distinto -> error de verificación y no queda ni parcial ni copia',
      () async {
        await env.addCloudItem('a', keepLocal: false);
        final item = (await env.items.getItem('a'))!;
        // Corrupción remota con el MISMO tamaño: solo el MD5 lo delata.
        env.cloud.corruptContent(item.driveFileId!);
        await expectLater(
          env.fetcher.ensureLocal(item),
          throwsA(isA<VaultFetchVerificationException>()),
        );
        expect(env.localFile('a').existsSync(), isFalse);
        expect(File('${env.localFile('a').path}.part').existsSync(), isFalse);
        expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
      },
    );

    test('tamaño distinto -> error de verificación', () async {
      await env.addCloudItem('a', keepLocal: false);
      final item = (await env.items.getItem('a'))!;
      env.cloud.tamper(item.driveFileId!); // +1 byte y MD5 falso
      await expectLater(
        env.fetcher.ensureLocal(item),
        throwsA(
          isA<VaultFetchVerificationException>().having(
            (e) => e.detail,
            'detail',
            contains('tamaño'),
          ),
        ),
      );
      expect(env.localFile('a').existsSync(), isFalse);
    });

    test('sin red -> CloudNoNetworkException y se puede reintentar', () async {
      await env.addCloudItem('a', keepLocal: false);
      final item = (await env.items.getItem('a'))!;
      var fail = true;
      env.cloud.failure = (op) {
        if (op == 'bytes' && fail) return const CloudNoNetworkException();
        return null;
      };
      await expectLater(
        env.fetcher.ensureLocal(item),
        throwsA(isA<CloudNoNetworkException>()),
      );
      expect(env.localFile('a').existsSync(), isFalse);
      fail = false;
      await env.fetcher.ensureLocal(item);
      expect(env.localFile('a').existsSync(), isTrue);
    });

    test('item sin copia verificada y sin archivo -> no disponible', () async {
      await env.addCloudItem(
        'a',
        verified: false,
        keepLocal: false,
        status: SyncStatus.pendiente,
      );
      final item = (await env.items.getItem('a'))!;
      await expectLater(
        env.fetcher.ensureLocal(item),
        throwsA(isA<VaultFetchUnavailableException>()),
      );
    });

    test('item offline efectivo vuelve a sin_conexion al descargar', () async {
      await env.addFolder('f', offline: true);
      await env.addCloudItem('a', folderId: 'f', keepLocal: false);
      await env.fetcher.ensureLocal((await env.items.getItem('a'))!);
      expect(
        (await env.items.getItem('a'))!.syncStatus,
        SyncStatus.sinConexion,
      );
    });

    test('dos peticiones simultáneas comparten una descarga', () async {
      await env.addCloudItem('a', keepLocal: false);
      final item = (await env.items.getItem('a'))!;
      final f1 = env.fetcher.ensureLocal(item);
      final f2 = env.fetcher.ensureLocal(item);
      expect((await f1).path, (await f2).path);
    });
  });

  group('caché LRU (CacheManager)', () {
    Future<List<String>> statusOf(List<String> ids) async => [
      for (final id in ids) (await env.items.getItem(id))!.syncStatus.dbValue,
    ];

    test(
      'purga por lastAccessedAt ascendente hasta bajar del límite',
      () async {
        // Orden de inserción distinto del de uso.
        await env.addCloudItem('c', size: 100 * kb, lastAccessedAt: 30);
        await env.addCloudItem('a', size: 100 * kb, lastAccessedAt: 10);
        await env.addCloudItem('d', size: 100 * kb, lastAccessedAt: 40);
        await env.addCloudItem('b', size: 100 * kb, lastAccessedAt: 20);

        final evicted = await env.cache.enforce(maxBytes: 250 * kb);

        expect(evicted, ['a', 'b']); // los dos menos recientes (200 KB <= 250)
        expect(env.localFile('a').existsSync(), isFalse);
        expect(env.localFile('b').existsSync(), isFalse);
        expect(env.localFile('c').existsSync(), isTrue);
        expect(env.localFile('d').existsSync(), isTrue);
        expect(await statusOf(['a', 'b', 'c', 'd']), [
          'en_nube',
          'en_nube',
          'en_nube',
          'en_nube',
        ]);
        // La miniatura se conserva.
        expect(AppPaths.resolve('thumbs/a.thumb').existsSync(), isTrue);
      },
    );

    test('no hace nada si está bajo el límite', () async {
      await env.addCloudItem('a', size: 100 * kb, lastAccessedAt: 1);
      expect(await env.cache.enforce(maxBytes: 100 * kb), isEmpty);
      expect(env.localFile('a').existsSync(), isTrue);
    });

    test('sin lastAccessedAt se usa la fecha de creación', () async {
      await env.addCloudItem(
        'nuevo',
        size: 100 * kb,
        createdAt: '2026-03-01T00:00:00',
      );
      await env.addCloudItem(
        'viejo',
        size: 100 * kb,
        createdAt: '2025-01-01T00:00:00',
      );
      final evicted = await env.cache.enforce(maxBytes: 100 * kb);
      expect(evicted, ['viejo']);
    });

    test('nunca purga pendiente/subiendo/error ni sin verificar', () async {
      await env.addCloudItem(
        'pend',
        size: 100 * kb,
        lastAccessedAt: 1,
        status: SyncStatus.pendiente,
        verified: false,
      );
      await env.addCloudItem(
        'sub',
        size: 100 * kb,
        lastAccessedAt: 2,
        status: SyncStatus.subiendo,
        verified: false,
      );
      await env.addCloudItem(
        'err',
        size: 100 * kb,
        lastAccessedAt: 3,
        status: SyncStatus.error,
        verified: false,
      );
      // en_nube pero SIN verificar (sin md5/tamaño): tampoco.
      await env.addCloudItem(
        'nover',
        size: 100 * kb,
        lastAccessedAt: 4,
        verified: false,
      );
      await env.addCloudItem('ok', size: 100 * kb, lastAccessedAt: 99);

      final evicted = await env.cache.enforce(maxBytes: 0);

      expect(evicted, ['ok']);
      for (final id in ['pend', 'sub', 'err', 'nover']) {
        expect(env.localFile(id).existsSync(), isTrue, reason: id);
      }
      expect(await statusOf(['pend', 'sub', 'err']), [
        'pendiente',
        'subiendo',
        'error',
      ]);
    });

    test(
      'un item con driveFileId pero error con copia verificada tampoco se purga',
      () async {
        await env.addCloudItem(
          'e',
          size: 100 * kb,
          lastAccessedAt: 1,
          status: SyncStatus.error,
        );
        expect(await env.cache.enforce(maxBytes: 0), isEmpty);
        expect(env.localFile('e').existsSync(), isTrue);
      },
    );

    test('excluye offline propio y heredado de carpeta ancestra', () async {
      await env.addFolder('abuela', offline: true);
      await env.addFolder('madre', parent: 'abuela');
      await env.addFolder('libre');
      await env.addCloudItem(
        'propio',
        lastAccessedAt: 1,
        offline: true,
        status: SyncStatus.sinConexion,
      );
      await env.addCloudItem('heredado', folderId: 'madre', lastAccessedAt: 2);
      await env.addCloudItem('purgable', folderId: 'libre', lastAccessedAt: 3);
      await env.addCloudItem('raiz', lastAccessedAt: 4);

      final evicted = await env.cache.enforce(maxBytes: 0);

      expect(evicted, ['purgable', 'raiz']);
      expect(env.localFile('propio').existsSync(), isTrue);
      expect(env.localFile('heredado').existsSync(), isTrue);
    });

    test('los offline no cuentan contra el presupuesto', () async {
      await env.addCloudItem(
        'off',
        size: 400 * kb,
        lastAccessedAt: 1,
        offline: true,
        status: SyncStatus.sinConexion,
      );
      await env.addCloudItem('x', size: 100 * kb, lastAccessedAt: 2);
      // 500 KB en total pero solo 100 KB son purgables: límite de 150 KB basta.
      expect(await env.cache.enforce(maxBytes: 150 * kb), isEmpty);
      final s = await env.cache.stats();
      expect(s.cachedBytes, 100 * kb);
      expect(s.offlineCount, 1);
      expect(s.cachedCount, 1);
    });

    test(
      'límite por defecto 500 MB, persistido y aplicado al cambiarlo',
      () async {
        expect(await env.cache.getLimitBytes(), 500 * 1024 * 1024);
        await env.addCloudItem('a', size: 100 * kb, lastAccessedAt: 1);
        await env.addCloudItem('b', size: 100 * kb, lastAccessedAt: 2);
        final evicted = await env.cache.setLimitBytes(100 * kb + 50);
        expect(evicted, ['a']);
        // Persistido: otra instancia lee el mismo valor.
        final other = CachePreferences(env.store);
        expect(await other.getLimitBytes(), 100 * kb + 50);
        expect(() => other.setLimitBytes(-1), throwsArgumentError);
      },
    );

    test('purgado y reabierto: se vuelve a descargar de Drive', () async {
      await env.addCloudItem('a', size: 100 * kb, lastAccessedAt: 1);
      await env.cache.enforce(maxBytes: 0);
      expect(env.localFile('a').existsSync(), isFalse);
      final item = (await env.items.getItem('a'))!;
      expect(item.syncStatus, SyncStatus.enNube);
      await env.fetcher.ensureLocal(item);
      expect(env.localFile('a').existsSync(), isTrue);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enCache);
    });

    test('llamadas concurrentes se serializan sin errores', () async {
      for (var i = 0; i < 5; i++) {
        await env.addCloudItem('i$i', size: 50 * kb, lastAccessedAt: i);
      }
      final r = await Future.wait([
        env.cache.enforce(maxBytes: 100 * kb),
        env.cache.enforce(maxBytes: 100 * kb),
      ]);
      expect(r[0].length + r[1].length, 3);
    });
  });

  group('disponible sin conexión (OfflineService)', () {
    test('por archivo: descarga lo que falta y pasa a sin_conexion', () async {
      await env.addCloudItem('a', keepLocal: false);
      expect(await env.offline.setItemOffline('a', true), isTrue);
      await env.offline.idle();
      expect(env.localFile('a').existsSync(), isTrue);
      final i = (await env.items.getItem('a'))!;
      expect(i.isOffline, isTrue);
      expect(i.syncStatus, SyncStatus.sinConexion);
    });

    test('por carpeta: baja todo el árbol, incluidas subcarpetas', () async {
      await env.addFolder('f');
      await env.addFolder('g', parent: 'f');
      await env.addCloudItem('a', folderId: 'f', keepLocal: false);
      await env.addCloudItem('b', folderId: 'g', keepLocal: false);
      await env.addCloudItem('fuera', keepLocal: false);

      final seen = <double>[];
      env.offline.progress.addListener(
        () => seen.addAll(env.offline.progress.value.values),
      );
      await env.offline.setFolderOffline('f', true);
      await env.offline.idle();

      expect(env.localFile('a').existsSync(), isTrue);
      expect(env.localFile('b').existsSync(), isTrue);
      expect(env.localFile('fuera').existsSync(), isFalse);
      expect(
        (await env.items.getItem('b'))!.syncStatus,
        SyncStatus.sinConexion,
      );
      expect((await env.items.getItem('fuera'))!.syncStatus, SyncStatus.enNube);
      expect(seen, isNotEmpty); // hubo progreso por item
      expect(env.offline.progress.value, isEmpty); // y termina limpio
    });

    test('no se purga lo marcado y sigue disponible tras la purga', () async {
      await env.addFolder('f');
      await env.addCloudItem(
        'a',
        folderId: 'f',
        keepLocal: false,
        lastAccessedAt: 1,
      );
      await env.addCloudItem('otro', lastAccessedAt: 2);
      await env.offline.setFolderOffline('f', true);
      await env.offline.idle();
      final evicted = await env.cache.enforce(maxBytes: 0);
      expect(evicted, ['otro']);
      expect(env.localFile('a').existsSync(), isTrue);
    });

    test(
      'quitar sin conexión NO borra: pasa a en_cache y queda purgable',
      () async {
        await env.addFolder('f');
        await env.addCloudItem(
          'a',
          folderId: 'f',
          keepLocal: false,
          lastAccessedAt: 1,
        );
        await env.offline.setFolderOffline('f', true);
        await env.offline.idle();
        await env.offline.setFolderOffline('f', false);
        expect(env.localFile('a').existsSync(), isTrue);
        expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enCache);
        expect(await env.cache.enforce(maxBytes: 0), ['a']);
      },
    );

    test(
      'solo Wi-Fi: con datos móviles espera; al volver el Wi-Fi descarga',
      () async {
        await env.addCloudItem('a', keepLocal: false);
        env.offline.start();
        env.net.kind = NetworkKind.mobile; // solo-Wi-Fi por defecto
        await env.offline.setItemOffline('a', true);
        await env.offline.idle();
        expect(env.localFile('a').existsSync(), isFalse);

        env.net.set(NetworkKind.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await env.offline.idle();
        expect(env.localFile('a').existsSync(), isTrue);
      },
    );

    test('con solo-Wi-Fi apagado descarga también con datos móviles', () async {
      await env.syncPrefs.setWifiOnly(false);
      await env.addCloudItem('a', keepLocal: false);
      env.net.kind = NetworkKind.mobile;
      await env.offline.setItemOffline('a', true);
      await env.offline.idle();
      expect(env.localFile('a').existsSync(), isTrue);
    });

    test('sin red: no falla ni pierde la marca', () async {
      await env.addCloudItem('a', keepLocal: false);
      env.net.kind = NetworkKind.none;
      expect(await env.offline.setItemOffline('a', true), isTrue);
      await env.offline.idle();
      expect(env.localFile('a').existsSync(), isFalse);
      expect((await env.items.getItem('a'))!.isOffline, isTrue);
    });

    test(
      'un item pendiente de subir marcado offline no cambia de estado',
      () async {
        await env.addCloudItem(
          'p',
          verified: false,
          status: SyncStatus.pendiente,
        );
        await env.offline.setItemOffline('p', true);
        await env.offline.idle();
        final i = (await env.items.getItem('p'))!;
        expect(i.syncStatus, SyncStatus.pendiente); // se seguirá subiendo
        expect(i.isOffline, isTrue);
      },
    );

    test('un error de descarga (MD5) no rompe la cola y se anota', () async {
      await env.addCloudItem('mal', keepLocal: false);
      await env.addCloudItem('bien', keepLocal: false);
      env.cloud.corruptContent((await env.items.getItem('mal'))!.driveFileId!);
      await env.offline.setItemOffline('mal', true);
      await env.offline.setItemOffline('bien', true);
      await env.offline.idle();
      expect(env.localFile('mal').existsSync(), isFalse);
      expect(env.localFile('bien').existsSync(), isTrue);
      expect(
        env.offline.failures['mal'],
        isA<VaultFetchVerificationException>(),
      );
    });
  });

  group('borrado remoto (delete_remote)', () {
    test('encola, borra .vault y .thumb de Drive y vacía la cola', () async {
      await env.addCloudItem('a');
      final thumb = await env.cloud.uploadBytes(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'a.thumb',
      );
      final item = (await env.items.getItem('a'))!;
      await env.items.deleteItem('a'); // la fila ya no existe

      await env.sync.enqueueRemoteDelete(
        'a',
        driveFileId: item.driveFileId,
        thumbDriveFileId: thumb.id,
      );
      final job = (await env.queue.find('a', SyncJobKind.deleteRemote))!;
      expect(
        job.payload,
        contains(item.driveFileId!),
      ); // ids en la fila de cola

      await env.sync.run();
      expect(env.cloud.byName('a.vault'), isNull);
      expect(env.cloud.byName('a.thumb'), isNull);
      expect(await env.queue.all(), isEmpty);
    });

    test('un 404 cuenta como éxito', () async {
      await env.addCloudItem('a');
      final id = (await env.items.getItem('a'))!.driveFileId!;
      env.cloud.remove(id); // ya no existe en Drive
      await env.sync.enqueueRemoteDelete('a', driveFileId: id);
      await env.sync.run();
      expect(await env.queue.all(), isEmpty);
    });

    test(
      'si borrar falla (5xx) se reintenta con backoff y luego se completa',
      () async {
        await env.addCloudItem('a');
        final id = (await env.items.getItem('a'))!.driveFileId!;
        var failures = 1;
        env.cloud.failure = (op) {
          if (op == 'delete' && failures-- > 0) {
            return const CloudServerException(503);
          }
          return null;
        };
        await env.sync.enqueueRemoteDelete('a', driveFileId: id);
        await env.sync.run();
        var job = (await env.queue.find('a', SyncJobKind.deleteRemote))!;
        expect(job.attempts, 1);
        expect(job.state, SyncJobState.pendiente);
        expect(job.nextAttemptAt, greaterThan(env.now)); // backoff
        expect(env.cloud.byName('a.vault'), isNotNull);

        env.now += 60 * 60 * 1000;
        await env.sync.run();
        expect(await env.queue.all(), isEmpty);
        expect(env.cloud.byName('a.vault'), isNull);
      },
    );

    test('sin red se queda en la cola sin gastar intentos', () async {
      await env.addCloudItem('a');
      final id = (await env.items.getItem('a'))!.driveFileId!;
      env.net.kind = NetworkKind.none;
      await env.sync.enqueueRemoteDelete('a', driveFileId: id);
      await env.sync.run();
      final job = (await env.queue.find('a', SyncJobKind.deleteRemote))!;
      expect(job.attempts, 0);
      expect(env.cloud.byName('a.vault'), isNotNull);
      env.net.kind = NetworkKind.wifi;
      await env.sync.run();
      expect(await env.queue.all(), isEmpty);
    });

    test('sin ids (subida terminó después) también borra por nombre', () async {
      await env.cloud.uploadBytes(
        bytes: Uint8List.fromList([9, 9]),
        name: 'huerfano.vault',
      );
      await env.sync.enqueueRemoteDelete('huerfano');
      await env.sync.run();
      expect(env.cloud.byName('huerfano.vault'), isNull);
    });

    test(
      'removeForItem no quita el borrado remoto pero sí la subida',
      () async {
        await env.addCloudItem('a');
        await env.queue.enqueue('a', SyncJobKind.file, now: 1);
        await env.sync.enqueueRemoteDelete('a', driveFileId: 'x');
        await env.queue.removeForItem('a');
        expect(await env.queue.find('a', SyncJobKind.file), isNull);
        expect(await env.queue.find('a', SyncJobKind.deleteRemote), isNotNull);
      },
    );

    test('con bóveda bloqueada no toca la nube', () async {
      await env.addCloudItem('a');
      final id = (await env.items.getItem('a'))!.driveFileId!;
      await env.sync.enqueueRemoteDelete('a', driveFileId: id);
      env.session.clear();
      await env.sync.run();
      expect(env.cloud.byName('a.vault'), isNotNull);
    });
  });
}
