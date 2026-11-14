import 'dart:typed_data';

import 'package:vault/core/crypto/biometric_key_store.dart';
import 'package:vault/core/crypto/kdf.dart';
import 'package:vault/core/crypto/secure_kv_store.dart';

/// Parámetros Argon2id mínimos para que las pruebas corran rápido.
const Argon2Params fastKdf = Argon2Params(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

/// Almacenamiento seguro en memoria. Compartir la misma instancia entre dos
/// AuthController simula "cerrar y reabrir la app".
class InMemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Biometría simulada.
class FakeBiometricKeyStore implements BiometricKeyStore {
  BiometricAvailability available = BiometricAvailability.available;
  Uint8List? stored;
  bool cancelNext = false;
  int reads = 0;

  /// Simula que el SO invalida la llave (p. ej. se añadió una huella).
  void invalidate() => stored = null;

  @override
  Future<BiometricAvailability> availability() async => available;

  @override
  Future<void> writeKey(Uint8List key) async {
    if (cancelNext) {
      cancelNext = false;
      throw const BiometricCancelledException();
    }
    stored = Uint8List.fromList(key);
  }

  @override
  Future<Uint8List?> readKey() async {
    reads++;
    if (cancelNext) {
      cancelNext = false;
      throw const BiometricCancelledException();
    }
    final s = stored;
    return s == null ? null : Uint8List.fromList(s);
  }

  @override
  Future<void> deleteKey() async => stored = null;
}

/// Reloj controlable.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 1, 1);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}
