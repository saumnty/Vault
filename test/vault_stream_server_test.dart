import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/core/streaming/vault_stream_server.dart';

Uint8List _bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

class _Resp {
  _Resp(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final Uint8List body;
  String? h(String name) => headers.value(name);
}

void main() {
  late Directory tmp;
  final key = SecretKey(List.generate(32, (i) => i * 7 + 3));
  final format = VaultFileFormat();
  final client = HttpClient();
  final servers = <VaultStreamServer>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('stream_test');
  });
  tearDown(() async {
    for (final s in servers) {
      await s.close();
    }
    servers.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });
  tearDownAll(() => client.close(force: true));

  Future<File> encrypt(Uint8List plain, {int blockSize = 4096}) async {
    final src = File('${tmp.path}/plain.bin');
    await src.writeAsBytes(plain);
    final dest = File('${tmp.path}/v.vault');
    await format.encryptFile(src, dest, key, blockSize: blockSize);
    await src.delete();
    return dest;
  }

  Future<VaultStreamServer> serve(
    File vault, {
    String mime = 'video/mp4',
    void Function(VaultCryptoException)? onFail,
    int maxConnections = 8,
  }) async {
    final reader = await VaultFileReader.open(vault, key);
    final s = await VaultStreamServer.start(
      reader: reader,
      mimeType: mime,
      onIntegrityFailure: onFail,
      maxConnections: maxConnections,
    );
    servers.add(s);
    return s;
  }

  Future<_Resp> get(
    Uri uri, {
    String? range,
    String method = 'GET',
    String? host,
  }) async {
    final req = await client.openUrl(method, uri);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    if (host != null) req.headers.set(HttpHeaders.hostHeader, host);
    final res = await req.close();
    final b = BytesBuilder(copy: false);
    await for (final c in res) {
      b.add(c);
    }
    return _Resp(res.statusCode, res.headers, b.takeBytes());
  }

  /// Petición HTTP cruda (para cabeceras Host arbitrarias o ausentes).
  Future<String> raw(int port, String request) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    s.add(utf8.encode(request));
    await s.flush();
    final out = await s
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 5));
    s.destroy();
    return latin1.decode(out);
  }

  group('parseRangeHeader', () {
    test('formas válidas, recorte, sufijo e ignorables', () {
      PartialRange p(String h, int t) =>
          parseRangeHeader(h, t) as PartialRange;
      expect(parseRangeHeader(null, 10), isA<FullRange>());
      expect(p('bytes=0-0', 10).length, 1);
      expect(p('bytes=2-5', 10).start, 2);
      expect(p('bytes=2-5', 10).endInclusive, 5);
      expect(p('bytes=4-', 10).endInclusive, 9);
      expect(p('bytes=4-999', 10).endInclusive, 9); // recorte
      expect(p('bytes=-3', 10).start, 7);
      expect(p('bytes=-30', 10).start, 0); // sufijo mayor que el total
      expect(p('BYTES = 1-2', 10).length, 2);
      expect(parseRangeHeader('bytes=10-', 10), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=10-20', 10), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=-0', 10), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=0-', 0), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=-5', 0), isA<UnsatisfiableRange>());
      // Ignorables -> 200 completo.
      for (final h in [
        'bytes=5-2',
        'bytes=0-1,4-5',
        'items=0-1',
        'bytes=a-b',
        'bytes=-',
        'bytes=1-2-3',
        'bytes=9999999999999999999999-',
        'garbage',
      ]) {
        expect(parseRangeHeader(h, 10), isA<FullRange>(), reason: h);
      }
    });

    test('videoMimeType y extensión', () {
      expect(videoMimeType(mimeType: 'video/webm', fileName: 'x.mp4'),
          'video/webm');
      expect(videoMimeType(mimeType: 'application/octet-stream',
          fileName: 'A.MOV'), 'video/quicktime');
      expect(videoMimeType(fileName: 'clip.m4v'), 'video/mp4');
      expect(videoMimeType(fileName: 'sin_extension'), 'video/mp4');
      expect(videoExtensionFor('video/quicktime'), '.mov');
      expect(videoExtensionFor('video/mp4'), '.mp4');
    });
  });

  group('respuestas', () {
    const bs = 4096;
    late Uint8List plain;
    late VaultStreamServer server;

    setUp(() async {
      plain = _bytes(bs * 10 + 777, 3); // 11 bloques, último parcial
      server = await serve(await encrypt(plain));
    });

    test('URL: solo loopback, puerto efímero, token >= 256 bits', () async {
      expect(server.uri.host, '127.0.0.1');
      expect(server.port, greaterThan(0));
      final seg = server.uri.pathSegments;
      expect(seg.first, 'v');
      final token = seg.last.replaceAll('.mp4', '');
      expect(base64Url.decode(base64Url.normalize(token)).length, 32);
      final other = await serve(await encrypt(_bytes(10)));
      expect(other.uri.path, isNot(server.uri.path));
      expect(other.port, isNot(server.port));
    });

    test('200 sin Range: contenido idéntico (sha256) y cabeceras', () async {
      final r = await get(server.uri);
      expect(r.status, 200);
      expect(hash.sha256.convert(r.body), hash.sha256.convert(plain));
      expect(r.h('content-length'), '${plain.length}');
      expect(r.h('accept-ranges'), 'bytes');
      expect(r.h('content-type'), 'video/mp4');
      expect(r.h('cache-control'), 'no-store');
      expect(r.h('x-content-type-options'), 'nosniff');
      expect(r.h('access-control-allow-origin'), isNull);
      expect(r.h('x-frame-options'), isNull);
      expect(server.stats.responses200, 1);
    });

    Future<void> expectRange(String header, int start, int endIncl) async {
      final r = await get(server.uri, range: header);
      expect(r.status, 206, reason: header);
      expect(r.h('content-range'), 'bytes $start-$endIncl/${plain.length}');
      expect(r.h('content-length'), '${endIncl - start + 1}');
      expect(r.h('accept-ranges'), 'bytes');
      expect(r.body, plain.sublist(start, endIncl + 1), reason: header);
    }

    test('206: inicio, medio, final, sufijo, abierto y recorte', () async {
      final last = plain.length - 1;
      await expectRange('bytes=0-1', 0, 1); // sondeo típico de AVPlayer
      await expectRange('bytes=0-99', 0, 99);
      await expectRange('bytes=5000-5100', 5000, 5100); // medio de un bloque
      await expectRange('bytes=${last - 50}-$last', last - 50, last);
      await expectRange('bytes=-1000', plain.length - 1000, last);
      await expectRange('bytes=${bs * 7}-', bs * 7, last);
      await expectRange('bytes=10-99999999', 10, last);
      await expectRange('bytes=-99999999', 0, last);
      await expectRange('bytes=$last-$last', last, last);
    });

    test('206: rangos que cruzan límites de bloque', () async {
      await expectRange('bytes=${bs - 1}-$bs', bs - 1, bs); // 2 bloques, 2 B
      await expectRange('bytes=${bs - 10}-${3 * bs + 5}', bs - 10, 3 * bs + 5);
      await expectRange('bytes=$bs-${2 * bs - 1}', bs, 2 * bs - 1); // exacto
      await expectRange(
        'bytes=${9 * bs + 1}-${plain.length - 1}',
        9 * bs + 1,
        plain.length - 1,
      ); // penúltimo + final parcial
    });

    test('416 fuera de rango con Content-Range bytes */total', () async {
      for (final h in [
        'bytes=${plain.length}-',
        'bytes=${plain.length + 5}-${plain.length + 9}',
        'bytes=-0',
      ]) {
        final r = await get(server.uri, range: h);
        expect(r.status, 416, reason: h);
        expect(r.h('content-range'), 'bytes */${plain.length}');
        expect(r.body, isEmpty);
      }
      expect(server.stats.responses416, 3);
    });

    test('Range inválido o múltiple se ignora: 200 completo', () async {
      final r = await get(server.uri, range: 'bytes=0-1,5-9');
      expect(r.status, 200);
      expect(r.body.length, plain.length);
    });

    test('HEAD: cabeceras sin cuerpo (con y sin Range)', () async {
      var r = await get(server.uri, method: 'HEAD');
      expect(r.status, 200);
      expect(r.h('content-length'), '${plain.length}');
      expect(r.h('content-type'), 'video/mp4');
      expect(r.body, isEmpty);
      r = await get(server.uri, method: 'HEAD', range: 'bytes=100-199');
      expect(r.status, 206);
      expect(r.h('content-range'), 'bytes 100-199/${plain.length}');
      expect(r.h('content-length'), '100');
      expect(r.body, isEmpty);
      expect(server.stats.blocksDecrypted, 0); // HEAD no descifra
    });

    test('token/ruta incorrectos -> 404 vacío e indistinguible', () async {
      final good = server.uri;
      final token = good.pathSegments.last;
      final flipped =
          (token[0] == 'A' ? 'B' : 'A') + token.substring(1); // 1 carácter
      final variants = [
        good.replace(path: '/v/$flipped'),
        good.replace(path: '/v/${token.substring(0, token.length - 1)}'),
        good.replace(path: '/v/${token}x'),
        good.replace(path: '/v/'),
        good.replace(path: '/'),
        good.replace(path: '/favicon.ico'),
        good.replace(query: 'a=1'),
      ];
      final bodies = <String>{};
      for (final u in variants) {
        final r = await get(u);
        expect(r.status, 404, reason: '$u');
        expect(r.body, isEmpty);
        expect(r.h('content-type'), isNull);
        bodies.add('${r.status}${r.h('content-length')}');
      }
      expect(bodies.length, 1);
      expect(server.stats.blocksDecrypted, 0);
    });

    test('Host distinto de 127.0.0.1/localhost:<puerto> -> 403', () async {
      final port = server.port;
      final path = server.uri.path;
      for (final host in [
        'evil.example:$port',
        '127.0.0.1',
        '127.0.0.1:${port + 1}',
        '192.168.1.5:$port',
        '[::1]:$port',
      ]) {
        final r = await get(server.uri, host: host);
        expect(r.status, 403, reason: host);
        expect(r.body, isEmpty);
      }
      // Sin Host en absoluto (HTTP/1.0 crudo).
      final noHost = await raw(port, 'GET $path HTTP/1.0\r\n\r\n');
      expect(noHost, matches(RegExp(r'^HTTP/1\.[01] 403')));
      // localhost:<puerto> sí vale.
      final ok = await raw(
        port,
        'GET $path HTTP/1.1\r\nHost: localhost:$port\r\n'
        'Range: bytes=0-3\r\nConnection: close\r\n\r\n',
      );
      expect(ok, startsWith('HTTP/1.1 206'));
    });

    test('métodos distintos de GET/HEAD -> 405', () async {
      for (final m in ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
        final r = await get(server.uri, method: m);
        expect(r.status, 405, reason: m);
        expect(r.body, isEmpty);
      }
    });

    test('peticiones concurrentes devuelven cada una su rango', () async {
      final rng = Random(5);
      final futures = <Future<void>>[];
      for (var i = 0; i < 6; i++) {
        final a = rng.nextInt(plain.length);
        final b = min(plain.length - 1, a + rng.nextInt(3 * bs));
        futures.add(
          get(server.uri, range: 'bytes=$a-$b').then((r) {
            expect(r.status, 206);
            expect(r.body, plain.sublist(a, b + 1));
          }),
        );
      }
      futures.add(
        get(server.uri).then((r) => expect(r.body.length, plain.length)),
      );
      await Future.wait(futures);
      expect(server.stats.maxActiveBodies, greaterThan(1));
    });

    test('tope de conexiones simultáneas -> 503 sin cuerpo', () async {
      final s = await serve(
        await encrypt(_bytes(64 * 64 * 1024, 2), blockSize: 64 * 1024),
        maxConnections: 1,
      );
      final req = await client.getUrl(s.uri);
      final res = await req.close(); // primera respuesta, sin leer
      expect(res.statusCode, 200);
      final r = await get(s.uri, range: 'bytes=0-9');
      expect(r.status, 503);
      expect(r.body, isEmpty);
      (await res.detachSocket()).destroy();
    });

    test('archivo vacío: 200 con 0 bytes y 416 para cualquier rango', () async {
      final s = await serve(await encrypt(Uint8List(0)));
      final r = await get(s.uri);
      expect(r.status, 200);
      expect(r.body, isEmpty);
      expect(r.h('content-length'), '0');
      expect((await get(s.uri, range: 'bytes=0-')).status, 416);
    });
  });

  group('cierre', () {
    test('release: deja de aceptar y corta conexiones activas', () async {
      final plain = _bytes(64 * 64 * 1024, 4); // 4 MiB, bloques de 64 KiB
      final s = await serve(await encrypt(plain, blockSize: 64 * 1024));
      final req = await client.getUrl(s.uri);
      final res = await req.close();
      var got = 0;
      var paused = false;
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = res.listen(
        (c) {
          got += c.length;
          if (!paused && got >= 64 * 1024) {
            paused = true;
            sub.pause(); // lector lento
          }
        },
        onError: (Object e) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await s.close();
      sub.resume();
      await done.future.timeout(const Duration(seconds: 5));
      expect(got, lessThan(plain.length)); // respuesta cortada
      expect(s.isClosed, isTrue);
      // Ya no escucha: conexión rechazada.
      await expectLater(
        client.getUrl(s.uri).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
      expect(VaultStreamServer.liveCount, 0);
    });

    test('bloquear la bóveda (VaultSession.clear) cierra el servidor', () async {
      final session = VaultSession.create();
      session.addOnClear(VaultStreamServer.closeAllNow);
      final s = await serve(await encrypt(_bytes(5000)));
      expect((await get(s.uri, range: 'bytes=0-9')).status, 206);
      session.clear();
      expect(s.isClosed, isTrue); // síncrono
      await expectLater(
        client.getUrl(s.uri).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
    });

    test('close es idempotente y cierra el lector', () async {
      final reader = await VaultFileReader.open(
        await encrypt(_bytes(100)),
        key,
      );
      final s = await VaultStreamServer.start(
        reader: reader,
        mimeType: 'video/mp4',
      );
      await s.close();
      await s.close();
      await expectLater(reader.decryptBlock(0), throwsA(isA<StateError>()));
    });
  });

  group('integridad', () {
    const bs = 4096;

    Future<File> tampered(Uint8List plain, int blockIndex) async {
      final f = await encrypt(plain);
      final raw = await f.readAsBytes();
      final layout = VaultLayout.fromEncryptedLength(raw.length, bs);
      raw[layout.encryptedBlockOffset(blockIndex) + 40] ^= 0x01;
      await f.writeAsBytes(raw);
      return f;
    }

    test(
      'bloque alterado a mitad: se corta la respuesta y no se entrega '
      'nada del bloque malo; luego 500',
      () async {
        final plain = _bytes(bs * 12, 6);
        VaultCryptoException? failure;
        final s = await serve(await tampered(plain, 5), onFail: (e) => failure = e);

        final req = await client.getUrl(s.uri);
        final res = await req.close();
        expect(res.statusCode, 200);
        final b = BytesBuilder();
        Object? error;
        try {
          await for (final c in res) {
            b.add(c);
          }
        } on Object catch (e) {
          error = e;
        }
        final got = b.takeBytes();
        expect(error, isNotNull); // el cliente ve un fallo, no un fin limpio
        expect(got.length, lessThanOrEqualTo(5 * bs));
        expect(got, plain.sublist(0, got.length)); // solo datos auténticos
        expect(failure, isA<VaultAuthException>());
        expect(s.integrityFailure, isNotNull);
        expect(s.stats.integrityFailures, 1);

        // Envenenado: todo responde 500 sin cuerpo, incluso rangos buenos.
        final again = await get(s.uri, range: 'bytes=0-9');
        expect(again.status, 500);
        expect(again.body, isEmpty);
      },
    );

    test('rango que empieza en el bloque alterado -> 500 sin cuerpo', () async {
      final plain = _bytes(bs * 8, 7);
      final s = await serve(await tampered(plain, 3));
      final r = await get(s.uri, range: 'bytes=${3 * bs + 10}-${3 * bs + 20}');
      expect(r.status, 500);
      expect(r.body, isEmpty);
      expect(r.h('content-range'), isNull);
    });

    test('archivo truncado antes de abrir: el lector lo rechaza', () async {
      final f = await encrypt(_bytes(bs * 6, 8));
      final raw = await f.readAsBytes();
      // Quitar el último bloque completo (estructura válida, final falso).
      final layout = VaultLayout.fromEncryptedLength(raw.length, bs);
      await f.writeAsBytes(raw.sublist(0, layout.encryptedBlockOffset(5)));
      await expectLater(
        VaultFileReader.open(f, key),
        throwsA(isA<VaultCryptoException>()),
      );
      // Truncado a mitad de bloque.
      await f.writeAsBytes(raw.sublist(0, raw.length - 3));
      await expectLater(
        VaultFileReader.open(f, key),
        throwsA(isA<VaultCryptoException>()),
      );
    });

    test('archivo truncado DESPUÉS de abrir: no se sirve el tramo', () async {
      final plain = _bytes(bs * 6, 9);
      final f = await encrypt(plain);
      final s = await serve(f);
      final raf = await f.open(mode: FileMode.append);
      await raf.truncate(VaultHeader.length + 3 * (bs + 28) + 10);
      await raf.close();
      final r = await get(s.uri, range: 'bytes=${4 * bs}-');
      expect(r.status, 500);
      expect(r.body, isEmpty);
      // Lo anterior al corte también queda bloqueado (envenenado).
      expect((await get(s.uri, range: 'bytes=0-9')).status, 500);
    });
  });

  group('recursos', () {
    const bs = 64 * 1024;
    const blocks = 256; // 16 MiB

    late Uint8List plain;
    late VaultStreamServer server;
    setUp(() async {
      plain = _bytes(bs * blocks, 10);
      server = await serve(await encrypt(plain, blockSize: bs));
    });

    test('desconexión del cliente cancela la lectura/descifrado', () async {
      final req = await client.getUrl(server.uri);
      final res = await req.close();
      final sock = await res.detachSocket();
      sock.destroy(); // el cliente se va sin leer
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final after = server.stats.blocksDecrypted;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(server.stats.blocksDecrypted, after); // ya no avanza
      expect(after, lessThan(blocks ~/ 2));
      expect(server.stats.aborted, 1);
      expect(server.stats.activeBodies, 0);
    });

    test(
      'memoria acotada: con un cliente que no lee no se descifra todo y '
      'como mucho 2 bloques en claro a la vez',
      () async {
        final req = await client.getUrl(server.uri);
        final res = await req.close();
        var got = 0;
        var paused = false;
        late StreamSubscription<List<int>> sub;
        final done = Completer<void>();
        sub = res.listen(
          (c) {
            got += c.length;
            if (!paused && got > bs) {
              paused = true;
              sub.pause();
            }
          },
          onDone: done.complete,
          onError: (Object _) => done.complete(),
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        final decryptedWhilePaused = server.stats.blocksDecrypted;
        expect(decryptedWhilePaused, lessThan(blocks ~/ 2));
        expect(server.stats.maxLiveBlocks, lessThanOrEqualTo(2));
        sub.resume();
        await done.future;
        expect(got, plain.length);
        expect(server.stats.blocksDecrypted, blocks);
        expect(server.stats.maxLiveBlocks, lessThanOrEqualTo(2));
      },
    );

    test('NINGÚN byte en claro se escribe en disco', () async {
      Map<String, int> snapshot() => {
        for (final e in tmp.listSync(recursive: true))
          if (e is File) e.path: e.lengthSync(),
      };
      final before = snapshot();
      final sysBefore = Directory.systemTemp
          .listSync()
          .map((e) => e.path)
          .toSet();
      final r = await get(server.uri);
      expect(hash.sha256.convert(r.body), hash.sha256.convert(plain));
      await get(server.uri, range: 'bytes=${bs * 100}-${bs * 130}');
      expect(snapshot(), before); // solo el .vault, sin cambios
      final sysAfter = Directory.systemTemp
          .listSync()
          .map((e) => e.path)
          .toSet();
      final created = sysAfter.difference(sysBefore);
      // Ningún archivo nuevo en el temporal del sistema contiene el texto
      // en claro (otros procesos pueden crear cosas: se revisa contenido).
      final probe = plain.sublist(bs * 3, bs * 3 + 64);
      for (final path in created) {
        final f = File(path);
        if (!f.existsSync()) continue;
        final data = f.readAsBytesSync();
        expect(_contains(data, probe), isFalse, reason: path);
      }
    });
  });
}

bool _contains(Uint8List hay, Uint8List needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
