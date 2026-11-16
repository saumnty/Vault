import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/crypto/crypto_service.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../../features/vault/models/browser_entry.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import 'gallery_asset_source.dart';
import 'video_thumbnailer.dart';

/// Resultado de una pasada de regeneración.
class ThumbnailRegenerationResult {
  const ThumbnailRegenerationResult({
    required this.candidates,
    required this.regenerated,
    required this.failed,
  });
  final int candidates;
  final int regenerated;
  final int failed;
}

/// Regenera las miniaturas que faltan de items YA importados (importaciones
/// anteriores a la corrección, o miniaturas perdidas al restaurar).
///
/// Por item, en este orden:
/// 1. La fototeca (`sourceAssetId`), si el original sigue ahí. En iOS puede
///    traerla de iCloud. // iOS: sin probar en dispositivo.
/// 2. Si es video y el `.vault` está en el teléfono: se descifra a un
///    temporal (borrado siempre, en `finally`) y se extrae un fotograma.
///    Los `.vault` que solo están en la nube NO se descargan solos.
///
/// Se ejecuta sola al desbloquear (acotada: [maxPerRun], y en modo automático
/// solo descifra videos de hasta [autoMaxDecryptBytes]) y a petición desde
/// Ajustes ([manual]), sin esos topes. Cada item fallido se recuerda hasta
/// que se cierre la app para no reintentarlo en cada desbloqueo.
class ThumbnailRegenerationService {
  ThumbnailRegenerationService({
    required this.repository,
    required this.source,
    required this.videoThumbnailer,
    required this.filesKey,
    required this.thumbsKey,
    required this.tempDirProvider,
    CryptoService? crypto,
    this.thumbnailSize = 256,
    this.maxPerRun = 40,
    this.autoMaxDecryptBytes = 100 * 1024 * 1024,
    String Function(String id)? thumbRelative,
  }) : _crypto = crypto ?? CryptoService(),
       _thumbRelative = thumbRelative ?? AppPaths.thumbRelativePath;

  final VaultDataRepository repository;
  final GalleryAssetSource source;
  final VideoThumbnailer videoThumbnailer;
  final SecretKey? Function() filesKey;
  final SecretKey? Function() thumbsKey;
  final Directory Function() tempDirProvider;
  final int thumbnailSize;
  final int maxPerRun;
  final int autoMaxDecryptBytes;
  final CryptoService _crypto;
  final String Function(String id) _thumbRelative;

  final Set<String> _failedThisSession = {};
  bool _running = false;
  bool get isRunning => _running;

  /// Cuántos items sin miniatura (imágenes y videos) hay ahora.
  Future<int> countMissing() async => (await _candidates()).length;

  Future<List<VaultItemModel>> _candidates() async {
    // Sin miniatura registrada, O registrada pero cuyo archivo local ya no
    // está (borrado, restauración incompleta).
    final all = await repository.getAllItems();
    return [
      for (final i in all)
        if ((fileKindOf(i) == FileKind.image ||
                fileKindOf(i) == FileKind.video) &&
            (i.thumbPath == null ||
                !AppPaths.resolve(i.thumbPath!).existsSync()))
          i,
    ];
  }

