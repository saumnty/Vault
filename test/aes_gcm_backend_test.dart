import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/aes_gcm_backend.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/vault_file_format.dart';

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Backend "nativo" simulado: delega en Dart, cuenta llamadas y puede fallar.
class _FakePrimary implements AesGcmBackend {
  _FakePrimary({this.error, this.truncate = false});

  Object? error;
  bool truncate;
  int calls = 0;
  final _dart = DartAesGcmBackend();

  @override
  String get name => 'fake-native';

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> aad = const <int>[],
  }) async {
    calls++;
    if (error != null) throw error!;
    final box = await _dart.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );
    if (truncate) {
      return SecretBox(
        box.cipherText.sublist(0, box.cipherText.length - 1),
        nonce: box.nonce,
        mac: box.mac,
      );
    }
    return box;
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
  }) async {
    calls++;
    if (error != null) throw error!;
    final out = await _dart.decrypt(secretBox, secretKey: secretKey, aad: aad);
    return truncate ? out.sublist(0, max(0, out.length - 1)) : out;
  }
}

void main() {
  // AES-256-GCM, "The Galois/Counter Mode of Operation (GCM)" (McGrew &
  // Viega), Test Case 16: llave 256 bits, IV 96 bits, 60 B de texto, 20 B AAD.
  final kKey = _hex(
    'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308',
  );
  final kIv = _hex('cafebabefacedbaddecaf888');
  final kAad = _hex('feedfacedeadbeeffeedfacedeadbeefabaddad2');
  final kPlain = _hex(
    'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72'
    '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39',
  );
  const kCipher =
      '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa'
      '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662';
  const kTag = '76fc6ece0f4e1768cddf8853bb2d551b';

  tearDown(() => AesGcmBackend.current = null);

  group('vector conocido (GCM spec, Test Case 16)', () {
    test('DartAesGcmBackend', () async {
      final b = DartAesGcmBackend();
      final box = await b.encrypt(
        kPlain,
        secretKey: SecretKeyData(kKey),
        nonce: kIv,
        aad: kAad,
      );
      expect(_toHex(box.cipherText), kCipher);
      expect(_toHex(box.mac.bytes), kTag);
      final clear = await b.decrypt(
        box,
        secretKey: SecretKeyData(kKey),
        aad: kAad,
      );
      expect(clear, kPlain);
    });

    test('FallbackAesGcmBackend (umbral 0) da los mismos bytes', () async {
      final p = _FakePrimary();
      final b = FallbackAesGcmBackend(
        primary: p,
        fallback: DartAesGcmBackend(),
        minNativeLength: 0,
      );
      final box = await b.encrypt(
        kPlain,
        secretKey: SecretKeyData(kKey),
        nonce: kIv,
        aad: kAad,
      );
      expect(_toHex(box.cipherText), kCipher);
      expect(_toHex(box.mac.bytes), kTag);
      expect(b.lastUsed, 'fake-native');
    });
  });

  group('FallbackAesGcmBackend', () {
    final key = SecretKeyData(List<int>.generate(32, (i) => i));
    final nonce = Uint8List(12)..[0] = 7;
    final data = Uint8List.fromList(List<int>.generate(4096, (i) => i * 31));

    FallbackAesGcmBackend make(_FakePrimary p) =>
        FallbackAesGcmBackend(primary: p, fallback: DartAesGcmBackend());

    test('datos cortos (< umbral) no tocan el nativo', () async {
      final p = _FakePrimary();
      final b = make(p);
      await b.encrypt(Uint8List(32), secretKey: key, nonce: nonce);
      expect(p.calls, 0);
      expect(b.lastUsed, 'dart');
    });

    test(
      'fallo de plataforma → mismo resultado con Dart y nativo desactivado',
      () async {
        final ref = await DartAesGcmBackend().encrypt(
          data,
          secretKey: key,
          nonce: nonce,
        );
        final p = _FakePrimary(error: PlatformException(code: 'CAUGHT_ERROR'));
        final b = make(p);
        final box = await b.encrypt(data, secretKey: key, nonce: nonce);
        expect(box.cipherText, ref.cipherText);
        expect(box.mac, ref.mac);
        expect(b.primaryBroken, isTrue);
        expect(b.lastUsed, 'dart');
        final clear = await b.decrypt(box, secretKey: key);
        expect(clear, data);
        expect(p.calls, 1, reason: 'tras el fallo ya no se intenta el nativo');
      },
    );

    test('MissingPluginException también cae a Dart', () async {
      final p = _FakePrimary(error: MissingPluginException());
      final b = make(p);
      final box = await DartAesGcmBackend().encrypt(
        data,
        secretKey: key,
        nonce: nonce,
      );
      expect(await b.decrypt(box, secretKey: key), data);
      expect(b.primaryBroken, isTrue);
    });

    test('salida de longitud incorrecta del nativo → Dart', () async {
      final p = _FakePrimary(truncate: true);
      final b = make(p);
      final box = await b.encrypt(data, secretKey: key, nonce: nonce);
      expect(box.cipherText.length, data.length);
      expect(b.primaryBroken, isTrue);
    });

    test('tag inválido: SecretBoxAuthenticationError en ambos backends, '
        'sin reintentar ni desactivar el nativo', () async {
      final box = await DartAesGcmBackend().encrypt(
        data,
        secretKey: key,
        nonce: nonce,
      );
      final bad = SecretBox(
        box.cipherText,
        nonce: box.nonce,
        mac: Mac(List<int>.from(box.mac.bytes)..[0] ^= 1),
      );
      final p = _FakePrimary();
      final b = make(p);
      await expectLater(
        b.decrypt(bad, secretKey: key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      expect(p.calls, 1);
      expect(b.primaryBroken, isFalse);
      await expectLater(
        DartAesGcmBackend().decrypt(bad, secretKey: key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      // AAD distinta también.
      await expectLater(
        b.decrypt(box, secretKey: key, aad: [1]),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('tag de longitud incorrecta → SecretBoxAuthenticationError', () async {
      final b = make(_FakePrimary());
      await expectLater(
        b.decrypt(
          SecretBox(data, nonce: nonce, mac: Mac(Uint8List(8))),
          secretKey: key,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('llave destruida → StateError y el nativo sigue activo', () async {
      final p = _FakePrimary();
      final b = make(p);
      final k = SecretKeyData(List<int>.filled(32, 9));
      k.destroy();
      await expectLater(
        b.encrypt(data, secretKey: k, nonce: nonce),
        throwsA(isA<StateError>()),
      );
      expect(p.calls, 0);
      expect(b.primaryBroken, isFalse);
    });

    test('llave de longitud incorrecta → ArgumentError', () async {
      final b = make(_FakePrimary());
      await expectLater(
        b.encrypt(data, secretKey: SecretKeyData(Uint8List(16)), nonce: nonce),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'el nativo recibe una copia de la llave que se borra al terminar',
      () async {
        SecretKey? seen;
        final p = _CapturingPrimary((k) => seen = k);
        final b = FallbackAesGcmBackend(
          primary: p,
          fallback: DartAesGcmBackend(),
        );
        await b.encrypt(data, secretKey: key, nonce: nonce);
        expect(identical(seen, key), isFalse);
        expect((seen! as SecretKeyData).hasBeenDestroyed, isTrue);
        expect(key.hasBeenDestroyed, isFalse);
      },
    );
  });

  group('formato .vault v2 independiente del backend', () {
    final key = SecretKeyData(List<int>.generate(32, (i) => 200 - i));

    test('mismos bytes con Dart y con Fallback(nativo simulado)', () async {
      final plain = Uint8List.fromList(
        List<int>.generate(3 * 1024 + 17, (i) => (i * 7) & 0xff),
      );
      for (final size in [0, 1, 1024, 1025, plain.length]) {
        final p = Uint8List.sublistView(plain, 0, size);
        final a = await VaultFileFormat(
          random: Random(42),
          backend: DartAesGcmBackend(),
        ).encryptBytes(p, key, blockSize: 1024);
        final b = await VaultFileFormat(
          random: Random(42),
          backend: FallbackAesGcmBackend(
            primary: _FakePrimary(),
            fallback: DartAesGcmBackend(),
            minNativeLength: 0,
          ),
        ).encryptBytes(p, key, blockSize: 1024);
        expect(b, a, reason: 'tamaño $size');
      }
    });

    test(
      'bloque alterado → VaultAuthException con cualquier backend',
      () async {
        final enc = await VaultFileFormat(
          backend: DartAesGcmBackend(),
        ).encryptBytes(Uint8List(5000), key, blockSize: 2048);
        enc[VaultHeader.length + 40] ^= 0x01;
        for (final backend in <AesGcmBackend>[
          DartAesGcmBackend(),
          FallbackAesGcmBackend(
            primary: _FakePrimary(),
            fallback: DartAesGcmBackend(),
            minNativeLength: 0,
          ),
          // Nativo roto: cae a Dart y sigue siendo VaultAuthException.
          FallbackAesGcmBackend(
            primary: _FakePrimary(error: PlatformException(code: 'X')),
            fallback: DartAesGcmBackend(),
            minNativeLength: 0,
          ),
        ]) {
          await expectLater(
            VaultFileFormat(backend: backend).decryptBytes(enc, key),
            throwsA(
              isA<VaultAuthException>().having((e) => e.blockIndex, 'idx', 0),
            ),
            reason: backend.name,
          );
        }
      },
    );

    test(
      'AesGcmBackend.current se usa en cada operación (CryptoService)',
      () async {
        final p = _FakePrimary();
        AesGcmBackend.current = FallbackAesGcmBackend(
          primary: p,
          fallback: DartAesGcmBackend(),
          minNativeLength: 0,
        );
        final crypto = CryptoService();
        final enc = await crypto.encryptBytes(utf8.encode('hola'), key);
        expect(utf8.decode(await crypto.decryptBytes(enc, key)), 'hola');
        final s = await crypto.encryptData('texto', key);
        expect(await crypto.decryptData(s, key), 'texto');
        expect(p.calls, 4);
      },
    );

    test('en flutter test el backend de plataforma es Dart', () {
      expect(AesGcmBackend.platformDefault(), isA<DartAesGcmBackend>());
    });
  });
}

class _CapturingPrimary implements AesGcmBackend {
  _CapturingPrimary(this.onKey);
  final void Function(SecretKey) onKey;
  final _dart = DartAesGcmBackend();

  @override
  String get name => 'capturing';

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> aad = const <int>[],
  }) {
    onKey(secretKey);
    return _dart.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
  }) {
    onKey(secretKey);
    return _dart.decrypt(secretBox, secretKey: secretKey, aad: aad);
  }
}
