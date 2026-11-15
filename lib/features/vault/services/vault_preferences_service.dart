import '../../../core/services/app_paths.dart';
import '../../../data/models/sync_status.dart';
import '../../../data/repositories/vault_data_repository.dart';
import '../../../data/cloud/cloud_provider.dart';

class VaultPreferenceService {
  final VaultDataRepository _repo = VaultDataRepository();

  /// Alternar estado de Favorito
  Future<void> toggleFavorite(String itemId, bool currentStatus) =>
      _repo.setItemFavorite(itemId, !currentStatus);

  /// Alternar modo Sin Conexión de un item. Al activarlo se asegura la copia
  /// local cifrada (`encryptedPath`), descargándola de Drive si falta.
  Future<bool> toggleOfflineMode(String itemId, bool makeOffline) async {
    try {
      final item = await _repo.getItem(itemId);
      if (item == null) return false;

      if (makeOffline) {
        await AppPaths.init();
        final target = AppPaths.resolve(item.encryptedPath);
        if (!await target.exists()) {
          final driveId = item.driveFileId;
          if (driveId == null) return false;
          await CloudProvider.instance.download(driveId, target);
        }
        await _repo.updateSyncStatus(itemId, SyncStatus.sinConexion);
      } else if (item.syncStatus == SyncStatus.sinConexion) {
        await _repo.updateSyncStatus(
          itemId,
          item.driveFileId != null ? SyncStatus.enCache : SyncStatus.pendiente,
        );
      }
      await _repo.setItemOffline(itemId, makeOffline);
      return true;
    } catch (e) {
      return false;
    }
  }
}
