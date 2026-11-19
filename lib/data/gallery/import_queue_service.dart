import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/vault_log.dart';
import '../../core/session/session_ticket.dart';
import '../migration/free_space.dart';
import '../sync/network_monitor.dart';
import 'gallery_album_source.dart';
import 'gallery_asset_source.dart';
import 'gallery_import_service.dart';
import 'import_queue_repository.dart';
import 'import_wake_lock.dart';
import 'video_compressor.dart';

/// Qué importar (D86): un álbum entero (menos [excluded]) o una lista
/// explícita de assets elegidos a mano.
class ImportRequest {
  const ImportRequest.album(
    String this.albumId, {
    this.excluded = const {},
    this.folderId,
    this.videoQuality = VideoQualityOption.original,
  }) : assets = const [];

  const ImportRequest.assets(
    this.assets, {
    this.folderId,
    this.videoQuality = VideoQualityOption.original,
  }) : albumId = null,
       excluded = const {};

  final String? albumId;
  final Set<String> excluded;
  final List<GalleryAsset> assets;
  final String? folderId;
  final VideoQualityOption videoQuality;
}

/// Resultado de preparar un lote: lo que la UI enseña ANTES de empezar.
class ImportPreflight {
  const ImportPreflight({
    required this.batchId,
    required this.total,
    required this.estimatedBytes,
    required this.neededBytes,
    this.freeBytes,
    this.cellular = false,
  });

  final String batchId;
  final int total;

  /// Lo que se estima que ocupará en la bóveda.
  final int estimatedBytes;

  /// [estimatedBytes] + margen de trabajo (temporales, BD).
  final int neededBytes;

  /// Espacio libre del teléfono (`null` si no se puede saber: no bloquea).
  final int? freeBytes;

  /// iOS con datos móviles: lo que esté solo en iCloud se descargará por
  /// datos móviles.
  final bool cellular;

  bool get spaceInsufficient => freeBytes != null && freeBytes! < neededBytes;
}

/// Ya hay un lote sin cerrar: hay que reanudarlo o descartarlo primero.
class ImportBatchBusyException implements Exception {
  const ImportBatchBusyException();
}

/// Estado observable de la cola (para la UI).
@immutable
class ImportQueueStatus {
  const ImportQueueStatus({
    this.batchId,
    this.state,
    this.counts = const ImportCounts(),
    this.running = false,
    this.currentName,
    this.stage,
    this.fraction,
    this.originalBytes,
    this.compressedBytes,
    this.remaining,
    this.cellular = false,
    this.pauseReason,
    this.lastError,
  });

  final String? batchId;

  /// Estado persistido del lote (`null` = no hay lote).
  final ImportBatchState? state;
  final ImportCounts counts;

  /// `true` mientras el bucle está procesando.
  final bool running;
  final String? currentName;
  final ImportStage? stage;
  final double? fraction;
  final int? originalBytes;
  final int? compressedBytes;

  /// Tiempo estimado restante (`null` hasta tener datos).
  final Duration? remaining;

  /// Descargando de iCloud con datos móviles.
  final bool cellular;
  final ImportPauseReason? pauseReason;

  /// Motivo del último archivo con error (en pantalla).
  final ImportErrorCode? lastError;

  bool get hasBatch => batchId != null && state != null;
  bool get isOpen => state?.isOpen ?? false;

  ImportQueueStatus copyWith({
    ImportBatchState? state,
    ImportCounts? counts,
    bool? running,
    String? currentName,
    ImportStage? stage,
    double? fraction,
    int? originalBytes,
    int? compressedBytes,
    Duration? remaining,
    bool? cellular,
    ImportPauseReason? pauseReason,
    ImportErrorCode? lastError,
    bool clearCurrent = false,
  }) => ImportQueueStatus(
    batchId: batchId,
    state: state ?? this.state,
    counts: counts ?? this.counts,
    running: running ?? this.running,
    currentName: clearCurrent ? null : (currentName ?? this.currentName),
    stage: clearCurrent ? null : (stage ?? this.stage),
    fraction: clearCurrent ? null : fraction,
    originalBytes: clearCurrent ? null : originalBytes,
    compressedBytes: clearCurrent ? null : compressedBytes,
    remaining: remaining ?? this.remaining,
    cellular: cellular ?? this.cellular,
    pauseReason: pauseReason ?? this.pauseReason,
    lastError: lastError ?? this.lastError,
  );
}

