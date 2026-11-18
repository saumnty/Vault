import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logging/vault_log.dart';
import '../../core/session/session_ticket.dart';
import '../cloud/cloud_storage.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import '../sync/network_monitor.dart';
import '../sync/sync_preferences.dart';
import '../sync/sync_queue_repository.dart';
import '../sync/sync_service.dart';
import '../sync/vault_file_fetcher.dart';
import 'free_space.dart';
import 'migration_repository.dart';

/// Resultado de la comprobación previa (lo que se muestra en la hoja
/// explicativa ANTES de empezar).
class MigrationPlan {
  const MigrationPlan({
    required this.oldEmail,
    required this.itemCount,
    required this.lostCount,
    required this.bytesToDownload,
    required this.thumbsToDownload,
    required this.uploadBytes,
    required this.freeBytes,
    required this.enoughLocalSpace,
  });

  final String? oldEmail;
  final int itemCount;

  /// Items sin copia local NI copia en la cuenta vieja (no se pueden migrar).
  final int lostCount;
  final int bytesToDownload;
  final int thumbsToDownload;

  /// Lo que ocupará en la cuenta nueva (cifrado, con miniaturas).
  final int uploadBytes;

  /// Espacio libre del teléfono (`null` = desconocido).
  final int? freeBytes;
  final bool enoughLocalSpace;
}

/// Estado para la UI (se actualiza mientras corre el flujo).
class MigrationStatus {
  const MigrationStatus({
    this.phase,
    this.running = false,
    this.fraction,
    this.message,
    this.oldEmail,
    this.newEmail,
    this.itemsDone = 0,
    this.itemsTotal = 0,
    this.needsAttention = false,
  });

  /// `null` = no hay migración en curso.
  final MigrationPhase? phase;
  final bool running;

  /// 0..1 de la fase actual, o `null` si no se puede calcular.
  final double? fraction;

  /// Mensaje corto en español (qué pasa o por qué está en pausa).
  final String? message;
  final String? oldEmail;
  final String? newEmail;
  final int itemsDone;
  final int itemsTotal;

  /// Está parado esperando una acción del usuario (cuenta, reintento...).
  final bool needsAttention;

  bool get active => phase != null;

  MigrationStatus copyWith({
    MigrationPhase? phase,
    bool? running,
    double? fraction,
    bool clearFraction = false,
    String? message,
    bool clearMessage = false,
    String? oldEmail,
    String? newEmail,
    int? itemsDone,
    int? itemsTotal,
    bool? needsAttention,
  }) => MigrationStatus(
    phase: phase ?? this.phase,
    running: running ?? this.running,
    fraction: clearFraction ? null : (fraction ?? this.fraction),
    message: clearMessage ? null : (message ?? this.message),
    oldEmail: oldEmail ?? this.oldEmail,
    newEmail: newEmail ?? this.newEmail,
    itemsDone: itemsDone ?? this.itemsDone,
    itemsTotal: itemsTotal ?? this.itemsTotal,
    needsAttention: needsAttention ?? this.needsAttention,
  );
}

class MigrationException implements Exception {
  const MigrationException(this.message);
  final String message;
  @override
  String toString() => 'MigrationException: $message';
}

