import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/crypto/crypto_service.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../../core/session/session_ticket.dart';
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

  /// D86: ya estaba en la bóveda (mismo `sourceAssetId` y misma huella del
  /// original): no se importa otra vez.
  duplicate,
}

/// Motivo de un fallo por archivo (D86). Se guarda en la cola y se muestra
/// en pantalla; nunca lleva texto de excepciones (podría traer rutas).
enum ImportErrorCode {
  /// El asset ya no existe en la galería.
  gone('Ya no está en la galería'),

  /// Solo en la nube del sistema y no se puede descargar aquí.
  notLocal('El original no está en el teléfono'),

  /// iOS: la descarga de iCloud falló.
  iCloud('No se pudo descargar de iCloud'),

  /// Sin espacio en el teléfono.
  noSpace('No hay espacio en el teléfono'),

  /// No se pudo leer el original.
  read('No se pudo leer el original'),

  /// Falló el cifrado o la escritura del archivo cifrado.
  encrypt('No se pudo cifrar'),

  /// La app se cerró varias veces con este archivo a medias.
  interrupted('Se interrumpió varias veces'),

  /// Cualquier otro.
  unknown('Error inesperado');

  const ImportErrorCode(this.message);

  /// Motivo en español para la pantalla.
  final String message;

  static ImportErrorCode fromDb(String? v) => ImportErrorCode.values.firstWhere(
    (c) => c.name == v,
    orElse: () => ImportErrorCode.unknown,
  );
}

/// Fallo clasificado de un archivo (D86).
class ImportFailure implements Exception {
  const ImportFailure(this.code);
  final ImportErrorCode code;

  @override
  String toString() => code.message;
}

/// `true` si [e] es «sin espacio» (ENOSPC = 28 en Android/Linux y en iOS).
bool isNoSpaceError(Object e) =>
    e is FileSystemException && e.osError?.errorCode == 28;

/// Dedupe de la cola (D86): [mayExist] es barato (¿hay algún item vivo con
/// ese `sourceAssetId`?); solo si lo hay se calcula la huella del original y
/// [find] devuelve el id del item que ya lo tiene (o `null`).
class ImportDedupe {
  const ImportDedupe({required this.mayExist, required this.find});
  final Future<bool> Function(String assetId) mayExist;
  final Future<String?> Function(String assetId, String sourceHash) find;
}

