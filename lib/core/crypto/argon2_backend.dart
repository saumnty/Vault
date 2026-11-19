import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:sodium_libs/sodium_libs_sumo.dart'
    show CryptoPwhashAlgorithm, SodiumSumo, SodiumSumoInit;

import 'kdf.dart';

/// Implementación de Argon2id (v1.3 / 0x13) que deriva [Argon2Params.hashLength]
/// bytes a partir de un secreto y un salt.
///
/// Todas las implementaciones deben dar EXACTAMENTE el mismo resultado para
/// los mismos parámetros: el respaldo de recuperación se abre en otro teléfono
/// (posiblemente con otro backend). `test/argon2_backend_test.dart` lo verifica
/// con vectores de RFC 9106 y comparando backends entre sí.
///
/// Selección ([Argon2Backend.current]):
/// * Android / iOS → [FallbackArgon2Backend] (nativo libsodium vía
///   [SodiumArgon2Backend]; si la librería no carga o los parámetros no los
///   admite libsodium, cae a [IsolateDartArgon2Backend]).
/// * Escritorio → [IsolateDartArgon2Backend] (Dart puro en un isolate).
/// * `flutter test` (variable FLUTTER_TEST) → [DartArgon2Backend] en el mismo
///   isolate, compatible con FakeAsync; el plugin nativo no está registrado.
/// * Las pruebas pueden fijar otro con [Argon2Backend.current] = ….
///
/// En la app ninguna implementación corre en el isolate de la UI: el cálculo
/// no congela la interfaz.
abstract interface class Argon2Backend {
  /// Nombre corto para logs y pruebas.
  String get name;

  /// Deriva la llave. [secret] y [salt] no se modifican.
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  });

  static Argon2Backend? _current;

  /// Backend en uso. Se crea perezosamente con [platformDefault].
  static Argon2Backend get current => _current ??= platformDefault();

  /// Permite inyectar otro backend (pruebas). `null` vuelve al de plataforma.
  static set current(Argon2Backend? backend) => _current = backend;

  /// Backend por defecto según la plataforma (ver documentación de la clase).
  static Argon2Backend platformDefault() {
    // `flutter test` (FLUTTER_TEST=true): mismo isolate. Los testWidgets usan
    // FakeAsync y una respuesta de otro isolate no llega nunca mientras el
    // reloj es falso (la prueba se colgaría). El backend en isolate se prueba
    // aparte en test/argon2_backend_test.dart.
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return const DartArgon2Backend();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return FallbackArgon2Backend(
        primary: SodiumArgon2Backend(),
        fallback: const IsolateDartArgon2Backend(),
      );
    }
    return const IsolateDartArgon2Backend();
  }
}

/// Argon2id en Dart puro ([DartArgon2id] de `cryptography`), ejecutado en el
/// isolate que llama. Es la referencia; solo se usa directamente en pruebas.
class DartArgon2Backend implements Argon2Backend {
  const DartArgon2Backend();

  @override
  String get name => 'dart';

  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) => _dartDerive(
    secret,
    salt,
    params.memoryKiB,
    params.iterations,
    params.parallelism,
    params.hashLength,
  );
}

Future<Uint8List> _dartDerive(
  Uint8List secret,
  Uint8List salt,
  int memoryKiB,
  int iterations,
  int parallelism,
  int hashLength,
) async {
  final argon2 = DartArgon2id(
    memory: memoryKiB,
    iterations: iterations,
    parallelism: parallelism,
    hashLength: hashLength,
  );
  final secretKey = SecretKeyData(
    Uint8List.fromList(secret),
    overwriteWhenDestroyed: true,
  );
  try {
    final key = await argon2.deriveKey(secretKey: secretKey, nonce: salt);
    return Uint8List.fromList(await key.extractBytes());
  } finally {
    secretKey.destroy();
  }
}

/// [DartArgon2id] ejecutado en un isolate nuevo ([Isolate.run]): la UI no se
/// congela. Respaldo cuando no hay backend nativo (escritorio, pruebas, o si
/// libsodium no carga).
///
/// Al isolate se envían copias de [secret]/[salt] y los parámetros como
/// enteros; el resultado vuelve por `Isolate.exit` (sin copia). La copia del
/// secreto en el isolate se sobrescribe al terminar.
class IsolateDartArgon2Backend implements Argon2Backend {
  const IsolateDartArgon2Backend();