class _Stop implements Exception {
  const _Stop();
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Cambio de cuenta de Google CON migración.
///
/// 1. Baja de la cuenta vieja los `.vault`/`.thumb` que no están en el
///    teléfono (verifica tamaño + MD5 y el `fileId`).
/// 2. Cierra sesión e inicia con la cuenta nueva. Si ésta ya tiene el
///    respaldo de recuperación de OTRA bóveda, se detiene SIN sobrescribir.
/// 3. Sube todo con la verificación habitual (tamaño + MD5), más el respaldo
///    de recuperación y un snapshot fresco.
/// 4. Marca `en_nube` con los nuevos `driveFileId`/`cloudMd5`.
/// 5. Ofrece (con confirmación) borrar los datos de la cuenta vieja, o
///    conservarlos.
///
/// El estado vive en la BD cifrada ([MigrationRepository]): sobrevive a matar
/// la app y a bloquear; se reanuda al desbloquear. Mientras dura, la
/// sincronización normal está en pausa y la caché LRU no purga.
class AccountMigrationService {
  AccountMigrationService({
    required this.cloud,
    required this.items,
    required this.migration,
    required this.queue,
    required this.sync,
    required this.fetcher,
    required this.network,
    required this.prefs,
    required this.recoveryBackupProvider,
    required this.resolvePath,
    this.setCachePurgeSuspended,
    this.rotationActive,
    this.sessionTicket,
    FreeSpaceProvider? freeSpace,
    int Function()? nowMs,
    this.freeSpaceMargin = 100 * 1024 * 1024,
    this.maxUploadRounds = 40,
  }) : _freeSpace = freeSpace ?? (() async => null),
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CloudStorage cloud;
  final VaultDataRepository items;
  final MigrationRepository migration;
  final SyncQueueRepository queue;
  final SyncService sync;
  final VaultFileFetcher fetcher;
  final NetworkMonitor network;
  final SyncPreferences prefs;

  /// JSON del respaldo de recuperación local.
  final Future<String?> Function() recoveryBackupProvider;
  final File Function(String relativePath) resolvePath;

  /// Suspende/reanuda la purga de la caché LRU.
  final void Function(bool suspended)? setCachePurgeSuspended;

  /// `true` si hay una rotación de la DEK registrada (D61): el cambio de
  /// cuenta y la rotación son excluyentes.
  final Future<bool> Function()? rotationActive;
  final FreeSpaceProvider _freeSpace;
  final int Function() _now;

  /// D67 (fase 8): ticket de la sesión PRINCIPAL abierta, o `null` si la
  /// principal no está abierta. `null` (pruebas) = sin esta guarda.
  final SessionTicket? Function()? sessionTicket;

  /// Margen de espacio libre que se exige además de lo que hay que bajar.
  final int freeSpaceMargin;
  final int maxUploadRounds;

  /// Tamaño que se estima para una miniatura cuando no se conoce.
  static const int _thumbEstimate = 48 * 1024;

  /// Snapshot y respaldo (estimación para la cuota).
  static const int _metaEstimate = 2 * 1024 * 1024;

  final ValueNotifier<MigrationStatus> status = ValueNotifier(
    const MigrationStatus(),
  );

  bool _running = false;
  bool get isRunning => _running;
  CloudCancelToken? _token;
  bool _cancelRequested = false;

  // ---------------------------------------------------------------- consulta

  /// `true` si hay un cambio de cuenta empezado (en cualquier fase).
  Future<bool> hasActive() async => (await migration.load()) != null;

  /// Lee el estado persistido y lo publica (la UI/arranque lo llaman al
  /// desbloquear). Si hay migración activa, pausa la sincronización normal y
  /// la purga de caché.
  Future<MigrationState?> refresh() async {
    final state = await migration.load();
    _applyGuards(state != null);
    if (state == null) {
      status.value = const MigrationStatus();
    } else if (!_running) {
      status.value = _statusFor(state);
    }
    return state;
  }

  void _applyGuards(bool active) {
    sync.pausedForMigration = active;
    setCachePurgeSuspended?.call(active);
  }

  /// Comprobación previa: qué hay que bajar, cuánto ocupará y si cabe en el
  /// teléfono. No toca nada.
  Future<MigrationPlan> plan() async {
    final all = await items.getAllItems();
    var lost = 0;
    var down = 0;
    var thumbsDown = 0;
    var up = _metaEstimate;
    for (final i in all) {
      final file = resolvePath(i.encryptedPath);
      final local = file.existsSync();
      final size = local ? file.lengthSync() : (i.cloudSize ?? i.fileSize);
      up += size;
      if (!local) {
        if (i.driveFileId != null) {
          down += size;
        } else {
          lost++;
        }
      }
      final tp = i.thumbPath;
      if (tp != null) {
        final tFile = resolvePath(tp);
        up += tFile.existsSync() ? tFile.lengthSync() : _thumbEstimate;
        if (!tFile.existsSync() && i.thumbDriveFileId != null) {
          thumbsDown++;
          down += _thumbEstimate;
        }
      }
    }
    final free = await _freeSpace();
    final enough =
        free == null || free >= down + (down ~/ 10) + freeSpaceMargin;
    return MigrationPlan(
      oldEmail: cloud.currentAccountEmail,
      itemCount: all.length,
      lostCount: lost,
      bytesToDownload: down,
      thumbsToDownload: thumbsDown,
      uploadBytes: up,
      freeBytes: free,
      enoughLocalSpace: enough,
    );
  }

