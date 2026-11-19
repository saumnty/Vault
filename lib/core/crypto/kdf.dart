import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import 'argon2_backend.dart';
import 'crypto_debug.dart';

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
  // Rangos fijos (S-08): producción es m=19456, t=2, p=1; se deja margen para
  // endurecerlo, pero nada que pueda colgar o matar por memoria la app.
  static const int maxMemoryKiB = 256 * 1024; // 256 MiB
  static const int maxIterations = 10;
  static const int maxParallelism = 4;
  static const int minMemoryKiB = 8;

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
        p > maxParallelism ||
        t < 1 ||
        t > maxIterations ||
        m < minMemoryKiB * p ||
        m > maxMemoryKiB) {
      throw FormatException(
        'Parámetros Argon2id fuera de rango (m=$m KiB, t=$t, p=$p): '
        'permitido m ${minMemoryKiB * p}–$maxMemoryKiB KiB, '
        't 1–$maxIterations, p 1–$maxParallelism. No se deriva nada.',
      );
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
    // Copia propia del secreto, solo para esta llamada: se pone a cero al
    // terminar, cuando el backend ya no la usa (las llamadas concurrentes
    // nunca comparten este buffer).
    final s = Uint8List.fromList(secret);
    final b = backend ?? Argon2Backend.current;
    final sw = kDebugMode ? (Stopwatch()..start()) : null;
    try {
      final out = await b.derive(
        secret: s,
        salt: Uint8List.fromList(salt),
        params: this,
      );
      if (out.length != hashLength) {
        throw StateError('Argon2id devolvió ${out.length} bytes');
      }
      if (sw != null) {
        final used = b is FallbackArgon2Backend ? b.lastUsed : b.name;
        cryptoDebugLog(
          'argon2id ok backend=$used m=$memoryKiB t=$iterations '
          'p=$parallelism secretLen=${s.length} saltLen=${salt.length} '
          'salt#=${fingerprint(salt)} ${sw.elapsedMilliseconds} ms',
        );
      }
      return SecretKeyData(out, overwriteWhenDestroyed: true);
    } catch (e) {
      if (sw != null) {
        cryptoDebugLog(
          'argon2id ERROR backend=${b.name} ${sw.elapsedMilliseconds} ms: '
          '${e.runtimeType}',
        );
      }
      rethrow;
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
