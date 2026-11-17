import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/crypto/crypto_service.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import 'gallery_asset_source.dart';
import 'video_compressor.dart';
import 'video_thumbnailer.dart';

/// Etapa por la que pasa un archivo del lote.
enum ImportStage {
  queued,
  downloading, // iOS: iCloud
  compressing,
  hashing,
  encrypting,
  thumbnail,
  done,
  failed,
  cancelled,
}

/// Cancelación cooperativa de un lote.
class ImportCancelToken {
  bool _cancelled = false;
  final List<VoidCallback> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void addListener(VoidCallback l) => _listeners.add(l);
  void removeListener(VoidCallback l) => _listeners.remove(l);
}

/// Resultado de un archivo del lote.
class ImportItemResult {
  const ImportItemResult({
    required this.assetId,
    required this.stage,
    this.itemId,
    this.error,
    this.originalBytes,
    this.storedBytes,
    this.compressed = false,
    this.thumbnailCreated = false,
  });

  final String assetId;

  /// `done`, `failed` o `cancelled`.
  final ImportStage stage;
  final String? itemId;
  final String? error;

  /// Tamaño del original y del contenido guardado (difieren si se comprimió).
  final int? originalBytes;
  final int? storedBytes;
  final bool compressed;
  final bool thumbnailCreated;

  bool get ok => stage == ImportStage.done;
}

class ImportBatchResult {
  const ImportBatchResult(this.items, {required this.cancelled});
  final List<ImportItemResult> items;
  final bool cancelled;

  int get succeeded => items.where((i) => i.ok).length;
  int get failed => items.where((i) => i.stage == ImportStage.failed).length;
  int get notProcessed =>
      items.where((i) => i.stage == ImportStage.cancelled).length;
}

/// Progreso observable del lote (para la UI).
@immutable
class ImportBatchProgress {
  const ImportBatchProgress({
    this.total = 0,
    this.completed = 0,
    this.failed = 0,
    this.currentIndex = 0,
    this.currentName,
    this.stage = ImportStage.queued,
    this.fraction,
    this.originalBytes,
    this.compressedBytes,
    this.running = false,
  });

  final int total;

  /// Terminados correctamente.
  final int completed;
  final int failed;
  final int currentIndex;
  final String? currentName;
  final ImportStage stage;

  /// Avance de la etapa actual (0..1) o `null` si es indeterminado.
  final double? fraction;

  /// Tamaño antes/después de comprimir el video actual.
  final int? originalBytes;
  final int? compressedBytes;
  final bool running;
}

class ImportOptions {
  const ImportOptions({
    this.folderId,
    this.videoQuality = VideoQualityOption.original,
  });
  final String? folderId;
  final VideoQualityOption videoQuality;
}

/// Importa assets de la galería a la bóveda: (descarga iCloud) -> (comprime
/// video) -> SHA-256 -> cifra a `vault/<id>.vault` -> miniatura cifrada ->
/// registro en BD. Un error en un archivo no aborta el lote.
///
/// NUNCA borra originales por su cuenta: ver
/// [deleteOriginalsConfirmedInCloud].
class GalleryImportService {
  GalleryImportService({
    required this.source,
    required this.compressor,
    required this.repository,
    required this.filesKey,
    required this.thumbsKey,
    required this.tempDirProvider,
    CryptoService? crypto,
    String Function()? idGenerator,
    DateTime Function()? clock,
    bool? isIOS,
    this.originalDeletionEnabled = false,
    this.deletionEnabledProvider,
    this.cloudVerifier,
    this.thumbnailSize = 256,
    VideoThumbnailer? videoThumbnailer,
  }) : _crypto = crypto ?? CryptoService(),
       _videoThumbs = videoThumbnailer ?? PlatformVideoThumbnailer(),
       _newId = idGenerator ?? (() => const Uuid().v4()),
       _clock = clock ?? DateTime.now,
       _isIOS = isIOS ?? Platform.isIOS;

  final GalleryAssetSource source;
  final VideoCompressor compressor;
  final VaultDataRepository repository;