  // ------------------------------------------------------------------ inicio

  /// Empieza el cambio de cuenta y lo ejecuta hasta que termina, se pausa o
  /// necesita al usuario. Exige sesión en la cuenta vieja y que
  /// quepa en el teléfono. Lanza [MigrationException] si no se puede.
  Future<void> start(MigrationPlan plan) async {
    if (_running) throw const MigrationException('Ya hay un cambio en curso');
    if (await hasActive()) {
      throw const MigrationException('Ya hay un cambio de cuenta empezado');
    }
    if (await rotationActive?.call() ?? false) {
      throw const MigrationException(
        'Hay un cambio de llave maestra en curso. Espera a que termine.',
      );
    }
    final old = cloud.currentAccountEmail;
    if (old == null) {
      throw const MigrationException(
        'Inicia sesión en tu cuenta actual de Google antes de cambiarla.',
      );
    }
    if (!plan.enoughLocalSpace) {
      throw const MigrationException(
        'No hay espacio suficiente en el teléfono para bajar tus archivos.',
      );
    }
    await migration.begin(
      oldEmail: old,
      neededBytes: plan.uploadBytes,
      downloadTotal: plan.bytesToDownload,
      now: _now(),
    );
    VaultLog.d('Cambio de cuenta iniciado', category: 'migration');
    _applyGuards(true);
    // Corre el flujo completo; la UI lo llama con `unawaited` y sigue el
    // progreso por [status].
    await resume();
  }

  /// Continúa desde donde quedó (tras pausa, corte o reinicio).
  ///
  /// D67 (fase 8): con [sessionTicket] (la app) solo corre con la principal
  /// abierta y para, sin escribir nada más, en cuanto la sesión cambia
  /// (bloqueo u otra bóveda).
  Future<void> resume() async {
    if (_running) return;
    final SessionTicket? ticket;
    final provider = sessionTicket;
    if (provider != null) {
      ticket = provider();
      if (ticket == null) return;
    } else {
      ticket = null;
    }
    bool stale() => ticket != null && !ticket.isValid;
    final first = await migration.load();
    if (first == null || stale()) return;
    _running = true;
    _cancelRequested = false;
    _token = CloudCancelToken();
    _applyGuards(true);
    try {
      while (true) {
        if (stale()) throw const _Stop();
        final state = await migration.load();
        if (stale()) throw const _Stop();
        if (state == null) break;
        _emit(state, running: true);
        final next = await _step(state);
        if (!next) break;
      }
    } on _Cancelled {
      // cancelAndRestore se encarga del resto.
    } on _Stop {
      // Pausa o bloqueo ya publicados.
    } on CloudException catch (e) {
      // D67: con la sesión cambiada no se escribe el error (la nube corta
      // con la secundaria abierta: no es un fallo de la migración).
      if (!stale()) {
        final s = await migration.load();
        VaultLog.e('Cambio de cuenta en pausa', e, 'migration');
        await _setError(describeSyncError(e));
        if (s != null) _emit((await migration.load()) ?? s, running: false);
      }
    } finally {
      _running = false;
      if (!stale()) {
        final s = await migration.load();
        if (s != null) {
          _emit(s, running: false);
        } else {
          status.value = const MigrationStatus();
        }
      }
    }
  }

