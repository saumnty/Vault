import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'aes_gcm_backend.dart';
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
///
/// Errores de formato → [VaultFormatException]; de autenticación (llave
/// incorrecta, alteración, reordenado, truncado, bloque ajeno) →
/// [VaultAuthException].
class CryptoService {
  /// [backend] fija la implementación AES-GCM (pruebas); por defecto
  /// [AesGcmBackend.current] en cada operación (D22).
  CryptoService({AesGcmBackend? backend})
    : _backend = backend,
      _format = VaultFileFormat(backend: backend);

  final AesGcmBackend? _backend;
  final VaultFileFormat _format;

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
    String? expectedFileId,
  }) => VaultFileReader.open(
    encryptedFile,
    filesKey,
    verifyFinal: verifyFinal,
    backend: _backend,
    expectedFileId: expectedFileId,
  );

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
  Future<Uint8List> decryptBytes(
    List<int> encrypted,
    SecretKey key, {
    String? expectedFileId,
  }) => _format.decryptBytes(encrypted, key, expectedFileId: expectedFileId);

  /// fileId (UUID) del encabezado de un `.vault`/`.thumb` a partir de sus
  /// primeros bytes, SIN llave (S-09). Lanza [VaultFormatException].
  static String fileIdOfHeader(List<int> firstBytes) =>
      VaultHeader.parse(firstBytes).fileIdString;

  /// Igual que [fileIdOfHeader] leyendo los primeros bytes de [file].
  static Future<String> fileIdOfFile(File file) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      return fileIdOfHeader(await raf.read(VaultHeader.length));
    } finally {
      await raf.close();
    }
  }
}
