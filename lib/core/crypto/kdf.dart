import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'argon2_backend.dart';

export 'argon2_backend.dart' show Argon2Backend;

/// Parámetros de Argon2id.
///
/// Producción: m = 19456 KiB (19 MiB), t = 2, p = 1. Es la configuración
/// mínima recomendada por OWASP (Password Storage Cheat Sheet) para Argon2id
/// y cabe holgadamente en la RAM de cualquier teléfono. En las pruebas se
/// inyectan valores reducidos para que corran rápido.
///
/// Los parámetros se guardan junto a cada envoltura (JSON), de modo que se
/// pueden endurecer en el futuro sin romper envolturas antiguas.
class Argon2Params {
  const Argon2Params({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  static const Argon2Params production = Argon2Params(
    memoryKiB: 19456,
    iterations: 2,
    parallelism: 1,
  );

  // Límites de cordura al leer parámetros de un JSON externo (p. ej. el
  // respaldo descargado de Drive): evitan que un archivo manipulado nos haga
  // reservar gigabytes de RAM o iterar indefinidamente.
  static const int _maxMemoryKiB = 1024 * 1024; // 1 GiB
  static const int _maxIterations = 16;
  static const int _maxParallelism = 8;

  Map<String, dynamic> toJson() => {
    'alg': 'argon2id',
    'v': 0x13,
    'm': memoryKiB,
    't': iterations,
    'p': parallelism,
  };

  factory Argon2Params.fromJson(Map<String, dynamic> json) {
    if (json['alg'] != 'argon2id' || json['v'] != 0x13) {
      throw const FormatException('KDF no soportada');
    }
    final m = json['m'], t = json['t'], p = json['p'];
    if (m is! int || t is! int || p is! int) {
      throw const FormatException('Parámetros Argon2id inválidos');
    }
    if (p < 1 ||
        p > _maxParallelism ||
        t < 1 ||
        t > _maxIterations ||
        m < 8 * p ||
        m > _maxMemoryKiB) {
      throw const FormatException('Parámetros Argon2id fuera de rango');
    }
    return Argon2Params(memoryKiB: m, iterations: t, parallelism: p);
  }

  /// Longitud de la llave derivada (bytes). Fija: AES-256.
  int get hashLength => 32;

  /// Deriva una llave de 256 bits (KEK) a partir de [secret] y [salt].
  ///
  /// El cálculo lo hace [Argon2Backend.current] (o [backend] si se indica):
  /// libsodium nativo en Android/iOS y Dart puro en otras plataformas, en la
  /// app siempre fuera del isolate de la UI (en `flutter test`, en el mismo
  /// isolate por compatibilidad con FakeAsync). Todos los backends producen el mismo
  /// resultado (Argon2id v1.3), así que el respaldo de recuperación se abre en
  /// cualquier teléfono. Ver `argon2_backend.dart`.
  Future<SecretKeyData> deriveKey(
    List<int> secret,
    List<int> salt, {
    Argon2Backend? backend,
  }) async {
    final s = Uint8List.fromList(secret);
    try {
      final out = await (backend ?? Argon2Backend.current).derive(
        secret: s,
        salt: Uint8List.fromList(salt),
        params: this,
      );
      if (out.length != hashLength) {
        throw StateError('Argon2id devolvió ${out.length} bytes');
      }
      return SecretKeyData(out, overwriteWhenDestroyed: true);
    } finally {
      s.fillRange(0, s.length, 0);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Argon2Params &&
      other.memoryKiB == memoryKiB &&
      other.iterations == iterations &&
      other.parallelism == parallelism;

  @override
  int get hashCode => Object.hash(memoryKiB, iterations, parallelism);
}
