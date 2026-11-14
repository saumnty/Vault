import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

// Alias para evitar que el editor borre los símbolos de menor/mayor que
typedef RecoveryMap = Map<String, dynamic>;

class KeyRecoveryService {
  final AesGcm _aes = AesGcm.with256bits();

  String generateRecoveryCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    
    List<String> blocks = [];
    for (int i = 0; i < 4; i++) {
      String block = '';
      for (int j = 0; j < 4; j++) {
        block += chars[random.nextInt(chars.length)];
      }
      blocks.add(block);
    }
    return blocks.join('-');
  }

  // Usamos el alias RecoveryMap aquí para solucionar el error de sintaxis
  Future<RecoveryMap> wrapMasterKey(SecretKey masterKey, String recoveryCode) async {
    final codeBytes = utf8.encode(recoveryCode);
    final recoveryKey = await SecretKey(codeBytes).extractBytes();
    
    final hashedRecoveryKey = await Sha256().hash(recoveryKey);
    final aesKey = SecretKey(hashedRecoveryKey.bytes);

    final dekBytes = await masterKey.extractBytes();
    final nonce = _aes.newNonce();
    final secretBox = await _aes.encrypt(
      dekBytes,
      secretKey: aesKey,
      nonce: nonce,
    );

    return {
      'nonce': base64Encode(nonce),
      'mac': base64Encode(secretBox.mac.bytes),
      'ciphertext': base64Encode(secretBox.cipherText),
    };
  }

  Future<SecretKey?> unwrapMasterKey({
    required String recoveryCode,
    required String base64Nonce,
    required String base64Mac,
    required String base64Ciphertext,
  }) async {
    try {
      final codeBytes = utf8.encode(recoveryCode);
      final recoveryKey = await SecretKey(codeBytes).extractBytes();
      final hashedRecoveryKey = await Sha256().hash(recoveryKey);
      final aesKey = SecretKey(hashedRecoveryKey.bytes);

      final secretBox = SecretBox(
        base64Decode(base64Ciphertext),
        nonce: base64Decode(base64Nonce),
        mac: Mac(base64Decode(base64Mac)),
      );

      final dekBytes = await _aes.decrypt(
        secretBox,
        secretKey: aesKey,
      );

      return SecretKey(dekBytes);
    } catch (e) {
      return null;
    }
  }
}