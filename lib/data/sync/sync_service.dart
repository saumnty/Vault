import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../../core/crypto/key_recovery_service.dart';
import '../../core/logging/vault_log.dart';
import '../cloud/cloud_names.dart';
import '../cloud/cloud_storage.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import '../repositories/vault_database.dart' show SnapshotCopy;
import '../restore/generation_sweeper.dart';
import 'network_monitor.dart';
import 'sync_preferences.dart';
import 'sync_queue_repository.dart';

// Los nombres remotos viven en `cloud_names.dart` (D60); se reexportan para
// no cambiar los imports existentes.
export '../cloud/cloud_names.dart';

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

/// Una guarda de la rotación de la DEK impidió una subida que rompería un
/// conjunto de respaldo (C2/D61): p. ej. un snapshot con filas de otra
/// generación, o un nombre de la generación vieja ya congelada. Es un error
/// de programa: no se reintenta solo.
class SyncGuardException implements Exception {
  const SyncGuardException(this.detail);
  final String detail;
  @override
  String toString() => 'SyncGuardException: $detail';
}

/// Estado de una rotación de la DEK visto por la sincronización (D61). La
/// implementación real lee el registro de la rotación; [NoRotationGuard] es
/// "no hay rotación".
abstract interface class RotationGuard {
  /// Hay una rotación registrada (cualquier fase).
  bool get active;

  /// Entre `freezing` y el corte: el conjunto viejo de Drive (respaldo y
  /// snapshot de [fromGen]) está congelado y la sincronización normal no
  /// sube metadatos.
  bool get freezeMeta;

  /// Generaciones de la rotación (sin rotación, ambas = la vigente).
  int get fromGen;
  int get toGen;
}

/// Sin rotación de la DEK.
class NoRotationGuard implements RotationGuard {
  const NoRotationGuard();
  @override
  bool get active => false;
  @override
  bool get freezeMeta => false;
  @override
  int get fromGen => 1;
  @override
  int get toGen => 1;
}

/// D75: la sesión de Google cambió de cuenta mientras se subía un archivo. Lo
/// subido NO se registra (sería de otra cuenta); el trabajo vuelve a
/// pendiente sin contar intento y se repite con la cuenta nueva.
class SyncAccountChangedException implements Exception {
  const SyncAccountChangedException();
  @override
  String toString() => 'SyncAccountChangedException';
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
  SyncGuardException() => 'Subida detenida durante la rotación de la llave',
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
    this.snapshotDebounce = const Duration(seconds: 30),
    this.snapshotMaxAge = const Duration(hours: 6),
    this.scheduleWakeups = true,
    this.afterRun,
    RotationGuard? rotation,
    Future<int> Function()? currentKeyGen,
    this.accountTag,
    this.afterSignIn,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random(),
       rotation = rotation ?? const NoRotationGuard(),
       currentKeyGen = currentKeyGen ?? (() async => 1);

  /// Rotación de la DEK en curso (D61): congela los metadatos del conjunto
  /// viejo y bloquea subidas que lo romperían.
  final RotationGuard rotation;

  /// Generación de llave vigente (`vault.v1.key_gen`): da nombre al respaldo
  /// de recuperación (`recovery_backup[.kN].json`).
  final Future<int> Function() currentKeyGen;

  /// D75: tag (hash con sal) de la cuenta de la sesión actual, o `null` sin
  /// sesión (`CloudAccountTagger.current`). Sin proveedor (pruebas antiguas)
  /// no se escriben tags y todo funciona como antes de v11.
  final Future<String?> Function()? accountTag;

  /// D75: tras un [signIn] correcto (en lugar de `run`): la app comprueba la
  /// copia en la nube si la cuenta no es la de los tags (y luego sincroniza).
  final Future<void> Function()? afterSignIn;

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
  final Future<SnapshotCopy> Function() snapshotProvider;

  final int maxAttempts;

  /// Espera tras el último cambio de datos antes de intentar el snapshot.
  final Duration snapshotDebounce;

  /// Edad máxima del snapshot: pasada, se sube otro aunque no haya cambios.
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

  /// Cambio de cuenta de Google en curso: la sincronización normal queda en
  /// pausa (la subida a la cuenta nueva la dirige `AccountMigrationService`).
  bool pausedForMigration = false;

  /// D75: «Verificar copia en la nube» en curso: la sincronización normal
  /// espera (la verificación la relanza al terminar).
  bool pausedForVerification = false;

