import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/crypto_service.dart';
import 'package:cryptography/cryptography.dart';

void main() {
  group('CryptoService Unit Tests', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = CryptoService();
    });

    test('Generación de Llave Maestra (DEK)', () async {
      final dek = await cryptoService.generateMasterKey();
      final bytes = await dek.extractBytes();
      expect(bytes.length, equals(32)); // AES-256 requiere 32 bytes
    });

    test('Derivación de clave con Argon2id', () async {
      final key = await cryptoService.deriveKeyFromPin('123456', 'salt_de_prueba_1234');
      final bytes = await key.extractBytes();
      expect(bytes.length, equals(32));
    });
  });
}