  Future<bool> _step(MigrationState state) async {
    switch (state.phase) {
      case MigrationPhase.downloading:
        await _download(state);
        return true;
      case MigrationPhase.signInNew:
        return _signInNew(state);
      case MigrationPhase.checkingNew:
        return _checkNew(state);
      case MigrationPhase.uploading:
        return _upload(state);
      case MigrationPhase.finalizing:
        return _finalize(state);
      case MigrationPhase.askDeleteOld:
      case MigrationPhase.blockedOtherVault:
      case MigrationPhase.blockedQuota:
        return false; // espera una decisión del usuario
    }
  }

  // -------------------------------------------------------------- fase 1

  Future<void> _download(MigrationState state) async {
    await _requireNetwork(state);
    final all = await items.getAllItems();
    final missing = <VaultItemModel>[
      for (final i in all)
        if (i.driveFileId != null && !resolvePath(i.encryptedPath).existsSync())
          i,
    ];
    final missingThumbs = <VaultItemModel>[
      for (final i in all)
        if (i.thumbPath != null &&
            i.thumbDriveFileId != null &&
            !resolvePath(i.thumbPath!).existsSync())
          i,
    ];
    final total = state.downloadTotal;
    var remaining = 0;
    for (final i in missing) {
      remaining += i.cloudSize ?? i.fileSize;
    }
    remaining += missingThumbs.length * _thumbEstimate;
    var done = (total - remaining).clamp(0, total);
    var processed = 0;
    final itemsTotal = missing.length + missingThumbs.length;

    void progress(int bytes) {
      final frac = total <= 0 ? 1.0 : (done + bytes) / total;
      status.value = status.value.copyWith(
        phase: MigrationPhase.downloading,
        running: true,
        fraction: frac.clamp(0.0, 1.0),
        itemsDone: processed,
        itemsTotal: itemsTotal,
        message: 'Descargando de tu cuenta anterior…',
      );
    }

    progress(0);
    for (final item in missing) {
      _checkCancelled();
      try {
        await fetcher.ensureLocal(
          item,
          cancel: _token,
          onProgress: (got, _) => progress(got),
        );
      } on VaultFetchUnavailableException {
        VaultLog.d(
          'Archivo sin copia en la cuenta anterior',
          category: 'migration',
        );
      } on VaultFetchVerificationException {
        VaultLog.d(
          'Archivo dañado en la cuenta anterior',
          category: 'migration',
        );
      } on CloudNotFoundException {
        VaultLog.d(
          'Archivo ausente en la cuenta anterior',
          category: 'migration',
        );
      } on CloudCancelledException {
        throw const _Cancelled();
      }
      done += item.cloudSize ?? item.fileSize;
      processed++;
      await migration.update(downloadDone: done, now: _now());
      progress(0);
    }
    for (final item in missingThumbs) {
      _checkCancelled();
      try {
        await _downloadThumb(item);
      } on CloudNotFoundException {
        VaultLog.d(
          'Miniatura ausente en la cuenta anterior',
          category: 'migration',
        );
      } on CloudCancelledException {
        throw const _Cancelled();
      }
      done += _thumbEstimate;
      processed++;
      progress(0);
    }
    await migration.update(
      phase: MigrationPhase.signInNew,
      downloadDone: total,
      clearError: true,
      now: _now(),
    );
  }

  Future<void> _downloadThumb(VaultItemModel item) async {
    final target = resolvePath(item.thumbPath!);
    final id = item.thumbDriveFileId!;
    final meta = await cloud.getMetadata(id);
    if (!target.parent.existsSync()) target.parent.createSync(recursive: true);
    final part = File('${target.path}.part');
    try {
      if (part.existsSync()) await part.delete();
      await cloud.download(id, part, cancel: _token, maxBytes: 8 * 1024 * 1024);
      if (await part.length() != meta.size) {
        throw const VaultFetchVerificationException('miniatura: tamaño');
      }
      final md5 = meta.md5Checksum;
      if (md5 != null && await md5OfFile(part) != md5.toLowerCase()) {
        throw const VaultFetchVerificationException('miniatura: MD5');
      }
      await part.rename(target.path);
    } on VaultFetchVerificationException {
      // Miniatura dañada: se descarta (se podrá regenerar).
      if (part.existsSync()) await part.delete();
    } catch (_) {
      if (part.existsSync()) {
        try {
          await part.delete();
        } on FileSystemException {
          // ignorado
        }
      }
      rethrow;
    }
  }

