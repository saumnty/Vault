import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import '../../../core/crypto/crypto_service.dart';

class VaultRepository {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final CryptoService _cryptoService = CryptoService();

  static const String _vaultDataKey = 'vault_encrypted_items';

  Future<void> saveItem(String title, String content, SecretKey secretKey) async {
    final existingItems = await getAllItemsRaw();
    final encryptedContent = await _cryptoService.encryptData(content, secretKey);

    final newItem = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'title': title,
      'data': encryptedContent,
      'createdAt': DateTime.now().toIso8601String(),
    };

    existingItems.add(newItem);

    await _secureStorage.write(
      key: _vaultDataKey,
      value: jsonEncode(existingItems),
    );
  }

  Future<List < Map < String, dynamic > > > getAllItemsRaw() async {
    final rawData = await _secureStorage.read(key: _vaultDataKey);
    if (rawData == null) return [];

    final List<dynamic> decoded = jsonDecode(rawData);
    return decoded.cast < Map < String, dynamic > > ();
  }

  Future<String> decryptItemContent(Map<String, dynamic> encryptedItem, SecretKey secretKey) async {
    final encryptedData = Map<String, String>.from(encryptedItem['data']);
    return await _cryptoService.decryptData(encryptedData, secretKey);
  }
}