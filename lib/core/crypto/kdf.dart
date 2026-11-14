import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

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

  /// Deriva una llave de 256 bits (KEK) a partir de [secret] y [salt].
  ///
  /// Se usa explícitamente la implementación en Dart puro ([DartArgon2id])
  /// para que el resultado sea idéntico en cualquier plataforma (el respaldo
  /// de recuperación debe poder abrirse en otro teléfono). Dicha
  /// implementación cede el hilo periódicamente, así que no congela la UI
  /// por completo, aunque sí la ralentiza durante ~0,5–2 s en producción.
  Future<SecretKeyData> deriveKey(List<int> secret, List<int> salt) async {
    final argon2 = DartArgon2id(
      memory: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: 32,
    );
    final key = await argon2.deriveKey(
      secretKey: SecretKeyData(
        Uint8List.fromList(secret),
        overwriteWhenDestroyed: true,
      ),
      nonce: salt,
    );
    return SecretKeyData(
      Uint8List.fromList(await key.extractBytes()),
      overwriteWhenDestroyed: true,
    );
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