/// Importación por lotes grandes y reanudable (v2.2, D86):
///
/// * La cola vive en la BD cifrada de SU bóveda (`import_queue`): solo ids
///   de assets y estado por archivo. Al preparar se paginan los assets del
///   álbum de [pageSize] en [pageSize] (nunca se cargan todos); al importar
///   se lee UNA fila y se pide UN asset por id: memoria acotada.
/// * De uno en uno. Antes de empezar un archivo se guarda su `itemId`
///   (`running`); si la app muere, al reanudar: fila en `vault_items` con ese
///   id ⇒ hecho; si no ⇒ se borran sus restos y se repite (tras
///   [maxAttempts] cierres seguidos, error «se interrumpió varias veces»).
/// * Dedupe: mismo `sourceAssetId` + misma huella del original (`sourceHash`
///   o `contentHash`), fuera de la Papelera ⇒ «ya estaba».
/// * Un error por archivo no detiene el lote (motivo en pantalla); «sin
///   espacio» lo pone en pausa.
/// * Bloqueo de la app: el archivo en curso se aborta sin dejar nada (las
///   guardas del importador) y el lote queda `running`: tras desbloquear,
///   [onUnlocked] lo retoma.
/// * Pantalla encendida ([ImportWakeLock]) solo mientras el bucle corre;
///   se libera en `finally`.
class ImportQueueService {
  ImportQueueService({
    required this.importer,
    required this.source,
    required this.queue,
    this.freeSpace,
    this.network,
    ImportWakeLock? wakeLock,
    this.sessionTicket,
    bool? isIOS,
    this.pageSize = 100,
    this.maxAttempts = 3,
    this.spaceMarginBytes = 200 * 1024 * 1024,
    String Function()? idGenerator,
    DateTime Function()? clock,
  }) : _wake = wakeLock ?? const NoopWakeLock(),
       _isIOS = isIOS ?? Platform.isIOS,
       _newId = idGenerator ?? (() => const Uuid().v4()),
       _clock = clock ?? DateTime.now;

  final GalleryImportService importer;
  final GalleryAlbumSource source;
  final ImportQueueRepository queue;
  final FreeSpaceProvider? freeSpace;
  final NetworkMonitor? network;
  final SessionTicket? Function()? sessionTicket;
  final int pageSize;
  final int maxAttempts;
  final int spaceMarginBytes;
  final ImportWakeLock _wake;
  final bool _isIOS;
  final String Function() _newId;
  final DateTime Function() _clock;

  final ValueNotifier<ImportQueueStatus> status = ValueNotifier(
    const ImportQueueStatus(),
  );

  Future<void>? _loop;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  ImportCancelToken? _token;

  bool get isRunning => _loop != null;

  int _now() => _clock().millisecondsSinceEpoch;

  SessionTicket? _ticketOrThrow() {
    final provider = sessionTicket;
    if (provider == null) return null;
    final t = provider();
    if (t == null) throw StateError('La bóveda está bloqueada');
    return t;
  }

  // ------------------------------------------------------------ preparar