  /// Subllaves de la sesión (`null` = bóveda bloqueada).
  final SecretKey? Function() filesKey;
  final SecretKey? Function() thumbsKey;

  /// Directorio para temporales; se crea bajo demanda.
  final Directory Function() tempDirProvider;
  final int thumbnailSize;

  /// Bandera maestra del borrado de originales. APAGADA hasta que F5 verifique
  /// la copia en la nube.
  final bool originalDeletionEnabled;

  /// Si se da, manda sobre [originalDeletionEnabled]: se consulta en cada
  /// intento (la preferencia del usuario, apagada por defecto).
  final Future<bool> Function()? deletionEnabledProvider;

  Future<bool> get isDeletionEnabled async {
    final provider = deletionEnabledProvider;
    if (provider == null) return originalDeletionEnabled;
    try {
      return await provider();
    } on Object {
      return false;
    }
  }

  /// Lo aporta F5: confirma (hash/tamaño) que la copia de Drive coincide.
  /// Sin verificador no se borra nada.
  final Future<bool> Function(VaultItemModel item)? cloudVerifier;

  final CryptoService _crypto;
  final VideoThumbnailer _videoThumbs;
  final String Function() _newId;
  final DateTime Function() _clock;
  final bool _isIOS;

  final ValueNotifier<ImportBatchProgress> progress = ValueNotifier(
    const ImportBatchProgress(),
  );

  bool _running = false;
  bool get isRunning => _running;

  /// Importa [assets] secuencialmente. Lanza [StateError] si la bóveda está
  /// bloqueada o ya hay un lote en curso.
  Future<ImportBatchResult> importAssets(
    List<GalleryAsset> assets,
    ImportOptions options, {
    ImportCancelToken? cancelToken,
  }) async {
    final fKey = filesKey();
    final tKey = thumbsKey();
    if (fKey == null || tKey == null) {
      throw StateError('La bóveda está bloqueada');
    }
    if (_running) throw StateError('Ya hay una importación en curso');
    _running = true;
    final token = cancelToken ?? ImportCancelToken();
    void onCancel() => compressor.cancel();
    token.addListener(onCancel);

    await AppPaths.init();
    final results = <ImportItemResult>[];
    var done = 0;
    var failed = 0;
    VaultLog.d(
      'Importación iniciada: ${assets.length} elementos',
      category: 'import',
    );
    try {
      for (var i = 0; i < assets.length; i++) {
        final asset = assets[i];
        if (token.isCancelled) {
          results.add(
            ImportItemResult(assetId: asset.id, stage: ImportStage.cancelled),
          );
          continue;
        }
        void emit(
          ImportStage stage, {
          double? fraction,
          int? original,
          int? compressed,
        }) {
          progress.value = ImportBatchProgress(
            total: assets.length,
            completed: done,
            failed: failed,
            currentIndex: i,
            currentName: asset.title,
            stage: stage,
            fraction: fraction,
            originalBytes: original,
            compressedBytes: compressed,
            running: true,
          );
        }

        emit(ImportStage.queued);
        ImportItemResult result;
        try {
          result = await _importOne(asset, options, fKey, tKey, token, emit);
        } on _Cancelled {
          result = ImportItemResult(
            assetId: asset.id,
            stage: ImportStage.cancelled,
          );
        } on Object catch (e) {
          result = ImportItemResult(
            assetId: asset.id,
            stage: ImportStage.failed,
            error: e.toString(),
          );
        }
        if (result.ok) done++;
        if (result.stage == ImportStage.failed) failed++;
        results.add(result);
      }
    } finally {
      token.removeListener(onCancel);
      try {
        await compressor.cleanup();
      } on Object {
        // Limpieza best-effort.
      }
      await _cleanTempRoot();
      await _clearSourceCaches();
      progress.value = ImportBatchProgress(
        total: assets.length,
        completed: done,
        failed: failed,
        currentIndex: assets.length,
        stage: token.isCancelled ? ImportStage.cancelled : ImportStage.done,
        running: false,
      );
      _running = false;
      VaultLog.d(
        'Importación terminada: $done ok, $failed fallos',
        category: 'import',
      );
    }
    return ImportBatchResult(results, cancelled: token.isCancelled);
  }

