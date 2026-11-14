import 'dart:io';
import '../../../data/repositories/vault_database.dart';
import '../../../core/services/cache_manager.dart';
import '../../../data/services/google_drive_service.dart';

class VaultPreferenceService {
  final GoogleDriveService _driveService = GoogleDriveService();
  final CacheManager _cacheManager = CacheManager.instance;

  /// Alternar estado de Favorito
  Future<void> toggleFavorite(String dbKey, String itemId, bool currentStatus) async {
    final db = await VaultDatabase.instance.database(dbKey);
    await db.update(
      'vault_items',
      {'isFavorite': currentStatus ? 0 : 1},
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  /// Alternar modo Sin Conexión (Offline Mode)
  Future<bool> toggleOfflineMode(String dbKey, String itemId, String cloudId, String fileName, bool makeOffline) async {
    try {
      final db = await VaultDatabase.instance.database(dbKey);
      final cacheDir = await _cacheManager.getCacheDirectory();
      final targetFile = File('${cacheDir.path}/$fileName');

      if (makeOffline) {
        // Si se marca como offline, debemos asegurar que el archivo cifrado esté descargado localmente
        if (!await targetFile.exists()) {
          final downloaded = await _driveService.downloadEncryptedFile(cloudId, targetFile.path);
          if (downloaded == null) return false;
        }
      }

      // Actualizar base de datos
      await db.update(
        'vault_items',
        {'isOffline': makeOffline ? 1 : 0},
        where: 'id = ?',
        whereArgs: [itemId],
      );

      return true;
    } catch (e) {
      return false;
    }
  }
}