/// Avisa de la etapa del archivo en curso.
typedef ImportStageEmitter =
    void Function(
      ImportStage stage, {
      double? fraction,
      int? original,
      int? compressed,
    });

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
    this.errorCode,
  });

  /// Motivo clasificado si falló (D86).
  final ImportErrorCode? errorCode;

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
    int Function()? keyGen,
    this.originalsDeletionPaused,
    VaultPaths? paths,
    this.sessionTicket,
  }) : _paths = paths ?? VaultPaths.primary,
       _keyGen = keyGen ?? (() => 1),
       _crypto = crypto ?? CryptoService(),
       _videoThumbs = videoThumbnailer ?? PlatformVideoThumbnailer(),
       _newId = idGenerator ?? (() => const Uuid().v4()),
       _clock = clock ?? DateTime.now,
       _isIOS = isIOS ?? Platform.isIOS;

  final GalleryAssetSource source;
  final VideoCompressor compressor;
  final VaultDataRepository repository;

  /// Subllaves de la sesión para CIFRAR lo nuevo (`null` = bóveda bloqueada).
  final SecretKey? Function() filesKey;
  final SecretKey? Function() thumbsKey;

  /// Generación de llave de [filesKey]/[thumbsKey] (D60;
  /// `VaultSession.currentGen`). Se lee junto con las llaves al empezar el
  /// lote: los items nacen con esa `keyGen` y con sus nombres `.kN`.
  final int Function() _keyGen;

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

  /// `true` mientras el borrado de originales está en pausa (A1: rotación de
  /// la DEK en curso). El verificador ya devuelve `false` entonces; esto
  /// además apaga el aviso de la cuadrícula.
  final bool Function()? originalsDeletionPaused;

  /// Rutas de la bóveda a la que importa (D67; por defecto la principal).
  final VaultPaths _paths;

  /// D67 (fase 8): ticket de la sesión de SU bóveda (o `null` si no está
  /// abierta). Se captura al empezar el lote y se comprueba antes de cada
  /// escritura: si se bloquea o se abre la otra bóveda a mitad, el lote se
  /// corta sin escribir nada más. `null` (pruebas) = sin esta guarda.
  final SessionTicket? Function()? sessionTicket;

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

  ImportCancelToken? _currentToken;

  /// Cancela el lote en curso (lo llama el bloqueo: D67).
  void cancelRunning() => _currentToken?.cancel();

  /// Importa [assets] secuencialmente. Lanza [StateError] si la bóveda está
  /// bloqueada o ya hay un lote en curso.
  Future<ImportBatchResult> importAssets(
    List<GalleryAsset> assets,
    ImportOptions options, {
    ImportCancelToken? cancelToken,
  }) async {
    // Llaves y su generación, leídas juntas (sin `await` en medio).
    final gen = _keyGen();
    final fKey = filesKey();
    final tKey = thumbsKey();
    if (fKey == null || tKey == null) {
      throw StateError('La bóveda está bloqueada');
    }
    final SessionTicket? ticket;
    final provider = sessionTicket;
    if (provider != null) {
      ticket = provider();
      if (ticket == null) throw StateError('La bóveda está bloqueada');
    } else {
      ticket = null;
    }
    if (_running) throw StateError('Ya hay una importación en curso');
    _running = true;
    final token = cancelToken ?? ImportCancelToken();
    _currentToken = token;
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
        if (ticket != null && !ticket.isValid) token.cancel();
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
          result = await _importOne(
            asset,
            options,
            gen,
            fKey,
            tKey,
            token,
            ticket,
            emit,
          );
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
            errorCode: classifyImportError(e),
          );
        }
        if (result.ok) done++;
        if (result.stage == ImportStage.failed) failed++;
        results.add(result);
      }
    } finally {
      token.removeListener(onCancel);
      if (identical(_currentToken, token)) _currentToken = null;
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

  /// D86: importa UN asset de la cola persistente con un [itemId] fijado de
  /// antemano (la cola lo guarda ANTES de empezar: tras un cierre a mitad se
  /// sabe si la fila llegó a la BD). Llaves, generación y ticket se leen
  /// AHORA (una rotación entre dos archivos usa la llave vigente). Lanza
  /// [StateError] con la bóveda bloqueada o con otro lote en curso;
  /// [ImportFailure] con el motivo si el archivo falla; devuelve `cancelled`
  /// si [token] se cancela (o la sesión cambia) a mitad, sin dejar nada.
  Future<ImportItemResult> importQueued(
    GalleryAsset asset,
    ImportOptions options, {
    required String itemId,
    required ImportCancelToken token,
    ImportDedupe? dedupe,
    ImportStageEmitter? onStage,
  }) async {
    final gen = _keyGen();
    final fKey = filesKey();
    final tKey = thumbsKey();
    if (fKey == null || tKey == null) {
      throw StateError('La bóveda está bloqueada');
    }
    final SessionTicket? ticket;
    final provider = sessionTicket;
    if (provider != null) {
      ticket = provider();
      if (ticket == null) throw StateError('La bóveda está bloqueada');
    } else {
      ticket = null;
    }
    if (_running) throw StateError('Ya hay una importación en curso');
    _running = true;
    _currentToken = token;
    void onCancel() => compressor.cancel();
    token.addListener(onCancel);
    try {
      await AppPaths.init();
      return await _importOne(
        asset,
        options,
        gen,
        fKey,
        tKey,
        token,
        ticket,
        onStage ?? (_, {fraction, original, compressed}) {},
        forcedItemId: itemId,
        dedupe: dedupe,
      );
    } on _Cancelled {
      return ImportItemResult(assetId: asset.id, stage: ImportStage.cancelled);
    } on ImportFailure {
      rethrow;
    } on Object catch (e) {
      if (ticket != null && !ticket.isValid) {
        // Bloqueo a mitad: no es un fallo del archivo.
        return ImportItemResult(
          assetId: asset.id,
          stage: ImportStage.cancelled,
        );
      }
      throw ImportFailure(classifyImportError(e));
    } finally {
      token.removeListener(onCancel);
      if (identical(_currentToken, token)) _currentToken = null;
      _running = false;
    }
  }

  /// D86: borra lo que un intento interrumpido (app cerrada a mitad) pudo
  /// dejar de [itemId] SIN fila en la BD: `.vault` y `.thumb` de cualquier
  /// generación hasta la vigente, en SU bóveda. El llamador comprueba antes
  /// que la fila no existe. Nunca lanza.
  Future<void> discardPartial(String itemId) async {
    await AppPaths.init();
    // +1 por si una rotación avanzó entre medias.
    final top = (_keyGen() + 1).clamp(1, AppPaths.maxKeyGen);
    for (var gen = 1; gen <= top; gen++) {
      await _tryDelete(_paths.resolve(AppPaths.vaultRelativePath(itemId, gen: gen)));
      await _tryDelete(_paths.resolve(AppPaths.thumbRelativePath(itemId, gen: gen)));
    }
  }

  /// D86: limpieza al terminar, pausar o cancelar un lote de la cola (lo
  /// mismo que el `finally` de [importAssets]): temporales del compresor y
  /// de la importación y cachés en claro del plugin. Nunca lanza.
  Future<void> batchCleanup() async {
    try {
      await compressor.cleanup();
    } on Object {
      // Limpieza best-effort.
    }
    await _cleanTempRoot();
    await _clearSourceCaches();
  }

  Future<ImportItemResult> _importOne(
    GalleryAsset asset,
    ImportOptions options,
    int gen,
    SecretKey fKey,
    SecretKey tKey,
    ImportCancelToken token,
    SessionTicket? ticket,
    ImportStageEmitter emit, {
    String? forcedItemId,
    ImportDedupe? dedupe,
  }) async {
    void check() {
      // D67: un bloqueo u otra bóveda a mitad cancelan el lote.
      if (ticket != null && !ticket.isValid) token.cancel();
      if (token.isCancelled) throw _Cancelled();
    }

    final itemId = forcedItemId ?? _newId();
    final vaultRel = AppPaths.vaultRelativePath(itemId, gen: gen);
    final thumbRel = AppPaths.thumbRelativePath(itemId, gen: gen);
    // D67: rutas absolutas de SU bóveda, capturadas al empezar.
    final vaultFile = _paths.resolve(vaultRel);
    final thumbFile = _paths.resolve(thumbRel);
    final workDir = Directory(p.join(tempDirProvider().path, itemId));
    final toDelete = <File>[];
    var committed = false;
    try {
      check();
      await workDir.create(recursive: true);

      // (a) Materializar el original. iOS: si solo está en iCloud, descarga
      // con progreso.
      // iOS: RUTA SIN PROBAR (iCloud real no verificado).
      final local = await source.isLocallyAvailable(asset.id);
      if (!local && !_isIOS) {
        if (forcedItemId != null) {
          throw const ImportFailure(ImportErrorCode.notLocal);
        }
        throw StateError('El original no está disponible en el dispositivo');
      }
      emit(
        local ? ImportStage.hashing : ImportStage.downloading,
        fraction: local ? null : 0,
      );
      final OriginFile? origin;
      try {
        origin = await source.originFile(
          asset.id,
          allowNetwork: !local && _isIOS,
          onProgress: (f) => emit(ImportStage.downloading, fraction: f),
        );
      } on Object catch (e) {
        if (forcedItemId == null) rethrow;
        if (isNoSpaceError(e)) throw const ImportFailure(ImportErrorCode.noSpace);
        throw ImportFailure(
          local ? ImportErrorCode.read : ImportErrorCode.iCloud,
        );
      }
      if (origin == null) {
        if (forcedItemId != null) {
          throw ImportFailure(
            local ? ImportErrorCode.gone : ImportErrorCode.iCloud,
          );
        }
        throw StateError('No se pudo obtener el archivo original');
      }
      if (origin.isTemporary) toDelete.add(origin.file);
      check();
      final originalBytes = await origin.file.length();

      // D86: huella del ORIGINAL. Solo se calcula aquí si hace falta para el
      // dedupe (ya hay un item vivo de ese asset) o porque se va a comprimir
      // (el contenido guardado será otro). Si no, es el `contentHash`.
      final willCompress =
          asset.isVideo && options.videoQuality != VideoQualityOption.original;
      String? sourceHash;
      if (dedupe != null && await dedupe.mayExist(asset.id)) {
        emit(ImportStage.hashing);
        sourceHash = await sha256OfFile(origin.file);
        check();
        final existing = await dedupe.find(asset.id, sourceHash);
        if (existing != null) {
          return ImportItemResult(
            assetId: asset.id,
            stage: ImportStage.duplicate,
            itemId: existing,
            originalBytes: originalBytes,
          );
        }
      }
      if (willCompress && forcedItemId != null && sourceHash == null) {
        emit(ImportStage.hashing);
        sourceHash = await sha256OfFile(origin.file);
        check();
      }

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
      // D86: sin compresión el contenido ES el original (una sola pasada).
      final contentHash = !compressed && sourceHash != null
          ? sourceHash
          : await sha256OfFile(content);
      final hashMs = stageWatch.elapsedMilliseconds;
      check();

      // (d) Cifrar con la subllave "files".
      emit(ImportStage.encrypting);
      stageWatch.reset();
      check();
      final VaultHeader fileHeader;
      try {
        fileHeader = await _crypto.encryptFile(content, vaultFile, fKey);
      } on Object catch (e) {
        if (forcedItemId == null || (ticket != null && !ticket.isValid)) {
          rethrow;
        }
        throw ImportFailure(
          isNoSpaceError(e) ? ImportErrorCode.noSpace : ImportErrorCode.encrypt,
        );
      }
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
          check();
          await thumbFile.writeAsBytes(enc, flush: true);
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
      check(); // D67: nunca una fila en la BD de otra sesión
      await repository.insertItem(
        VaultItemModel(
          // D60: la generación de las llaves con que se cifró.
          keyGen: gen,
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
          // D86: huella del original (= contentHash sin compresión).
          sourceHash: compressed ? sourceHash : contentHash,
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
        // Sin fila en BD no debe quedar nada cifrado huérfano (rutas de SU
        // bóveda: nunca toca la otra).
        await _tryDelete(vaultFile);
        await _tryDelete(thumbFile);
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
  ///
  /// A1 (D61): durante una rotación de la DEK ([originalsDeletionPaused]) da
  /// 0: lo importado en la ventana aún no se puede restaurar si se pierde el
  /// teléfono.
  Future<int> pendingOriginalsCount() async {
    if (originalsDeletionPaused?.call() ?? false) return 0;
    if (cloudVerifier == null || !await isDeletionEnabled) return 0;
    final all = await deleteOriginalCandidates();
    return {for (final c in all) c.sourceAssetId}.length;
  }

  /// Candidatos cuya copia en la nube SE VERIFICA ahora mismo (consulta a
  /// Drive). Es la lista que se muestra al usuario antes de pedir la
  /// confirmación. Vacía si el borrado está apagado o no hay verificador. No
  /// borra nada.
  Future<List<VaultItemModel>> verifiedDeleteCandidates({
    void Function(int done, int total)? onProgress,
  }) async {
    final verifier = cloudVerifier;
    if (verifier == null || !await isDeletionEnabled) return const [];
    // Un mismo original puede haberse importado varias veces (p. ej. con
    // otra calidad): se lista UNA vez por original, con la copia más grande
    // que se verifique.
    final all = await deleteOriginalCandidates()
      ..sort((a, b) => b.fileSize.compareTo(a.fileSize));
    final seen = <String>{};
    final out = <VaultItemModel>[];
    var done = 0;
    for (final c in all) {
      onProgress?.call(done++, all.length);
      if (seen.contains(c.sourceAssetId)) continue;
      if (await verifier(c)) {
        seen.add(c.sourceAssetId!);
        out.add(c);
      }
    }
    onProgress?.call(all.length, all.length);
    return out;
  }

  /// D87: tope de ids por llamada a `deleteAssets`. Android 11+ e iOS piden
  /// UNA confirmación del sistema por llamada, así que hasta este número es
  /// una sola; por encima se trocea (una URI ocupa ~60 B en la transacción
  /// Binder de `createDeleteRequest`: 500 ≈ 30 KB, lejos del límite de 1 MB).
  static const int deleteChunkSize = 500;

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
    void Function(int done, int total)? onProgress,
  }) async {
    if (!userConfirmed || !await isDeletionEnabled) return const [];
    final verifier = cloudVerifier;
    if (verifier == null) return const [];
    final candidatesNow = await deleteOriginalCandidates();
    final eligible = {for (final c in candidatesNow) c.id};
    final byAsset = <String, String>{}; // assetId -> itemId
    var checked = 0;
    for (final c in candidates) {
      onProgress?.call(checked++, candidates.length);
      if (!eligible.contains(c.id)) continue;
      // Releer: el estado pudo cambiar desde que se mostró la lista.
      final fresh = await repository.getItem(c.id);
      if (fresh == null || fresh.syncStatus != SyncStatus.enNube) continue;
      if (fresh.driveFileId == null || fresh.sourceAssetId == null) continue;
      if (!await verifier(fresh)) continue;
      byAsset[fresh.sourceAssetId!] = fresh.id;
    }
    onProgress?.call(candidates.length, candidates.length);
    if (byAsset.isEmpty) return const [];
    // D87: hasta [deleteChunkSize] originales = UNA confirmación del sistema.
    // Si el usuario rechaza un trozo (0 borrados) no se le vuelve a preguntar.
    final ids = byAsset.keys.toList();
    final deletedAssets = <String>[];
    for (var i = 0; i < ids.length; i += deleteChunkSize) {
      final end = i + deleteChunkSize < ids.length
          ? i + deleteChunkSize
          : ids.length;
      final got = await source.deleteAssets(ids.sublist(i, end));
      deletedAssets.addAll(got);
      if (got.isEmpty) break;
    }
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

/// Motivo de un fallo cualquiera de un archivo (D86).
ImportErrorCode classifyImportError(Object e) {
  if (e is ImportFailure) return e.code;
  if (isNoSpaceError(e)) return ImportErrorCode.noSpace;
  if (e is FileSystemException) return ImportErrorCode.read;
  return ImportErrorCode.unknown;
}

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
