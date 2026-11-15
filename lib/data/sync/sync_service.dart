import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../../core/crypto/key_recovery_service.dart';
import '../cloud/cloud_storage.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import 'network_monitor.dart';
import 'sync_preferences.dart';
import 'sync_queue_repository.dart';

/// Nombres remotos en appDataFolder (sin nombres reales de archivos).
abstract final class CloudNames {
  static String file(String itemId) => '$itemId.vault';
  static String thumb(String itemId) => '$itemId.thumb';
  static const String recoveryBackup = 'recovery_backup.json';
  static const String dbSnapshot = 'vault_db.snapshot';
}

/// Estado global de la sincronización, para la UI.
enum SyncPhase { idle, running, offline, waitingWifi, needsSignIn, quotaFull }

class SyncSummary {
  const SyncSummary({
    this.phase = SyncPhase.idle,
    this.counts = const SyncCounts(),
    this.accountEmail,
    this.lastMessage,
  });

  final SyncPhase phase;
  final SyncCounts counts;
  final String? accountEmail;

  /// Último error global (p. ej. de inicio de sesión), en español.
  final String? lastMessage;

  SyncSummary copyWith({
    SyncPhase? phase,
    SyncCounts? counts,
    Object? accountEmail = _keep,
    Object? lastMessage = _keep,
  }) => SyncSummary(
    phase: phase ?? this.phase,
    counts: counts ?? this.counts,
    accountEmail: identical(accountEmail, _keep)
        ? this.accountEmail
        : accountEmail as String?,
    lastMessage: identical(lastMessage, _keep)
        ? this.lastMessage
        : lastMessage as String?,
  );

  static const Object _keep = Object();
}

/// La copia remota no coincide con la local (tamaño o MD5).
class SyncVerificationException implements Exception {
  const SyncVerificationException(this.detail);
  final String detail;
  @override
  String toString() => 'SyncVerificationException: $detail';
}

/// Falta el archivo local (no se puede subir; no se reintenta solo).
class SyncLocalMissingException implements Exception {
  const SyncLocalMissingException(this.path);
  final String path;
  @override
  String toString() => 'SyncLocalMissingException: $path';
}

/// Mensaje en español para un error de la cola.
String describeSyncError(Object e) => switch (e) {
  CloudNoNetworkException() => 'Sin conexión a internet',
  CloudNotAuthenticatedException() => 'Sesión de Google no válida',
  CloudQuotaExceededException() => 'Tu Google Drive está lleno',
  CloudForbiddenException(:final rateLimited) =>
    rateLimited
        ? 'Drive limitó las solicitudes; se reintentará'
        : 'Drive denegó el acceso (403)',
  CloudServerException(:final status) =>
    'Error del servidor de Drive ($status)',
  CloudNotFoundException() => 'No se encontró el archivo en la nube',
  CloudSignInFailedException(:final message) => message,
  CloudException(:final message) => message,
  SyncVerificationException(:final detail) =>
    'La copia en la nube no coincide ($detail)',
  SyncLocalMissingException() => 'Falta el archivo cifrado local',
  _ => 'Error inesperado de sincronización',
};

