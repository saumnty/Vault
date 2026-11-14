import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:vault/core/crypto/key_hierarchy.dart';
import 'package:vault/core/crypto/vault_file_format.dart';
import 'package:vault/core/crypto/wrapped_key.dart';

const int mib = 1024 * 1024;
const int hdr = VaultHeader.length; // 24
const int ovh = VaultLayout.blockOverhead; // 28

/// Bytes pseudoaleatorios reproducibles (contenido de prueba, no llaves).
Uint8List sample(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Matcher throwsAuth() => throwsA(isA<VaultAuthException>());
Matcher throwsFormat() => throwsA(isA<VaultFormatException>());

void main() {
  late CryptoService crypto;
  late KeyHierarchy keys;
  late Directory tmp;
  var counter = 0;

  setUp(() async {
    crypto = CryptoService();
    keys = await KeyHierarchy.fromDek(randomBytes(32));
    tmp = await Directory.systemTemp.createTemp('vault_v2_');
  });

  tearDown(() async {
    keys.destroy();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File newFile(String ext) => File('${tmp.path}/f${counter++}.$ext');

  /// Cifra [data] y devuelve el .vault.
  Future<File> encrypt(Uint8List data, {int blockSize = mib}) async {
    final src = newFile('bin')..writeAsBytesSync(data);
    final enc = newFile('vault');
    await crypto.encryptFile(src, enc, keys.files, blockSize: blockSize);
    return enc;
  }

  /// Descifra y comprueba que falla con [matcher] y que no queda destino.
  Future<void> expectDecryptFails(File enc, Matcher matcher) async {
    final out = newFile('out');
    await expectLater(crypto.decryptFile(enc, out, keys.files), matcher);
    expect(out.existsSync(), isFalse, reason: 'el destino parcial se borra');
  }

  group('ida y vuelta (bloques de 1 MiB)', () {
    final cases = <String, (int, int)>{
      '0 bytes': (0, 1),
      '1 byte': (1, 1),
      'exactamente 1 MiB': (mib, 1),
      '1 MiB + 1 byte': (mib + 1, 2),
      '5 MiB + 12345 bytes': (5 * mib + 12345, 6),
    };
    cases.forEach((name, c) {
      final (size, expectedBlocks) = c;
      test(name, () async {
        final data = sample(size, size);
        final enc = await encrypt(data);

        // Longitud exacta: sin bloque final vacío salvo el archivo vacío.
        expect(enc.lengthSync(), hdr + expectedBlocks * ovh + size);

        final bytes = enc.readAsBytesSync();
        expect(bytes.sublist(0, 4), [0x56, 0x4C, 0x54, 0x02]);
        expect(ByteData.sublistView(bytes).getUint32(20, Endian.little), mib);

        final out = newFile('out');
        await crypto.decryptFile(enc, out, keys.files);
        expect(out.readAsBytesSync(), data);

        final reader = await crypto.openReader(enc, keys.files);
        try {
          expect(reader.blockCount, expectedBlocks);
          expect(reader.plaintextLength, size);
        } finally {
          await reader.close();
        }
      });
    });

    test(
      'múltiplo exacto de varios bloques termina en bloque final lleno',
      () async {
        final data = sample(3 * 1024);
        final enc = await encrypt(data, blockSize: 1024);
        expect(enc.lengthSync(), hdr + 3 * (1024 + ovh));
        final out = newFile('out');
        await crypto.decryptFile(enc, out, keys.files);
        expect(out.readAsBytesSync(), data);
      },
    );
  });

  group('ataques', () {
    const bs = 1024;

    test('bloque alterado (ciphertext, tag, nonce y encabezado)', () async {
      final data = sample(bs * 3 + 100);
      final enc = await encrypt(data, blockSize: bs);
      final orig = enc.readAsBytesSync();
      final positions = {
        'ciphertext bloque 1': hdr + (bs + ovh) + 12 + 5,
        'tag bloque 0': hdr + bs + ovh - 1,
        'nonce bloque 2': hdr + 2 * (bs + ovh),
        'fileId en encabezado': 10,
        'último byte (tag final)': orig.length - 1,
      };
      for (final entry in positions.entries) {
        final tampered = Uint8List.fromList(orig);
        tampered[entry.value] ^= 0x01;
        enc.writeAsBytesSync(tampered);
        await expectDecryptFails(enc, throwsAuth());
      }
    });

    test('blockSize del encabezado alterado no pasa', () async {
      final enc = await encrypt(sample(4096), blockSize: bs);
      final b = enc.readAsBytesSync();
      ByteData.sublistView(b).setUint32(20, 2048, Endian.little);
      enc.writeAsBytesSync(b);
      await expectDecryptFails(enc, throwsAuth());
    });

    test('bloques reordenados', () async {
      final data = sample(bs * 3 + 7);
      final enc = await encrypt(data, blockSize: bs);
      final b = enc.readAsBytesSync();
      const e = bs + ovh;
      final block0 = b.sublist(hdr, hdr + e);
      final block1 = b.sublist(hdr + e, hdr + 2 * e);
      b.setAll(hdr, block1);
      b.setAll(hdr + e, block0);
      enc.writeAsBytesSync(b);
      await expectDecryptFails(enc, throwsAuth());
    });

    test('truncado quitando el bloque final (parcial)', () async {
      final enc = await encrypt(sample(bs * 2 + 500), blockSize: bs);
      final b = enc.readAsBytesSync();
      enc.writeAsBytesSync(b.sublist(0, hdr + 2 * (bs + ovh)));
      await expectDecryptFails(enc, throwsAuth());
    });

    test('truncado quitando el bloque final (lleno)', () async {
      final enc = await encrypt(sample(bs * 3), blockSize: bs);
      final b = enc.readAsBytesSync();
      enc.writeAsBytesSync(b.sublist(0, hdr + 2 * (bs + ovh)));
      await expectDecryptFails(enc, throwsAuth());
    });

    test('truncado a mitad de bloque', () async {
      final enc = await encrypt(sample(bs * 2 + 500), blockSize: bs);
      final b = enc.readAsBytesSync();
      // El último bloque queda más corto pero con longitud válida → tag.
      enc.writeAsBytesSync(b.sublist(0, b.length - 100));
      await expectDecryptFails(enc, throwsAuth());
      // Cortar dentro de un bloque completo → bloque final "falso" → tag.
      enc.writeAsBytesSync(b.sublist(0, hdr + (bs + ovh) + 300));
      await expectDecryptFails(enc, throwsAuth());
      // Resto < 28 bytes: longitud imposible → formato.
      enc.writeAsBytesSync(b.sublist(0, hdr + 2 * (bs + ovh) + 10));
      await expectDecryptFails(enc, throwsFormat());
      // Bloque final vacío en archivo no vacío → formato.
      enc.writeAsBytesSync(b.sublist(0, hdr + 2 * (bs + ovh) + ovh));
      await expectDecryptFails(enc, throwsFormat());
      // Solo el encabezado → formato.
      enc.writeAsBytesSync(b.sublist(0, hdr));
      await expectDecryptFails(enc, throwsFormat());
    });

    test('bloque añadido al final', () async {
      final enc = await encrypt(sample(bs * 2), blockSize: bs);
      final b = enc.readAsBytesSync();
      enc.writeAsBytesSync([...b, ...b.sublist(hdr, hdr + bs + ovh)]);
      await expectDecryptFails(enc, throwsAuth());
    });

    test('bloque copiado de otro archivo con la misma llave', () async {
      final a = await encrypt(sample(bs * 3, 1), blockSize: bs);
      final b = await encrypt(sample(bs * 3, 2), blockSize: bs);
      final ab = a.readAsBytesSync();
      final bb = b.readAsBytesSync();
      const e = bs + ovh;

      // Bloque 1 de B (mismo índice, misma bandera) dentro de A.
      final mixed = Uint8List.fromList(ab)
        ..setAll(hdr + e, bb.sublist(hdr + e, hdr + 2 * e));
      a.writeAsBytesSync(mixed);
      await expectDecryptFails(a, throwsAuth());

      // Encabezado de B con los bloques de A.
      final swapped = Uint8List.fromList(ab)..setAll(0, bb.sublist(0, hdr));
      a.writeAsBytesSync(swapped);
      await expectDecryptFails(a, throwsAuth());

      // Sanidad: el original de A sigue descifrando.
      a.writeAsBytesSync(ab);
      final out = newFile('out');
      await crypto.decryptFile(a, out, keys.files);
      expect(out.readAsBytesSync(), sample(bs * 3, 1));
    });

    test('ataque con el tamaño de bloque por defecto (1 MiB)', () async {
      final enc = await encrypt(sample(2 * mib + 3));
      final b = enc.readAsBytesSync();
      enc.writeAsBytesSync(b.sublist(0, hdr + 2 * (mib + ovh)));
      await expectDecryptFails(enc, throwsAuth());
    });
  });

  group('acceso aleatorio', () {
    test('descifrar desde un bloque intermedio y por rangos', () async {
      const bs = 1024;
      final data = sample(bs * 6 + 321);
      final enc = await encrypt(data, blockSize: bs);

      // API de un solo bloque (abre/cierra).
      expect(
        await crypto.decryptBlock(enc, 3, keys.files),
        data.sublist(3 * bs, 4 * bs),
      );
      // Último bloque (isFinal deducido de la longitud física).
      expect(
        await crypto.decryptBlock(enc, 6, keys.files),
        data.sublist(6 * bs),
      );

      final reader = await crypto.openReader(enc, keys.files);
      try {
        expect(reader.blockCount, 7);
        expect(reader.plaintextLength, data.length);
        expect(await reader.decryptBlock(4), data.sublist(4 * bs, 5 * bs));
        // Rango que cruza bloques.
        expect(
          await reader.readRange(bs * 2 + 1000, 2000),
          data.sublist(bs * 2 + 1000, bs * 2 + 3000),
        );
        // Rango recortado al final.
        expect(
          await reader.readRange(data.length - 10, 100),
          data.sublist(data.length - 10),
        );
        expect(await reader.readRange(data.length, 10), isEmpty);
        // Stream desde un offset arbitrario.
        final streamed = <int>[];
        await for (final c in reader.streamRange(5000)) {
          streamed.addAll(c);
        }
        expect(streamed, data.sublist(5000));
        // Lecturas concurrentes se serializan sin error.
        final results = await Future.wait([
          reader.decryptBlock(0),
          reader.decryptBlock(5),
          reader.readRange(100, 3000),
        ]);
        expect(results[0], data.sublist(0, bs));
        expect(results[1], data.sublist(5 * bs, 6 * bs));
        expect(results[2], data.sublist(100, 3100));
        expect(() => reader.decryptBlock(7), throwsRangeError);
      } finally {
        await reader.close();
      }

      expect(
        await crypto.readRange(enc, 1500, 10, keys.files),
        data.sublist(1500, 1510),
      );
    });

    test('bloque intermedio con 1 MiB', () async {
      final data = sample(3 * mib + 5);
      final enc = await encrypt(data);
      expect(
        await crypto.decryptBlock(enc, 1, keys.files),
        data.sublist(mib, 2 * mib),
      );
    });

    test('openReader detecta truncado aunque solo se lea un bloque', () async {
      const bs = 1024;
      final data = sample(bs * 4 + 10);
      final enc = await encrypt(data, blockSize: bs);
      final b = enc.readAsBytesSync();
      enc.writeAsBytesSync(b.sublist(0, hdr + 4 * (bs + ovh)));

      await expectLater(crypto.openReader(enc, keys.files), throwsAuth());
      // Sin verificación previa, un bloque intermedio intacto sí descifra,
      // pero el nuevo "final" falla.
      final r = await crypto.openReader(enc, keys.files, verifyFinal: false);
      try {
        expect(await r.decryptBlock(1), data.sublist(bs, 2 * bs));
        await expectLater(r.decryptBlock(3), throwsAuth());
      } finally {
        await r.close();
      }
    });
  });

  group('llave y encabezado', () {
    test('llave incorrecta falla y borra el destino', () async {
      final enc = await encrypt(sample(5000), blockSize: 1024);
      final out = newFile('out');
      await expectLater(
        crypto.decryptFile(enc, out, keys.thumbs),
        throwsAuth(),
      );
      expect(out.existsSync(), isFalse);
      await expectLater(crypto.decryptBlock(enc, 2, keys.thumbs), throwsAuth());
    });

    test('magic, versión, tamaño de bloque y longitud inválidos', () async {
      final enc = await encrypt(sample(100));
      final orig = enc.readAsBytesSync();

      final badMagic = Uint8List.fromList(orig)..[0] = 0x58;
      enc.writeAsBytesSync(badMagic);
      await expectDecryptFails(enc, throwsFormat());

      final v1 = Uint8List.fromList(orig)..[3] = 0x01;
      enc.writeAsBytesSync(v1);
      await expectDecryptFails(enc, throwsFormat());

      final v3 = Uint8List.fromList(orig)..[3] = 0x03;
      enc.writeAsBytesSync(v3);
      await expectDecryptFails(enc, throwsFormat());

      final hugeBlock = Uint8List.fromList(orig);
      ByteData.sublistView(hugeBlock).setUint32(20, 0xFFFFFFFF, Endian.little);
      enc.writeAsBytesSync(hugeBlock);
      await expectDecryptFails(enc, throwsFormat());

      enc.writeAsBytesSync(orig.sublist(0, 10));
      await expectDecryptFails(enc, throwsFormat());

      enc.writeAsBytesSync(const []);
      await expectDecryptFails(enc, throwsFormat());
    });

    test('dos cifrados del mismo archivo difieren (fileId y salida)', () async {
      final data = sample(3000);
      final src = newFile('bin')..writeAsBytesSync(data);
      final e1 = newFile('vault'), e2 = newFile('vault');
      final h1 = await crypto.encryptFile(src, e1, keys.files);
      final h2 = await crypto.encryptFile(src, e2, keys.files);
      expect(h1.fileId, isNot(equals(h2.fileId)));
      expect(h1.fileIdString, isNot(h2.fileIdString));
      final b1 = e1.readAsBytesSync(), b2 = e2.readAsBytesSync();
      expect(b1.sublist(4, 20), h1.fileId);
      expect(b1.sublist(4, 20), isNot(equals(b2.sublist(4, 20))));
      expect(b1.sublist(hdr), isNot(equals(b2.sublist(hdr))));
      // fileId es un UUID v4 válido.
      expect(
        h1.fileIdString,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test(
      'blockSize fuera de rango al cifrar es un error de argumento',
      () async {
        final src = newFile('bin')..writeAsBytesSync([1]);
        final enc = newFile('vault');
        await expectLater(
          crypto.encryptFile(src, enc, keys.files, blockSize: 16),
          throwsArgumentError,
        );
        expect(enc.existsSync(), isFalse);
      },
    );
  });

  group('encryptBytes/decryptBytes (miniaturas)', () {
    test('ida y vuelta con la subllave "thumbs"', () async {
      for (final n in [0, 1, 1023, 1024, 1025, 5000]) {
        final data = sample(n, n + 7);
        final enc = await crypto.encryptBytes(
          data,
          keys.thumbs,
          blockSize: 1024,
        );
        final blocks = n == 0 ? 1 : (n + 1023) ~/ 1024;
        expect(enc.length, hdr + blocks * ovh + n);
        expect(await crypto.decryptBytes(enc, keys.thumbs), data);
      }
      // Tamaño por defecto (un solo bloque para una miniatura).
      final thumb = sample(40000);
      final enc = await crypto.encryptBytes(thumb, keys.thumbs);
      expect(enc.length, hdr + ovh + thumb.length);
      expect(await crypto.decryptBytes(enc, keys.thumbs), thumb);
    });

    test('alteración, llave incorrecta y truncado fallan', () async {
      final data = sample(3000);
      final enc = await crypto.encryptBytes(data, keys.thumbs, blockSize: 1024);
      final tampered = Uint8List.fromList(enc)..[hdr + 40] ^= 0x80;
      await expectLater(
        crypto.decryptBytes(tampered, keys.thumbs),
        throwsAuth(),
      );
      await expectLater(crypto.decryptBytes(enc, keys.files), throwsAuth());
      await expectLater(
        crypto.decryptBytes(
          enc.sublist(0, hdr + 2 * (1024 + ovh)),
          keys.thumbs,
        ),
        throwsAuth(),
      );
      await expectLater(
        crypto.decryptBytes(enc.sublist(0, 5), keys.thumbs),
        throwsFormat(),
      );
    });

    test('mismo formato que los archivos', () async {
      final data = sample(2500);
      final enc = await crypto.encryptBytes(data, keys.files, blockSize: 1024);
      final f = newFile('vault')..writeAsBytesSync(enc);
      final out = newFile('out');
      await crypto.decryptFile(f, out, keys.files);
      expect(out.readAsBytesSync(), data);

      final fromFile = await encrypt(data, blockSize: 1024);
      expect(
        await crypto.decryptBytes(fromFile.readAsBytesSync(), keys.files),
        data,
      );
    });
  });

  group('VaultLayout', () {
    test('geometría y offsets', () {
      final l = VaultLayout.forPlaintext(2500, 1024);
      expect(l.blockCount, 3);
      expect(l.plainBlockLength(0), 1024);
      expect(l.plainBlockLength(2), 452);
      expect(l.encryptedBlockOffset(2), hdr + 2 * (1024 + ovh));
      expect(l.blockIndexForOffset(2047), 1);
      expect(l.blockIndexForOffset(2048), 2);
      final back = VaultLayout.fromEncryptedLength(l.encryptedLength, 1024);
      expect(back.blockCount, 3);
      expect(back.plaintextLength, 2500);
      expect(back.isFinal(2), isTrue);
      expect(back.isFinal(1), isFalse);

      final empty = VaultLayout.fromEncryptedLength(hdr + ovh, 1024);
      expect(empty.blockCount, 1);
      expect(empty.plaintextLength, 0);
    });
  });
}