  Future<ImportItemResult> _importOne(
    GalleryAsset asset,
    ImportOptions options,
    SecretKey fKey,
    SecretKey tKey,
    ImportCancelToken token,
    void Function(
      ImportStage stage, {
      double? fraction,
      int? original,
      int? compressed,
    })
    emit,
  ) async {
    void check() {
      if (token.isCancelled) throw _Cancelled();
    }

    final itemId = _newId();
    final vaultRel = AppPaths.vaultRelativePath(itemId);
    final thumbRel = AppPaths.thumbRelativePath(itemId);
    final workDir = Directory(p.join(tempDirProvider().path, itemId));
    final toDelete = <File>[];
    var committed = false;
    try {
      await workDir.create(recursive: true);

      // (a) Materializar el original. iOS: si solo está en iCloud, descarga
      // con progreso.
      // iOS: RUTA SIN PROBAR (iCloud real no verificado).
      final local = await source.isLocallyAvailable(asset.id);
      if (!local && !_isIOS) {
        throw StateError('El original no está disponible en el dispositivo');
      }
      emit(
        local ? ImportStage.hashing : ImportStage.downloading,
        fraction: local ? null : 0,
      );
      final origin = await source.originFile(
        asset.id,
        allowNetwork: !local && _isIOS,
        onProgress: (f) => emit(ImportStage.downloading, fraction: f),
      );
      if (origin == null) {
        throw StateError('No se pudo obtener el archivo original');
      }
      if (origin.isTemporary) toDelete.add(origin.file);
      check();
      final originalBytes = await origin.file.length();

      // (b) Compresión opcional de video.
      var content = origin.file;
      var compressed = false;
      if (asset.isVideo &&
          options.videoQuality != VideoQualityOption.original) {
        emit(ImportStage.compressing, fraction: 0, original: originalBytes);
        final compressWatch = Stopwatch()..start();
        final out = await compressor.compress(
          origin.file,
          options.videoQuality,
          onProgress: (f) => emit(
            ImportStage.compressing,
            fraction: f,
            original: originalBytes,
          ),
        );
        check();
        if (!kReleaseMode) {
          // Solo tamaños y duración (sin nombres ni rutas).
          debugPrint(
            '[vault-import] compresion ${options.videoQuality.name}: '
            'original $originalBytes B -> '
            '${out == null ? 'sin resultado' : '${out.sizeBytes} B'} '
            'en ${compressWatch.elapsedMilliseconds} ms; se usa el '
            'comprimido: ${out != null && out.sizeBytes < originalBytes}',
          );
        }
        if (out != null) {
          toDelete.add(out.file);
          // Solo se usa si realmente ahorra espacio.
          if (out.sizeBytes < originalBytes) {
            content = out.file;
            compressed = true;
            emit(
              ImportStage.compressing,
              fraction: 1,
              original: originalBytes,
              compressed: out.sizeBytes,
            );
          }
        }
      }
      final storedBytes = await content.length();

      // (c) SHA-256 en streaming del contenido que se guarda (el original si
      // no se comprimió; el comprimido en caso contrario).
      emit(ImportStage.hashing);
      final stageWatch = Stopwatch()..start();
      final contentHash = await sha256OfFile(content);
      final hashMs = stageWatch.elapsedMilliseconds;
      check();

      // (d) Cifrar con la subllave "files".
      emit(ImportStage.encrypting);
      stageWatch.reset();
      final fileHeader = await _crypto.encryptFile(
        content,
        AppPaths.resolve(vaultRel),
        fKey,
      );
      if (!kReleaseMode) {
        // Solo tamaños y duraciones (sin nombres ni rutas).
        debugPrint(
          '[vault-import] $storedBytes B: sha256 $hashMs ms, '
          'cifrado ${stageWatch.elapsedMilliseconds} ms',
        );
      }
      check();

      // (e) Miniatura cifrada con la subllave "thumbs". Su fallo no aborta.
      emit(ImportStage.thumbnail);
      var thumbOk = false;
      String? thumbFileId;
      try {
        Uint8List? bytes;
        if (asset.isVideo) {
          // Videos: primero un fotograma del archivo ya materializado (también
          // sirve si el original venía de iCloud); no depende de la fototeca.
          bytes = await _videoThumbs.thumbnail(content, size: thumbnailSize);
          if (bytes == null || bytes.isEmpty) {
            VaultLog.d(
              'Miniatura de video: se prueba la fototeca',
              category: 'thumbs',
            );
          }
        }
        if (bytes == null || bytes.isEmpty) {
          bytes = await source.thumbnail(asset.id, size: thumbnailSize);
        }
        if (bytes != null && bytes.isNotEmpty) {
          final enc = await _crypto.encryptBytes(bytes, tKey);
          await AppPaths.resolve(thumbRel).writeAsBytes(enc, flush: true);
          thumbFileId = CryptoService.fileIdOfHeader(enc);
          thumbOk = true;
          VaultLog.d('Miniatura generada', category: 'thumbs');
        } else {
          VaultLog.d(
            asset.isVideo ? 'Sin miniatura (video)' : 'Sin miniatura (imagen)',
            category: 'thumbs',
          );
        }
      } on Object catch (e) {
        VaultLog.e('Miniatura no generada', e, 'thumbs');
      }
      check();

      // (f) Registro en BD.
      final name =
          asset.title ?? p.basename(origin.file.path).replaceAll('\\', '/');
      await repository.insertItem(
        VaultItemModel(
          id: itemId,
          name: name,
          folderId: options.folderId,
          encryptedPath: vaultRel,
          fileSize: storedBytes,
          mimeType: asset.mimeType ?? mimeFromName(name, asset.type),
          createdAt: _clock().toIso8601String(),
          syncStatus: SyncStatus.pendiente,
          thumbPath: thumbOk ? thumbRel : null,
          fileId: fileHeader.fileIdString,
          thumbFileId: thumbOk ? thumbFileId : null,
          contentHash: contentHash,
          sourceAssetId: asset.id,
          durationMs: asset.isVideo ? asset.duration.inMilliseconds : null,
        ),
      );
      committed = true;
      emit(ImportStage.done, fraction: 1);
      return ImportItemResult(
        assetId: asset.id,
        stage: ImportStage.done,
        itemId: itemId,
        originalBytes: originalBytes,
        storedBytes: storedBytes,
        compressed: compressed,
        thumbnailCreated: thumbOk,
      );
    } finally {
      for (final f in toDelete) {
        await _tryDelete(f);
      }
      if (!committed) {
        // Sin fila en BD no debe quedar nada cifrado huérfano.
        await _tryDelete(AppPaths.resolve(vaultRel));
        await _tryDelete(AppPaths.resolve(thumbRel));
      }
      try {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      } on Object {
        // Best-effort.
      }
    }
  }