  /// Una pasada. [manual] ignora los topes de la pasada automática y
  /// reintenta también los que fallaron antes. [onProgress] recibe
  /// (hechos, total). Nunca lanza.
  Future<ThumbnailRegenerationResult> run({
    bool manual = false,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_running) {
      return const ThumbnailRegenerationResult(
        candidates: 0,
        regenerated: 0,
        failed: 0,
      );
    }
    _running = true;
    var regenerated = 0;
    var failed = 0;
    var candidates = 0;
    try {
      final tKey = thumbsKey();
      final fKey = filesKey();
      if (tKey == null || fKey == null) {
        return const ThumbnailRegenerationResult(
          candidates: 0,
          regenerated: 0,
          failed: 0,
        );
      }
      await AppPaths.init();
      var list = await _candidates();
      if (!manual) {
        list = [
          for (final i in list)
            if (!_failedThisSession.contains(i.id)) i,
        ];
        if (list.length > maxPerRun) list = list.sublist(0, maxPerRun);
      }
      candidates = list.length;
      if (candidates > 0) {
        VaultLog.d(
          'Regenerando miniaturas: $candidates elementos',
          category: 'thumbs',
        );
      }
      var done = 0;
      for (final item in list) {
        if (isCancelled?.call() ?? false) break;
        // Si se bloqueó la bóveda a mitad, se corta.
        if (thumbsKey() == null || filesKey() == null) break;
        try {
          final ok = await _one(item, tKey, fKey, manual: manual);
          if (ok) {
            regenerated++;
          } else {
            failed++;
            _failedThisSession.add(item.id);
          }
        } on Object catch (e) {
          failed++;
          _failedThisSession.add(item.id);
          VaultLog.e('Miniatura no regenerada', e, 'thumbs');
        }
        done++;
        onProgress?.call(done, candidates);
      }
      if (candidates > 0) {
        VaultLog.d(
          'Miniaturas: $regenerated regeneradas, $failed sin resolver',
          category: 'thumbs',
        );
      }
    } finally {
      _running = false;
    }
    return ThumbnailRegenerationResult(
      candidates: candidates,
      regenerated: regenerated,
      failed: failed,
    );
  }

  Future<bool> _one(
    VaultItemModel item,
    SecretKey tKey,
    SecretKey fKey, {
    required bool manual,
  }) async {
    Uint8List? bytes;
    // 1. Fototeca (si el original sigue allí).
    final assetId = item.sourceAssetId;
    if (assetId != null) {
      try {
        bytes = await source.thumbnail(assetId, size: thumbnailSize);
      } on Object catch (e) {
        VaultLog.e('Fototeca sin miniatura', e, 'thumbs');
      }
    }
    // 2. Video con .vault local: fotograma del contenido descifrado.
    if ((bytes == null || bytes.isEmpty) &&
        fileKindOf(item) == FileKind.video) {
      bytes = await _frameFromLocalVault(item, fKey, manual: manual);
    }
    if (bytes == null || bytes.isEmpty) return false;
    final enc = await _crypto.encryptBytes(bytes, tKey);
    final rel = _thumbRelative(item.id);
    await AppPaths.resolve(rel).writeAsBytes(enc, flush: true);
    await repository.setThumb(
      item.id,
      thumbPath: rel,
      thumbFileId: CryptoService.fileIdOfHeader(enc),
    );
    return true;
  }

  Future<Uint8List?> _frameFromLocalVault(
    VaultItemModel item,
    SecretKey fKey, {
    required bool manual,
  }) async {
    final vault = AppPaths.resolve(item.encryptedPath);
    if (!await vault.exists()) return null; // solo en la nube: no se descarga
    if (!manual && await vault.length() > autoMaxDecryptBytes) return null;
    final workDir = Directory(
      p.join(tempDirProvider().path, 'regen_${item.id}'),
    );
    final plain = File(
      p.join(workDir.path, 'video${p.extension(item.name).toLowerCase()}'),
    );
    try {
      await workDir.create(recursive: true);
      // S-09: el .vault debe ser el registrado para este item.
      final expected = item.fileId;
      if (expected != null &&
          await CryptoService.fileIdOfFile(vault) != expected) {
        VaultLog.d('Miniatura: .vault no coincide', category: 'thumbs');
        return null;
      }
      await _crypto.decryptFile(vault, plain, fKey);
      return await videoThumbnailer.thumbnail(plain, size: thumbnailSize);
    } finally {
      try {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      } on FileSystemException {
        // El barrido de arranque limpia import_tmp.
      }
    }
  }

  @visibleForTesting
  Set<String> get failedThisSession => _failedThisSession;
}
