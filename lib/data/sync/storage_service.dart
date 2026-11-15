import '../../core/services/cache_manager.dart';
import '../repositories/vault_data_repository.dart';
import 'offline_service.dart';

/// Espacio liberado por una limpieza (Ajustes > Almacenamiento).
class FreedSpace {
  const FreedSpace({required this.files, required this.bytes});

  final int files;
  final int bytes;
}

/// Operaciones de almacenamiento de Ajustes (F8) sobre la caché LRU y el modo
/// "sin conexión". Solo toca copias locales de items con copia VERIFICADA en
/// la nube (ver [CacheManager]): nunca `pendiente`, `subiendo` ni `error`.
class StorageService {
  StorageService({
    required this.cache,
    required VaultDataRepository items,
    this.offline,
  }) : _items = items;

  final CacheManager cache;
  final VaultDataRepository _items;
  final OfflineService? offline;

  Future<CacheStats> stats() => cache.stats();

  /// Cambia el límite y purga de inmediato lo que lo exceda. Devuelve lo
  /// liberado.
  Future<FreedSpace> setLimitBytes(int bytes) async {
    final before = await cache.stats();
    await cache.setLimitBytes(bytes);
    final after = await cache.stats();
    return _diff(before, after, includeOffline: false);
  }

  /// "Vaciar caché ahora": purga toda la caché purgable. Lo "sin conexión"
  /// se conserva.
  Future<FreedSpace> clearCache() async {
    final before = await cache.stats();
    await cache.enforce(maxBytes: 0);
    final after = await cache.stats();
    return _diff(before, after, includeOffline: false);
  }

  /// "Liberar espacio sin conexión": quita la marca de todo lo verificado en
  /// la nube y purga su copia local. Los archivos siguen en la nube y se
  /// vuelven a descargar al abrirlos. Los abiertos en este momento se
  /// conservan.
  Future<FreedSpace> freeOfflineSpace() async {
    final before = await cache.stats();
    await _items.clearOfflineFlagsForVerified();
    // sin_conexion -> en_cache/en_nube según haya copia local.
    await offline?.reconcile();
    await cache.enforce(maxBytes: 0);
    final after = await cache.stats();
    return _diff(before, after, includeOffline: true);
  }

  FreedSpace _diff(
    CacheStats before,
    CacheStats after, {
    required bool includeOffline,
  }) {
    final files =
        before.cachedCount -
        after.cachedCount +
        (includeOffline ? before.offlineCount - after.offlineCount : 0);
    final bytes =
        before.cachedBytes -
        after.cachedBytes +
        (includeOffline ? before.offlineBytes - after.offlineBytes : 0);
    return FreedSpace(
      files: files < 0 ? 0 : files,
      bytes: bytes < 0 ? 0 : bytes,
    );
  }
}
