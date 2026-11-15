import 'dart:async';
import 'dart:io';

import '../../data/models/sync_status.dart';
import '../../data/models/vault_item_model.dart';
import '../../data/repositories/vault_data_repository.dart';
import '../crypto/secure_kv_store.dart';
import 'app_paths.dart';

/// Preferencia persistida del límite de caché (la ajusta F8).
class CachePreferences {
  CachePreferences(this._store);

  final SecureKeyValueStore _store;

  static const String limitKey = 'cache.v1.limit_bytes';

  /// 500 MB por defecto.
  static const int defaultLimitBytes = 500 * 1024 * 1024;

  /// Mínimo aceptado en ajustes (0 = purgar todo lo purgable; solo pruebas).
  static const int minLimitBytes = 0;

  Future<int> getLimitBytes() async {
    final v = int.tryParse(await _store.read(limitKey) ?? '');
    return v == null || v < minLimitBytes ? defaultLimitBytes : v;
  }

  Future<void> setLimitBytes(int bytes) {
    if (bytes < minLimitBytes) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'El límite no puede ser negativo',
      );
    }
    return _store.write(limitKey, '$bytes');
  }
}

/// Resumen de la caché local.
class CacheStats {
  const CacheStats({
    required this.cachedBytes,
    required this.cachedCount,
    required this.offlineBytes,
    required this.offlineCount,
    required this.limitBytes,
  });

  /// Bytes de `.vault` locales con copia verificada en la nube que se pueden
  /// purgar (cuentan contra el límite).
  final int cachedBytes;
  final int cachedCount;

  /// Bytes de los "disponibles sin conexión" (no se purgan ni cuentan).
  final int offlineBytes;
  final int offlineCount;
  final int limitBytes;
}

/// Caché LRU de archivos cifrados de items que ya están verificados en la
/// nube (F6a).
///
/// * Candidatos: `.vault` locales de items `en_nube`/`en_cache` con
///   `driveFileId` + `cloudMd5` + `cloudSize` y que NO sean offline efectivos
///   (propios o por carpeta ancestra). Nunca se tocan `pendiente`,
///   `subiendo`, `error` ni `sin_conexion`.
/// * El presupuesto ([getLimitBytes], 500 MB por defecto) cuenta solo los
///   candidatos: lo "sin conexión" es una promesa al usuario y no debe
///   provocar que se purgue todo lo demás.
/// * Se purga por `lastAccessedAt` ascendente (si nunca se abrió, vale la
///   fecha de creación) hasta bajar del límite. Al purgar: borra
///   `vault/<id>.vault`, el item pasa a `en_nube` y se CONSERVA la miniatura.
class CacheManager {
  CacheManager({
    required VaultDataRepository repository,
    required CachePreferences preferences,
    File Function(String relativePath)? resolvePath,
  }) : _repo = repository,
       _prefs = preferences,
       _resolve = resolvePath ?? AppPaths.resolve;

  final VaultDataRepository _repo;
  final CachePreferences _prefs;
  final File Function(String) _resolve;

  Future<void> _tail = Future<void>.value();

  /// Items abiertos ahora mismo (p. ej. un video en streaming, F6b): su
  /// `.vault` no se purga aunque se supere el límite. Contador por id.
  final Map<String, int> _inUse = {};

  /// Marca [itemId] como en uso hasta [releaseInUse].
  void markInUse(String itemId) =>
      _inUse.update(itemId, (n) => n + 1, ifAbsent: () => 1);

  void releaseInUse(String itemId) {
    final n = _inUse[itemId];
    if (n == null) return;
    if (n <= 1) {
      _inUse.remove(itemId);
    } else {
      _inUse[itemId] = n - 1;
    }
  }

  bool isInUse(String itemId) => _inUse.containsKey(itemId);

  Future<int> getLimitBytes() => _prefs.getLimitBytes();

  /// API para F8 (ajustes). Aplica el nuevo límite de inmediato.
  Future<List<String>> setLimitBytes(int bytes) async {
    await _prefs.setLimitBytes(bytes);
    return enforce();
  }

  int _lastUsed(VaultItemModel i) =>
      i.lastAccessedAt ??
      DateTime.tryParse(i.createdAt)?.millisecondsSinceEpoch ??
      0;

  /// Tamaños actuales.
  Future<CacheStats> stats() async {
    final verified = await _repo.getCloudVerifiedItems();
    final offline = await _repo.getEffectiveOfflineItemIds();
    var cb = 0, cc = 0, ob = 0, oc = 0;
    for (final item in verified) {
      final f = _resolve(item.encryptedPath);
      if (!await f.exists()) continue;
      final len = await f.length();
      if (offline.contains(item.id)) {
        ob += len;
        oc++;
      } else {
        cb += len;
        cc++;
      }
    }
    return CacheStats(
      cachedBytes: cb,
      cachedCount: cc,
      offlineBytes: ob,
      offlineCount: oc,
      limitBytes: await getLimitBytes(),
    );
  }

  /// Purga LRU hasta bajar de [maxBytes] (por defecto el límite guardado).
  /// Las llamadas se serializan. Devuelve los ids purgados, en orden.
  Future<List<String>> enforce({int? maxBytes}) {
    final run = _tail.then((_) => _enforce(maxBytes));
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<List<String>> _enforce(int? maxBytes) async {
    final limit = maxBytes ?? await getLimitBytes();
    final verified = await _repo.getCloudVerifiedItems();
    final protected = await _repo.getEffectiveOfflineItemIds();
    final candidates = <(VaultItemModel, int)>[];
    var total = 0;
    for (final item in verified) {
      if (protected.contains(item.id) || item.isOffline) continue;
      if (item.syncStatus != SyncStatus.enNube &&
          item.syncStatus != SyncStatus.enCache) {
        continue;
      }
      final f = _resolve(item.encryptedPath);
      if (!await f.exists()) continue;
      final len = await f.length();
      candidates.add((item, len));
      total += len;
    }
    if (total <= limit) return const [];
    candidates.sort((a, b) => _lastUsed(a.$1).compareTo(_lastUsed(b.$1)));
    final evicted = <String>[];
    for (final (item, size) in candidates) {
      if (total <= limit) break;
      if (_inUse.containsKey(item.id)) continue; // abierto: no se purga
      try {
        await _resolve(item.encryptedPath).delete();
      } on FileSystemException {
        continue; // en uso: se intentará la próxima vez
      }
      try {
        await _repo.updateSyncStatus(item.id, SyncStatus.enNube);
      } on StateError catch (e) {
        if (e.message.contains('bloqueada')) rethrow;
      }
      total -= size;
      evicted.add(item.id);
    }
    return evicted;
  }
}