  @override
  String get name => 'dart-isolate';

  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) {
    final s = Uint8List.fromList(secret);
    final n = Uint8List.fromList(salt);
    final m = params.memoryKiB, t = params.iterations, p = params.parallelism;
    final len = params.hashLength;
    return Isolate.run(() async {
      try {
        return await _dartDerive(s, n, m, t, p, len);
      } finally {
        s.fillRange(0, s.length, 0);
      }
    }, debugName: 'argon2id');
  }
}

/// Argon2id nativo de libsodium (`crypto_pwhash`, ALG_ARGON2ID13) mediante
/// `sodium_libs` (binarios precompilados para Android e iOS).
///
/// La llamada FFI es síncrona, así que se ejecuta con
/// [SodiumSumo.runIsolated] (isolate aparte que carga la misma librería).
///
/// Restricciones de libsodium (ver [supports]): paralelismo fijo en 1 y salt
/// de exactamente 16 bytes (`crypto_pwhash_SALTBYTES`). Con esos parámetros
/// el resultado es idéntico a Argon2id v1.3 de RFC 9106 sin secreto ni datos
/// asociados (lo mismo que hace [DartArgon2id]).
class SodiumArgon2Backend implements Argon2Backend {
  SodiumArgon2Backend({Future<SodiumSumo> Function()? loader})
    : _loader = loader ?? SodiumSumoInit.init;

  final Future<SodiumSumo> Function() _loader;
  Future<SodiumSumo>? _sodium;

  static const int saltBytes = 16;

  @override
  String get name => 'libsodium';

  /// `true` si libsodium puede calcular estos parámetros.
  static bool supports(Argon2Params params, int saltLength) =>
      params.parallelism == 1 &&
      saltLength == saltBytes &&
      params.iterations >= 1 &&
      params.memoryKiB >= 8 &&
      params.hashLength >= 16;

  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    if (!supports(params, salt.length)) {
      throw UnsupportedError('libsodium no admite estos parámetros Argon2id');
    }
    final sodium = await (_sodium ??= _loader());
    // Copias propias: lo que captura el closure se copia al otro isolate.
    final password = Int8List.fromList(secret);
    final saltCopy = Uint8List.fromList(salt);
    final opsLimit = params.iterations;
    final memLimit = params.memoryKiB * 1024; // libsodium usa bytes
    final outLen = params.hashLength;
    try {
      return await sodium.runIsolated((sodium, _, _) {
        final key = sodium.crypto.pwhash(
          outLen: outLen,
          password: password,
          salt: saltCopy,
          opsLimit: opsLimit,
          memLimit: memLimit,
          alg: CryptoPwhashAlgorithm.argon2id13,
        );
        try {
          return key.extractBytes();
        } finally {
          key.dispose();
          password.fillRange(0, password.length, 0);
        }
      });
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }
}

/// Usa [primary] y, si falla al cargar o no admite los parámetros, [fallback].
///
/// Ambos dan el mismo resultado, así que el respaldo solo cuesta tiempo. Tras
/// un fallo de carga del nativo deja de intentarlo durante la sesión.
class FallbackArgon2Backend implements Argon2Backend {
  FallbackArgon2Backend({required this.primary, required this.fallback});

  final Argon2Backend primary;
  final Argon2Backend fallback;
  bool _primaryBroken = false;

  /// Backend que resolvió la última derivación (diagnóstico/pruebas).
  String? lastUsed;

  @override
  String get name => '${primary.name}|${fallback.name}';

  @override
  Future<Uint8List> derive({
    required Uint8List secret,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    final primaryOk =
        !_primaryBroken &&
        (primary is! SodiumArgon2Backend ||
            SodiumArgon2Backend.supports(params, salt.length));
    if (primaryOk) {
      // El primario recibe COPIAS propias: aunque fallara a mitad de camino
      // después de tocar sus entradas, el respaldo calcula siempre con el
      // secreto/salt originales intactos (si no, un fallo nativo→Dart podría
      // derivar con un buffer a cero y dar "PIN incorrecto").
      final secretCopy = Uint8List.fromList(secret);
      try {
        final out = await primary.derive(
          secret: secretCopy,
          salt: Uint8List.fromList(salt),
          params: params,
        );
        lastUsed = primary.name;
        return out;
      } catch (e) {
        _primaryBroken = true;
        if (kDebugMode) {
          debugPrint(
            '[vault-auth] Argon2id: ${primary.name} falló '
            '(${e.runtimeType}); uso ${fallback.name}',
          );
        }
      } finally {
        secretCopy.fillRange(0, secretCopy.length, 0);
      }
    }
    final out = await fallback.derive(
      secret: secret,
      salt: salt,
      params: params,
    );
    lastUsed = fallback.name;
    return out;
  }
}
