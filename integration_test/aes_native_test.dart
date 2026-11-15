import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vault/core/crypto/aes_gcm_backend.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/streaming/vault_stream_server.dart';

/// AES-GCM nativo (cryptography_flutter) vs Dart en emulador/dispositivo:
/// compatibilidad bit a bit, semántica de errores y velocidad.
///   flutter test integration_test/aes_native_test.dart -d emulator-5554
/// (El benchmark vive aquí, no en lib/.)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final rng = Random(20261115);
  Uint8List bytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));
  String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  Uint8List unhex(String h) => Uint8List.fromList([
    for (var i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ]);
  // ignore: avoid_print
  void log(String s) => print('AES-BENCH $s');

  final dart = DartAesGcmBackend();
  final native = NativeAesGcmBackend();

  setUpAll(configureCryptography);
  tearDown(() => AesGcmBackend.current = null);

  test('el backend de plataforma usa el nativo', () async {
    expect(native.isAvailable, isTrue);
    final def = AesGcmBackend.platformDefault();
    expect(def, isA<FallbackAesGcmBackend>());
    final f = def as FallbackAesGcmBackend;
    final key = SecretKeyData(bytes(32));
    final box = await f.encrypt(bytes(4096), secretKey: key, nonce: bytes(12));
    expect(f.lastUsed, 'native');
    await f.decrypt(box, secretKey: key);
    expect(f.lastUsed, 'native');
    expect(f.primaryBroken, isFalse);
    // Envoltura de DEK (32 B): por debajo del umbral, Dart.
    await f.encrypt(bytes(32), secretKey: key, nonce: bytes(12));
    expect(f.lastUsed, 'dart');
  });

  test('vector GCM Test Case 16 en nativo', () async {
    final key = SecretKeyData(
      unhex('feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308'),
    );
    final box = await native.encrypt(
      unhex(
        'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72'
        '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39',
      ),
      secretKey: key,
      nonce: unhex('cafebabefacedbaddecaf888'),
      aad: unhex('feedfacedeadbeeffeedfacedeadbeefabaddad2'),
    );
    expect(
      hex(box.cipherText),
      '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa'
      '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662',
    );
    expect(hex(box.mac.bytes), '76fc6ece0f4e1768cddf8853bb2d551b');
  });

  test('cruzado nativo ↔ Dart: mismos bytes y descifrado mutuo', () async {
    for (final n in [
      0, 1, 15, 16, 17, 31, 1000, 1023, 1024, 4096, 65537, //
      1024 * 1024, 1024 * 1024 + 5, 3 * 1024 * 1024 + 1,
    ]) {
      final key = SecretKeyData(bytes(32));
      final nonce = bytes(12);
      final aad = bytes(33);
      final plain = bytes(n);
      final a = await native.encrypt(
        plain,
        secretKey: key,
        nonce: nonce,
        aad: aad,
      );
      final b = await dart.encrypt(
        plain,
        secretKey: key,
        nonce: nonce,
        aad: aad,
      );
      expect(a.cipherText, b.cipherText, reason: 'ct n=$n');
      expect(a.mac.bytes, b.mac.bytes, reason: 'tag n=$n');
      expect(await dart.decrypt(a, secretKey: key, aad: aad), plain);
      expect(await native.decrypt(b, secretKey: key, aad: aad), plain);
    }
  });

  test(
    'tag/AAD/llave incorrectos: SecretBoxAuthenticationError en ambos',
    () async {
      final key = SecretKeyData(bytes(32));
      final nonce = bytes(12);
      final plain = bytes(5000);
      final box = await dart.encrypt(plain, secretKey: key, nonce: nonce);
      final ct = Uint8List.fromList(box.cipherText)..[10] ^= 1;
      final cases = <String, (SecretBox, SecretKey, List<int>)>{
        'ct alterado': (
          SecretBox(ct, nonce: nonce, mac: box.mac),
          key,
          const [],
        ),
        'tag alterado': (
          SecretBox(
            box.cipherText,
            nonce: nonce,
            mac: Mac(List<int>.from(box.mac.bytes)..[15] ^= 0x80),
          ),
          key,
          const [],
        ),
        'aad distinta': (box, key, const [1, 2, 3]),
        'otra llave': (box, SecretKeyData(bytes(32)), const []),
      };
      for (final e in cases.entries) {
        final (b, k, aad) = e.value;
        for (final backend in <AesGcmBackend>[
          dart,
          native,
          FallbackAesGcmBackend(primary: native, fallback: dart),
        ]) {
          await expectLater(
            backend.decrypt(b, secretKey: k, aad: aad),
            throwsA(isA<SecretBoxAuthenticationError>()),
            reason: '${e.key} / ${backend.name}',
          );
        }
      }
    },
  );

  test('.vault v2: nativo y Dart producen el mismo archivo; alteración → '
      'VaultAuthException', () async {
    final key = SecretKeyData(bytes(32));
    final plain = bytes(2 * 1024 * 1024 + 777);
    final fNative = FallbackAesGcmBackend(primary: native, fallback: dart);
    final encN = await VaultFileFormat(
      random: Random(7),
      backend: fNative,
    ).encryptBytes(plain, key);
    // El bloque final (777 B) queda bajo el umbral y va por Dart; los dos
    // primeros (1 MiB) por el nativo. Con umbral 0, todo nativo:
    final allNative = FallbackAesGcmBackend(
      primary: native,
      fallback: dart,
      minNativeLength: 0,
    );
    final encAll = await VaultFileFormat(
      random: Random(7),
      backend: allNative,
    ).encryptBytes(plain, key);
    expect(allNative.lastUsed, 'native');
    expect(encAll, encN);
    final encD = await VaultFileFormat(
      random: Random(7),
      backend: dart,
    ).encryptBytes(plain, key);
    expect(encN, encD);
    expect(await VaultFileFormat(backend: dart).decryptBytes(encN, key), plain);
    expect(
      await VaultFileFormat(backend: fNative).decryptBytes(encD, key),
      plain,
    );
    final bad = Uint8List.fromList(encN)..[VaultHeader.length + 100] ^= 4;
    await expectLater(
      VaultFileFormat(backend: fNative).decryptBytes(bad, key),
      throwsA(isA<VaultAuthException>()),
    );
    expect(fNative.primaryBroken, isFalse);

    // Truncado (quitar el bloque final).
    final layout = VaultLayout.forPlaintext(plain.length, 1024 * 1024);
    final truncated = Uint8List.sublistView(
      encN,
      0,
      layout.encryptedBlockOffset(layout.blockCount - 1),
    );
    await expectLater(
      VaultFileFormat(backend: fNative).decryptBytes(truncated, key),
      throwsA(isA<VaultAuthException>()),
    );
  });

  test('descifrados concurrentes (como la prelectura del servidor)', () async {
    final key = SecretKeyData(bytes(32));
    final plain = bytes(1024 * 1024);
    final boxes = [
      for (var i = 0; i < 8; i++)
        await native.encrypt(plain, secretKey: key, nonce: bytes(12)),
    ];
    final outs = await Future.wait([
      for (final b in boxes) native.decrypt(b, secretKey: key),
    ]);
    for (final o in outs) {
      expect(o, plain);
    }
  });

  test(
    'benchmark: bloques de 1 MiB, archivo de 25 MB y bloqueo del hilo UI',
    () async {
      final key = SecretKeyData(bytes(32));
      const mib = 1024 * 1024;
      final plain = bytes(mib);
      final header = VaultHeader.generate();

      Future<void> bench(String name, AesGcmBackend b, int blocks) async {
        final cipher = VaultBlockCipher(backend: b);
        // Calentamiento.
        final warm = await cipher.seal(header, 0, false, plain, key);
        await cipher.open(header, 0, false, warm, key);

        // Máximo tiempo sin que el bucle de eventos del isolate de UI atienda
        // un temporizador (≈ jank). Se cierra con el hueco final: si el
        // backend nunca cede (Dart: futuros ya completos), cuenta todo.
        var maxGap = 0;
        var last = DateTime.now().microsecondsSinceEpoch;
        final timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
          final now = DateTime.now().microsecondsSinceEpoch;
          maxGap = max(maxGap, now - last);
          last = now;
        });
        String stats(List<int> us) {
          us.sort();
          final total = us.fold<int>(0, (a, x) => a + x);
          final mibs = us.length / (total / 1e6);
          return '${mibs.toStringAsFixed(1)} MiB/s '
              '(mediana ${(us[us.length ~/ 2] / 1000).toStringAsFixed(1)} ms, '
              'p90 ${(us[(us.length * 9) ~/ 10] / 1000).toStringAsFixed(1)} ms, '
              'max ${(us.last / 1000).toStringAsFixed(1)} ms por bloque)';
        }

        final sealed = <Uint8List>[];
        final enc = <int>[];
        for (var i = 0; i < blocks; i++) {
          final sw = Stopwatch()..start();
          sealed.add(await cipher.seal(header, i, false, plain, key));
          enc.add(sw.elapsedMicroseconds);
        }
        final dec = <int>[];
        for (var i = 0; i < blocks; i++) {
          final sw = Stopwatch()..start();
          final out = await cipher.open(header, i, false, sealed[i], key);
          dec.add(sw.elapsedMicroseconds);
          expect(out.length, mib);
        }
        maxGap = max(maxGap, DateTime.now().microsecondsSinceEpoch - last);
        timer.cancel();
        log(
          '$name n=$blocks cifrado ${stats(enc)}; descifrado ${stats(dec)}; '
          'maxBloqueoEventLoop ${(maxGap / 1000).round()} ms',
        );
      }

      await bench('dart', dart, 6);
      await bench('native', native, 64);
      await bench(
        'fallback(native)',
        FallbackAesGcmBackend(primary: native, fallback: dart),
        64,
      );

      // Archivo completo con E/S (≈ importación en Original de 24,9 MB).
      final dir = await getTemporaryDirectory();
      final src = File('${dir.path}/aes_bench_src.bin');
      final dst = File('${dir.path}/aes_bench_dst.vault');
      final out = File('${dir.path}/aes_bench_out.bin');
      final sink = src.openWrite();
      for (var i = 0; i < 24; i++) {
        sink.add(plain);
      }
      sink.add(bytes(783 * 1024));
      await sink.close();
      final size = await src.length();
      try {
        for (final (name, b) in <(String, AesGcmBackend)>[
          ('native', FallbackAesGcmBackend(primary: native, fallback: dart)),
          ('dart', dart),
        ]) {
          final fmt = VaultFileFormat(backend: b);
          final swE = Stopwatch()..start();
          await fmt.encryptFile(src, dst, key);
          swE.stop();
          final swD = Stopwatch()..start();
          await fmt.decryptFile(dst, out, key);
          swD.stop();
          expect(await out.length(), size);
          log(
            '$name archivo ${(size / mib).toStringAsFixed(1)} MiB: '
            'encryptFile ${swE.elapsedMilliseconds} ms, '
            'decryptFile ${swD.elapsedMilliseconds} ms',
          );
        }
      } finally {
        for (final f in [src, dst, out]) {
          if (await f.exists()) await f.delete();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'servidor loopback: 25 MB por HTTP con cada backend (sin ExoPlayer)',
    () async {
      final key = SecretKeyData(bytes(32));
      final dir = await getTemporaryDirectory();
      final src = File('${dir.path}/srv_src.bin');
      final vault = File('${dir.path}/srv.vault');
      final sink = src.openWrite();
      for (var i = 0; i < 24; i++) {
        sink.add(bytes(1024 * 1024));
      }
      sink.add(bytes(783 * 1024));
      await sink.close();
      await VaultFileFormat(
        backend: FallbackAesGcmBackend(primary: native, fallback: dart),
      ).encryptFile(src, vault, key);
      await src.delete();
      final client = HttpClient();
      try {
        for (final (name, b) in <(String, AesGcmBackend)>[
          ('native', FallbackAesGcmBackend(primary: native, fallback: dart)),
          ('dart', dart),
        ]) {
          AesGcmBackend.current = b;
          final reader = await VaultFileReader.open(vault, key);
          final server = await VaultStreamServer.start(
            reader: reader,
            mimeType: 'video/mp4',
          );
          try {
            final sw = Stopwatch()..start();
            final req = await client.getUrl(server.uri);
            final res = await req.close();
            var n = 0;
            var firstMiB = 0;
            await for (final chunk in res) {
              n += chunk.length;
              if (firstMiB == 0 && n >= 1024 * 1024) {
                firstMiB = sw.elapsedMilliseconds;
              }
            }
            sw.stop();
            expect(n, reader.plaintextLength);
            log(
              'servidor $name: ${(n / 1048576).toStringAsFixed(1)} MiB en '
              '${sw.elapsedMilliseconds} ms '
              '(${(n / 1048576 / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(1)} MiB/s, '
              'primer MiB a los $firstMiB ms)',
            );
          } finally {
            await server.close();
            AesGcmBackend.current = null;
          }
        }
      } finally {
        client.close(force: true);
        if (await vault.exists()) await vault.delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
