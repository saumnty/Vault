import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/argon2_backend.dart';
import 'package:vault/core/crypto/kdf.dart';

import 'support/fakes.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Backend que siempre falla (simula libsodium sin cargar).
class _BrokenBackend implements Argon2Backend {
  int calls = 0;
  @override
  String get name => 'roto';
  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    calls++;
    throw StateError('no hay librería nativa');
  }
}

void main() {
  // Vector de referencia de phc-winner-argon2 (src/test.c, Argon2id v1.3):
  // t=2, m=2^16 KiB, p=1, pwd="password", salt="somesalt", 32 bytes.
  const refParams = Argon2Params(
    memoryKiB: 65536,
    iterations: 2,
    parallelism: 1,
  );
  const refHex =
      '09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7';

  group('Argon2id v1.3: vector de referencia', () {
    for (final backend in const <Argon2Backend>[
      DartArgon2Backend(),
      IsolateDartArgon2Backend(),
    ]) {
      test(backend.name, () async {
        final out = await backend.derive(
          secret: _bytes('password'),
          salt: _bytes('somesalt'),
          params: refParams,
        );
        expect(_hex(out), refHex);
      });
    }
  });

  test('isolate y mismo hilo dan lo mismo con parámetros variados', () async {
    final salt = Uint8List.fromList(List.generate(16, (i) => i * 7));
    for (final p in const [
      Argon2Params(memoryKiB: 64, iterations: 1, parallelism: 1),
      Argon2Params(memoryKiB: 256, iterations: 3, parallelism: 1),
      Argon2Params(memoryKiB: 512, iterations: 2, parallelism: 2),
    ]) {
      final a = await const DartArgon2Backend().derive(
        secret: _bytes('123456'),
        salt: salt,
        params: p,
      );
      final b = await const IsolateDartArgon2Backend().derive(
        secret: _bytes('123456'),
        salt: salt,
        params: p,
      );
      expect(b, a);
      expect(a.length, 32);
    }
  });

  test('el backend no modifica secreto ni salt del llamador', () async {
    final secret = _bytes('123456');
    final salt = Uint8List.fromList(List.filled(16, 9));
    await const IsolateDartArgon2Backend().derive(
      secret: secret,
      salt: salt,
      params: fastKdf,
    );
    expect(secret, _bytes('123456'));
    expect(salt, List.filled(16, 9));
  });

  group('FallbackArgon2Backend', () {
    test('si el primario falla usa el respaldo y no reintenta', () async {
      final broken = _BrokenBackend();
      final fb = FallbackArgon2Backend(
        primary: broken,
        fallback: const IsolateDartArgon2Backend(),
      );
      final salt = Uint8List(16);
      final expected = await const DartArgon2Backend().derive(
        secret: _bytes('x'),
        salt: salt,
        params: fastKdf,
      );
      expect(
        await fb.derive(secret: _bytes('x'), salt: salt, params: fastKdf),
        expected,
      );
      expect(fb.lastUsed, 'dart-isolate');
      await fb.derive(secret: _bytes('x'), salt: salt, params: fastKdf);
      expect(broken.calls, 1);
    });

    test('parámetros no admitidos por libsodium van al respaldo', () async {
      final fb = FallbackArgon2Backend(
        primary: SodiumArgon2Backend(
          loader: () => throw StateError('no debería cargarse'),
        ),
        fallback: const DartArgon2Backend(),
      );
      const p2 = Argon2Params(memoryKiB: 64, iterations: 1, parallelism: 2);
      await fb.derive(secret: _bytes('x'), salt: Uint8List(16), params: p2);
      expect(fb.lastUsed, 'dart');
      // Salt de 8 bytes: libsodium exige 16.
      await fb.derive(secret: _bytes('x'), salt: Uint8List(8), params: fastKdf);
      expect(fb.lastUsed, 'dart');
    });

    test('SodiumArgon2Backend.supports', () {
      expect(SodiumArgon2Backend.supports(Argon2Params.production, 16), true);
      expect(SodiumArgon2Backend.supports(Argon2Params.production, 8), false);
      expect(
        SodiumArgon2Backend.supports(
          const Argon2Params(memoryKiB: 19456, iterations: 2, parallelism: 4),
          16,
        ),
        false,
      );
    });
  });

  group('Argon2Params.deriveKey', () {
    tearDown(() => Argon2Backend.current = null);

    test('en flutter test el backend por defecto es Dart en el mismo hilo', () {
      // FLUTTER_TEST=true lo pone `flutter test` (compatible con FakeAsync).
      expect(Argon2Backend.platformDefault(), isA<DartArgon2Backend>());
    });

    test('usa el backend inyectado y devuelve 32 bytes', () async {
      final calls = <String>[];
      Argon2Backend.current = _RecordingBackend(calls);
      final key = await fastKdf.deriveKey([1, 2, 3], List.filled(16, 1));
      expect(calls, ['dart']);
      expect((await key.extractBytes()).length, 32);
    });

    test('producción: m=19456 KiB, t=2, p=1 (mínimo OWASP, no bajar)', () {
      const p = Argon2Params.production;
      expect(p.memoryKiB, greaterThanOrEqualTo(19456));
      expect(p.iterations, greaterThanOrEqualTo(2));
      expect(p.parallelism, 1);
    });
  });
}

class _RecordingBackend implements Argon2Backend {
  _RecordingBackend(this.calls);
  final List<String> calls;
  @override
  String get name => 'grabadora';
  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) {
    calls.add('dart');
    return const DartArgon2Backend().derive(
      secret: secret,
      salt: salt,
      params: params,
    );
  }
}
