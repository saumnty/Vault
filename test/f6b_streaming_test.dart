// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/services/app_paths.dart';
import 'package:vault/core/services/plain_temp_manager.dart';
import 'package:vault/core/streaming/vault_stream_server.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/features/vault/viewer/media_opener.dart';

import 'support/f6_env.dart';
import 'support/fake_video_platform.dart';

Uint8List _bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

/// Lee [uri] como lo haría ExoPlayer al preparar: un sondeo con Range y,
/// opcionalmente, el recurso entero. Lanza si algo no es 2xx o se corta.
Future<Uint8List> _fetch(HttpClient client, Uri uri, {String? range}) async {
  final req = await client.getUrl(uri);
  if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
  final res = await req.close();
  if (res.statusCode != 200 && res.statusCode != 206) {
    await res.drain<void>();
    throw HttpException('status ${res.statusCode}');
  }
  final b = BytesBuilder(copy: false);
  await for (final c in res) {
    b.add(c);
  }
  final out = b.takeBytes();
  if (res.contentLength >= 0 && out.length != res.contentLength) {
    throw const HttpException('respuesta incompleta');
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // El binding de pruebas sustituye HttpClient por uno falso (todo 400): aquí
  // se necesita el cliente REAL de dart:io contra el servidor en loopback.
  HttpOverrides.global = null;
  late F6Env env;
  late PlainTempManager temp;
  late FakeVideoPlayerPlatform platform;
  final client = HttpClient();

  Directory plainDir() => AppPaths.tmpPlainDir;
  List<FileSystemEntity> plainLeftovers() =>
      plainDir().existsSync() ? plainDir().listSync() : const [];

  /// Todo archivo bajo el directorio de la app que NO sea un `.vault`, la
  /// BD o una miniatura cifrada (es decir: posible texto plano).
  List<String> suspiciousFiles() => env.tmp
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where(
        (p) =>
            !p.endsWith('.vault') &&
            !p.endsWith('.thumb') &&
            !p.contains('${Platform.pathSeparator}db${Platform.pathSeparator}'),
      )
      .toList();

  VaultMediaOpener makeOpener({Duration? timeout}) => VaultMediaOpener(
    fetcher: env.fetcher,
    filesKey: () => env.session.filesKey,
    temp: temp,
    session: env.session,
    streamInitTimeout: timeout ?? const Duration(seconds: 30),
  );

  setUp(() async {
    env = F6Env();
    await env.setUp();
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    temp = PlainTempManager(dirProvider: () => AppPaths.tmpPlainDir);
  });
  tearDown(() async {
    VaultStreamServer.closeAllNow();
    await env.tearDown();
  });
  tearDownAll(() => client.close(force: true));

  test('por defecto el visor usa streaming', () async {
    final item = await env.addCloudItem(
      'v',
      plain: _bytes(1000),
      name: 'clip.mp4',
      mime: 'video/mp4',
    );
    expect(makeOpener().videoSource(item), isA<StreamingVideoSource>());
    final legacy = VaultMediaOpener(
      fetcher: env.fetcher,
      filesKey: () => env.session.filesKey,
      streaming: false,
    );
    expect(legacy.videoSource(item), isA<FullDecryptVideoSource>());
  });

  test('streaming: URL loopback, contenido idéntico, NADA en claro en disco y '
      'release cierra el servidor', () async {
    final plain = _bytes(3 * 1024 * 1024 + 4321, 2);
    final item = await env.addCloudItem(
      'v',
      plain: plain,
      name: 'clip.mov',
      mime: 'video/quicktime',
    );
    final before = suspiciousFiles();
    final probes = <int>[];
    platform.onCreate = (ds) async {
      // Como ExoPlayer: sondeo inicial y luego un rango al final (moov).
      final uri = Uri.parse(ds.uri!);
      probes.add((await _fetch(client, uri, range: 'bytes=0-1')).length);
      probes.add((await _fetch(client, uri, range: 'bytes=-4096')).length);
    };
    final progress = <MediaProgress>[];
    final source = makeOpener().videoSource(item) as StreamingVideoSource;
    final controller = await source.open(onProgress: progress.add);

    expect(controller.value.isInitialized, isTrue);
    expect(source.usedFallback, isFalse);
    expect(probes, [2, 4096]);
    final uri = Uri.parse(platform.openedUris.single);
    expect(uri.scheme, 'http');
    expect(uri.host, '127.0.0.1');
    expect(uri.path, startsWith('/v/'));
    expect(uri.path, endsWith('.mov'));
    expect(source.server!.mimeType, 'video/quicktime');
    // Sin fase de descifrado: arranque inmediato.
    expect(progress.where((p) => p.phase == MediaPhase.decrypting), isEmpty);

    // El contenido servido es el original, bit a bit.
    final all = await _fetch(client, uri);
    expect(hash.sha256.convert(all), hash.sha256.convert(plain));
    final mid = await _fetch(client, uri, range: 'bytes=1048570-2097160');
    expect(mid, plain.sublist(1048570, 2097161));

    // Ni un byte en claro en disco: tmp_plain vacío y ningún archivo nuevo.
    expect(plainLeftovers(), isEmpty);
    expect(suspiciousFiles(), before);

    await source.release();
    expect(source.server, isNull);
    expect(VaultStreamServer.liveCount, 0);
    expect(platform.calls, contains('dispose'));
    await expectLater(
      client.getUrl(uri).then((r) => r.close()),
      throwsA(isA<SocketException>()),
    );
    await source.release(); // idempotente
  });

  test(
    '.vault purgado: baja de Drive con verificación y LUEGO hace streaming',
    () async {
      final plain = _bytes(1024 * 1024 + 99, 3);
      final item = await env.addCloudItem(
        'v',
        plain: plain,
        name: 'clip.mp4',
        mime: 'video/mp4',
        keepLocal: false,
      );
      expect(env.localFile('v').existsSync(), isFalse);
      final progress = <MediaProgress>[];
      final source = makeOpener().videoSource(item) as StreamingVideoSource;
      await source.open(onProgress: progress.add);
      expect(progress.where((p) => p.phase == MediaPhase.decrypting), isEmpty);
      expect(env.localFile('v').existsSync(), isTrue);
      expect((await env.items.getItem('v'))!.syncStatus, SyncStatus.enCache);
      final all = await _fetch(client, source.server!.uri);
      expect(all, plain);
      expect(plainLeftovers(), isEmpty);
      await source.release();
    },
  );

  test('descarga con MD5 distinto: error, sin caída ni temporales', () async {
    final item = await env.addCloudItem(
      'v',
      plain: _bytes(4096),
      name: 'clip.mp4',
      mime: 'video/mp4',
      keepLocal: false,
    );
    env.cloud.corruptContent(item.driveFileId!);
    final source = makeOpener().videoSource(item) as StreamingVideoSource;
    await expectLater(
      source.open(),
      throwsA(isA<Exception>().having((e) => '$e', 'e', contains('MD5'))),
    );
    expect(source.usedFallback, isFalse);
    expect(plainLeftovers(), isEmpty);
    expect(VaultStreamServer.liveCount, 0);
  });

  test(
    'la purga LRU no borra el .vault mientras se reproduce; tras liberar sí',
    () async {
      final plain = _bytes(2 * 1024 * 1024, 11);
      final item = await env.addCloudItem(
        'v',
        plain: plain,
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      final opener = VaultMediaOpener(
        fetcher: env.fetcher,
        filesKey: () => env.session.filesKey,
        temp: temp,
        session: env.session,
        markInUse: env.cache.markInUse,
        releaseInUse: env.cache.releaseInUse,
      );
      final source = opener.videoSource(item) as StreamingVideoSource;
      await source.open();
      expect(env.cache.isInUse('v'), isTrue);
      expect(await env.cache.enforce(maxBytes: 0), isEmpty);
      expect(env.localFile('v').existsSync(), isTrue);
      expect(await _fetch(client, source.server!.uri), plain);

      await source.release();
      expect(env.cache.isInUse('v'), isFalse);
      expect(await env.cache.enforce(maxBytes: 0), ['v']);
      expect(env.localFile('v').existsSync(), isFalse);
    },
  );

  test(
    'bloquear la bóveda corta el servidor con una lectura en curso',
    () async {
      env.session.addOnClear(VaultStreamServer.closeAllNow);
      final plain = _bytes(8 * 1024 * 1024, 4);
      final item = await env.addCloudItem(
        'v',
        plain: plain,
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      final source = makeOpener().videoSource(item) as StreamingVideoSource;
      await source.open();
      final uri = source.server!.uri;
      final req = await client.getUrl(uri);
      final res = await req.close();
      var got = 0;
      var paused = false;
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = res.listen(
        (c) {
          got += c.length;
          if (!paused) {
            paused = true;
            sub.pause();
          }
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      env.session.clear(); // bloqueo
      expect(source.server!.isClosed, isTrue);
      sub.resume();
      await done.future.timeout(const Duration(seconds: 5));
      expect(got, lessThan(plain.length));
      await expectLater(
        client.getUrl(uri).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
      await source.release();
      expect(plainLeftovers(), isEmpty);
    },
  );

  group('caída a completo-primero', () {
    test('si el reproductor no puede usar la URL local (p. ej. cleartext '
        'bloqueado) cae a completo-primero y libera todo', () async {
      final plain = _bytes(2 * 1024 * 1024 + 5, 5);
      final item = await env.addCloudItem(
        'v',
        plain: plain,
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      platform.onCreate = (ds) async {
        if (ds.sourceType == DataSourceType.network) {
          throw PlatformException(
            code: 'VideoError',
            message: 'Cleartext HTTP traffic not permitted',
          );
        }
      };
      final progress = <MediaProgress>[];
      final source = makeOpener().videoSource(item) as StreamingVideoSource;
      final controller = await source.open(onProgress: progress.add);
      expect(controller.value.isInitialized, isTrue);
      expect(source.usedFallback, isTrue);
      expect(VaultStreamServer.liveCount, 0); // el servidor ya se cerró
      expect(platform.openedUris.first, startsWith('http://127.0.0.1:'));
      expect(platform.openedUris.last, contains(AppPaths.tmpPlainDirName));
      expect(
        progress.where((p) => p.phase == MediaPhase.decrypting),
        isNotEmpty,
      );
      expect(await source.fallback!.tempFile!.readAsBytes(), plain);

      await source.release();
      expect(plainLeftovers(), isEmpty);
    });

    test('timeout del reproductor -> completo-primero', () async {
      final item = await env.addCloudItem(
        'v',
        plain: _bytes(10000, 6),
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      final never = Completer<void>();
      platform.onCreate = (ds) async {
        if (ds.sourceType == DataSourceType.network) await never.future;
      };
      final source =
          makeOpener(
                timeout: const Duration(milliseconds: 200),
              ).videoSource(item)
              as StreamingVideoSource;
      final c = await source.open();
      expect(c.value.isInitialized, isTrue);
      expect(source.usedFallback, isTrue);
      expect(VaultStreamServer.liveCount, 0);
      await source.release();
      expect(plainLeftovers(), isEmpty);
    });

    test(
      'archivo alterado: NO cae a completo-primero; error "dañado"',
      () async {
        final plain = _bytes(6 * 1024 * 1024, 7);
        final item = await env.addCloudItem(
          'v',
          plain: plain,
          name: 'clip.mp4',
          mime: 'video/mp4',
        );
        final f = env.localFile('v');
        final raw = await f.readAsBytes();
        final layout = VaultLayout.fromEncryptedLength(
          raw.length,
          VaultHeader.defaultBlockSize,
        );
        raw[layout.encryptedBlockOffset(2) + 100] ^= 0x80; // bloque intermedio
        await f.writeAsBytes(raw);
        final received = <int>[];
        platform.onCreate = (ds) async {
          // ExoPlayer leyendo de corrido: la respuesta se corta en el bloque 2.
          final req = await client.getUrl(Uri.parse(ds.uri!));
          final res = await req.close();
          await for (final c in res) {
            received.addAll(c);
          }
        };
        final source = makeOpener().videoSource(item) as StreamingVideoSource;
        Object? error;
        try {
          await source.open();
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<VaultAuthException>());
        final msg = describeMediaError(error!);
        expect(msg.message, contains('dañado'));
        expect(msg.canRetry, isFalse);
        expect(source.usedFallback, isFalse);
        // Solo llegaron bytes auténticos (los 2 primeros bloques como mucho).
        expect(received.length, lessThanOrEqualTo(2 * 1024 * 1024));
        expect(received, plain.sublist(0, received.length));
        expect(VaultStreamServer.liveCount, 0);
        expect(plainLeftovers(), isEmpty);
      },
    );

    test('archivo truncado: error de formato, sin caída', () async {
      final item = await env.addCloudItem(
        'v',
        plain: _bytes(3 * 1024 * 1024, 8),
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      final f = env.localFile('v');
      final raw = await f.readAsBytes();
      await f.writeAsBytes(raw.sublist(0, raw.length - 1000));
      final source = makeOpener().videoSource(item) as StreamingVideoSource;
      await expectLater(source.open(), throwsA(isA<VaultCryptoException>()));
      expect(source.usedFallback, isFalse);
      expect(platform.openedUris, isEmpty); // ni siquiera llegó al reproductor
      expect(plainLeftovers(), isEmpty);
    });

    test('bóveda bloqueada: StateError, sin caída', () async {
      final item = await env.addCloudItem(
        'v',
        plain: _bytes(1000),
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      env.session.clear();
      final source = makeOpener().videoSource(item) as StreamingVideoSource;
      await expectLater(source.open(), throwsA(isA<StateError>()));
      expect(source.usedFallback, isFalse);
      expect(VaultStreamServer.liveCount, 0);
    });
  });

  test('release durante la apertura: cancela y cierra el servidor', () async {
    final item = await env.addCloudItem(
      'v',
      plain: _bytes(1024 * 1024, 9),
      name: 'clip.mp4',
      mime: 'video/mp4',
    );
    final gate = Completer<void>();
    platform.onCreate = (_) => gate.future;
    final source = makeOpener().videoSource(item) as StreamingVideoSource;
    final pending = source.open();
    final result = expectLater(pending, throwsA(isA<MediaOpenCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(VaultStreamServer.liveCount, 1);
    await source.release();
    gate.complete();
    await result;
    expect(VaultStreamServer.liveCount, 0);
    expect(source.usedFallback, isFalse);
    expect(plainLeftovers(), isEmpty);
  });

  test(
    'integridad durante la reproducción: playbackFailure lo explica',
    () async {
      final plain = _bytes(4 * 1024 * 1024, 10);
      final item = await env.addCloudItem(
        'v',
        plain: plain,
        name: 'clip.mp4',
        mime: 'video/mp4',
      );
      final f = env.localFile('v');
      final raw = await f.readAsBytes();
      final layout = VaultLayout.fromEncryptedLength(
        raw.length,
        VaultHeader.defaultBlockSize,
      );
      raw[layout.encryptedBlockOffset(1) + 50] ^= 0x01;
      await f.writeAsBytes(raw);
      final source = makeOpener().videoSource(item) as StreamingVideoSource;
      await source.open(); // el reproductor falso no lee nada al iniciar
      expect(source.playbackFailure, isNull);
      // Más tarde el reproductor pide el bloque alterado.
      await expectLater(
        _fetch(client, source.server!.uri, range: 'bytes=1048576-'),
        throwsA(isA<HttpException>()),
      );
      expect(source.playbackFailure, isA<VaultAuthException>());
      expect(
        describeMediaError(source.playbackFailure!).message,
        contains('dañado'),
      );
      await source.release();
    },
  );
}