  /// D75: tag de una cuenta en la que la verificación encontró el respaldo de
  /// recuperación de OTRA bóveda con el mismo nombre: en esa cuenta no se
  /// sube (ni se reemplaza) el respaldo. Solo en memoria; la verificación
  /// del siguiente desbloqueo lo vuelve a decidir.
  String? recoveryBackupBlockedTag;

  bool _running = false;
  bool get isRunning => _running;
  CloudCancelToken? _token;
  Timer? _wake;
  Timer? _dirtyTimer;
  bool _lockFlushRunning = false;
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
    _dirtyTimer?.cancel();
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
    _dirtyTimer?.cancel();
    _dirtyTimer = null;
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
    final hook = afterSignIn;
    if (hook == null) {
      unawaited(run(manual: true));
    } else {
      unawaited(
        hook().catchError((Object e) {
          VaultLog.e('Tras iniciar sesión falló', e, 'sync');
        }),
      );
    }
  }

  Future<void> signOut() async {
    _token?.cancel();
    await cloud.signOut();
    // Otra cuenta (o la misma, más tarde) debe recibir de nuevo el respaldo de
    // recuperación: se olvida la marca de "ya subido".
    await prefs.setRecoveryUploadedSha('');
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
    // En caliente: al activar "solo Wi-Fi" con una subida en curso por datos
    // móviles, se detiene (queda pendiente y se reanuda con Wi-Fi).
    if (value && _running) {
      final net = await network.current();
      if (net == NetworkKind.mobile) _token?.cancel();
    }
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
  ///
  /// Con [pausedForMigration] solo corre si [force] (la usa el cambio de
  /// cuenta, que es quien manda la subida mientras dura).
  Future<void> run({bool manual = false, bool force = false}) async {
    if (_running || _disposed) return;
    if (!isUnlocked()) return;
    if ((pausedForMigration || pausedForVerification) && !force) return;
    _running = true;
    VaultLog.d('Sincronización iniciada', category: 'sync');
    final token = _token = CloudCancelToken();
    _wake?.cancel();
    _wake = null;
    _dirtyTimer?.cancel();
    _dirtyTimer = null;
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
      if (phase == SyncPhase.running && !token.isCancelled) {
        await _maybeSweepGenerations();
      }
      await _finish(token.isCancelled ? SyncPhase.idle : _idleIf(phase));
      if (!token.isCancelled && phase == SyncPhase.running) {
        unawaited(refreshQuota());
      }
    } on StateError {
      // Bóveda bloqueada a mitad de la ejecución: se descarta sin ruido.
      _publishQuiet();
    } on CloudException catch (e) {
      VaultLog.e('Sincronización con error', e, 'sync');
      summary.value = summary.value.copyWith(lastMessage: describeSyncError(e));
      await _finish(SyncPhase.idle);
    } finally {
      _running = false;
      VaultLog.d('Sincronización terminada', category: 'sync');
      progress.value = const {};
      final hook = afterRun;
      if (hook != null && !_disposed && isUnlocked()) {
        try {
          await hook();
        } on Object catch (e) {
          VaultLog.e('afterRun falló', e, 'sync');
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
      // D75: también si se subió a OTRA cuenta (tag distinto), aunque nadie
      // llamara a `signOut`.
      final tag = await _currentTag();
      final otherAccount =
          tag != null && tag != await prefs.getRecoveryUploadedTag();
      final blocked = tag != null && tag == recoveryBackupBlockedTag;
      if (!blocked &&
          (otherAccount || sha != await prefs.getRecoveryUploadedSha())) {
        await queue.enqueue(
          SyncQueueRepository.noItem,
          SyncJobKind.recoveryBackup,
          now: now,
        );
      }
    }
  }

  /// Política del snapshot (F9). Se llama cuando ya no quedan trabajos
  /// vencidos (todo lo subible está subido), de modo que la copia incluye
  /// los `driveFileId`/`cloudMd5` de lo recién subido. Se encola si:
  /// * hay cambios desde el último snapshot (marca "sucio" persistida), o
  /// * el último snapshot tiene más de [snapshotMaxAge] (seguro contra una
  ///   copia remota perdida).
  Future<void> _maybeEnqueueSnapshot() async {
    if (_lockFlushRunning) return;
    // D61: con el conjunto viejo congelado no se publica ningún snapshot (la
    // marca "sucio" persiste y se sube tras el corte).
    if (rotation.freezeMeta) return;
    final dirty = await prefs.getDirtyAt() != null;
    final at = await prefs.getSnapshotAt();
    final aged = at != null && _now() - at >= snapshotMaxAge.inMilliseconds;
    if (dirty || aged) {
      await queue.enqueue(
        SyncQueueRepository.noItem,
        SyncJobKind.dbSnapshot,
        now: _now(),
      );
    }
  }

  /// D61: tras restaurar en una generación > 1, borra de Drive (por lista y
  /// con la guarda de [GenerationSweeper]) las generaciones anteriores. Solo
  /// sin rotación en curso; un fallo deja la marca para la próxima pasada.
  Future<void> _maybeSweepGenerations() async {
    if (rotation.active) return;
    if (!await prefs.getGenerationSweepPending()) return;
    final gen = await currentKeyGen();
    final local = await recoveryBackupProvider();
    if (gen <= 1 || local == null) {
      await prefs.setGenerationSweepPending(false);
      return;
    }
    try {
      final r = await GenerationSweeper(
        cloud: cloud,
      ).sweep(currentGen: gen, localRecoveryBackupJson: local);
      if (r == SweepResult.done) await prefs.setGenerationSweepPending(false);
    } on CloudException catch (e) {
      VaultLog.e('Barrido de generaciones pendiente', e, 'sync');
    }
  }

  /// Los datos cambiaron (lo llama `VaultDataRepository.onDataChanged`):
  /// marca el snapshot como sucio (persistido) y programa una pasada tras
  /// [snapshotDebounce] sin más cambios.
  void notifyDataChanged() {
    if (_disposed) return;
    unawaited(
      prefs.markDirty(_now()).catchError((Object _) {
        // almacén seguro no disponible: se reintentará con el próximo cambio
      }),
    );
    if (!scheduleWakeups) return;
    _dirtyTimer?.cancel();
    _dirtyTimer = Timer(snapshotDebounce, () {
      _dirtyTimer = null;
      if (!_disposed && !_running && isUnlocked()) unawaited(run());
    });
  }

  /// Al bloquear (best-effort): si hay cambios sin respaldar y la red lo
  /// permite, toma la copia cifrada de la BD AHORA (antes de que se cierre la
  /// sesión) y la sube en segundo plano sin necesitar llaves. Devuelve
  /// cuando la copia está tomada; la subida sigue por su cuenta. Si falla,
  /// la marca "sucio" persiste y la próxima sesión lo reintenta.
  Future<void> flushSnapshotBeforeLock() async {
    if (_disposed || _lockFlushRunning || !isUnlocked()) return;
    if (rotation.freezeMeta) return; // D61: conjunto viejo congelado
    // D75: ni con un cambio de cuenta ni con una verificación en curso (la
    // cuenta de la sesión puede no ser aquella cuyas referencias tiene la BD).
    if (pausedForMigration || pausedForVerification) return;
    try {
      if (await prefs.getDirtyAt() == null) return;
      if (cloud.currentAccountEmail == null) return;
      // D75: solo a la cuenta a la que ya se subió el último snapshot (la
      // sincronización normal, que verifica, se encarga de una cuenta nueva).
      String? tag;
      if (accountTag != null) {
        tag = await _currentTag();
        if (tag == null || tag != await prefs.getSnapshotUploadedTag()) return;
      }
      final net = await network.current();
      if (!net.isOnline) return;
      if (net == NetworkKind.mobile && await prefs.getWifiOnly()) return;
      _lockFlushRunning = true;
      final takenAt = _now();
      final snapshot = await snapshotProvider();
      unawaited(_uploadFlushedSnapshot(snapshot, takenAt, tag));
    } on Object catch (e) {
      _lockFlushRunning = false;
      if (kDebugMode) debugPrint('[sync] snapshot al bloquear omitido: $e');
    }
  }

  /// `true` mientras una subida de snapshot (del flush al bloquear) sigue en
  /// vuelo. La rotación espera a que termine antes de congelar (D61).
  bool get snapshotFlushInFlight => _lockFlushRunning;

  Future<void> _uploadFlushedSnapshot(
    SnapshotCopy snapshot,
    int takenAt,
    String? tag,
  ) async {
    try {
      await _uploadSnapshotFile(
        snapshot,
        CloudCancelToken(),
        takenAt,
        accountTagAtStart: tag,
      );
      if (kDebugMode) debugPrint('[sync] snapshot subido al bloquear');
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('[sync] snapshot al bloquear falló: ${e.runtimeType}');
      }
    } finally {
      _lockFlushRunning = false;
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
    } on SyncAccountChangedException {
      // D75: la sesión cambió de cuenta a mitad: se repite con la nueva.
      VaultLog.d('Subida descartada: la cuenta cambió', category: 'sync');
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
        e is SyncGuardException ||
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
      // D61: con el conjunto viejo congelado, los metadatos no se publican.
      // El trabajo se da por hecho: la marca "sucio" (snapshot) y el SHA del
      // respaldo (reconcile) los vuelven a encolar después del corte.
      case SyncJobKind.recoveryBackup:
        if (rotation.freezeMeta) return true;
        return _uploadRecoveryBackup();
      case SyncJobKind.dbSnapshot:
        if (rotation.freezeMeta) return true;
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
    // D61: entre la congelación y el corte NO se crean nombres de la
    // generación vieja (romperían la lista exacta del conjunto 1).
    if (rotation.freezeMeta && item.keyGen == rotation.fromGen) {
      throw SyncGuardException(
        'archivo de la generación ${item.keyGen} con el conjunto congelado',
      );
    }
    final file = resolvePath(rel);
    if (!await file.exists()) {
      // M4: si la fila cambió entretanto (re-cifrado: otra ruta/generación),
      // no es un archivo perdido; el trabajo nuevo ya está en la cola.
      final fresh = await items.getItem(job.itemId);
      if (fresh == null) return true;
      final freshRel = isThumb ? fresh.thumbPath : fresh.encryptedPath;
      if (fresh.keyGen != item.keyGen || freshRel != rel) return true;
      throw SyncLocalMissingException(rel);
    }

    final name = isThumb
        ? CloudNames.thumb(item.id, gen: item.keyGen)
        : CloudNames.file(item.id, gen: item.keyGen);
    // D75: cuenta capturada al EMPEZAR; si al terminar es otra, lo subido no
    // se registra (el trabajo se repite).
    final tag = await _currentTag();
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
    if (accountTag != null && await _currentTag() != tag) {
      throw const SyncAccountChangedException();
    }
    // M4: solo se registra si la fila sigue siendo la que se subió (misma
    // generación y ruta). Si cambió o se borró, el trabajo se da por hecho
    // SIN borrar nada en Drive (ese id puede estar en un conjunto de
    // respaldo; lo limpia la rotación o el borrado remoto).
    final bool marked;
    if (isThumb) {
      marked = await items.setThumbDriveFileIdIf(
        item.id,
        remote.id,
        expectKeyGen: item.keyGen,
        expectThumbPath: rel,
        accountTag: tag,
      );
    } else {
      marked = await items.markCloudVerifiedIf(
        item.id,
        driveFileId: remote.id,
        md5: md5,
        size: size,
        expectKeyGen: item.keyGen,
        expectPath: rel,
        accountTag: tag,
      );
      if (marked) await prefs.addUpload();
    }
    if (marked) await prefs.markDirty(_now());
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
    // D60: los nombres del item en TODAS las generaciones conocidas (y su
    // cuarentena, D61/M6): un borrado durante o tras una rotación no deja
    // restos de otra generación.
    final current = await currentKeyGen();
    final maxGen = max(current, max(rotation.toGen, rotation.fromGen));
    for (var gen = 1; gen <= maxGen; gen++) {
      for (final name in [
        CloudNames.file(job.itemId, gen: gen),
        CloudNames.thumb(job.itemId, gen: gen),
        CloudNames.quarantine(job.itemId, gen),
      ]) {
        final found = await cloud.findByName(name);
        if (found != null) ids.add(found.id);
      }
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
    // S-04 (revisión de seguridad): NO se reemplaza el contenido con
    // `files.update`: Drive guarda el contenido anterior como REVISIÓN
    // (≈30 días) y el respaldo viejo seguiría abriendo la MISMA DEK con el
    // código VIEJO tras "Generar código nuevo". Se crea un archivo nuevo, se
    // verifica y después se BORRAN (permanente, con sus revisiones) todos los
    // anteriores con ese nombre. Si el borrado falla, el trabajo falla y se
    // reintenta (se vuelve a crear y a borrar todo lo previo).
    // D60: el nombre es el de la generación vigente (`recovery_backup.json`
    // en la 1, `recovery_backup.kN.json` después de rotar).
    final name = CloudNames.recoveryBackupFor(await currentKeyGen());
    // D75: en una cuenta con el respaldo de OTRA bóveda (lo vio la
    // verificación) no se crea ni se reemplaza nada.
    final tag = await _currentTag();
    if (tag != null && tag == recoveryBackupBlockedTag) return true;
    final previous = [
      for (final f in await cloud.list())
        if (f.name == name) f.id,
    ];
    final remote = await cloud.uploadBytes(bytes: bytes, name: name);
    _verify(remote, bytes.length, md5OfBytes(bytes));
    for (final id in previous) {
      if (id == remote.id) continue;
      try {
        await cloud.delete(id);
      } on CloudNotFoundException {
        // ya no existe
      }
    }
    final sha = crypto.sha256.convert(bytes).toString();
    await prefs.setRecoveryUploadedSha(sha);
    if (accountTag != null) {
      await prefs.setRecoveryUploadedTag(
        await _currentTag() == tag ? tag : null,
      );
    }
    if (kDebugMode) {
      // Diagnóstico (solo depuración): confirma la subida sin exponer nada
      // más que el prefijo del SHA-256 del respaldo (ya cifrado).
      debugPrint(
        '[sync] respaldo de recuperación subido: ${bytes.length} B '
        'sha#=${sha.substring(0, 8)}',
      );
    }
    return true;
  }

  Future<bool> _uploadSnapshot(CloudCancelToken token) async {
    final takenAt = _now();
    final tag = await _currentTag();
    final snapshot = await snapshotProvider();
    return _uploadSnapshotFile(
      snapshot,
      token,
      takenAt,
      accountTagAtStart: tag,
    );
  }

  /// D75: tag de la cuenta actual (`null` sin proveedor o sin sesión).
  Future<String?> _currentTag() async {
    final provider = accountTag;
    if (provider == null) return null;
    return provider();
  }

  /// Identidad cruda de la sesión (solo para comparar en memoria; nunca se
  /// registra ni se guarda).
  String? get _sessionIdentity =>
      cloud.currentAccountId ?? cloud.currentAccountEmail;

  /// Sube [copy] (copia ya cifrada de la BD) y la borra al terminar.
  /// [takenAt]: instante en que se tomó la copia (ver
  /// [SyncPreferences.markSnapshotDone]).
  ///
  /// C2 (D61), guarda en el punto más bajo: el nombre sale de la generación
  /// de la COPIA (`vault_db[.kN].snapshot`) y se niega
  /// ([SyncGuardException]) si sus filas no son todas de esa generación, o
  /// si el conjunto viejo está congelado (rotación) y no lo pide la propia
  /// rotación ([byRotation]).
  Future<bool> _uploadSnapshotFile(
    SnapshotCopy copy,
    CloudCancelToken token,
    int takenAt, {
    bool byRotation = false,
    String? accountTagAtStart,
  }) async {
    final snapshot = copy.file;
    final identity = _sessionIdentity;
    try {
      if (!copy.isCoherent) {
        throw SyncGuardException(
          'snapshot con filas de generaciones ${copy.minKeyGen}..'
          '${copy.maxKeyGen} y llave de la ${copy.dbGen}',
        );
      }
      if (rotation.freezeMeta && !byRotation) {
        throw const SyncGuardException('snapshot con el conjunto congelado');
      }
      final name = CloudNames.dbSnapshotFor(copy.dbGen);
      final size = await snapshot.length();
      final md5 = await md5OfFile(snapshot);
      final existing = await cloud.findByName(name);
      final remote = await cloud.uploadFile(
        file: snapshot,
        name: name,
        replaceFileId: existing?.id,
        cancel: token,
      );
      _verify(remote, size, md5);
      await prefs.markSnapshotDone(_now(), takenAtMs: takenAt);
      if (accountTag != null) {
        // Sin BD (flush tras bloquear): se compara la sesión en memoria.
        await prefs.setSnapshotUploadedTag(
          identity != null && identity == _sessionIdentity
              ? accountTagAtStart
              : null,
        );
      }
      VaultLog.d('Snapshot de la BD subido', category: 'sync');
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
  ///
  /// A1 (D61): durante una rotación de la DEK devuelve SIEMPRE `false`: lo
  /// importado en la ventana no está en ningún conjunto que se pueda
  /// restaurar hasta el corte, así que no se borra ningún original.
  ///
  /// D75: con [accountTag], exige además que el item esté comprobado en la
  /// cuenta ACTUAL (`cloudAccountTag` igual al tag de la sesión, no nulo).
  Future<bool> cloudVerifier(VaultItemModel item) async {
    if (rotation.active) return false;
    if (pausedForMigration || pausedForVerification) return false;
    try {
      final fresh = await items.getItem(item.id);
      if (fresh == null ||
          fresh.syncStatus != SyncStatus.enNube ||
          fresh.driveFileId == null ||
          fresh.cloudMd5 == null ||
          fresh.cloudSize == null) {
        return false;
      }
      if (accountTag != null) {
        final tag = await _currentTag();
        if (tag == null || fresh.cloudAccountTag != tag) return false;
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