  // -------------------------------------------------------------- fase 2

  Future<bool> _signInNew(MigrationState state) async {
    final old = state.oldEmail;
    final current =
        cloud.currentAccountEmail ?? (await cloud.signInSilently())?.email;
    if (current != null && current != old) {
      // Ya estamos en la cuenta nueva (reanudación tras un corte).
      await migration.update(
        phase: MigrationPhase.checkingNew,
        newEmail: current,
        clearError: true,
        now: _now(),
      );
      return true;
    }
    if (current != null) {
      await cloud.signOut();
      await prefs.setRecoveryUploadedSha('');
    }
    await _publishWaiting(
      state,
      'Elige la cuenta de Google NUEVA en la ventana que se abre.',
    );
    final CloudAccount account;
    try {
      account = await cloud.signIn();
    } on CloudSignInCancelledException {
      await _publishWaiting(
        state,
        'No elegiste ninguna cuenta. Vuelve a intentarlo.',
      );
      throw const _Stop();
    }
    if (account.email == old) {
      await cloud.signOut();
      await _publishWaiting(
        state,
        'Elegiste la misma cuenta. Elige OTRA cuenta de Google.',
      );
      throw const _Stop();
    }
    await migration.update(
      phase: MigrationPhase.checkingNew,
      newEmail: account.email,
      clearError: true,
      now: _now(),
    );
    return true;
  }

  Future<bool> _checkNew(MigrationState state) async {
    final backup = await recoveryBackupProvider();
    if (backup == null) {
      await _setError('No hay respaldo de recuperación local.');
      throw const _Stop();
    }
    // D60: el respaldo lleva la generación de llave vigente en el nombre. Un
    // respaldo de OTRA generación en la cuenta nueva es de otra bóveda (o de
    // otra rama): tampoco se sobrescribe ni se mezcla.
    final ours = CloudNames.recoveryBackupFor(await sync.currentKeyGen());
    final foreign = [
      for (final f in await cloud.list())
        if (f.name != ours &&
            switch (CloudNames.parse(f.name)?.kind) {
              CloudNameKind.recoveryBackup ||
              CloudNameKind.bridgeBackup => true,
              _ => false,
            })
          f,
    ];
    if (foreign.isNotEmpty) {
      await migration.update(
        phase: MigrationPhase.blockedOtherVault,
        now: _now(),
      );
      VaultLog.d('Cuenta nueva con otra bóveda', category: 'migration');
      return false;
    }
    final remote = await cloud.findByName(ours);
    if (remote != null) {
      final bytes = await cloud.downloadBytes(remote.id, maxBytes: 4096);
      final ours = md5OfBytes(bytes) == md5OfBytes(utf8.encode(backup));
      if (!ours) {
        // OTRA bóveda: no se sobrescribe NADA.
        await migration.update(
          phase: MigrationPhase.blockedOtherVault,
          now: _now(),
        );
        VaultLog.d('Cuenta nueva con otra bóveda', category: 'migration');
        return false;
      }
      // Es la nuestra (migración reanudada): no se revisa la cuota.
    } else {
      final q = await cloud.getQuota();
      final limit = q.limitBytes;
      if (limit != null && limit - q.usedBytes < state.neededBytes) {
        await migration.update(phase: MigrationPhase.blockedQuota, now: _now());
        VaultLog.d('Cuenta nueva sin espacio', category: 'migration');
        return false;
      }
    }
    await migration.update(
      phase: MigrationPhase.uploading,
      clearError: true,
      now: _now(),
    );
    return true;
  }

  // -------------------------------------------------------------- fase 3-4

