import 'dart:convert';
import 'package:cryptography/cryptography.dart';

class CryptoService {
  final _aes = AesGcm.with256bits();

  /// Deriva una clave criptográfica de 256 bits a partir del PIN maestro del usuario
  Future<SecretKey> deriveKeyFromPin(String pin, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000, // Alto número de iteraciones para mayor seguridad ante ataques de fuerza bruta
      bits: 256,
    );
    
    final secretKey = SecretKey(utf8.encode(pin));
    return await pbkdf2.deriveKey(secretKey: secretKey, nonce: salt);
  }

  /// Cifra texto plano utilizando AES-GCM
  Future<Map<String, String>> encryptData(String plainText, SecretKey secretKey) async {
    final nonce = _aes.newNonce();
    final clearTextBytes = utf8.encode(plainText);

    final secretBox = await _aes.encrypt(
      clearTextBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    return {
      'cipherText': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  /// Descifra la información previamente cifrada
  Future<String> decryptData(Map<String, String> encryptedData, SecretKey secretKey) async {
    final cipherText = base64Decode(encryptedData['cipherText']!);
    final nonce = base64Decode(encryptedData['nonce']!);
    final macBytes = base64Decode(encryptedData['mac']!);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final clearTextBytes = await _aes.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    return utf8.decode(clearTextBytes);
  }
}