  /// Encola [request] en un lote nuevo `preparing` y estima su tamaño. No
  /// importa nada: la UI muestra [ImportPreflight] y llama a [start] o a
  /// [discard]. Con un lote abierto lanza [ImportBatchBusyException]; un lote
  /// terminado sin cerrar se descarta. Lanza [StateError] si se bloquea.
  Future<ImportPreflight> prepare(ImportRequest request) async {
    final ticket = _ticketOrThrow();
    await _discardPreparing();
    final current = await queue.currentBatch();
    if (current != null) {
      if (current.state.isOpen) throw const ImportBatchBusyException();
      await queue.deleteBatch(current.id);
    }
    final id = _newId();
    await queue.createBatch(
      ImportBatch(
        id: id,
        state: ImportBatchState.preparing,
        folderId: request.folderId,
        videoQuality: request.videoQuality,
      ),
      now: _now(),
    );
    final compress = request.videoQuality != VideoQualityOption.original;
    int? estimateVideo(Duration d) =>
        estimateVideoBytes(duration: d, quality: request.videoQuality);
    var seq = 0;
    var estimated = 0;
    Future<void> addPage(List<GalleryAsset> page) async {
      if (ticket != null && !ticket.isValid) {
        throw SessionChangedException();
      }
      final ids = <String>[];
      for (final a in page) {
        if (request.excluded.contains(a.id)) continue;
        ids.add(a.id);
        estimated += estimateAssetBytes(
          a,
          compress: compress,
          estimateVideo: estimateVideo,
        );
      }
      seq += await queue.addJobs(id, seq, ids);
    }

    try {
      final albumId = request.albumId;
      if (albumId == null) {
        for (var i = 0; i < request.assets.length; i += pageSize) {
          final end = i + pageSize < request.assets.length
              ? i + pageSize
              : request.assets.length;
          await addPage(request.assets.sublist(i, end));
        }
      } else {
        for (var page = 0; ; page++) {
          final list = await source.listAlbumAssets(
            albumId,
            page: page,
            size: pageSize,
          );
          if (list.isEmpty) break;
          await addPage(list);
          if (list.length < pageSize) break;
        }
      }
      await queue.updateBatch(
        id,
        total: seq,
        estimatedBytes: estimated,
        now: _now(),
      );
    } on Object {
      try {
        await queue.deleteBatch(id);
      } on Object {
        // bloqueada: se descarta al próximo desbloqueo (`preparing`)
      }
      rethrow;
    }
    if (seq == 0) {
      await queue.deleteBatch(id);
    }
    int? free;
    try {
      free = await freeSpace?.call();
    } on Object {
      free = null;
    }
    var cellular = false;
    if (_isIOS && network != null) {
      try {
        cellular = await network!.current() == NetworkKind.mobile;
      } on Object {
        cellular = false;
      }
    }
    VaultLog.d(
      'Importación preparada: $seq elementos',
      category: 'import',
    );
    return ImportPreflight(
      batchId: id,
      total: seq,
      estimatedBytes: estimated,
      neededBytes: estimated + spaceMarginBytes,
      freeBytes: free,
      cellular: cellular,
    );
  }

  /// Descarta un lote preparado y no confirmado (o cualquiera).
  Future<void> discard(String batchId) async {
    if (status.value.batchId == batchId && _loop != null) {
      throw StateError('El lote está en marcha');
    }
    await queue.deleteBatch(batchId);
    if (status.value.batchId == batchId) {
      status.value = const ImportQueueStatus();
    }
  }

  Future<void> _discardPreparing() async {
    for (final id in await queue.preparingBatchIds()) {
      await queue.deleteBatch(id);
    }
  }

  // ------------------------------------------------------------ correr

  /// Confirma un lote preparado y lo procesa. [folderId] fija la carpeta
  /// destino (se crea al confirmar, no al preparar: cancelar no deja una
  /// carpeta vacía). Devuelve cuando termina, se pausa, se cancela o se
  /// bloquea la bóveda.
  Future<void> start(String batchId, {String? folderId}) async {
    _ticketOrThrow();
    // Síncrono, antes del primer `await`: la hoja ya ve el lote en marcha.
    status.value = ImportQueueStatus(
      batchId: batchId,
      state: ImportBatchState.running,
      running: true,
    );
    try {
      await queue.updateBatch(
        batchId,
        state: ImportBatchState.running,
        clearPauseReason: true,
        folderId: folderId,
        now: _now(),
      );
    } on Object {
      status.value = status.value.copyWith(running: false);
      rethrow;
    }
    return _ensureLoop(batchId);
  }

  /// Reanuda el lote abierto (en pausa o interrumpido). No hace nada sin
  /// lote abierto.
  Future<void> resume() async {
    _ticketOrThrow();
    final b = await queue.currentBatch();
    if (b == null || !b.state.isOpen) return;
    status.value = status.value.copyWith(
      state: ImportBatchState.running,
      running: true,
    );
    if (b.state != ImportBatchState.running) {
      await queue.updateBatch(
        b.id,
        state: ImportBatchState.running,
        clearPauseReason: true,
        now: _now(),
      );
    }
    return _ensureLoop(b.id);
  }