  Future<bool> _upload(MigrationState state) async {
    if (!await migration.hasSavedRefs()) {
      final all = await items.getAllItems();
      final local = <String>{
        for (final i in all)
          if (resolvePath(i.encryptedPath).existsSync()) i.id,
      };
      await migration.resetForUpload(localItemIds: local, now: _now());
      await prefs.setRecoveryUploadedSha('');
      await prefs.markDirty(_now());
      VaultLog.d('Subiendo a la cuenta nueva', category: 'migration');
    } else {
      await queue.retryErrors();
    }
    final total = (await items.getAllItems()).length;
    var stalled = 0;
    var lastRemaining = -1;
    for (var round = 0; round < maxUploadRounds; round++) {
      _checkCancelled();
      await sync.run(manual: true, force: true);
      _checkCancelled();
      final remaining = await _remainingUploads();
      status.value = status.value.copyWith(
        phase: MigrationPhase.uploading,
        running: true,
        fraction: total == 0
            ? 1.0
            : ((total - remaining) / total).clamp(0.0, 1.0),
        itemsDone: (total - remaining).clamp(0, total),
        itemsTotal: total,
        message: 'Subiendo a tu cuenta nueva…',
      );
      if (remaining == 0) {
        await migration.update(
          phase: MigrationPhase.finalizing,
          clearError: true,
          now: _now(),
        );
        return true;
      }
      final phase = sync.summary.value.phase;
      if (phase == SyncPhase.offline ||
          phase == SyncPhase.waitingWifi ||
          phase == SyncPhase.needsSignIn) {
        await _pause(
          state,
          phase == SyncPhase.waitingWifi
              ? 'En pausa: esperando Wi-Fi.'
              : phase == SyncPhase.needsSignIn
              ? 'En pausa: inicia sesión de nuevo en la cuenta nueva.'
              : 'En pausa: sin conexión. Se reanudará al volver la red.',
        );
        throw const _Stop();
      }
      if (phase == SyncPhase.quotaFull) {
        await migration.update(phase: MigrationPhase.blockedQuota, now: _now());
        return false;
      }
      final counts = await queue.counts();
      if (counts.errors > 0 && counts.pending == 0 && counts.uploading == 0) {
        await _pause(
          state,
          '${counts.errors} archivo(s) no se pudieron subir. Reintenta.',
        );
        throw const _Stop();
      }
      stalled = remaining == lastRemaining ? stalled + 1 : 0;
      lastRemaining = remaining;
      if (stalled >= 3) {
        await _pause(state, 'La subida no avanza. Reintenta en un momento.');
        throw const _Stop();
      }
    }
    await _pause(state, 'La subida sigue en curso. Reanuda para continuar.');
    throw const _Stop();
  }

  Future<int> _remainingUploads() async {
    var n = 0;
    for (final s in [SyncStatus.pendiente, SyncStatus.subiendo]) {
      n += (await items.getItemsBySyncStatus(s)).length;
    }
    final c = await queue.counts();
    // Las miniaturas pendientes también cuentan (trabajos en cola sin item
    // pendiente).
    n += c.pending + c.uploading;
    return n;
  }

  Future<bool> _finalize(MigrationState state) async {
    final backup = await recoveryBackupProvider();
    // D60: nombres de la generación vigente (el snapshot se cifra con ella).
    final gen = await sync.currentKeyGen();
    final backupName = CloudNames.recoveryBackupFor(gen);
    final snapName = CloudNames.dbSnapshotFor(gen);
    final remoteBackup = await cloud.findByName(backupName);
    final remoteSnap = await cloud.findByName(snapName);
    if (backup == null) {
      await _setError('No hay respaldo de recuperación local.');
      throw const _Stop();
    }
    if (remoteBackup == null || remoteSnap == null) {
      await queue.enqueue(
        SyncQueueRepository.noItem,
        SyncJobKind.dbSnapshot,
        now: _now(),
      );
      await prefs.setRecoveryUploadedSha('');
      await sync.run(manual: true, force: true);
      final b = await cloud.findByName(backupName);
      final s = await cloud.findByName(snapName);
      if (b == null || s == null) {
        await _pause(
          state,
          'Falta subir el respaldo de recuperación y el índice. Reintenta.',
        );
        throw const _Stop();
      }
    }
    await migration.update(
      phase: MigrationPhase.askDeleteOld,
      clearError: true,
      now: _now(),
    );
    VaultLog.d('Datos en la cuenta nueva', category: 'migration');
    return true;
  }

