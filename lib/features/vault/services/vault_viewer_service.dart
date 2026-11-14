import 'dart:io';
import 'package:cryptography/cryptography.dart';
import '../../../core/services/cache_manager.dart';
import '../../../data/services/google_drive_service.dart';

class VaultViewerService {
  final CacheManager _cacheManager = CacheManager.instance;
  final GoogleDriveService _driveService = GoogleDriveService();
  final AesGcm _aes = AesGcm.with256bits();

  /// Obtiene el archivo listo para mostrarse (en texto plano temporal) bajo demanda
  Future<File?> getPlainFileForViewing({
    required String cloudId,
    required String fileName,
    required SecretKey secretKey,
  }) async {
    try {
      // 1. Verificar si ya está en la caché local del dispositivo
      final cacheDir = await _cacheManager.getCacheDirectory();
      final localPlainFile = File('${cacheDir.path}/plain_$fileName');

      if (await localPlainFile.exists()) {
        return localPlainFile; // Ya está disponible localmente
      }

      // 2. Si no está en caché, descargarlo cifrado desde Google Drive (appDataFolder)
      final tempEncryptedFile = File('${cacheDir.path}/enc_$fileName');
      final downloaded = await _driveService.downloadEncryptedFile(cloudId, tempEncryptedFile);

      if (!downloaded) return null;
      final downloadedFile = tempEncryptedFile;

      // 3. Leer los bytes cifrados (nonce + mac + cipherText)
      // TODO(F6): no coincide con el formato por bloques de CryptoService.encryptFile.
      final encryptedBytes = await downloadedFile.readAsBytes();
      
      // Extraer componentes del empaquetado binario
      final nonce = encryptedBytes.sublist(0, 12);
      final macBytes = encryptedBytes.sublist(12, 28);
      final cipherText = encryptedBytes.sublist(28);

      final secretBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(macBytes),
      );

      // 4. Descifrar usando AES-GCM con la llave maestra (DEK)
      final decryptedBytes = await _aes.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      // 5. Guardar temporalmente en texto plano en la caché para visualización inmediata
      await localPlainFile.writeAsBytes(decryptedBytes);

      // Limpiar el archivo cifrado temporal descargado
      if (await downloadedFile.exists()) {
        await downloadedFile.delete();
      }

      return localPlainFile;
    } catch (e) {
      return null;
    }
  }
}