  /// Pide pausa: el archivo en curso se aborta (sin dejar nada) y vuelve a
  /// la cola. El lote queda `paused` hasta «Reanudar».
  void pause() {
    if (_loop == null) return;
    _pauseRequested = true;
    _token?.cancel();
  }

  /// Pide cancelar: lo pendiente no se importa. Sin bucle en marcha (lote
  /// en pausa) marca el lote cancelado directamente.
  Future<void> cancel() async {
    if (_loop != null) {
      _cancelRequested = true;
      _token?.cancel();
      await _loop;
      return;
    }
    final b = await queue.currentBatch();
    if (b == null || !b.state.isOpen) return;
    await queue.updateBatch(
      b.id,
      state: ImportBatchState.cancelled,
      now: _now(),
    );
    await refresh();
  }

  /// Cierra el resumen («Listo»): borra el lote terminado o cancelado.
  Future<void> acknowledge() async {
    final b = await queue.currentBatch();
    if (b == null || b.state.isOpen) return;
    await queue.deleteBatch(b.id);
    status.value = const ImportQueueStatus();
  }

  /// Relee el lote actual y publica su estado. Devuelve el lote.
  Future<ImportBatch?> refresh() async {
    final b = await queue.currentBatch();
    if (b == null) {
      if (_loop == null) status.value = const ImportQueueStatus();
      return null;
    }
    final counts = await queue.counts(b.id);
    final prev = status.value;
    status.value = ImportQueueStatus(
      batchId: b.id,
      state: b.state,
      counts: counts,
      running: _loop != null,
      currentName: prev.batchId == b.id ? prev.currentName : null,
      stage: prev.batchId == b.id ? prev.stage : null,
      remaining: prev.batchId == b.id ? prev.remaining : null,
      pauseReason: b.pauseReason,
      lastError: prev.batchId == b.id ? prev.lastError : null,
    );
    return b;
  }

  /// Archivos con error del lote actual (resumen).
  Future<List<ImportJob>> errors({int limit = 50}) async {
    final id = status.value.batchId;
    if (id == null) return const [];
    return queue.errors(id, limit: limit);
  }

  /// Al desbloquear SU bóveda: descarta lotes `preparing` (nunca
  /// confirmados) y, si el lote quedó
  /// `running` (cierre o bloqueo a mitad), lo retoma en segundo plano.
  /// Devuelve el lote actual (para que la UI lo muestre).
  Future<ImportBatch?> onUnlocked() async {
    if (sessionTicket != null && sessionTicket!() == null) return null;
    await _discardPreparing();
    final b = await refresh();
    // Los temporales de un cierre a mitad ya los barre el arranque (D41) y
    // los de un bloqueo, el `finally` del propio archivo y del bucle.
    if (b != null && b.state == ImportBatchState.running && _loop == null) {
      unawaited(
        _ensureLoop(b.id).catchError((Object e) {
          VaultLog.e('Importación no reanudada', e, 'import');
        }),
      );
    }
    return b;
  }

  /// Al bloquear: corta el archivo en curso (el importador ya se cancela con
  /// su propio gancho). El lote sigue `running` en la BD.
  void onLock() {
    final cur = _currentJob;
    if (cur != null) _lockInterrupted.add(cur);
    _token?.cancel();
  }

  /// Archivo en curso (`batchId#seq`).
  String? _currentJob;

  /// Archivos cortados por un BLOQUEO en este proceso (no por un cierre): al
  /// reanudar no cuentan como intento fallido.
  final Set<String> _lockInterrupted = {};

  Future<void> _ensureLoop(String batchId) {
    final running = _loop;
    if (running != null) return running;
    _pauseRequested = false;
    _cancelRequested = false;
    final f = _run(batchId);
    _loop = f;
    return f.whenComplete(() {
      if (identical(_loop, f)) _loop = null;
    });
  }