  Future<void> _cleanTempRoot() async {
    try {
      final root = tempDirProvider();
      if (await root.exists()) await root.delete(recursive: true);
    } on Object {
      // Best-effort.
    }
  }

  /// S-03: miniaturas/copias en claro que el plugin de la galería deja en la
  /// caché de la app (Glide en Android).
  Future<void> _clearSourceCaches() async {
    try {
      await source.clearPlainCaches();
    } on Object {
      // Best-effort: también se limpia al arrancar.
    }
  }

  Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on Object {
      // Best-effort.
    }
  }

  // ---------------------------------------------------------------------
  // Borrado de originales (g)
  // ---------------------------------------------------------------------

  /// Items cuyo original PODRÍA borrarse: `en_nube`, con `driveFileId`,
  /// `contentHash` y `sourceAssetId`. No borra nada.
  Future<List<VaultItemModel>> deleteOriginalCandidates() async {
    final inCloud = await repository.getItemsBySyncStatus(
      SyncStatus.enNube,
      includeTrashed: false,
    );
    return [
      for (final i in inCloud)
        if (i.driveFileId != null &&
            i.contentHash != null &&
            i.sourceAssetId != null)
          i,
    ];
  }

  /// Cuántos originales distintos podrían borrarse (ya en la nube según la BD
  /// local, SIN consultar a Drive). 0 si el borrado está apagado o no hay
  /// verificador. Sirve para el aviso de la cuadrícula; no borra nada.
  Future<int> pendingOriginalsCount() async {
    if (cloudVerifier == null || !await isDeletionEnabled) return 0;
    final all = await deleteOriginalCandidates();
    return {for (final c in all) c.sourceAssetId}.length;
  }

  /// Candidatos cuya copia en la nube SE VERIFICA ahora mismo (consulta a
  /// Drive). Es la lista que se muestra al usuario antes de pedir la
  /// confirmación. Vacía si el borrado está apagado o no hay verificador. No
  /// borra nada.
  Future<List<VaultItemModel>> verifiedDeleteCandidates() async {
    final verifier = cloudVerifier;
    if (verifier == null || !await isDeletionEnabled) return const [];
    // Un mismo original puede haberse importado varias veces (p. ej. con
    // otra calidad): se lista UNA vez por original, con la copia más grande
    // que se verifique.
    final all = await deleteOriginalCandidates()
      ..sort((a, b) => b.fileSize.compareTo(a.fileSize));
    final seen = <String>{};
    final out = <VaultItemModel>[];
    for (final c in all) {
      if (seen.contains(c.sourceAssetId)) continue;
      if (await verifier(c)) {
        seen.add(c.sourceAssetId!);
        out.add(c);
      }
    }
    return out;
  }

  /// Borra de la galería los originales de [candidates] (subconjunto de
  /// [deleteOriginalCandidates] que el usuario VIO y confirmó).
  ///
  /// No borra NADA si: [userConfirmed] es false, la bandera
  /// [originalDeletionEnabled] está apagada, no hay [cloudVerifier] (F5), o el
  /// item ya no cumple las condiciones / no pasa la verificación. Devuelve los
  /// ids de item cuyo original se borró.
  Future<List<String>> deleteOriginalsConfirmedInCloud({
    required List<VaultItemModel> candidates,
    required bool userConfirmed,
  }) async {
    if (!userConfirmed || !await isDeletionEnabled) return const [];
    final verifier = cloudVerifier;
    if (verifier == null) return const [];
    final candidatesNow = await deleteOriginalCandidates();
    final eligible = {for (final c in candidatesNow) c.id};
    final byAsset = <String, String>{}; // assetId -> itemId
    for (final c in candidates) {
      if (!eligible.contains(c.id)) continue;
      // Releer: el estado pudo cambiar desde que se mostró la lista.
      final fresh = await repository.getItem(c.id);
      if (fresh == null || fresh.syncStatus != SyncStatus.enNube) continue;
      if (fresh.driveFileId == null || fresh.sourceAssetId == null) continue;
      if (!await verifier(fresh)) continue;
      byAsset[fresh.sourceAssetId!] = fresh.id;
    }
    if (byAsset.isEmpty) return const [];
    final deletedAssets = await source.deleteAssets(byAsset.keys.toList());
    // S-03: sin original en la galería, sus miniaturas en la caché del
    // plugin serían la única copia en claro fuera de la bóveda.
    await _clearSourceCaches();
    final deletedItems = [
      for (final a in deletedAssets)
        if (byAsset.containsKey(a)) byAsset[a]!,
    ];
    // Ya no hay original: ningún item de ese asset vuelve a ser candidato.
    final gone = deletedAssets.toSet();
    for (final c in candidatesNow) {
      if (gone.contains(c.sourceAssetId)) {
        await repository.clearSourceAssetId(c.id);
      }
    }
    return deletedItems;
  }
}

class _Cancelled implements Exception {}

/// SHA-256 hex de un archivo, en streaming.
Future<String> sha256OfFile(File file) async {
  final sink = Sha256().newHashSink();
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  final hash = await sink.hash();
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// MIME aproximado por extensión (con respaldo por tipo de asset).
String mimeFromName(String name, GalleryAssetType type) {
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  const map = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'm4v': 'video/x-m4v',
    '3gp': 'video/3gpp',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
  };
  return map[ext] ??
      (type == GalleryAssetType.video ? 'video/mp4' : 'image/jpeg');
}
