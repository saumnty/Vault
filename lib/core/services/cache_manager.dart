import 'dart:io';

import '../../data/models/sync_status.dart';
import '../../data/repositories/vault_data_repository.dart';
import 'app_paths.dart';

/// Caché local de archivos cifrados de items que ya están en la nube.
///
/// Un item `en_cache` tiene copia local en `vault/<id>.vault` que se puede
/// expulsar (LRU por `lastAccessedAt`) sin perder datos, porque existe en
/// Drive. Los items offline efectivos (propios o por carpeta) nunca se
/// expulsan. TODO(F6): afinar política y tamaño configurable.
class CacheManager {
  static final CacheManager instance = CacheManager._init(
    VaultDataRepository(),
  );
  CacheManager._init(this._repo);

  /// Para pruebas / inyección.
  CacheManager.withRepository(this._repo);

  final VaultDataRepository _repo;

  // Límite máximo de caché local (Ejemplo: 500 MB)
  static const int maxCacheSizeBytes = 500 * 1024 * 1024;

  /// Directorio de temporales de descarga/visualización.
  Future<Directory> getCacheDirectory() async {
    await AppPaths.init();
    return AppPaths.cacheDir;
  }

  /// Expulsa copias locales `en_cache` (menos usadas primero) hasta bajar de
  /// [maxBytes], saltando items offline efectivos. Devuelve los ids expulsados.
  Future<List<String>> enforceLruLimit({int maxBytes = maxCacheSizeBytes}) async {
    await AppPaths.init();
    final cached = await _repo.getCachedItemsLru();
    final sizes = <String, int>{};
    var total = 0;
    for (final item in cached) {
      final f = AppPaths.resolve(item.encryptedPath);
      if (await f.exists()) {
        final len = await f.length();
        sizes[item.id] = len;
        total += len;
      }
    }
    if (total <= maxBytes) return const [];

    final protected = await _repo.getEffectiveOfflineItemIds();
    final evicted = <String>[];
    for (final item in cached) {
      if (total <= maxBytes) break;
      if (protected.contains(item.id)) continue;
      final size = sizes[item.id];
      if (size == null) continue;
      if (item.driveFileId == null) continue; // sin copia en la nube: no borrar
      await AppPaths.resolve(item.encryptedPath).delete();
      await _repo.updateSyncStatus(item.id, SyncStatus.enNube);
      total -= size;
      evicted.add(item.id);
    }
    return evicted;
  }

  /// `true` si el archivo cifrado del item existe localmente.
  Future<bool> isItemLocallyAvailable(String itemId) async {
    final item = await _repo.getItem(itemId);
    if (item == null) return false;
    await AppPaths.init();
    return AppPaths.resolve(item.encryptedPath).exists();
  }

  Future<File> cacheFile(String fileName, List<int> bytes) async {
    await enforceLruLimit();
    final cacheDir = await getCacheDirectory();
    final file = File('${cacheDir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes);
    return file;
  }
}
