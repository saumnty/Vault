import '../../core/services/app_paths.dart';
import '../models/sync_status.dart';
import '../repositories/vault_data_repository.dart';
import 'google_drive_service.dart';

class SyncQueueService {
  final GoogleDriveService _driveService = GoogleDriveService();
  final VaultDataRepository _repo = VaultDataRepository();
  bool _isSyncing = false;

  /// Procesa los items `pendiente` hacia el appDataFolder.
  // TODO(F5): reintentos, `error`, id remoto devuelto por Drive (hoy
  // uploadEncryptedFile devuelve bool) y política de borrar copia local.
  Future<void> processSyncQueue() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      await AppPaths.init();
      final pending = await _repo.getItemsBySyncStatus(SyncStatus.pendiente);

      for (final item in pending) {
        final file = AppPaths.resolve(item.encryptedPath);
        if (!await file.exists()) continue;

        await _repo.updateSyncStatus(item.id, SyncStatus.subiendo);
        final uploaded = await _driveService.uploadEncryptedFile(
          file,
          '${item.id}.vault',
        );
        await _repo.updateSyncStatus(
          item.id,
          uploaded ? SyncStatus.enNube : SyncStatus.error,
        );
      }
    } catch (e) {
      // Error de red o sincronización: silencioso hasta F5.
    } finally {
      _isSyncing = false;
    }
  }
}
