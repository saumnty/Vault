import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'crypto_service.dart';

class AuthController {
  final CryptoService _cryptoService = CryptoService();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const String _saltKey = 'vault_master_salt';
  static const String _pinVerifierKey = 'vault_pin_verifier';

  /// Comprueba si ya existe un PIN maestro configurado en la app
  Future<bool> hasMasterPin() async {
    final salt = await _secureStorage.read(key: _saltKey);
    return salt != null;
  }

  /// Configura el PIN maestro por primera vez
  Future<void> setupMasterPin(String pin) async {
    // Generar una sal aleatoria de 16 bytes
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    
    // Guardar la sal en almacenamiento seguro
    await _secureStorage.write(key: _saltKey, value: base64Encode(salt));

    // Derivar la llave maestra
    final key = await _cryptoService.deriveKeyFromPin(pin, salt);

    // Guardar un texto cifrado de prueba (verificador) para comprobar el PIN en el futuro
    const verifierText = 'VAULT_ACCESS_VERIFIED';
    final encryptedVerifier = await _cryptoService.encryptData(verifierText, key);

    await _secureStorage.write(key: _pinVerifierKey, value: jsonEncode(encryptedVerifier));
  }

  /// Valida si el PIN ingresado es correcto
  Future<bool> verifyMasterPin(String pin) async {
    try {
      final saltString = await _secureStorage.read(key: _saltKey);
      final verifierString = await _secureStorage.read(key: _pinVerifierKey);

      if (saltString == null || verifierString == null) return false;

      final salt = base64Decode(saltString);
      final encryptedData = Map<String, String>.from(jsonDecode(verifierString));

      // Derivar la llave con el PIN ingresado y la sal existente
      final key = await _cryptoService.deriveKeyFromPin(pin, salt);

      // Intentar descifrar el verificador
      final decrypted = await _cryptoService.decryptData(encryptedData, key);
      return decrypted == 'VAULT_ACCESS_VERIFIED';
    } catch (e) {
      // Si falla el descifrado, el PIN es incorrecto
      return false;
    }
  }
}