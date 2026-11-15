// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/vault_file_fetcher.dart';
import 'package:vault/features/vault/models/browser_entry.dart';
import 'package:vault/features/vault/vault_browser_controller.dart';
import 'package:vault/features/vault/vault_services.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';

import 'support/f6_env.dart';
import 'support/fake_video_platform.dart';

Uint8List _bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F6Env env;
  late PlainTempManager temp;
  late VaultMediaOpener opener;
  late FakeVideoPlayerPlatform platform;
  final progressLog = <MediaProgress>[];

  Directory plainDir() => AppPaths.tmpPlainDir;
  List<FileSystemEntity> leftovers() =>
      plainDir().existsSync() ? plainDir().listSync() : const [];

  setUp(() async {
    env = F6Env();
    await env.setUp();
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    temp = PlainTempManager(dirProvider: () => AppPaths.tmpPlainDir);
    opener = VaultMediaOpener(
      fetcher: env.fetcher,
      filesKey: () => env.session.filesKey,
      temp: temp,
      // Estas pruebas cubren el respaldo completo-primero (F6a); el streaming
      // (por defecto) se prueba en f6b_streaming_test.dart.
      streaming: false,
    );
    progressLog.clear();
  });
  tearDown(() => env.tearDown());

  group('PlainTempManager', () {
    test('release borra el temporal y es idempotente', () async {
      final f = temp.newTempFile(extension: '.mp4');
      await f.writeAsBytes([1, 2, 3]);
      expect(temp.activeCount, 1);
      await temp.release(f);
      await temp.release(f);
      expect(f.existsSync(), isFalse);
      expect(temp.activeCount, 0);
    });

    test(
      'purgeSync (bloqueo) borra todo, incluso archivos no registrados',
      () async {
        final a = temp.newTempFile()..writeAsBytesSync([1]);
        File('${plainDir().path}/huerfano.bin').writeAsBytesSync([2]);
        temp.purgeSync();
        expect(a.existsSync(), isFalse);
        expect(leftovers(), isEmpty);
      },
    );

    test(
      'sweep (arranque/desbloqueo) barre lo que dejó un cierre abrupto',
      () async {
        plainDir().createSync(recursive: true);
        for (var i = 0; i < 3; i++) {
          File('${plainDir().path}/viejo$i.mp4').writeAsBytesSync([i]);
        }
        // Un manager nuevo (proceso nuevo) no conoce esos archivos.
        final fresh = PlainTempManager(dirProvider: () => AppPaths.tmpPlainDir);
        expect(await fresh.sweep(), 3);
        expect(leftovers(), isEmpty);
      },
    );

    test('sweep no toca un temporal en uso por un visor vivo', () async {
      final live = temp.newTempFile()..writeAsBytesSync([1]);
      File('${plainDir().path}/otro.bin').writeAsBytesSync([2]);
      await temp.sweep();
      expect(live.existsSync(), isTrue);
      expect(File('${plainDir().path}/otro.bin').existsSync(), isFalse);
    });

    test('sweep sin carpeta no falla', () async {
      expect(await temp.sweep(), 0);
    });
  });

  group('video completo-primero (FullDecryptVideoSource)', () {
    test(
      'descifra TODO a tmp_plain, reproduce y borra al cerrar el visor',
      () async {
        final plain = _bytes(3 * 1024 * 1024 + 123);
        final item = await env.addCloudItem(
          'v',
          plain: plain,
          name: 'clip.mp4',
          mime: 'video/mp4',
        );
        final source = opener.videoSource(item) as FullDecryptVideoSource;
        final controller = await source.open(onProgress: progressLog.add);

        expect(controller.value.isInitialized, isTrue);
        final tmp = source.tempFile!;
        expect(tmp.path, contains(AppPaths.tmpPlainDirName));
        expect(tmp.path, endsWith('.mp4'));
        expect(await tmp.readAsBytes(), plain); // texto plano completo
        expect(platform.openedUris.single, contains(AppPaths.tmpPlainDirName));
        // Progreso de descifrado creciente que termina en 1.
        final dec = progressLog
            .where((p) => p.phase == MediaPhase.decrypting)
            .map((p) => p.fraction!)
            .toList();
        expect(dec.first, 0);
        expect(dec.last, 1);
        expect(dec, orderedEquals([...dec]..sort()));

        await source.release();
        expect(tmp.existsSync(), isFalse);
        expect(leftovers(), isEmpty);
        expect(platform.calls, contains('dispose'));
        await source.release(); // idempotente
      },
    );

    test(
      'al bloquear la app el temporal desaparece (VaultSession.addOnClear)',
      () async {
        env.session.addOnClear(temp.purgeSync);
        final item = await env.addCloudItem(
          'v',
          plain: _bytes(2 * 1024 * 1024),
          name: 'clip.mp4',
          mime: 'video/mp4',
        );
        final source = opener.videoSource(item) as FullDecryptVideoSource;
        await source.open();
        expect(source.tempFile!.existsSync(), isTrue);

        env.session.clear(); // bloqueo
        expect(leftovers(), isEmpty);
        await source.release();
      },
    );

    test(
      '.vault purgado: lo baja de Drive con verificación, reproduce y marca en_cache',
      () async {
        final plain = _bytes(1024 * 1024 + 7, 9);
        final item = await env.addCloudItem(
          'v',
          plain: plain,
          name: 'clip.mp4',
          mime: 'video/mp4',
          keepLocal: false,
          lastAccessedAt: 3,
        );
        expect(env.localFile('v').existsSync(), isFalse);
        final source = opener.videoSource(item) as FullDecryptVideoSource;
        final controller = await source.open(onProgress: progressLog.add);
        expect(controller.value.isInitialized, isTrue);
        expect(await source.tempFile!.readAsBytes(), plain);
        expect(
          progressLog.map((p) => p.phase),
          containsAllInOrder([MediaPhase.decrypting]),
        );
        // Quedó guardado en vault/ y marcado.
        expect(env.localFile('v').existsSync(), isTrue);
        final after = (await env.items.getItem('v'))!;
        expect(after.syncStatus, SyncStatus.enCache);
        expect(after.lastAccessedAt, env.now);
        await source.release();
        expect(leftovers(), isEmpty);
      },
    );

    test(
      'descarga con MD5 distinto -> error claro y nada queda en claro',
      () async {
        final item = await env.addCloudItem(
          'v',
          plain: _bytes(512 * 1024),
          name: 'clip.mp4',
          mime: 'video/mp4',
          keepLocal: false,
        );
        env.cloud.corruptContent(item.driveFileId!);
        final source = opener.videoSource(item);
        Object? error;
        try {
          await source.open();
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<VaultFetchVerificationException>());
        final d = describeMediaError(error!);
        expect(d.message, contains('no coincide'));
        expect(d.canRetry, isTrue);
        expect(leftovers(), isEmpty);
        expect(env.localFile('v').existsSync(), isFalse);
      },
    );

    test('sin red: mensaje claro y reintento posible', () async {
      final item = await env.addCloudItem(
        'v',
        plain: _bytes(512 * 1024),
        name: 'clip.mp4',
        mime: 'video/mp4',
        keepLocal: false,
      );
      var offline = true;
      env.cloud.failure = (op) =>
          op == 'bytes' && offline ? const CloudNoNetworkException() : null;
      Object? error;
      try {
        await opener.videoSource(item).open();
      } on Object catch (e) {
        error = e;
      }
      final d = describeMediaError(error!);
      expect(d.message, contains('Sin conexión'));
      expect(d.canRetry, isTrue);

      offline = false;
      final retry = opener.videoSource(item);
      await retry.open();
      await retry.release();
      expect(leftovers(), isEmpty);
    });

    test(
      'archivo alterado: falla la autenticación y se borra el temporal',
      () async {
        final item = await env.addCloudItem(
          'v',
          plain: _bytes(2 * 1024 * 1024),
          name: 'clip.mp4',
          mime: 'video/mp4',
        );
        final f = env.localFile('v');
        final raw = await f.readAsBytes();
        raw[raw.length ~/ 2] ^= 0xff;
        await f.writeAsBytes(raw);
        Object? error;
        try {
          await opener.videoSource(item).open();
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<VaultAuthException>());
        expect(describeMediaError(error!).canRetry, isFalse);
        expect(leftovers(), isEmpty);
      },
    );

    test('release durante la apertura cancela y no deja temporales', () async {
      final item = await env.addCloudItem(
        'v',
        plain: _bytes(4 * 1024 * 1024),
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      final source = opener.videoSource(item);
      final pending = source.open();
      final result = expectLater(pending, throwsA(isA<MediaOpenCancelled>()));
      await source.release();
      await result;
      expect(leftovers(), isEmpty);
    });

    test('bóveda bloqueada: no abre', () async {
      final item = await env.addCloudItem(
        'v',
        plain: _bytes(1024),
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      env.session.clear();
      await expectLater(
        opener.videoSource(item).open(),
        throwsA(isA<StateError>()),
      );
      expect(leftovers(), isEmpty);
    });
  });

  group('fotos: solo en memoria', () {
    test(
      'loadImage devuelve los bytes y NO escribe nada en claro en disco',
      () async {
        final plain = _bytes(300 * 1024, 4);
        final item = await env.addCloudItem('i', plain: plain);
        final out = await opener.loadImage(item);
        expect(out, plain);
        expect(leftovers(), isEmpty);
        // Tampoco aparece un archivo de texto plano junto al .vault.
        final names = AppPaths.vaultDir.listSync().map((e) => e.path).toList();
        expect(names.where((n) => !n.endsWith('.vault')), isEmpty);
      },
    );

    test(
      'foto purgada: se descarga de Drive, se verifica y se muestra',
      () async {
        final plain = _bytes(200 * 1024, 5);
        final item = await env.addCloudItem(
          'i',
          plain: plain,
          keepLocal: false,
        );
        final prog = <MediaProgress>[];
        expect(await opener.loadImage(item, onProgress: prog.add), plain);
        expect((await env.items.getItem('i'))!.syncStatus, SyncStatus.enCache);
      },
    );

    test('foto con MD5 de descarga distinto -> error', () async {
      final item = await env.addCloudItem(
        'i',
        plain: _bytes(2048),
        keepLocal: false,
      );
      env.cloud.corruptContent(item.driveFileId!);
      await expectLater(
        opener.loadImage(item),
        throwsA(isA<VaultFetchVerificationException>()),
      );
    });
  });

  group('borrar item = borrar también en Drive (controlador)', () {
    VaultServices services() => VaultServices(
      repository: env.items,
      importFile: ({required folderId, required deleteOriginal}) async => false,
      syncRunner: () async {},
      thumbnailLoader: (_) async => null,
      offlineToggler: (id, v) async => true,
      fileCleaner: (ids) async {
        for (final id in ids) {
          for (final rel in [
            AppPaths.vaultRelativePath(id),
            AppPaths.thumbRelativePath(id),
          ]) {
            final f = AppPaths.resolve(rel);
            if (f.existsSync()) f.deleteSync();
          }
          await env.queue.removeForItem(id);
        }
      },
      remoteDeleter: (targets) async {
        for (final t in targets) {
          await env.sync.enqueueRemoteDelete(
            t.itemId,
            driveFileId: t.driveFileId,
            thumbDriveFileId: t.thumbDriveFileId,
          );
        }
      },
    );

    test(
      'item: borra fila, archivos locales, cola de subida y encola el borrado remoto',
      () async {
        final item = await env.addCloudItem('a');
        final thumb = await env.cloud.uploadBytes(
          bytes: Uint8List.fromList([1, 2, 3]),
          name: 'a.thumb',
        );
        await env.items.setThumbDriveFileId('a', thumb.id);
        await env.queue.enqueue(
          'a',
          SyncJobKind.file,
          now: 1,
        ); // subida pendiente
        final c = VaultBrowserController(services: services(), folderId: null);
        await c.load();

        await c.delete([c.entries.single]);

        expect(await env.items.getItem('a'), isNull);
        expect(env.localFile('a').existsSync(), isFalse);
        expect(AppPaths.resolve('thumbs/a.thumb').existsSync(), isFalse);
        expect(await env.queue.find('a', SyncJobKind.file), isNull);
        final job = (await env.queue.find('a', SyncJobKind.deleteRemote))!;
        expect(job.payload, contains(item.driveFileId!));
        expect(job.payload, contains(thumb.id));

        await env.sync.run();
        expect(env.cloud.byName('a.vault'), isNull);
        expect(env.cloud.byName('a.thumb'), isNull);
        expect(await env.queue.all(), isEmpty);
        c.dispose();
      },
    );

    test('carpeta: recursivo, encola los remotos de todos los items', () async {
      await env.addFolder('f');
      await env.addFolder('g', parent: 'f');
      await env.addCloudItem('a', folderId: 'f');
      await env.addCloudItem('b', folderId: 'g');
      await env.addCloudItem('fuera');
      final c = VaultBrowserController(services: services(), folderId: null);
      await c.load();

      await c.delete([c.entries.whereType<FolderEntry>().single]);

      expect(await env.items.getItem('a'), isNull);
      expect(await env.items.getItem('b'), isNull);
      expect(await env.items.getFolder('g'), isNull);
      expect(await env.items.getItem('fuera'), isNotNull);
      expect(await env.queue.find('a', SyncJobKind.deleteRemote), isNotNull);
      expect(await env.queue.find('b', SyncJobKind.deleteRemote), isNotNull);
      expect(await env.queue.find('fuera', SyncJobKind.deleteRemote), isNull);

      await env.sync.run();
      expect(env.cloud.byName('a.vault'), isNull);
      expect(env.cloud.byName('b.vault'), isNull);
      expect(env.cloud.byName('fuera.vault'), isNotNull);
      c.dispose();
    });

    test(
      'sin conexión a internet: el borrado queda en cola y se completa luego',
      () async {
        await env.addCloudItem('a');
        final c = VaultBrowserController(services: services(), folderId: null);
        await c.load();
        env.cloud.failure = (op) => op == 'find' || op == 'delete'
            ? const CloudNoNetworkException()
            : null;
        await c.delete(c.entries);
        await env.sync.run();
        expect(await env.queue.find('a', SyncJobKind.deleteRemote), isNotNull);
        expect(env.cloud.byName('a.vault'), isNotNull);

        env.cloud.failure = null;
        await env.sync.run();
        expect(env.cloud.byName('a.vault'), isNull);
        c.dispose();
      },
    );
  });

  group('"sin conexión" desde el controlador', () {
    test('carpeta y archivo usan los togglers y recargan', () async {
      await env.addFolder('f');
      await env.addCloudItem('a', keepLocal: false);
      final services = VaultServices(
        repository: env.items,
        importFile: ({required folderId, required deleteOriginal}) async =>
            false,
        syncRunner: () async {},
        thumbnailLoader: (_) async => null,
        fileCleaner: (_) async {},
        offlineToggler: env.offline.setItemOffline,
        folderOfflineToggler: env.offline.setFolderOffline,
      );
      final c = VaultBrowserController(services: services, folderId: null);
      await c.load();
      final folder = c.entries.whereType<FolderEntry>().single;
      final file = c.entries.whereType<FileEntry>().single;
      expect(c.isOffline(folder), isFalse);

      expect(await c.setOffline([folder, file], true), 0);
      await env.offline.idle();
      await c.load();
      expect(c.isOffline(c.entries.whereType<FolderEntry>().single), isTrue);
      expect(c.isOffline(c.entries.whereType<FileEntry>().single), isTrue);
      expect(env.localFile('a').existsSync(), isTrue);

      await c.setOffline(c.entries, false);
      expect(c.isOffline(c.entries.whereType<FolderEntry>().single), isFalse);
      expect(env.localFile('a').existsSync(), isTrue); // no se borra
      c.dispose();
    });
  });
}
