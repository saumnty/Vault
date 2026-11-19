import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/crypto/crypto_service.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../../core/session/session_ticket.dart';
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
    this.paused,
    VaultPaths? paths,
    this.sessionTicket,
  }) : _crypto = crypto ?? CryptoService(),
       _paths = paths ?? VaultPaths.primary;

  /// Rutas de SU bóveda (D67; por defecto la principal).
  final VaultPaths _paths;

  /// D67 (fase 8): ticket de la sesión de SU bóveda (o `null` si no está
  /// abierta). Se captura al empezar la pasada y se comprueba antes de cada
  /// escritura (temporal, miniatura, fila). `null` (pruebas) = sin guarda.
  final SessionTicket? Function()? sessionTicket;

  bool _cancelRequested = false;

  /// Corta la pasada en curso (lo llama el bloqueo: D67).
  void cancel() {
    if (_running) _cancelRequested = true;
  }

  /// D61: `true` durante una rotación de la DEK (no se escriben miniaturas
  /// mientras los items cambian de generación). [run] no hace nada.
  final bool Function()? paused;

  final VaultDataRepository repository;
  final GalleryAssetSource source;
  final VideoThumbnailer videoThumbnailer;

  /// Subllaves por generación de llave del item (D60): la miniatura se
  /// escribe con la MISMA generación que su `.vault` (y con su nombre
  /// `thumbs/<id>[.kN].thumb`). `null` = bóveda bloqueada.
  final SecretKey? Function(int keyGen) filesKey;
  final SecretKey? Function(int keyGen) thumbsKey;
  final Directory Function() tempDirProvider;
  final int thumbnailSize;
  final int maxPerRun;
  final int autoMaxDecryptBytes;
  final CryptoService _crypto;

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
            (i.thumbPath == null || !_paths.resolve(i.thumbPath!).existsSync()))
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
    if (_running || (paused?.call() ?? false)) {
      return const ThumbnailRegenerationResult(
        candidates: 0,
        regenerated: 0,
        failed: 0,
      );
    }
    SessionTicket? ticket;
    final provider = sessionTicket;
    if (provider != null) {
      ticket = provider();
      if (ticket == null) {
        return const ThumbnailRegenerationResult(
          candidates: 0,
          regenerated: 0,
          failed: 0,
        );
      }
    }
    _running = true;
    _cancelRequested = false;
    var regenerated = 0;
    var failed = 0;
    var candidates = 0;
    bool halted() =>
        _cancelRequested ||
        (ticket != null && !ticket.isValid) ||
        (isCancelled?.call() ?? false);
    try {
      await AppPaths.init();
      List<VaultItemModel> list;
      try {
        list = await _candidates();
      } on StateError {
        // Bóveda bloqueada: nada que hacer.
        return const ThumbnailRegenerationResult(
          candidates: 0,
          regenerated: 0,
          failed: 0,
        );
      }
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
        if (halted()) break;
        // Si se bloqueó la bóveda a mitad, se corta.
        final tKey = thumbsKey(item.keyGen);
        final fKey = filesKey(item.keyGen);
        if (tKey == null || fKey == null) {
          // Bloqueada antes de empezar: la pasada no tuvo candidatos.
          if (done == 0) candidates = 0;
          break;
        }
        try {
          final ok = await _one(
            item,
            tKey,
            fKey,
            manual: manual,
            halted: halted,
          );
          if (ok) {
            regenerated++;
          } else {
            failed++;
            _failedThisSession.add(item.id);
          }
        } on _Halted {
          break;
        } on Object catch (e) {
          if (halted()) break;
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
      _cancelRequested = false;
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
    required bool Function() halted,
  }) async {
    void check() {
      if (halted()) throw const _Halted();
    }

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
      check();
      bytes = await _frameFromLocalVault(item, fKey, manual: manual);
    }
    if (bytes == null || bytes.isEmpty) return false;
    final enc = await _crypto.encryptBytes(bytes, tKey);
    final rel = AppPaths.thumbRelativePath(item.id, gen: item.keyGen);
    check(); // D67: antes de escribir la miniatura
    await _paths.resolve(rel).writeAsBytes(enc, flush: true);
    check(); // ...y antes de la fila
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
    final vault = _paths.resolve(item.encryptedPath);
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

/// La pasada se corta (bloqueo, otra bóveda, cancelación).
class _Halted implements Exception {
  const _Halted();
}