/// Espera antes del reintento número [attempts] (1 = primer fallo):
/// exponencial `base * 2^(attempts-1)` con tope [cap] y jitter en
/// [50 %, 100 %] del valor.
Duration syncBackoff(
  int attempts,
  Random random, {
  Duration base = const Duration(seconds: 10),
  Duration cap = const Duration(minutes: 15),
}) {
  final n = max(1, attempts);
  final exp = min(
    cap.inMilliseconds.toDouble(),
    base.inMilliseconds * pow(2, min(n - 1, 30)).toDouble(),
  );
  return Duration(
    milliseconds: (exp * (0.5 + 0.5 * random.nextDouble())).round(),
  );
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// MD5 hex de un archivo, en streaming (el que compara Drive `md5Checksum`).
Future<String> md5OfFile(File file) async {
  final out = _DigestSink();
  final input = crypto.md5.startChunkedConversion(out);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return out.value.toString();
}

String md5OfBytes(List<int> bytes) => crypto.md5.convert(bytes).toString();

/// Verifica que [json] es un respaldo de recuperación válido (DEK envuelta
/// con KEK_rec) y que su contenido es solo el esperado: sin campos extra
/// que puedan ser material de llaves en claro.
void assertRecoveryBackupSafe(String json) {
  RecoveryBackup.parse(json); // tipo + propósito 'recovery'
  final map = jsonDecode(json) as Map<String, dynamic>;
  const allowed = {'type', 'v', 'purpose', 'kdf', 'salt', 'nonce', 'ct', 'mac'};
  final extra = map.keys.where((k) => !allowed.contains(k)).toList();
  if (extra.isNotEmpty) {
    throw StateError('El respaldo tiene campos inesperados: $extra');
  }
}

/// Orquestador de la sincronización con la nube.
///
/// * Cola persistente en SQLCipher ([SyncQueueRepository]); un solo worker
///   a la vez ([run] devuelve de inmediato si ya hay uno).
/// * pendiente -> subiendo -> en_nube (solo tras verificar tamaño + MD5) /
///   error (tras [maxAttempts] fallos; reintento manual).
/// * Reintentos con backoff exponencial + jitter ([syncBackoff]). Los fallos
///   de red, de sesión o la cancelación NO cuentan como intento.
/// * "Solo Wi-Fi" ([SyncPreferences]) y reanudación (al abrir/desbloquear,
///   al volver la red, "Sincronizar ahora").
/// * [cancel] (al bloquear) detiene todo sin perder estado.
class SyncService {
  SyncService({
    required this.cloud,
    required this.queue,
    required this.items,
    required this.network,
    required this.prefs,
    required this.isUnlocked,
    required this.resolvePath,
    required this.recoveryBackupProvider,
    required this.snapshotProvider,
    int Function()? nowMs,
    Random? random,
    this.maxAttempts = 5,
    this.snapshotEveryUploads = 20,
    this.snapshotMaxAge = const Duration(hours: 6),
    this.scheduleWakeups = true,
    this.afterRun,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random();

  final CloudStorage cloud;
  final SyncQueueRepository queue;
  final VaultDataRepository items;
  final NetworkMonitor network;
  final SyncPreferences prefs;

  /// `false` con la bóveda bloqueada: no se toca la BD ni la nube.
  final bool Function() isUnlocked;

  /// Ruta relativa guardada en la BD -> archivo real.
  final File Function(String relativePath) resolvePath;

  /// JSON del respaldo de recuperación (`AuthController.exportRecoveryBackup`).
  final Future<String?> Function() recoveryBackupProvider;

  /// Copia de la BD cifrada (`VaultDatabase.exportEncryptedSnapshot`). Se
  /// borra tras subirla.
  final Future<File> Function() snapshotProvider;

  final int maxAttempts;
  final int snapshotEveryUploads;
  final Duration snapshotMaxAge;
  final bool scheduleWakeups;

  /// Se invoca al terminar cada pasada del worker (aunque no haya red). La app
  /// lo usa para aplicar el límite de la caché tras subir (F6a).
  final Future<void> Function()? afterRun;

  final int Function() _now;
  final Random _random;

  /// Estado para la UI.
  final ValueNotifier<SyncSummary> summary = ValueNotifier(const SyncSummary());

  /// Progreso 0..1 por item mientras se sube su `.vault` (alimenta el ícono
  /// "subiendo con progreso").
  final ValueNotifier<Map<String, double>> progress = ValueNotifier(const {});

  /// Última cuota consultada.
  final ValueNotifier<CloudQuota?> quota = ValueNotifier(null);

  bool _running = false;
  bool get isRunning => _running;
  CloudCancelToken? _token;
  Timer? _wake;
  StreamSubscription<NetworkKind>? _netSub;
  bool _disposed = false;

  // ------------------------------------------------------------------ inicio

  /// Arranca el escuchador de red y restaura la sesión de Google sin UI.
  Future<void> start() async {
    _netSub ??= network.changes.listen(_onNetwork);
    if (cloud.currentAccountEmail == null) {
      await cloud.signInSilently();
    }
    await _publish();
  }

  Future<void> _onNetwork(NetworkKind kind) async {
    if (_disposed || !isUnlocked()) return;
    final blocked =
        !kind.isOnline ||
        (kind == NetworkKind.mobile && await prefs.getWifiOnly());
    if (blocked) {
      // Si se pierde la red permitida a mitad de una subida, se detiene: los
      // items quedan pendientes y se reanudan al volver.
      _token?.cancel();
    } else if (!_running) {
      unawaited(run());
    }
  }

  void dispose() {
    _disposed = true;
    _wake?.cancel();
    _token?.cancel();
    _netSub?.cancel();
    summary.dispose();
    progress.dispose();
    quota.dispose();
  }

  /// Bloqueo de la app: cancela la subida en curso y los reintentos
  /// programados; no pierde estado (los `subiendo` vuelven a `pendiente` en
  /// la próxima ejecución).
  void cancel() {
    _wake?.cancel();
    _wake = null;
    _token?.cancel();
    if (!_disposed) {
      progress.value = const {};
      summary.value = summary.value.copyWith(phase: SyncPhase.idle);
    }
  }

  // ---------------------------------------------------------------- cuenta

  Future<void> signIn() async {
    try {
      await cloud.signIn();
      summary.value = summary.value.copyWith(
        accountEmail: cloud.currentAccountEmail,
        lastMessage: null,
        phase: SyncPhase.idle,
      );
    } on CloudSignInCancelledException {
      return;
    } on CloudException catch (e) {
      summary.value = summary.value.copyWith(lastMessage: describeSyncError(e));
      rethrow;
    }
    unawaited(refreshQuota());
    unawaited(run(manual: true));
  }

  Future<void> signOut() async {
    _token?.cancel();
    await cloud.signOut();
    quota.value = null;
    summary.value = summary.value.copyWith(
      accountEmail: null,
      phase: SyncPhase.needsSignIn,
    );
  }

  Future<CloudQuota?> refreshQuota() async {
    try {
      final q = await cloud.getQuota();
      if (!_disposed) quota.value = q;
      return q;
    } on CloudException {
      return quota.value;
    }
  }

  Future<bool> getWifiOnly() => prefs.getWifiOnly();

  Future<void> setWifiOnly(bool value) async {
    await prefs.setWifiOnly(value);
    if (!value && !_running && isUnlocked()) unawaited(run());
  }

  Future<List<SyncJob>> recentErrors({int limit = 5}) async {
    try {
      return await queue.errors(limit: limit);
    } on StateError {
      return const [];
    }
  }

  /// Reintento manual de errores (todos, o uno).
  Future<void> retryErrors({int? jobId}) async {
    await queue.retryErrors(onlyId: jobId);
    await run(manual: true);
  }

  // -------------------------------------------------------------- ejecución

  /// Procesa la cola. [manual]: ignora la espera de backoff de los pendientes.
  Future<void> run({bool manual = false}) async {
    if (_running || _disposed) return;
    if (!isUnlocked()) return;
    _running = true;
    final token = _token = CloudCancelToken();
    _wake?.cancel();
    _wake = null;
    try {
      _setPhase(SyncPhase.running);
      // Reanudación: lo que quedó `subiendo` (app cerrada/bloqueada) vuelve a
      // pendiente. Se encola todo aunque no haya red/sesión, para que la cola
      // y los conteos de la UI reflejen lo pendiente.
      await queue.resetStuck();
      if (manual) await queue.clearBackoff();
      await _reconcile();
      if (cloud.currentAccountEmail == null &&
          await cloud.signInSilently() == null) {
        await _finish(SyncPhase.needsSignIn);
        return;
      }
      final net = await network.current();
      if (!net.isOnline) {
        await _finish(SyncPhase.offline);
        return;
      }
      if (net == NetworkKind.mobile && await prefs.getWifiOnly()) {
        await _finish(SyncPhase.waitingWifi);
        return;
      }
      var phase = await _drain(token);
      if (phase == SyncPhase.running && !token.isCancelled) {
        await _maybeEnqueueSnapshot();
        phase = await _drain(token);
      }
      await _finish(token.isCancelled ? SyncPhase.idle : _idleIf(phase));
      if (!token.isCancelled && phase == SyncPhase.running) {
        unawaited(refreshQuota());
      }
    } on StateError {
      // Bóveda bloqueada a mitad de la ejecución: se descarta sin ruido.
      _publishQuiet();
    } on CloudException catch (e) {
      summary.value = summary.value.copyWith(lastMessage: describeSyncError(e));
      await _finish(SyncPhase.idle);
    } finally {
      _running = false;
      progress.value = const {};
      final hook = afterRun;
      if (hook != null && !_disposed && isUnlocked()) {
        try {
          await hook();
        } on Object catch (e) {
          debugPrint('afterRun falló: $e');
        }
      }
    }
  }

  SyncPhase _idleIf(SyncPhase p) => p == SyncPhase.running ? SyncPhase.idle : p;

  void _setPhase(SyncPhase phase) {
    if (_disposed) return;
    summary.value = summary.value.copyWith(
      phase: phase,
      accountEmail: cloud.currentAccountEmail,
    );
  }

  Future<void> _finish(SyncPhase phase) async {
    if (_disposed) return;
    SyncCounts counts = summary.value.counts;
    int? next;
    try {
      counts = await queue.counts();
      next = await queue.earliestPendingAt();
    } on StateError {
      // bloqueada
    }
    summary.value = summary.value.copyWith(
      phase: phase,
      counts: counts,
      accountEmail: cloud.currentAccountEmail,
    );
    _scheduleWake(phase, next);
  }

  void _scheduleWake(SyncPhase phase, int? nextAt) {
    _wake?.cancel();
    _wake = null;
    if (!scheduleWakeups || _disposed || phase != SyncPhase.idle) return;
    if (nextAt == null || !isUnlocked()) return;
    final wait = max(1000, nextAt - _now());
    _wake = Timer(Duration(milliseconds: wait), () {
      _wake = null;
      unawaited(run());
    });
  }

  Future<void> _publish() async {
    if (_disposed) return;
    try {
      final counts = isUnlocked() ? await queue.counts() : const SyncCounts();
      if (_disposed) return;
      summary.value = summary.value.copyWith(
        counts: counts,
        accountEmail: cloud.currentAccountEmail,
      );
    } on StateError {
      _publishQuiet();
    }
  }

  void _publishQuiet() {
    if (_disposed) return;
    summary.value = summary.value.copyWith(
      phase: SyncPhase.idle,
      accountEmail: cloud.currentAccountEmail,
    );
  }

  /// Refresca solo los conteos (la UI lo llama al abrir la hoja).
  Future<void> refreshCounts() => _publish();

  // --------------------------------------------------------------- reconcile

  /// Garantiza que todo lo que debe subirse tenga fila en la cola.
  Future<void> _reconcile() async {
    final now = _now();
    for (final status in [SyncStatus.pendiente, SyncStatus.subiendo]) {
      for (final item in await items.getItemsBySyncStatus(status)) {
        await queue.enqueue(item.id, SyncJobKind.file, now: now);
      }
    }
    for (final item in await items.getItemsNeedingThumbUpload()) {
      await queue.enqueue(item.id, SyncJobKind.thumb, now: now);
    }
    final backup = await recoveryBackupProvider();
    if (backup != null) {
      final sha = crypto.sha256.convert(utf8.encode(backup)).toString();
      if (sha != await prefs.getRecoveryUploadedSha()) {
        await queue.enqueue(
          SyncQueueRepository.noItem,
          SyncJobKind.recoveryBackup,
          now: now,
        );
      }
    }
  }

  Future<void> _maybeEnqueueSnapshot() async {
    final uploads = await prefs.getUploadsSinceSnapshot();
    if (uploads == 0) return;
    final at = await prefs.getSnapshotAt();
    final due =
        uploads >= snapshotEveryUploads ||
        at == null ||
        _now() - at >= snapshotMaxAge.inMilliseconds;
    if (due) {
      await queue.enqueue(
        SyncQueueRepository.noItem,
        SyncJobKind.dbSnapshot,
        now: _now(),
      );
    }
  }

  // ------------------------------------------------------------------- drain

  /// Procesa trabajos vencidos. Devuelve la fase resultante: `running` si
  /// terminó normalmente, o la que obliga a parar (red, sesión, cuota).
  Future<SyncPhase> _drain(CloudCancelToken token) async {
    final skip = <int>{};
    while (!token.isCancelled && isUnlocked()) {
      final job = await queue.nextDue(_now(), skip: skip);
      if (job == null) break;
      skip.add(job.id); // un mismo trabajo no se repite dentro de la pasada
      final stop = await _process(job, token);
      await _publish();
      if (stop != null) return stop;
    }
    return SyncPhase.running;
  }

  /// Devuelve la fase que obliga a parar, o `null` para seguir.
  Future<SyncPhase?> _process(SyncJob job, CloudCancelToken token) async {
    final hasItem = job.kind == SyncJobKind.file;
    try {
      await queue.markUploading(job.id);
      if (hasItem) {
        await _setItemStatus(job.itemId, SyncStatus.subiendo);
      }
      final done = await _execute(job, token);
      if (done) await queue.remove(job.id);
      return null;
    } on CloudCancelledException {
      await _revert(job, hasItem);
      return SyncPhase.idle;
    } on CloudNoNetworkException catch (e) {
      await _revert(job, hasItem, message: describeSyncError(e));
      return SyncPhase.offline;
    } on CloudNotAuthenticatedException catch (e) {
      await _revert(job, hasItem, message: describeSyncError(e));
      return SyncPhase.needsSignIn;
    } on CloudQuotaExceededException catch (e) {
      await queue.markError(
        job.id,
        attempts: job.attempts + 1,
        error: describeSyncError(e),
      );
      if (hasItem) await _setItemStatus(job.itemId, SyncStatus.error);
      return SyncPhase.quotaFull;
    } on StateError {
      rethrow; // bóveda bloqueada
    } catch (e) {
      await _fail(job, e, hasItem);
      return null;
    } finally {
      _setProgress(job.itemId, null);
    }
  }

  Future<void> _setItemStatus(String id, SyncStatus s) async {
    try {
      await items.updateSyncStatus(id, s);
    } on StateError catch (e) {
      // "El item no existe" (borrado mientras estaba en cola) vs bloqueada.
      if (e.message.contains('bloqueada')) rethrow;
    }
  }

  /// Vuelve a pendiente sin contar intento (red/sesión/cancelación).
  Future<void> _revert(SyncJob job, bool hasItem, {String? message}) async {
    try {
      await queue.markPending(
        job.id,
        attempts: job.attempts,
        nextAttemptAt: 0,
        lastError: message,
      );
      if (hasItem) await _setItemStatus(job.itemId, SyncStatus.pendiente);
    } on StateError {
      // bloqueada: queda `subiendo` y se arregla en la reanudación.
    }
  }

  Future<void> _fail(SyncJob job, Object e, bool hasItem) async {
    final attempts = job.attempts + 1;
    final permanent =
        e is SyncLocalMissingException ||
        (e is CloudForbiddenException && !e.rateLimited);
    final message = describeSyncError(e);
    if (permanent || attempts >= maxAttempts) {
      await queue.markError(job.id, attempts: attempts, error: message);
      if (hasItem) await _setItemStatus(job.itemId, SyncStatus.error);
    } else {
      final wait = syncBackoff(attempts, _random);
      await queue.markPending(
        job.id,
        attempts: attempts,
        nextAttemptAt: _now() + wait.inMilliseconds,
        lastError: message,
      );
      if (hasItem) await _setItemStatus(job.itemId, SyncStatus.pendiente);
    }
  }

  // ------------------------------------------------------------- ejecución

  /// Ejecuta un trabajo. `true` = completado (se borra de la cola).
  Future<bool> _execute(SyncJob job, CloudCancelToken token) async {
    switch (job.kind) {
      case SyncJobKind.file:
      case SyncJobKind.thumb:
        return _uploadItemFile(job, token);
      case SyncJobKind.recoveryBackup:
        return _uploadRecoveryBackup();
      case SyncJobKind.dbSnapshot:
        return _uploadSnapshot(token);
      case SyncJobKind.deleteRemote:
        return _deleteRemote(job);
    }
  }

  void _setProgress(String itemId, double? value) {
    if (_disposed) return;
    final map = Map<String, double>.of(progress.value);
    if (value == null) {
      if (map.remove(itemId) == null) return;
    } else {
      final old = map[itemId];
      if (old != null && value < 1 && (value - old).abs() < 0.01) return;
      map[itemId] = value;
    }
    progress.value = map;
  }

  /// Compara tamaño y MD5 locales con los remotos. Lanza
  /// [SyncVerificationException] si no coinciden.
  void _verify(CloudFile remote, int size, String md5) {
    if (remote.size != size) {
      throw SyncVerificationException(
        'tamaño local $size, remoto ${remote.size}',
      );
    }
    if (remote.md5Checksum == null ||
        remote.md5Checksum!.toLowerCase() != md5.toLowerCase()) {
      throw const SyncVerificationException('MD5 distinto');
    }
  }

  Future<bool> _uploadItemFile(SyncJob job, CloudCancelToken token) async {
    final isThumb = job.kind == SyncJobKind.thumb;
    final item = await items.getItem(job.itemId);
    if (item == null) return true; // borrado mientras estaba en cola
    final rel = isThumb ? item.thumbPath : item.encryptedPath;
    if (rel == null) return true;
    final file = resolvePath(rel);
    if (!await file.exists()) throw SyncLocalMissingException(rel);

    final name = isThumb ? CloudNames.thumb(item.id) : CloudNames.file(item.id);
    final size = await file.length();
    final md5 = await md5OfFile(file);
    // Idempotente: si ya existe (subida anterior sin confirmar), se reemplaza
    // en vez de duplicar.
    final existing = await cloud.findByName(name);
    final remote = await cloud.uploadFile(
      file: file,
      name: name,
      replaceFileId: existing?.id,
      cancel: token,
      onProgress: isThumb
          ? null
          : (sent, total) =>
                _setProgress(item.id, total == 0 ? 1 : sent / total),
    );
    _verify(remote, size, md5);
    try {
      if (isThumb) {
        await items.setThumbDriveFileId(item.id, remote.id);
      } else {
        await items.markCloudVerified(
          item.id,
          driveFileId: remote.id,
          md5: md5,
          size: size,
        );
        await prefs.addUpload();
      }
    } on StateError catch (e) {
      // Borrado mientras se subía: nada que marcar. (La bloqueada se propaga.)
      if (e.message.contains('bloqueada')) rethrow;
    }
    return true;
  }

  // ------------------------------------------------------------ borrado remoto

  /// Encola el borrado en Drive de lo que subió un item eliminado. Los ids
  /// viajan en la fila de la cola (el item ya no existe en la BD). Aunque no
  /// haya ids (p. ej. la subida terminó justo después), el trabajo busca
  /// también por nombre (`<id>.vault`, `<id>.thumb`).
  Future<void> enqueueRemoteDelete(
    String itemId, {
    String? driveFileId,
    String? thumbDriveFileId,
  }) async {
    await queue.enqueue(
      itemId,
      SyncJobKind.deleteRemote,
      now: _now(),
      payload: jsonEncode({'file': driveFileId, 'thumb': thumbDriveFileId}),
    );
    await _publish();
  }

  /// Borra de Drive los ids del payload y, por si quedó algo sin registrar,
  /// lo que tenga el nombre del item. Un 404 cuenta como éxito.
  Future<bool> _deleteRemote(SyncJob job) async {
    final ids = <String>{};
    final raw = job.payload;
    if (raw != null) {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final k in ['file', 'thumb']) {
        final v = map[k];
        if (v is String && v.isNotEmpty) ids.add(v);
      }
    }
    for (final name in [
      CloudNames.file(job.itemId),
      CloudNames.thumb(job.itemId),
    ]) {
      final found = await cloud.findByName(name);
      if (found != null) ids.add(found.id);
    }
    for (final id in ids) {
      try {
        await cloud.delete(id);
      } on CloudNotFoundException {
        // ya no existe: objetivo cumplido
      }
    }
    if (kDebugMode) {
      // Diagnóstico (solo depuración, sin ids ni tokens): confirma el borrado.
      final left = await cloud.list();
      debugPrint(
        '[sync] borrado remoto: ${ids.length} id(s) borrados; '
        'quedan ${left.length} archivos en appDataFolder',
      );
    }
    return true;
  }

  Future<bool> _uploadRecoveryBackup() async {
    final json = await recoveryBackupProvider();
    if (json == null) return true;
    assertRecoveryBackupSafe(json);
    final bytes = Uint8List.fromList(utf8.encode(json));
    final existing = await cloud.findByName(CloudNames.recoveryBackup);
    final remote = await cloud.uploadBytes(
      bytes: bytes,
      name: CloudNames.recoveryBackup,
      replaceFileId: existing?.id,
    );
    _verify(remote, bytes.length, md5OfBytes(bytes));
    await prefs.setRecoveryUploadedSha(crypto.sha256.convert(bytes).toString());
    return true;
  }

  Future<bool> _uploadSnapshot(CloudCancelToken token) async {
    final snapshot = await snapshotProvider();
    try {
      final size = await snapshot.length();
      final md5 = await md5OfFile(snapshot);
      final existing = await cloud.findByName(CloudNames.dbSnapshot);
      final remote = await cloud.uploadFile(
        file: snapshot,
        name: CloudNames.dbSnapshot,
        replaceFileId: existing?.id,
        cancel: token,
      );
      _verify(remote, size, md5);
      await prefs.markSnapshotDone(_now());
      return true;
    } finally {
      try {
        if (await snapshot.exists()) await snapshot.delete();
      } on FileSystemException {
        // se limpiará en el próximo snapshot
      }
    }
  }

  // ---------------------------------------------------------------- verificador

  /// Verificador real para `GalleryImportService.cloudVerifier`: `true` solo
  /// si el item está `en_nube`, tiene `driveFileId`, MD5 y tamaño verificados
  /// al subir, la copia local (si existe) sigue coincidiendo y la copia
  /// remota existe ahora mismo con el mismo tamaño y MD5.
  Future<bool> cloudVerifier(VaultItemModel item) async {
    try {
      final fresh = await items.getItem(item.id);
      if (fresh == null ||
          fresh.syncStatus != SyncStatus.enNube ||
          fresh.driveFileId == null ||
          fresh.cloudMd5 == null ||
          fresh.cloudSize == null) {
        return false;
      }
      final local = resolvePath(fresh.encryptedPath);
      if (await local.exists()) {
        if (await local.length() != fresh.cloudSize) return false;
        if (await md5OfFile(local) != fresh.cloudMd5) return false;
      }
      final remote = await cloud.getMetadata(fresh.driveFileId!);
      return remote.size == fresh.cloudSize &&
          remote.md5Checksum?.toLowerCase() == fresh.cloudMd5!.toLowerCase();
    } on CloudException {
      return false;
    } on StateError {
      return false;
    }
  }
}
