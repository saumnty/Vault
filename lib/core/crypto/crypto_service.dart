import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'vault_file_format.dart';

export 'vault_file_format.dart'
    show
        VaultCryptoException,
        VaultFormatException,
        VaultAuthException,
        VaultHeader,
        VaultFileReader;

typedef StringMap = Map<String, String>;

/// Fachada de cifrado de la app.
///
/// * Archivos y bytes: formato `.vault` v2 (ver `vault_file_format.dart` para
///   el layout byte a byte). Llave = subllave "files" (`VaultSession().filesKey`)
///   para archivos y "thumbs" para miniaturas; nunca la DEK ni algo derivado
///   del PIN.
/// * Textos cortos: [encryptData]/[decryptData] (AES-GCM, usado por
///   VaultRepository).
///
/// Errores de formato → [VaultFormatException]; de autenticación (llave
/// incorrecta, alteración, reordenado, truncado, bloque ajeno) →
/// [VaultAuthException].
class CryptoService {
  final AesGcm _aes = AesGcm.with256bits();
  final VaultFileFormat _format = VaultFileFormat();

  /// Cifra un texto corto (AES-256-GCM). Usado por VaultRepository.
  Future<StringMap> encryptData(String plainText, SecretKey secretKey) async {
    final plainBytes = utf8.encode(plainText);
    final nonce = _aes.newNonce();
    final secretBox = await _aes.encrypt(
      plainBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    return {
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  Future<String> decryptData(
    StringMap encryptedData,
    SecretKey secretKey,
  ) async {
    final secretBox = SecretBox(
      base64Decode(encryptedData['ciphertext']!),
      nonce: base64Decode(encryptedData['nonce']!),
      mac: Mac(base64Decode(encryptedData['mac']!)),
    );
    final decryptedBytes = await _aes.decrypt(secretBox, secretKey: secretKey);
    return utf8.decode(decryptedBytes);
  }

  // =====================================================================
  // ARCHIVOS .vault v2
  // =====================================================================

  /// Cifra [sourceFile] hacia [destFile] en streaming. Devuelve el
  /// encabezado (fileId) generado. Si falla, [destFile] se borra.
  Future<VaultHeader> encryptFile(
    File sourceFile,
    File destFile,
    SecretKey filesKey, {
    int blockSize = VaultHeader.defaultBlockSize,
  }) =>
      _format.encryptFile(sourceFile, destFile, filesKey, blockSize: blockSize);

  /// Descifra un `.vault` completo en streaming. Si falla, [destFile] se
  /// borra y se relanza la excepción.
  Future<void> decryptFile(
    File encryptedFile,
    File destFile,
    SecretKey filesKey,
  ) => _format.decryptFile(encryptedFile, destFile, filesKey);

  /// Descifra solo el bloque [index] de un `.vault`.
  Future<Uint8List> decryptBlock(
    File encryptedFile,
    int index,
    SecretKey filesKey,
  ) => _format.decryptBlock(encryptedFile, index, filesKey);

  /// Abre un lector con acceso aleatorio (bloques, rangos, stream).
  /// Con [verifyFinal] autentica de entrada la longitud total.
  Future<VaultFileReader> openReader(
    File encryptedFile,
    SecretKey filesKey, {
    bool verifyFinal = true,
  }) => VaultFileReader.open(encryptedFile, filesKey, verifyFinal: verifyFinal);

  /// Lee [length] bytes en claro desde [offset] (recortado al final).
  Future<Uint8List> readRange(
    File encryptedFile,
    int offset,
    int length,
    SecretKey filesKey,
  ) async {
    final reader = await openReader(encryptedFile, filesKey);
    try {
      return await reader.readRange(offset, length);
    } finally {
      await reader.close();
    }
  }

  /// Cifra bytes en memoria con el formato v2 (miniaturas: subllave "thumbs").
  Future<Uint8List> encryptBytes(
    List<int> plain,
    SecretKey key, {
    int blockSize = VaultHeader.defaultBlockSize,
  }) => _format.encryptBytes(plain, key, blockSize: blockSize);

  /// Inverso de [encryptBytes].
  Future<Uint8List> decryptBytes(List<int> encrypted, SecretKey key) =>
      _format.decryptBytes(encrypted, key);
}
