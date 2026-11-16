import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/painting.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../core/services/app_paths.dart';
import '../../../core/session/image_cache_wipe.dart';
import '../../../data/models/vault_item_model.dart';

/// Descifra miniaturas (`thumbs/<id>.thumb`) con la subllave "thumbs" y las
/// guarda en una caché LRU en memoria (solo bytes descifrados de ~256 px).
///
/// La caché se vacía con [clear] (se enlaza al bloqueo de la sesión).
class EncryptedThumbnailLoader {
  EncryptedThumbnailLoader({
    required this.thumbsKey,
    this.capacity = 96,
    CryptoService? crypto,
    File Function(String relativePath)? resolve,
  }) : _crypto = crypto ?? CryptoService(),
       _resolve = resolve ?? AppPaths.resolve;

  /// `null` = bóveda bloqueada.
  final SecretKey? Function() thumbsKey;

  /// Máximo de miniaturas en memoria.
  final int capacity;
  final CryptoService _crypto;
  final File Function(String) _resolve;

  // LinkedHashMap mantiene orden de inserción: el primero es el menos usado.
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _inFlight = {};

  int get cachedCount => _cache.length;

  /// Firma compatible con `ThumbnailLoader` de `VaultServices`.
  Future<ImageProvider?> call(VaultItemModel item) async {
    final bytes = await load(item);
    return bytes == null ? null : MemoryImage(bytes);
  }

  /// Bytes descifrados (JPEG) o `null` si no hay miniatura o falla.
  Future<Uint8List?> load(VaultItemModel item) {
    final rel = item.thumbPath;
    if (rel == null) return Future.value(null);
    final cacheKey = '${item.id}|$rel';
    final hit = _cache.remove(cacheKey);
    if (hit != null) {
      _cache[cacheKey] = hit; // más reciente
      return Future.value(hit);
    }
    return _inFlight[cacheKey] ??= _decrypt(rel, item.thumbFileId).then((
      bytes,
    ) {
      _inFlight.remove(cacheKey);
      if (bytes != null) {
        _cache[cacheKey] = bytes;
        while (_cache.length > capacity) {
          _cache.remove(_cache.keys.first);
        }
      }
      return bytes;
    });
  }

  Future<Uint8List?> _decrypt(String rel, String? expectedFileId) async {
    final key = thumbsKey();
    if (key == null) return null;
    try {
      final file = _resolve(rel);
      if (!await file.exists()) return null;
      // S-09: una miniatura de otro item (mismo vault, auténtica) no se
      // muestra: se trata como dañada.
      return await _crypto.decryptBytes(
        await file.readAsBytes(),
        key,
        expectedFileId: expectedFileId,
      );
    } on Object {
      // Miniatura corrupta/ausente: la UI muestra el ícono por tipo.
      return null;
    }
  }

  /// Vacía la caché y sobrescribe con ceros los bytes en claro (S-05). Solo
  /// se llama al bloquear (ahí ya se vacía el `ImageCache`), así que ningún
  /// `ImageProvider` activo los volverá a leer.
  void clear() {
    for (final b in _cache.values) {
      zeroFill(b);
    }
    _cache.clear();
  }
}