  // -------------------------------------------------------------- fase 5

  /// Borra (de forma PERMANENTE, sin papelera ni revisiones) todos los datos
  /// de Vault de la cuenta anterior y termina. Pide iniciar sesión con la
  /// cuenta anterior y después vuelve a la nueva.
  Future<void> deleteOldAccountData() async {
    final state = await migration.load();
    if (state == null || state.phase != MigrationPhase.askDeleteOld) {
      throw const MigrationException('No hay nada que borrar');
    }
    final old = state.oldEmail;
    final newEmail = state.newEmail;
    await cloud.signOut();
    final account = await cloud.signIn();
    if (account.email != old) {
      // Vuelve a la cuenta nueva y avisa.
      await cloud.signOut();
      await cloud.signIn();
      throw MigrationException(
        'Elegiste otra cuenta. Para borrar, inicia sesión con $old.',
      );
    }
    var deleted = 0;
    for (final f in await cloud.list()) {
      if (_isVaultFile(f.name)) {
        try {
          await cloud.delete(f.id);
          deleted++;
        } on CloudNotFoundException {
          // ya no estaba
        }
      }
    }
    VaultLog.d(
      'Datos de la cuenta anterior borrados: $deleted',
      category: 'migration',
    );
    if (await prefs.getOldAccountKept() == old) {
      await prefs.clearOldAccountKept();
    }
    await cloud.signOut();
    try {
      final back = await cloud.signIn();
      if (back.email != newEmail) {
        throw MigrationException(
          'Datos borrados. Inicia sesión con $newEmail para seguir sincronizando.',
        );
      }
    } finally {
      await _finishClean();
    }
  }

  /// Conserva los datos de la cuenta anterior y termina.
  Future<void> keepOldAccountData() async {
    final state = await migration.load();
    if (state == null || state.phase != MigrationPhase.askDeleteOld) {
      throw const MigrationException('No hay nada que decidir');
    }
    // M7: la cuenta anterior guarda un conjunto que abre el código de
    // entonces; se recuerda para avisar al rotar la llave.
    final old = state.oldEmail;
    if (old != null) await prefs.setOldAccountKept(old);
    await _finishClean();
  }

  Future<void> _finishClean() async {
    await migration.clear();
    _applyGuards(false);
    status.value = const MigrationStatus();
    unawaited(sync.run(manual: true));
  }

  /// Solo los nombres que usa Vault, de cualquier generación de llave (D60):
  /// respaldos, snapshots y `<id>[.kN].vault` / `<id>[.kN].thumb` con id
  /// válido (UUID v4). Nada más se toca.
  static bool _isVaultFile(String name) => CloudNames.parse(name) != null;

  // ------------------------------------------------------------ cancelación

  /// Desde un bloqueo (otra bóveda / sin cuota) o en cualquier momento antes
  /// de subir: cierra la sesión de la cuenta nueva y vuelve a pedir una
  /// cuenta. No sube ni borra nada.
  Future<void> chooseAnotherAccount() async {
    final state = await migration.load();
    if (state == null) return;
    if (state.phase == MigrationPhase.uploading ||
        state.phase == MigrationPhase.finalizing ||
        state.phase == MigrationPhase.askDeleteOld) {
      throw const MigrationException(
        'Ya se empezó a subir a esta cuenta: cancela o termina el cambio.',
      );
    }
    if (_running) return;
    if (cloud.currentAccountEmail != null &&
        cloud.currentAccountEmail != state.oldEmail) {
      await cloud.signOut();
      await prefs.setRecoveryUploadedSha('');
    }
    await migration.update(
      phase: MigrationPhase.signInNew,
      clearError: true,
      now: _now(),
    );
    await resume();
  }

