import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// Diagnóstico de autenticación/KDF. Solo imprime en modo debug
/// ([kDebugMode]); en release/profile no hace nada.
///
/// NUNCA se debe pasar el PIN, llaves, DEK ni salts completos: solo
/// longitudes, duraciones, resultados, nombres de backend y huellas
/// truncadas ([fingerprint]).
void cryptoDebugLog(String message) {
  if (kDebugMode) debugPrint('[vault-auth] $message');
}

/// Huella corta para correlacionar logs sin revelar el valor: 4 primeros
/// bytes (8 hex) de SHA-256(bytes). Pensada para salts/envolturas, nunca
/// para secretos de baja entropía como el PIN.
String fingerprint(List<int> bytes) {
  final digest = sha256.convert(bytes).bytes;
  final sb = StringBuffer();
  for (var i = 0; i < 4; i++) {
    sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