  Future<void> _run(String batchId) async {
    final ticket = _ticketOrThrow();
    bool stale() => ticket != null && !ticket.isValid;
    final batch = await queue.batch(batchId);
    if (batch == null) return;
    var options = ImportOptions(
      folderId: batch.folderId,
      videoQuality: batch.videoQuality,
    );
    final dedupe = ImportDedupe(
      mayExist: queue.hasLiveItemForAsset,
      find: queue.findDuplicate,
    );
    final watch = Stopwatch()..start();
    var processed = 0;
    var counts = await queue.counts(batchId);
    status.value = ImportQueueStatus(
      batchId: batchId,
      state: ImportBatchState.running,
      counts: counts,
      running: true,
    );
    VaultLog.d(
      'Lote de importación: ${counts.finished} de ${counts.total} hechos',
      category: 'import',
    );
    await _wake.enable();
    try {
      // Barrido: restos de un intento anterior (cierre a mitad).
      await importer.batchCleanup();
      while (true) {
        if (stale()) break;
        if (_cancelRequested) {
          await queue.updateBatch(
            batchId,
            state: ImportBatchState.cancelled,
            now: _now(),
          );
          break;
        }
        if (_pauseRequested) {
          await queue.updateBatch(
            batchId,
            state: ImportBatchState.paused,
            pauseReason: ImportPauseReason.user,
            now: _now(),
          );
          break;
        }
        final job = await queue.nextJob(batchId);
        if (job == null) {
          await queue.updateBatch(
            batchId,
            state: ImportBatchState.finished,
            now: _now(),
          );
          break;
        }
        // La carpeta destino se borró (o fue a la Papelera) a mitad: lo que
        // falta va a la raíz, nunca a una carpeta invisible.
        final folder = options.folderId;
        if (folder != null && !await queue.folderAlive(folder)) {
          options = ImportOptions(videoQuality: options.videoQuality);
        }
        final outcome = await _processJob(job, options, dedupe, stale);
        if (outcome == _JobOutcome.stop) break;
        if (outcome == _JobOutcome.processed) processed++;
        counts = await queue.counts(batchId);
        Duration? remaining;
        if (processed >= 2 && counts.remaining > 0) {
          remaining = Duration(
            milliseconds:
                watch.elapsedMilliseconds * counts.remaining ~/ processed,
          );
        }
        status.value = status.value.copyWith(
          counts: counts,
          remaining: remaining,
          clearCurrent: true,
        );
      }
    } on StateError {
      // Bloqueo o BD cerrada a mitad: el lote sigue `running` en la BD y se
      // retoma al desbloquear.
    } on Object catch (e) {
      VaultLog.e('Lote de importación detenido', e, 'import');
      try {
        if (!stale()) {
          await queue.updateBatch(
            batchId,
            state: ImportBatchState.paused,
            pauseReason: ImportPauseReason.user,
            now: _now(),
          );
        }
      } on Object {
        // bloqueada
      }
    } finally {
      _token = null;
      await _wake.disable();
      await importer.batchCleanup();
      try {
        if (!stale()) {
          final b = await queue.batch(batchId);
          status.value = ImportQueueStatus(
            batchId: batchId,
            state: b?.state,
            counts: await queue.counts(batchId),
            running: false,
            pauseReason: b?.pauseReason,
            lastError: status.value.lastError,
          );
        } else {
          status.value = status.value.copyWith(
            running: false,
            clearCurrent: true,
          );
        }
      } on Object {
        status.value = status.value.copyWith(running: false, clearCurrent: true);
      }
      VaultLog.d('Lote de importación en pausa o terminado', category: 'import');
    }
  }

