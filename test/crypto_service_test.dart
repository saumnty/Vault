import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/kdf.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/wrapped_key.dart';

import 'support/fakes.dart';

void main() {
  group('CryptoService con la subllave "files"', () {
    late CryptoService crypto;
    late KeyHierarchy keys;
    late Directory tmp;

    setUp(() async {
      crypto = CryptoService();
      keys = await KeyHierarchy.fromDek(randomBytes(32));
      tmp = await Directory.systemTemp.createTemp('vault_crypto');
    });

    tearDown(() => tmp.delete(recursive: true));

    // Las pruebas del formato .vault v2 están en vault_file_format_test.dart.
    test('otra subllave no descifra', () async {
      final src = File('${tmp.path}/a.bin')..writeAsBytesSync([1, 2, 3]);
      final enc = File('${tmp.path}/a.vault');
      await crypto.encryptFile(src, enc, keys.files);
      await expectLater(
        crypto.decryptFile(enc, File('${tmp.path}/a.out'), keys.thumbs),
        throwsA(isA<VaultAuthException>()),
      );
    });

    test('encryptData/decryptData', () async {
      final box = await crypto.encryptData('hola', keys.files);
      expect(await crypto.decryptData(box, keys.files), 'hola');
    });
  });

  group('Argon2id', () {
    test('determinista, 32 bytes y sensible al salt', () async {
      final salt1 = randomBytes(16), salt2 = randomBytes(16);
      final a = await fastKdf.deriveKey([1, 2, 3, 4], salt1);
      final b = await fastKdf.deriveKey([1, 2, 3, 4], salt1);
      final c = await fastKdf.deriveKey([1, 2, 3, 4], salt2);
      expect(a.bytes.length, 32);
      expect(a.bytes, b.bytes);
      expect(a.bytes, isNot(equals(c.bytes)));
    });

    test('parámetros de producción y validación al leer JSON', () {
      const p = Argon2Params.production;
      expect(p.memoryKiB, 19456);
      expect(p.iterations, 2);
      expect(p.parallelism, 1);
      expect(Argon2Params.fromJson(p.toJson()), p);
      expect(
        () => Argon2Params.fromJson({...p.toJson(), 'm': 1 << 30}),
        throwsFormatException,
      );
      expect(
        () => Argon2Params.fromJson({...p.toJson(), 'alg': 'pbkdf2'}),
        throwsFormatException,
      );
    });
  });

  group('WrappedKey', () {
    test(
      'la AAD impide usar una envoltura de PIN como de recuperación',
      () async {
        final dek = randomBytes(32);
        final w = await WrappedKey.wrap(
          dek: dek,
          secret: [9, 9, 9, 9],
          purpose: WrapPurpose.pin,
          kdf: fastKdf,
        );
        expect(await w.unwrap([9, 9, 9, 9]), dek);
        expect(await w.unwrap([9, 9, 9, 8]), isNull);

        final json = w.toJson()..['purpose'] = 'recovery';
        final forged = WrappedKey.fromJson(
          json,
          expectedPurpose: WrapPurpose.recovery,
        );
        expect(await forged.unwrap([9, 9, 9, 9]), isNull);
      },
    );

    test('rechaza campos con longitudes inválidas', () async {
      final w = await WrappedKey.wrap(
        dek: randomBytes(32),
        secret: [1],
        purpose: WrapPurpose.pin,
        kdf: fastKdf,
      );
      final json = w.toJson()..['nonce'] = 'AAAA';
      expect(
        () => WrappedKey.fromJson(json, expectedPurpose: WrapPurpose.pin),
        throwsFormatException,
      );
    });
  });
}
