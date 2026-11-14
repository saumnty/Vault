import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

typedef StringMap = Map<String, String>;

/// Cifrado de archivos `.vault` (formato v1, se reemplaza en F2).
///
/// La llave que recibe debe ser la subllave "files" de la jerarquía
/// (`VaultSession().keys.files`), nunca la DEK ni algo derivado del PIN.
/// La derivación del PIN vive ahora en `kdf.dart` / `auth_controller.dart`.
class CryptoService {
  final AesGcm _aes = AesGcm.with256bits();

  // 1 MB por bloque (optimiza RAM y velocidad)
  static const int _chunkSize = 1024 * 1024;
  // "VLT" + Versión 1
  static const List<int> _magicHeader = [86, 76, 84, 1];

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
  // CIFRADO POR BLOQUES (ARCHIVOS PESADOS)
  // =====================================================================

  /// Cifra un archivo físico por bloques de 1MB hacia un nuevo archivo `.vault`
  Future<void> encryptFile(
    File sourceFile,
    File destFile,
    SecretKey masterKey,
  ) async {
    final raf = await sourceFile.open(mode: FileMode.read);
    final sink = destFile.openWrite();
    final length = await raf.length();
    int offset = 0;

    // 1. Escribir Encabezado Global
    sink.add(_magicHeader);

    // 2. Procesar por bloques
    while (offset < length) {
      final bytesToRead = (length - offset < _chunkSize)
          ? (length - offset)
          : _chunkSize;
      final chunk = await raf.read(bytesToRead);
      offset += bytesToRead;

      final nonce = _aes.newNonce();
      final secretBox = await _aes.encrypt(
        chunk,
        secretKey: masterKey,
        nonce: nonce,
      );

      // Calcular tamaño del ciphertext en 4 bytes (Endianness little)
      final lengthData = ByteData(4);
      lengthData.setUint32(0, secretBox.cipherText.length, Endian.little);

      // Escribir bloque: Tamaño -> Nonce -> MAC -> Ciphertext
      sink.add(lengthData.buffer.asUint8List());
      sink.add(nonce);
      sink.add(secretBox.mac.bytes);
      sink.add(secretBox.cipherText);
    }

    await raf.close();
    await sink.close();
  }

  /// Descifra un archivo `.vault` por bloques hacia un archivo temporal
  Future<void> decryptFile(
    File encryptedFile,
    File destFile,
    SecretKey masterKey,
  ) async {
    final raf = await encryptedFile.open(mode: FileMode.read);
    final length = await raf.length();

    // 1. Validar Encabezado
    final header = await raf.read(4);
    for (int i = 0; i < 4; i++) {
      if (header[i] != _magicHeader[i]) {
        await raf.close();
        throw Exception('Archivo corrupto o versión no soportada.');
      }
    }

    final sink = destFile.openWrite();
    int offset = 4; // Empezamos después del encabezado

    // try/finally: cerrar los descriptores aunque falle la autenticación
    // (en Windows un archivo abierto no se puede borrar).
    try {
      // 2. Leer y descifrar por bloques
      while (offset < length) {
        final lengthBytes = await raf.read(4);
        final cipherLen = ByteData.sublistView(
          Uint8List.fromList(lengthBytes),
        ).getUint32(0, Endian.little);

        final nonce = await raf.read(12);
        final mac = await raf.read(16);
        final cipherText = await raf.read(cipherLen);

        final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
        final plainTextBytes = await _aes.decrypt(
          secretBox,
          secretKey: masterKey,
        );

        sink.add(plainTextBytes);

        offset += 4 + 12 + 16 + cipherLen; // Tamaño + Nonce + MAC + Ciphertext
      }
    } finally {
      await raf.close();
      await sink.close();
    }
  }
}