  Future<_JobOutcome> _processJob(
    ImportJob job,
    ImportOptions options,
    ImportDedupe dedupe,
    bool Function() stale,
  ) async {
    final batchId = job.batchId;
    final key = '$batchId#${job.seq}';
    // Cortado por un bloqueo en ESTE proceso: no cuenta como intento.
    final cleanAbort = _lockInterrupted.remove(key);
    // 1. Recuperación de un intento interrumpido (app cerrada a mitad).
    if (job.state == ImportJobState.running) {
      final prevId = job.itemId;
      if (prevId != null && await queue.itemExists(prevId)) {
        // La fila llegó a la BD: el archivo está importado.
        await queue.markFinal(
          batchId,
          job.seq,
          ImportJobState.done,
          itemId: prevId,
          now: _now(),
        );
        return _JobOutcome.skipped;
      }
      if (prevId != null) await importer.discardPartial(prevId);
      if (!cleanAbort && job.attempts >= maxAttempts) {
        await queue.markFinal(
          batchId,
          job.seq,
          ImportJobState.error,
          error: ImportErrorCode.interrupted,
          now: _now(),
        );
        status.value = status.value.copyWith(
          lastError: ImportErrorCode.interrupted,
        );
        return _JobOutcome.processed;
      }
    }
    // 2. El asset (solo este) por id.
    GalleryAsset? asset;
    try {
      asset = await source.assetById(job.assetId);
    } on Object {
      asset = null;
    }
    if (stale()) return _JobOutcome.stop;
    if (asset == null) {
      await queue.markFinal(
        batchId,
        job.seq,
        ImportJobState.error,
        error: ImportErrorCode.gone,
        now: _now(),
      );
      status.value = status.value.copyWith(lastError: ImportErrorCode.gone);
      return _JobOutcome.processed;
    }
    final itemId = _newId();
    await queue.markRunning(
      batchId,
      job.seq,
      itemId,
      resetAttempts: cleanAbort,
      now: _now(),
    );
    _currentJob = key;
    final token = _token = ImportCancelToken();
    if (_pauseRequested || _cancelRequested) token.cancel();
    var cellular = false;
    if (_isIOS && network != null) {
      try {
        cellular = await network!.current() == NetworkKind.mobile;
      } on Object {
        cellular = false;
      }
    }
    final name = asset.title;
    status.value = status.value.copyWith(
      currentName: name,
      stage: ImportStage.queued,
      cellular: cellular,
    );
    ImportItemResult result;
    try {
      result = await importer.importQueued(
        asset,
        options,
        itemId: itemId,
        token: token,
        dedupe: dedupe,
        onStage: (stage, {fraction, original, compressed}) {
          status.value = status.value.copyWith(
            currentName: name,
            stage: stage,
            fraction: fraction,
            originalBytes: original,
            compressedBytes: compressed,
          );
        },
      );
    } on ImportFailure catch (f) {
      if (stale()) return _JobOutcome.stop;
      if (f.code == ImportErrorCode.noSpace) {
        // Sin espacio: seguir solo produciría más errores. En pausa.
        await importer.discardPartial(itemId);
        await queue.markPending(batchId, job.seq, now: _now());
        await queue.updateBatch(
          batchId,
          state: ImportBatchState.paused,
          pauseReason: ImportPauseReason.noSpace,
          now: _now(),
        );
        status.value = status.value.copyWith(
          pauseReason: ImportPauseReason.noSpace,
          lastError: ImportErrorCode.noSpace,
        );
        return _JobOutcome.stop;
      }
      await queue.markFinal(
        batchId,
        job.seq,
        ImportJobState.error,
        error: f.code,
        name: name,
        now: _now(),
      );
      status.value = status.value.copyWith(lastError: f.code);
      return _JobOutcome.processed;
    } finally {
      if (identical(_token, token)) _token = null;
      if (_currentJob == key) _currentJob = null;
    }
    switch (result.stage) {
      case ImportStage.done:
        await queue.markFinal(
          batchId,
          job.seq,
          ImportJobState.done,
          itemId: itemId,
          now: _now(),
        );
        return _JobOutcome.processed;
      case ImportStage.duplicate:
        await queue.markFinal(
          batchId,
          job.seq,
          ImportJobState.duplicate,
          itemId: result.itemId,
          now: _now(),
        );
        return _JobOutcome.processed;
      default:
        // Cancelado a mitad (pausa, cancelar o bloqueo): nada quedó escrito.
        if (stale()) return _JobOutcome.stop;
        await queue.markPending(batchId, job.seq, now: _now());
        return _JobOutcome.skipped;
    }
  }
}

enum _JobOutcome { processed, skipped, stop }
