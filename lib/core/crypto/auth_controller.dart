import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'crypto_service.dart';
import '../../core/session/vault_session.dart';

class AuthController {
  final CryptoService _cryptoService = CryptoService();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final LocalAuthentication _localAuth = LocalAuthentication();

  static const String _saltKey = 'vault_master_salt';
  static const String _verifierKey = 'vault_pin_verifier';

  IOSOptions get _iosOptions => const IOSOptions(
        accessibility: KeychainAccessibility.passcode,
      );

  AndroidOptions get _androidOptions => const AndroidOptions(
        encryptedSharedPreferences: true,
      );

  Future<bool> hasVault() async {
    final salt = await _secureStorage.read(key: _saltKey, iOptions: _iosOptions, aOptions: _androidOptions);
    return salt != null;
  }

  Future<String> createVault(String pin) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    await _secureStorage.write(key: _saltKey, value: base64Encode(salt), iOptions: _iosOptions, aOptions: _androidOptions);

    final masterKey = await _cryptoService.deriveKeyFromPin(pin, salt);
    
    // Guardamos la llave maestra en memoria para la sesión activa
    VaultSession().masterKey = masterKey;

    const verifierText = 'VAULT_ACCESS_VERIFIED';
    final encryptedVerifier = await _cryptoService.encryptData(verifierText, masterKey);
    await _secureStorage.write(key: _verifierKey, value: jsonEncode(encryptedVerifier), iOptions: _iosOptions, aOptions: _androidOptions);

    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final recoveryCode = String.fromCharCodes(Iterable.generate(24, (_) => chars.codeUnitAt(rng.nextInt(chars.length))));

    return recoveryCode; 
  }

  Future<bool> verifyPin(String pin) async {
    try {
      final saltString = await _secureStorage.read(key: _saltKey, iOptions: _iosOptions, aOptions: _androidOptions);
      final verifierString = await _secureStorage.read(key: _verifierKey, iOptions: _iosOptions, aOptions: _androidOptions);

      if (saltString == null || verifierString == null) return false;

      final salt = base64Decode(saltString);
      final encryptedData = Map<String, String>.from(jsonDecode(verifierString));

      final masterKey = await _cryptoService.deriveKeyFromPin(pin, salt);
      final decrypted = await _cryptoService.decryptData(encryptedData, masterKey);

      if (decrypted == 'VAULT_ACCESS_VERIFIED') {
        // Guardamos la llave maestra en memoria al desbloquear exitosamente
        VaultSession().masterKey = masterKey;
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> canUseBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      return canCheck || isSupported;
    } catch (e) {
      return false;
    }
  }

  Future<bool> authenticateBiometrically() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Desbloquea Vault con tu identidad',
      );
    } catch (e) {
      return false;
    }
  }
}