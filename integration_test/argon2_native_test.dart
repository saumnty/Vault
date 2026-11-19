import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vault/core/crypto/argon2_backend.dart';
import 'package:vault/core/crypto/kdf.dart';

/// Argon2id nativo (libsodium) en emulador/dispositivo, comparado con la
/// implementación Dart de referencia y con tiempos:
///   flutter test integration_test/argon2_native_test.dart -d ID_DISPOSITIVO
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  test(
    'libsodium == Dart (mismo resultado) y tiempos',
    () async {
      final sodium = SodiumArgon2Backend();
      final salt = Uint8List.fromList(List.generate(16, (i) => 0xA0 + i));
      final secret = Uint8List.fromList('123456'.codeUnits);

      for (final p in const [
        Argon2Params(memoryKiB: 64, iterations: 1, parallelism: 1),
        Argon2Params(memoryKiB: 1024, iterations: 3, parallelism: 1),
        Argon2Params.production,
      ]) {
        final swN = Stopwatch()..start();
        final native = await sodium.derive(
          secret: secret,
          salt: salt,
          params: p,
        );
        swN.stop();
        final swD = Stopwatch()..start();
        final dart = await const IsolateDartArgon2Backend().derive(
          secret: secret,
          salt: salt,
          params: p,
        );
        swD.stop();
        // ignore: avoid_print
        print(
          'ARGON2 m=${p.memoryKiB} t=${p.iterations} p=${p.parallelism}: '
          'libsodium ${swN.elapsedMilliseconds} ms, '
          'dart-isolate ${swD.elapsedMilliseconds} ms, ${hex(native)}',
        );
        expect(native, dart);
      }

      // En Android/iOS el backend por defecto usa libsodium (sin caer a Dart).
      expect(Argon2Backend.platformDefault(), isA<FallbackArgon2Backend>());
      final def = Argon2Backend.platformDefault() as FallbackArgon2Backend;
      await Argon2Params.production.deriveKey(secret, salt, backend: def);
      expect(def.lastUsed, 'libsodium');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