  /// Pide detener el flujo en curso (pausa: el estado se conserva y se puede
  /// reanudar). Para deshacer del todo use [cancelAndRestore].
  void pause() {
    _cancelRequested = true;
    _token?.cancel();
  }

  /// Cancela el cambio y vuelve a la cuenta anterior sin perder nada:
  /// restaura las referencias antiguas de los archivos y vuelve a iniciar
  /// sesión con la cuenta vieja. Lo ya subido a la cuenta nueva no se borra.
  Future<void> cancelAndRestore() async {
    pause();
    // Espera a que el flujo en curso se detenga.
    for (var i = 0; i < 200 && _running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final state = await migration.load();
    if (state == null) return;
    if (state.phase == MigrationPhase.askDeleteOld) {
      throw const MigrationException(
        'Los datos ya están en la cuenta nueva. Elige borrar o conservar.',
      );
    }
    final old = state.oldEmail;
    if (await migration.hasSavedRefs()) {
      final all = await items.getAllItems();
      final local = <String>{
        for (final i in all)
          if (resolvePath(i.encryptedPath).existsSync()) i.id,
      };
      await migration.restoreOldRefs(localItemIds: local);
    }
    final current = cloud.currentAccountEmail;
    if (current != old) {
      // Hay que volver a la cuenta anterior.
      if (current != null) await cloud.signOut();
      await prefs.setRecoveryUploadedSha('');
      final account = await cloud.signIn();
      if (account.email != old) {
        await cloud.signOut();
        throw MigrationException(
          'Para cancelar inicia sesión con tu cuenta anterior ($old).',
        );
      }
    }
    await _finishClean();
    VaultLog.d('Cambio de cuenta cancelado', category: 'migration');
  }

  // ---------------------------------------------------------------- ayudas

  void _checkCancelled() {
    if (_cancelRequested || (_token?.isCancelled ?? false)) {
      throw const _Cancelled();
    }
  }

  Future<void> _requireNetwork(MigrationState state) async {
    final net = await network.current();
    if (!net.isOnline) {
      await _pause(
        state,
        'En pausa: sin conexión. Se reanudará al volver la red.',
      );
      throw const _Stop();
    }
    if (net == NetworkKind.mobile && await prefs.getWifiOnly()) {
      await _pause(state, 'En pausa: esperando Wi-Fi (usa Wi-Fi para esto).');
      throw const _Stop();
    }
  }

  Future<void> _pause(MigrationState state, String message) async {
    await _setError(message);
    final s = await migration.load();
    status.value = _statusFor(s ?? state, message: message, attention: true);
  }

  Future<void> _setError(String message) =>
      migration.update(lastError: message, now: _now());

  Future<void> _publishWaiting(MigrationState state, String message) async {
    // Se guarda (sobrevive a un reinicio) y se publica.
    await _setError(message);
    status.value = _statusFor(state, message: message, attention: true);
  }

  void _emit(MigrationState state, {required bool running}) {
    final base = _statusFor(state);
    status.value = status.value.phase == state.phase && running
        ? status.value.copyWith(
            running: true,
            oldEmail: state.oldEmail,
            newEmail: state.newEmail,
          )
        : base.copyWith(running: running);
  }

  MigrationStatus _statusFor(
    MigrationState s, {
    String? message,
    bool attention = false,
  }) {
    final blocked =
        s.phase == MigrationPhase.blockedOtherVault ||
        s.phase == MigrationPhase.blockedQuota ||
        s.phase == MigrationPhase.askDeleteOld;
    return MigrationStatus(
      phase: s.phase,
      running: false,
      fraction: s.phase == MigrationPhase.downloading && s.downloadTotal > 0
          ? (s.downloadDone / s.downloadTotal).clamp(0.0, 1.0)
          : null,
      message: message ?? s.lastError,
      oldEmail: s.oldEmail,
      newEmail: s.newEmail,
      needsAttention: attention || blocked || s.lastError != null,
    );
  }
}
