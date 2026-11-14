import 'dart:io';
import '../repositories/vault_database.dart';
import 'google_drive_service.dart';

class SyncQueueService {
  final GoogleDriveService _driveService = GoogleDriveService();
  bool _isSyncing = false;

  /// Procesa los elementos pendientes de sincronización hacia el appDataFolder
  Future<void> processSyncQueue(String dbKey) async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final db = await VaultDatabase.instance.database(dbKey);
      
      // Buscar elementos no sincronizados en la base de datos local
      final rawResults = await db.query(
        'vault_items',
        where: 'isSynced = ?',
        whereArgs: [0],
      );

      for (var row in rawResults) {
        final itemId = row['id'] as String;
        final localPath = row['localPath'] as String;
        final originalName = row['originalName'] as String;

        final encryptedFile = File(localPath);
        if (await encryptedFile.exists()) {
          // 1. Subir archivo cifrado al appDataFolder de Google Drive
          final cloudId = await _driveService.uploadEncryptedFile(encryptedFile, originalName);

          if (cloudId != null) {
            // 2. Actualizar base de datos indicando que ya está sincronizado
            await db.update(
              'vault_items',
              {
                'cloudId': cloudId,
                'isSynced': 1,
              },
              where: 'id = ?',
              whereArgs: [itemId],
            );

            // 3. Cloud-First: Eliminar la copia local física para liberar espacio en el dispositivo
            if (await encryptedFile.exists()) {
              await encryptedFile.delete();
            }
          }
        }
      }
    } catch (e) {
      // Manejar error de red o sincronización silenciosa
    } finally {
      _isSyncing = false;
    }
  }
}