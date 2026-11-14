import 'dart:io';
import 'package:cryptography/cryptography.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/services/cache_manager.dart';
import '../../../data/services/google_drive_service.dart';

class VaultViewerService {
  final CacheManager _cacheManager = CacheManager.instance;
  final GoogleDriveService _driveService = GoogleDriveService();
  final CryptoService _cryptoService = CryptoService();

  /// Obtiene el archivo listo para mostrarse (en texto plano temporal) bajo demanda.
  ///
  /// [secretKey] debe ser la subllave "files" (`VaultSession().filesKey`).
  // TODO(F6): sustituir el archivo plano temporal por streaming con
  // CryptoService.openReader (lectura por rangos) y caché cifrada.
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
      try {
        final downloaded = await _driveService.downloadEncryptedFile(
          cloudId,
          tempEncryptedFile,
        );
        if (!downloaded) return null;

        // 3. Descifrar el .vault v2 en streaming. Si falla la autenticación,
        // decryptFile borra el archivo plano parcial y lanza excepción.
        await _cryptoService.decryptFile(
          tempEncryptedFile,
          localPlainFile,
          secretKey,
        );
        return localPlainFile;
      } finally {
        // Limpiar el archivo cifrado temporal descargado
        if (await tempEncryptedFile.exists()) {
          await tempEncryptedFile.delete();
        }
      }
    } catch (e) {
      return null;
    }
  }
}
