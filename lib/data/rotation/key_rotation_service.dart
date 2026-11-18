import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/key_hierarchy.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../../core/session/vault_session.dart';
import '../cloud/cloud_s04.dart';
import '../cloud/cloud_storage.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import '../repositories/vault_database.dart';
import '../restore/generation_sweeper.dart';
import '../sync/network_monitor.dart';
import '../sync/sync_preferences.dart';
import '../sync/sync_queue_repository.dart';
import '../sync/sync_service.dart';
import 'item_reencryptor.dart';
import 'rotation_repository.dart';

/// Puntos de la máquina de estados donde las pruebas simulan un corte
/// (§10.2). En la app no se usan.
enum RotationCrashPoint {
  confirmedChecked,
  freezingStateCreated,
  freezingSnapshotUploaded,
  freezingSnapshotRecorded,
  freezingBridgeUploaded,
  freezingOldFilesListed,
  beforeReencrypting,
  itemDone,
  uploadingVerified,
  rekeyDone,
  switchDone,
  snapshotUploaded,
  backupUploaded,

  /// Justo DESPUÉS de escribir la fase del corte (`deletingOldCloud`).
  afterCut,
  oldBackupDeleted,
  bridgeDeleted,
  oldSnapshotDeleted,
  blobDeleted,
  finalizeSwept,
  finalizeBeforeRecord,

  /// Tras quitar UN item sin copia ("Continuar sin ellos", D64).
  missingDropped,
}

/// Un archivo con problema al re-cifrar (para la UI; el nombre NUNCA va a
/// logs, Diagnóstico ni al registro de la rotación).
@immutable
class RotationProblemItem {
  const RotationProblemItem({required this.id, required this.name});
  final String id;
  final String name;
}

/// Archivos que frenan el re-cifrado (`blockedCorrupt` con `resumePhase =
/// reencrypting`).
@immutable
class RotationProblems {
  const RotationProblems({this.missing = const [], this.damaged = const []});

  /// Sin NINGUNA copia (ni en el teléfono ni en Drive): "Continuar sin
  /// ellos" los quita de la bóveda (D64).
  final List<RotationProblemItem> missing;

  /// Con copia que no abre: "Omitir los dañados" (cuarentena, M6).
  final List<RotationProblemItem> damaged;

  bool get isEmpty => missing.isEmpty && damaged.isEmpty;

  /// Texto para el registro (solo cuentas, sin nombres).
  String get summary => [
    if (missing.isNotEmpty) '${missing.length} archivo(s) sin ninguna copia',
    if (damaged.isNotEmpty) '${damaged.length} archivo(s) dañado(s)',
  ].join(' y ');
}

/// Estado para la UI.
@immutable
class RotationStatus {
  const RotationStatus({
    this.phase,
    this.running = false,
    this.message,
    this.needsPin = false,
    this.itemsDone = 0,
    this.itemsTotal = 0,
    this.finished = false,
    this.offerBiometric = false,
  });

  /// La rotación acaba de terminar ("Rotación terminada").
  final bool finished;

  /// La biometría estaba activa antes de la rotación: ofrecer reactivarla.
  final bool offerBiometric;

  /// `null` = no hay rotación.
  final RotationPhase? phase;
  final bool running;

  /// Qué pasa o por qué está en pausa (español).
  final String? message;

  /// Hace falta desbloquear con el PIN (la DEK nueva no está en memoria).
  final bool needsPin;
  final int itemsDone;
  final int itemsTotal;
}

/// Lo que implica una rotación (hoja previa).
@immutable
class RotationPlan {
  const RotationPlan({
    required this.items,
    required this.uploadBytes,
    required this.cloudOnlyBytes,
    required this.pendingUploads,
    required this.lostThumbnails,
    required this.quota,
    required this.enoughDriveSpace,
    required this.signedIn,
    this.oldAccountKept,
    this.noCopyItems = 0,
  });

  /// Archivos sin ninguna copia conocida (ni `.vault` local ni copia en
  /// Drive): no impiden empezar; durante el re-cifrado se pregunta qué
  /// hacer con ellos ("Continuar sin ellos", D64).
  final int noCopyItems;

  final int items;

  /// Lo que se vuelve a subir (≈ lo que ocupa la bóveda en Drive; durante
  /// la rotación Drive guarda el doble).
  final int uploadBytes;

  /// Lo que hay que bajar porque solo está en la nube.
  final int cloudOnlyBytes;

  /// Archivos sin subir o con error (A4: hay que resolverlos antes).
  final int pendingUploads;

  /// Miniaturas que no se podrán recuperar (L5).
  final int lostThumbnails;
  final CloudQuota? quota;
  final bool enoughDriveSpace;
  final bool signedIn;

  /// M7: correo de una cuenta anterior que conserva una copia vieja.
  final String? oldAccountKept;
}

/// Restos de generaciones que no son la vigente (limpieza manual, M11/D73).
@immutable
class LeftoversScan {
  const LeftoversScan({
    this.cloudAbandoned = 0,
    this.cloudStale = 0,
    this.cloudBytes = 0,
    this.localFiles = 0,
    this.staleSkipped = false,
  });

  /// Archivos de Drive con generación MAYOR que la vigente y sin respaldo.
  final int cloudAbandoned;

  /// Archivos de Drive de generaciones MENORES que la vigente.
  final int cloudStale;

  /// Lo que ocupan en Drive (los dos anteriores).
  final int cloudBytes;

  /// Archivos locales de una generación distinta a la de su item.
  final int localFiles;

  /// Solo en el resultado: los de generaciones menores NO se borraron porque
  /// la guarda del barrido no se cumplió (el conjunto vigente no está
  /// completo en Drive).
  final bool staleSkipped;

  int get cloudFiles => cloudAbandoned + cloudStale;
  bool get isEmpty => cloudFiles == 0 && localFiles == 0;
}

class RotationException implements Exception {
  const RotationException(this.message);
  final String message;
  @override
  String toString() => 'RotationException: $message';
}

/// Corte simulado en una prueba.
class _Stop implements Exception {
  const _Stop();
}

/// Rotación de la llave maestra (DEK), `docs/DISENO_ROTACION.md` §3.
///
/// Máquina de estados persistida en el almacén seguro (registro de la
/// rotación) y en la BD (`rotation_state`, `rotation_old_files`, `keyGen` por
/// item). La fase es una PISTA: cada paso es idempotente y comprueba el
/// mundo antes de actuar, así que un corte en cualquier punto se reanuda.
///
/// Entrega 10a: de `prepared` hasta el CORTE (`uploadingBackup` →
/// `deletingOldCloud`). El borrado del conjunto viejo y la limpieza final
/// llegan en 10b.
class KeyRotationService {
  KeyRotationService({
    required this.auth,
    required this.session,
    required this.db,
    required this.items,
    required this.queue,
    required this.sync,
    required this.cloud,
    required this.network,
    required this.prefs,
    required this.repo,
    required this.reencryptor,
    this.isInUse,
    this.migrationActive,
    this.crashPoint,
    int Function()? nowMs,
    this.maxPendingLocalBytes = 500 * 1024 * 1024,
    this.maxUploadRounds = 40,
    this.syncIdleTimeout = const Duration(minutes: 2),
    CryptoService? crypto,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _crypto = crypto ?? CryptoService();

  final AuthController auth;
  final VaultSession session;
  final VaultDatabase db;
  final VaultDataRepository items;
  final SyncQueueRepository queue;
  final SyncService sync;
  final CloudStorage cloud;
  final NetworkMonitor network;
  final SyncPreferences prefs;
  final RotationRepository repo;
  final ItemReencryptor reencryptor;

  /// El item está abierto en el visor/streaming: se deja para después.
  final bool Function(String itemId)? isInUse;

  /// Hay un cambio de cuenta en curso (excluyentes, D61).
  final Future<bool> Function()? migrationActive;

  /// Solo pruebas: se llama en cada [RotationCrashPoint] (puede lanzar).
  final void Function(RotationCrashPoint point)? crashPoint;

  /// Tope de `.kN` locales pendientes de subir antes de re-cifrar más items
  /// que solo están en la nube (§5).
  final int maxPendingLocalBytes;
  final int maxUploadRounds;
  final Duration syncIdleTimeout;
  final int Function() _now;
  final CryptoService _crypto;

  final ValueNotifier<RotationStatus> status = ValueNotifier(
    const RotationStatus(),
  );

  /// Archivos que frenan el re-cifrado (solo en memoria; tras reiniciar la
  /// app se recalculan con [loadProblems]).
  final ValueNotifier<RotationProblems?> problems = ValueNotifier(null);

  /// Avance (`37/120 archivos`) leído de lo persistido (D72); `null` si no
  /// hay rotación o aún no se congeló la cardinalidad.
  final ValueNotifier<RotationProgress?> progress = ValueNotifier(null);

  /// Una operación manual de limpieza está en curso (excluye una rotación).
  bool _maintenance = false;

  bool _running = false;
  bool get isRunning => _running;
  bool _stopRequested = false;

  /// Sesión (bóveda y época) con la que empezó la vuelta actual (D67).
  SessionTicket? _ticket;

  /// Hay que parar: pausa pedida, o la sesión cambió (bloqueo, otra
  /// bóveda). Con la sesión cambiada no se escribe ningún estado.
  bool get _halted => _stopRequested || !(_ticket?.isValid ?? false);
  CloudCancelToken _token = CloudCancelToken();

  RotationKeyStore get _store => auth.rotationStore;

  void _crash(RotationCrashPoint p) => crashPoint?.call(p);

  // ------------------------------------------------------------- inicio

  /// Siguiente generación: mayor que la vigente y que cualquiera vista en
  /// Drive (así nunca se reutiliza un nombre, §1).
  Future<int> nextGeneration() async {
    var max = await auth.currentKeyGen();
    for (final f in await cloud.list()) {
      final g = CloudNames.parse(f.name)?.gen;
      if (g != null && g > max) max = g;
    }
    return max + 1;
  }

  /// Empieza la rotación (fase `prepared`). Devuelve el código nuevo B para
  /// mostrarlo, o `null` si el PIN es incorrecto. Lanza
  /// [RotationException] si no se puede empezar.
  Future<String?> start(
    String pin, {
    RotationReason reason = RotationReason.rotateKey,
  }) async {
    if (await migrationActive?.call() ?? false) {
      throw const RotationException('Hay un cambio de cuenta en curso.');
    }
    if (_maintenance) {
      throw const RotationException(
        'Hay una limpieza en curso. Espera a que termine.',
      );
    }
    final email =
        cloud.currentAccountEmail ?? (await cloud.signInSilently())?.email;
    if (email == null) {
      throw const RotationException(
        'Inicia sesión con Google para cambiar la llave maestra.',
      );
    }
    final code = await auth.prepareRotation(
      pin,
      toGen: await nextGeneration(),
      accountEmail: email,
      reason: reason,
    );
    await _publish();
    return code;
  }

  /// El usuario confirmó B (`prepared` → `confirmed`).
  Future<bool> confirm(String code) async {
    final ok = await auth.confirmRotationCode(code);
    await _publish();
    return ok;
  }

  /// Cancela hasta `freezing` (nada re-cifrado todavía): borra el puente de
  /// Drive, los triggers y filas de la BD y lo local. El snapshot viejo
  /// recién subido se queda (es un snapshot válido de la generación vieja).
  Future<void> cancel() async {
    final rec = await _store.load();
    if (rec == null) return;
    if (!rec.isCancellable) {
      throw const RotationException(
        'El cambio de llave ya empezó: solo se puede pausar.',
      );
    }
    pause();
    for (var i = 0; i < 200 && _running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final bridgeName = CloudNames.bridgeBackup(rec.fromGen);
    for (final f in await cloud.list()) {
      if (f.name != bridgeName) continue;
      try {
        await cloud.delete(f.id);
      } on CloudNotFoundException {
        // ya no estaba
      }
    }
    await repo.clear();
    await auth.abandonRotation();
    problems.value = null;
    status.value = const RotationStatus();
  }

  /// `blockedForeign`: "Descartar restos". Borra lo local de una rotación
  /// que no es de esta bóveda (registro y, si son de otra rotación, las
  /// filas de la BD). No borra nada en Drive.
  Future<void> discardForeign() async {
    final rec = await _store.load();
    if (rec == null || rec.phase != RotationPhase.blockedForeign) return;
    pause();
    final state = await repo.load();
    if (state == null || state.rotationId != rec.id) await repo.clear();
    await auth.discardForeignRotation();
    problems.value = null;
    status.value = const RotationStatus();
  }

  /// Comprobación previa (§8, pantalla 2): qué implica la rotación.
  Future<RotationPlan> plan() async {
    final all = await items.getAllItems();
    var upload = 0;
    var cloudOnly = 0;
    var pending = 0;
    var lostThumbs = 0;
    var noCopy = 0;
    for (final i in all) {
      final f = _resolve(i.encryptedPath);
      final local = f.existsSync();
      if (!local && i.driveFileId == null) {
        noCopy++;
        continue;
      }
      final size = i.cloudSize ?? (local ? f.lengthSync() : i.fileSize);
      upload += size;
      if (!local) cloudOnly += size;
      if (i.syncStatus == SyncStatus.pendiente ||
          i.syncStatus == SyncStatus.subiendo ||
          i.syncStatus == SyncStatus.error) {
        pending++;
      }
      final t = i.thumbPath;
      if (t != null &&
          !_resolve(t).existsSync() &&
          i.thumbDriveFileId == null) {
        lostThumbs++;
      }
    }
    CloudQuota? quota;
    try {
      quota = await cloud.getQuota();
    } on CloudException {
      quota = null;
    }
    final limit = quota?.limitBytes;
    final enough =
        quota == null ||
        limit == null ||
        limit - quota.usedBytes >= upload + upload ~/ 20;
    // M7: si la cuenta anterior es la que se usa ahora, no hay nada que
    // ofrecer borrar (nunca se borra la cuenta actual).
    final kept = await prefs.getOldAccountKept();
    return RotationPlan(
      items: all.length,
      uploadBytes: upload,
      cloudOnlyBytes: cloudOnly,
      pendingUploads: pending,
      lostThumbnails: lostThumbs,
      quota: quota,
      enoughDriveSpace: enough,
      signedIn: cloud.currentAccountEmail != null,
      oldAccountKept: kept != null && kept != cloud.currentAccountEmail
          ? kept
          : null,
      noCopyItems: noCopy,
    );
  }

  // ------------------------------------------------- avance (contador, D72)

  /// Relee el avance de la BD (barato: dos conteos). Con la BD cerrada o sin
  /// rotación deja el valor anterior / `null`; nunca lanza.
  Future<void> refreshProgress() async {
    try {
      if (_store.record.value == null) {
        progress.value = null;
        return;
      }
      final p = await repo.progress();
      if (p != progress.value) progress.value = p;
    } on Object {
      // BD no disponible (bloqueada a mitad): se conserva lo último.
    }
  }

  // --------------------------------------- cuenta anterior (M7) y restos (M11)

  /// D72/D73: solo con la bóveda principal abierta, sin rotación ni cambio
  /// de cuenta en curso ni otra limpieza.
  Future<void> _requireIdleForMaintenance() async {
    if (!session.isUnlockedAs(VaultSlot.primary)) {
      throw const RotationException('Desbloquea tu bóveda para continuar.');
    }
    if (_running ||
        _maintenance ||
        _store.record.value != null ||
        await _store.load() != null) {
      throw const RotationException(
        'Hay un cambio de llave en curso. Termínalo antes de limpiar.',
      );
    }
    if (await migrationActive?.call() ?? false) {
      throw const RotationException('Hay un cambio de cuenta en curso.');
    }
  }

  /// M7 (D72): borra de forma PERMANENTE los datos de Vault que conserva la
  /// cuenta de Google ANTERIOR de un cambio de cuenta. Pide elegir esa
  /// cuenta, comprueba que el correo es el guardado (y distinto del actual)
  /// ANTES de borrar nada, y al terminar (o fallar) vuelve a la cuenta
  /// actual. Devuelve cuántos archivos se borraron. Solo la principal (el
  /// almacenamiento va además envuelto en `SlotGuardedCloudStorage`).
  Future<int> deleteOldAccountData() async {
    await _requireIdleForMaintenance();
    final old = await prefs.getOldAccountKept();
    if (old == null) {
      throw const RotationException(
        'No hay datos de una cuenta anterior que borrar.',
      );
    }
    final current =
        cloud.currentAccountEmail ?? (await cloud.signInSilently())?.email;
    if (current == null) {
      throw const RotationException(
        'Inicia sesión con tu cuenta actual para continuar.',
      );
    }
    if (current == old) {
      throw const RotationException(
        'Esa es la cuenta que usas ahora: no se borra nada.',
      );
    }
    _maintenance = true;
    final wasPaused = sync.pausedForMigration;
    // La sincronización normal NO puede subir nada a la cuenta anterior
    // mientras esté iniciada.
    sync.pausedForMigration = true;
    sync.cancel();
    Object? failure;
    var deleted = 0;
    try {
      await _waitSyncIdle();
      await cloud.signOut();
      final account = await cloud.signIn();
      if (account.email != old || account.email == current) {
        throw RotationException(
          'Elegiste otra cuenta. Para borrar, inicia sesión con $old.',
        );
      }
      for (final f in await cloud.list()) {
        if (CloudNames.parse(f.name) == null) continue; // nada ajeno a Vault
        try {
          await cloud.delete(f.id);
          deleted++;
        } on CloudNotFoundException {
          // ya no estaba
        }
      }
      await prefs.clearOldAccountKept();
      VaultLog.d(
        'Datos de la cuenta anterior borrados: $deleted',
        category: 'rotation',
      );
    } on Object catch (e) {
      failure = e;
    } finally {
      // Siempre de vuelta a la cuenta actual (nunca se queda la anterior).
      try {
        if (cloud.currentAccountEmail != current) {
          if (cloud.currentAccountEmail != null) await cloud.signOut();
          final back = await cloud.signIn();
          if (back.email != current && failure == null) {
            failure = RotationException(
              'Datos borrados. Inicia sesión con $current para seguir '
              'sincronizando.',
            );
          }
        }
      } on Object catch (e) {
        failure ??= RotationException(
          'Inicia sesión con $current para seguir sincronizando.',
        );
        VaultLog.e('Volver a la cuenta actual', e, 'rotation');
      }
      sync.pausedForMigration = wasPaused;
      _maintenance = false;
      unawaited(
        sync.refreshCounts().catchError((Object _) {
          // BD cerrada (bloqueo a mitad): el resumen se rehace al desbloquear
        }),
      );
    }
    if (failure != null) throw failure;
    return deleted;
  }

  /// Vista previa de la limpieza manual (M11, D73): no borra nada.
  Future<LeftoversScan> scanLeftovers() async {
    await _requireIdleForMaintenance();
    final gen = await auth.currentKeyGen();
    await _requireCloudAccount();
    final sweeper = GenerationSweeper(cloud: cloud);
    final abandoned = await sweeper.findAbandoned(currentGen: gen);
    final stale = await sweeper.findStale(currentGen: gen);
    return LeftoversScan(
      cloudAbandoned: abandoned.length,
      cloudStale: stale.length,
      cloudBytes: [...abandoned, ...stale].fold(0, (a, f) => a + f.size),
      localFiles: (await _localStale()).length,
    );
  }

  /// Borra los restos (Drive y teléfono). Vuelve a comprobar que no hay
  /// rotación justo antes de borrar. Las generaciones MENORES a la vigente
  /// solo se borran con la guarda de [GenerationSweeper.sweep]; las MAYORES
  /// solo si no tienen respaldo (nadie restaura con ellas).
  Future<LeftoversScan> cleanLeftovers() async {
    await _requireIdleForMaintenance();
    final gen = await auth.currentKeyGen();
    await _requireCloudAccount();
    _maintenance = true;
    try {
      final sweeper = GenerationSweeper(cloud: cloud);
      final abandoned = await sweeper.findAbandoned(currentGen: gen);
      final stale = await sweeper.findStale(currentGen: gen);
      var staleSkipped = false;
      var cloudStale = 0;
      if (stale.isNotEmpty) {
        final local = await auth.exportRecoveryBackup();
        final r = local == null
            ? SweepResult.guardFailed
            : await sweeper.sweep(
                currentGen: gen,
                localRecoveryBackupJson: local,
              );
        staleSkipped = r == SweepResult.guardFailed;
        if (!staleSkipped) cloudStale = stale.length;
      }
      final cloudAbandoned = await sweeper.sweepAbandoned(currentGen: gen);
      var local = 0;
      for (final f in await _localStale()) {
        await _delete(f);
        local++;
      }
      return LeftoversScan(
        cloudAbandoned: cloudAbandoned,
        cloudStale: cloudStale,
        cloudBytes: [
          ...abandoned,
          if (!staleSkipped) ...stale,
        ].fold(0, (a, f) => a + f.size),
        localFiles: local,
        staleSkipped: staleSkipped,
      );
    } finally {
      _maintenance = false;
    }
  }

  Future<void> _requireCloudAccount() async {
    final email =
        cloud.currentAccountEmail ?? (await cloud.signInSilently())?.email;
    if (email == null) {
      throw const RotationException(
        'Inicia sesión con Google para limpiar los restos de Drive.',
      );
    }
  }

  /// Archivos locales `<id>[.kN].vault|thumb` de un item que EXISTE pero cuya
  /// generación no es la de su fila (restos de una rotación). No toca los de
  /// items sin fila (otro barrido), ni `.part`.
  Future<List<File>> _localStale() async {
    final gens = {for (final i in await items.getAllItems()) i.id: i.keyGen};
    final out = <File>[];
    for (final dir in [AppPaths.vaultDir, AppPaths.thumbsDir]) {
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final info = CloudNames.parse(name);
        if (info == null || info.itemId == null) continue;
        if (info.kind != CloudNameKind.file &&
            info.kind != CloudNameKind.thumb) {
          continue;
        }
        final cur = gens[info.itemId];
        if (cur != null && cur != info.gen) out.add(f);
      }
    }
    return out;
  }

  /// Detiene el flujo (se reanuda con [resume]). Lo llama el bloqueo.
  void pause() {
    _stopRequested = true;
    _token.cancel();
  }

  /// Sale de un bloqueo (`blocked*`) y reanuda.
  Future<void> retry() async {
    problems.value = null;
    final rec = await _store.load();
    if (rec == null || !rec.phase.isBlocked) return resume();
    await _store.save(
      rec.copyWith(
        phase: rec.effectivePhase,
        resumePhase: null,
        lastError: null,
        updatedAt: _now(),
      ),
    );
    await resume();
  }

  // -------------------------------------------------------------- bucle

  /// Avanza todo lo posible: hasta terminar, necesitar al usuario, quedarse
  /// sin red o bloquearse.
  Future<void> resume() async {
    if (_running) return;
    // D67 (fase 8): la rotación es solo de la principal y avanza solo
    // mientras siga abierta la MISMA sesión.
    if (!session.isUnlockedAs(VaultSlot.primary)) return;
    _ticket = session.ticket();
    _running = true;
    _stopRequested = false;
    _token = CloudCancelToken();
    try {
      while (!_halted) {
        final rec = await _store.load();
        if (_halted) throw const _Stop();
        if (rec == null || rec.phase.isBlocked) break;
        // Un aviso de una pausa anterior ("la subida no avanza"…) ya no
        // aplica en cuanto la rotación vuelve a avanzar (hallado en la prueba
        // real: el mensaje viejo seguía visible tras reanudar).
        _lastMessage = null;
        _emit(rec, running: true);
        if (!await _step(rec)) break;
      }
    } on _Stop {
      // pausa ya publicada
    } on CloudCancelledException {
      // pausa
    } on CloudException catch (e) {
      VaultLog.e('Rotación en pausa', e, 'rotation');
      _message(describeSyncError(e));
    } on StateError catch (e) {
      // Bóveda bloqueada a mitad: se retoma al desbloquear.
      VaultLog.e('Rotación interrumpida', e, 'rotation');
    } finally {
      _running = false;
      await _publish(keepMessage: true);
    }
  }

  Future<bool> _step(RotationRecord rec) async {
    switch (rec.effectivePhase) {
      case RotationPhase.prepared:
        _message('Confirma tu código nuevo para continuar.');
        return false;
      case RotationPhase.confirmed:
        return _confirmed(rec);
      case RotationPhase.freezing:
        return _freezing(rec);
      case RotationPhase.reencrypting:
        return _reencrypting(rec);
      case RotationPhase.uploading:
        return _uploading(rec);
      case RotationPhase.rekeyingDb:
        return _rekeying(rec);
      case RotationPhase.switchingLocal:
        return _switching(rec);
      case RotationPhase.uploadingSnapshot:
        return _uploadingSnapshot(rec);
      case RotationPhase.uploadingBackup:
        return _uploadingBackup(rec);
      case RotationPhase.deletingOldCloud:
        return _deletingOldCloud(rec);
      case RotationPhase.finalizingLocal:
        return _finalizing(rec);
      default:
        return false;
    }
  }

  // ------------------------------------------------------------ fases

  /// A4: precondiciones duras para congelar.
  Future<bool> _confirmed(RotationRecord rec) async {
    if (await migrationActive?.call() ?? false) {
      _message('Hay un cambio de cuenta en curso.');
      return false;
    }
    if (await auth.pendingBridgeBackup() == null) {
      // El puente se perdió (escritura perdida): hay que generar otro
      // código (todavía no se subió nada con B).
      await _setPhase(RotationPhase.prepared);
      _message('Genera y confirma otro código nuevo para continuar.');
      return false;
    }
    if (!await _accountOk(rec)) return false;
    if (!await _networkOk()) return false;
    if (!await _nothingPending()) {
      await sync.run(manual: true);
      if (!await _nothingPending()) {
        _message(
          'Hay archivos sin subir: espera a que terminen (o reintenta los '
          'que fallaron) para empezar.',
        );
        return false;
      }
    }
    _crash(RotationCrashPoint.confirmedChecked);
    await _setPhase(RotationPhase.freezing);
    return true;
  }

  Future<bool> _freezing(RotationRecord rec) async {
    if (!await _accountOk(rec) || !await _networkOk()) return false;
    // (b) Nada de snapshot en vuelo (el registro ya dice `freezing`: la
    // sincronización no empezará otro).
    if (!await _waitSyncIdle()) {
      _message('Esperando a que termine la sincronización…');
      return false;
    }
    // (c) Cardinalidad congelada + triggers (una transacción).
    final frozen = await repo.freeze(
      rotationId: rec.id,
      fromGen: rec.fromGen,
      toGen: rec.toGen,
      nowMs: _now(),
    );
    if (!frozen) {
      await _block(
        RotationPhase.blockedForeign,
        'La BD no es de esta rotación',
      );
      return false;
    }
    _crash(RotationCrashPoint.freezingStateCreated);
    var state = (await repo.load())!;

    // (d) Snapshot de la generación vieja PROPIO de la rotación (S-04).
    if (!await _remoteMatches(state.oldSnapshotDriveId, state.oldSnapshotMd5)) {
      final copy = await db.exportEncryptedSnapshot();
      try {
        if (copy.dbGen != rec.fromGen ||
            !copy.isCoherent ||
            (copy.maxKeyGen ?? rec.fromGen) != rec.fromGen) {
          await _block(
            RotationPhase.blockedCorrupt,
            'El índice no es coherente para congelar',
          );
          return false;
        }
        final bytes = await copy.file.readAsBytes();
        final up = await uploadBytesReplacingByName(
          cloud,
          name: CloudNames.dbSnapshotFor(rec.fromGen),
          bytes: bytes,
        );
        _crash(RotationCrashPoint.freezingSnapshotUploaded);
        await repo.setFingerprints(
          oldSnapshotDriveId: up.id,
          oldSnapshotMd5: up.md5Checksum?.toLowerCase(),
        );
        await prefs.markSnapshotDone(_now());
      } finally {
        if (await copy.file.exists()) await copy.file.delete();
      }
      _crash(RotationCrashPoint.freezingSnapshotRecorded);
      state = (await repo.load())!;
    }

    // (e) Respaldo puente (S-04): desde aquí B restaura el conjunto viejo.
    final bridge = await auth.pendingBridgeBackup();
    if (bridge != null) {
      final up = await uploadBytesReplacingByName(
        cloud,
        name: CloudNames.bridgeBackup(rec.fromGen),
        bytes: Uint8List.fromList(utf8.encode(bridge)),
      );
      await repo.setFingerprints(bridgeDriveId: up.id);
      _crash(RotationCrashPoint.freezingBridgeUploaded);
      await auth.bridgeBackupUploaded();
    } else if (state.bridgeDriveId == null) {
      await _setPhase(RotationPhase.prepared);
      _message('Genera y confirma otro código nuevo para continuar.');
      return false;
    }

    // (f) Lista exacta y huellas del conjunto viejo (A5).
    final listing = await cloud.list();
    final old = <RotationOldFile>[];
    CloudFile? oldBackup;
    for (final f in listing) {
      final kind = _oldKind(f.name, rec.fromGen);
      if (kind == null) continue;
      old.add(
        RotationOldFile(
          driveId: f.id,
          name: f.name,
          kind: kind,
          md5: f.md5Checksum?.toLowerCase(),
          itemId: CloudNames.parse(f.name)?.itemId,
        ),
      );
      if (kind == 'backup') oldBackup = f;
    }
    await repo.replaceOldFiles(old);
    if (oldBackup != null) {
      await repo.setFingerprints(
        oldBackupDriveId: oldBackup.id,
        oldBackupMd5: oldBackup.md5Checksum?.toLowerCase(),
      );
    }
    _crash(RotationCrashPoint.freezingOldFilesListed);

    _crash(RotationCrashPoint.beforeReencrypting);
    try {
      await auth.enterReencrypting();
    } on RotationInProgressException catch (e) {
      status.value = RotationStatus(
        phase: rec.phase,
        message: e.message,
        needsPin: true,
      );
      return false;
    }
    return true;
  }

  Future<bool> _reencrypting(RotationRecord rec) async {
    final ring = session.keyring;
    final from = ring?.forGenOrNull(rec.fromGen);
    final to = ring?.forGenOrNull(rec.toGen);
    if (ring == null || !ring.isDual || from == null || to == null) {
      status.value = RotationStatus(
        phase: rec.phase,
        message: 'Desbloquea con tu PIN para continuar el cambio de llave',
        needsPin: true,
      );
      return false;
    }
    await sweepLocalLeftovers(rec);
    final pending = await items.getItemsByKeyGen(rec.fromGen);
    pending.sort((a, b) {
      final la = _resolve(a.encryptedPath).existsSync() ? 0 : 1;
      final lb = _resolve(b.encryptedPath).existsSync() ? 0 : 1;
      return la != lb ? la - lb : a.fileSize.compareTo(b.fileSize);
    });
    final listed = await _listedOldFileItems();
    final missing = <RotationProblemItem>[];
    final damaged = <RotationProblemItem>[];
    var skipped = 0;
    var done = 0;
    for (final item in pending) {
      if (_halted) throw const _Stop();
      if (isInUse?.call(item.id) ?? false) {
        skipped++;
        continue;
      }
      final local = _resolve(item.encryptedPath).existsSync();
      if (!local &&
          await _pendingLocalBytes(rec.toGen) > maxPendingLocalBytes) {
        await sync.run(manual: true);
        if (await _pendingLocalBytes(rec.toGen) > maxPendingLocalBytes) {
          _message('Esperando a que se suban los archivos ya re-cifrados…');
          return false;
        }
      }
      final r = await reencryptor.reencrypt(
        item,
        fromGen: rec.fromGen,
        from: from,
        toGen: rec.toGen,
        to: to,
        cancel: _token,
        ticket: _ticket,
      );
      final problem = _problemOf(item, r, listed);
      if (problem == ReencryptOutcome.missing) {
        missing.add(RotationProblemItem(id: item.id, name: item.name));
      } else if (problem == ReencryptOutcome.corrupt) {
        damaged.add(RotationProblemItem(id: item.id, name: item.name));
      } else {
        done++;
        status.value = RotationStatus(
          phase: rec.phase,
          running: true,
          message: 'Re-cifrando…',
          itemsDone: done,
          itemsTotal: pending.length,
        );
        await refreshProgress();
      }
      _crash(RotationCrashPoint.itemDone);
    }
    final found = RotationProblems(missing: missing, damaged: damaged);
    if (!found.isEmpty) {
      problems.value = found;
      await _block(RotationPhase.blockedCorrupt, found.summary);
      return false;
    }
    problems.value = null;
    if (skipped > 0 || (await items.getItemsByKeyGen(rec.fromGen)).isNotEmpty) {
      _message('Cierra los archivos abiertos para terminar de re-cifrar.');
      return false;
    }
    await _setPhase(RotationPhase.uploading);
    return true;
  }

  /// "Omitir" en `blockedCorrupt` durante el re-cifrado (M6): los items que
  /// siguen sin poder re-cifrarse quedan perdidos (`error`, generación
  /// nueva, sin archivo) y su blob viejo en cuarentena (no se borra).
  Future<int> skipCorruptItems() => _resolveProblems(ReencryptOutcome.corrupt, (
    item,
    rec,
  ) async {
    await repo.quarantineItem(item.id);
    await repo.markItemLost(item.id, fromGen: rec.fromGen, toGen: rec.toGen);
  });

  /// "Continuar sin ellos" (D64): quita de la bóveda los items SIN NINGUNA
  /// copia. Antes de quitar cada uno se vuelve a intentar re-cifrarlo (si la
  /// copia apareció, se re-cifra y se queda). Lo que aún exista de él en
  /// Drive (su miniatura) se borra por lista tras el corte; lo local
  /// (miniatura, `.vault` que no abre) se borra aquí. Devuelve cuántos
  /// se quitaron.
  Future<int> dropMissingItems() =>
      _resolveProblems(ReencryptOutcome.missing, (item, rec) async {
        for (final rel in [item.encryptedPath, ?item.thumbPath]) {
          await _delete(_resolve(rel));
        }
        if (await repo.dropMissingItem(item.id, fromGen: rec.fromGen)) {
          _crash(RotationCrashPoint.missingDropped);
        }
      });

  /// Recalcula [problems] (p. ej. tras reiniciar la app en `blockedCorrupt`):
  /// vuelve a intentar los items pendientes; los que se re-cifran salen de
  /// la lista. Lanza [RotationException] si hace falta el PIN.
  Future<RotationProblems> loadProblems() async {
    final rec = await _store.load();
    if (!_blockedReencrypting(rec)) return const RotationProblems();
    final current = problems.value;
    if (current != null) return current;
    final (from, to) = _dualKeys(rec!);
    final listed = await _listedOldFileItems();
    final missing = <RotationProblemItem>[];
    final damaged = <RotationProblemItem>[];
    // D67: con la sesión cambiada a mitad, el re-cifrado no escribe nada.
    final ticket = session.isUnlockedAs(VaultSlot.primary)
        ? session.ticket()
        : null;
    for (final item in await items.getItemsByKeyGen(rec.fromGen)) {
      if (isInUse?.call(item.id) ?? false) continue;
      final r = await reencryptor.reencrypt(
        item,
        fromGen: rec.fromGen,
        from: from,
        toGen: rec.toGen,
        to: to,
        ticket: ticket,
      );
      final p = RotationProblemItem(id: item.id, name: item.name);
      switch (_problemOf(item, r, listed)) {
        case ReencryptOutcome.missing:
          missing.add(p);
        case ReencryptOutcome.corrupt:
          damaged.add(p);
        default:
          break;
      }
    }
    return problems.value = RotationProblems(
      missing: missing,
      damaged: damaged,
    );
  }

  static bool _blockedReencrypting(RotationRecord? rec) =>
      rec != null &&
      rec.phase == RotationPhase.blockedCorrupt &&
      rec.resumePhase == RotationPhase.reencrypting;

  (KeyHierarchy, KeyHierarchy) _dualKeys(RotationRecord rec) {
    final ring = session.keyring;
    final from = ring?.forGenOrNull(rec.fromGen);
    final to = ring?.forGenOrNull(rec.toGen);
    if (ring == null || !ring.isDual || from == null || to == null) {
      throw const RotationException(
        'Desbloquea con tu PIN para continuar el cambio de llave.',
      );
    }
    return (from, to);
  }

  /// Ids de items cuyo `.vault` de la generación vieja SÍ está en Drive
  /// (en la lista exacta del conjunto viejo).
  Future<Set<String>> _listedOldFileItems() async => {
    for (final o in await repo.oldFiles())
      if (o.kind == 'file' && o.itemId != null) o.itemId!,
  };

  /// Clasifica el resultado de un re-cifrado: `missing`, `corrupt` o `null`
  /// (sin problema). Un "sin copia" cuyo blob viejo SÍ está en la lista de
  /// Drive se trata como dañado (M6: el blob se conserva en cuarentena;
  /// nunca se quita algo que todavía exista).
  static ReencryptOutcome? _problemOf(
    VaultItemModel item,
    ReencryptResult r,
    Set<String> listed,
  ) => switch (r.outcome) {
    ReencryptOutcome.missing =>
      listed.contains(item.id)
          ? ReencryptOutcome.corrupt
          : ReencryptOutcome.missing,
    ReencryptOutcome.corrupt => ReencryptOutcome.corrupt,
    _ => null,
  };

  /// Aplica [act] a cada item que, RE-INTENTADO ahora, sigue en la categoría
  /// [kind]; los demás problemas se quedan. Al terminar vuelve a
  /// `reencrypting` (si queda otro problema, el re-cifrado vuelve a parar).
  Future<int> _resolveProblems(
    ReencryptOutcome kind,
    Future<void> Function(VaultItemModel item, RotationRecord rec) act,
  ) async {
    final rec = await _store.load();
    if (!_blockedReencrypting(rec)) {
      throw const RotationException('No hay archivos con problemas.');
    }
    final (from, to) = _dualKeys(rec!);
    final listed = await _listedOldFileItems();
    var n = 0;
    for (final item in await items.getItemsByKeyGen(rec.fromGen)) {
      if (isInUse?.call(item.id) ?? false) continue;
      final r = await reencryptor.reencrypt(
        item,
        fromGen: rec.fromGen,
        from: from,
        toGen: rec.toGen,
        to: to,
      );
      if (_problemOf(item, r, listed) != kind) continue;
      await act(item, rec);
      n++;
    }
    problems.value = null;
    await _store.save(
      (await _store.load())!.copyWith(
        phase: RotationPhase.reencrypting,
        resumePhase: null,
        lastError: null,
        updatedAt: _now(),
      ),
    );
    return n;
  }

  Future<bool> _uploading(RotationRecord rec) async {
    if ((await items.getItemsByKeyGen(rec.fromGen)).isNotEmpty) {
      await _setPhase(RotationPhase.reencrypting);
      return true;
    }
    if (!await _allUploaded(rec)) return false;
    _crash(RotationCrashPoint.uploadingVerified);
    await _setPhase(RotationPhase.rekeyingDb);
    return true;
  }

  Future<bool> _rekeying(RotationRecord rec) async {
    final ring = session.keyring;
    if (ring != null && ring.isDual) {
      sync.cancel();
      await _waitSyncIdle();
      try {
        await db.rekeyTo(
          fromGen: rec.fromGen,
          from: ring.forGen(rec.fromGen),
          toGen: rec.toGen,
          to: ring.forGen(rec.toGen),
        );
      } on VaultRekeyVerificationException catch (e) {
        await _block(RotationPhase.blockedCorrupt, 'BD: ${e.detail}');
        return false;
      }
    } else {
      // La envoltura del PIN ya cambió (corte tras `switchingLocal`): la BD
      // tiene que abrir ya con la llave nueva.
      await db.database;
      if (db.openedGen != rec.toGen) {
        await _block(RotationPhase.blockedCorrupt, 'Falta la llave anterior');
        return false;
      }
    }
    _crash(RotationCrashPoint.rekeyDone);
    await _setPhase(RotationPhase.switchingLocal);
    return true;
  }

  Future<bool> _switching(RotationRecord rec) async {
    await auth.switchPrimary();
    _crash(RotationCrashPoint.switchDone);
    await db.deleteRekeyLeftovers(rec.fromGen);
    await _setPhase(RotationPhase.uploadingSnapshot);
    return true;
  }

  Future<bool> _uploadingSnapshot(RotationRecord rec) async {
    if (!await _guardDb(rec)) return false;
    if ((await items.getItemsByKeyGen(rec.fromGen)).isNotEmpty) {
      await _block(
        RotationPhase.blockedCorrupt,
        'Quedan archivos sin re-cifrar tras cambiar la llave',
      );
      return false;
    }
    if (!await _allUploaded(rec)) return false;
    final takenAt = _now();
    final copy = await db.exportEncryptedSnapshot();
    try {
      if (copy.dbGen != rec.toGen ||
          !copy.isCoherent ||
          (copy.maxKeyGen ?? rec.toGen) != rec.toGen) {
        await _block(RotationPhase.blockedCorrupt, 'Índice no coherente');
        return false;
      }
      await uploadBytesReplacingByName(
        cloud,
        name: CloudNames.dbSnapshotFor(rec.toGen),
        bytes: await copy.file.readAsBytes(),
      );
      await prefs.markSnapshotDone(_now(), takenAtMs: takenAt);
    } finally {
      if (await copy.file.exists()) await copy.file.delete();
    }
    _crash(RotationCrashPoint.snapshotUploaded);
    await _setPhase(RotationPhase.uploadingBackup);
    return true;
  }

  Future<bool> _uploadingBackup(RotationRecord rec) async {
    if (!await _guardDb(rec)) return false;
    if (!await _oldSetIntact(rec)) return false;
    final json = await auth.exportRecoveryBackup();
    if (json == null) {
      await _block(RotationPhase.blockedCorrupt, 'Falta el respaldo nuevo');
      return false;
    }
    assertRecoveryBackupSafe(json);
    final bytes = Uint8List.fromList(utf8.encode(json));
    await uploadBytesReplacingByName(
      cloud,
      name: CloudNames.recoveryBackupFor(rec.toGen),
      bytes: bytes,
    );
    _crash(RotationCrashPoint.backupUploaded);
    await prefs.setRecoveryUploadedSha(crypto.sha256.convert(bytes).toString());
    // CORTE: desde aquí B restaura el conjunto nuevo y la sincronización
    // normal se descongela con los nombres de la generación nueva (M10).
    await _setPhase(RotationPhase.deletingOldCloud);
    VaultLog.d('Rotación: corte', category: 'rotation');
    _crash(RotationCrashPoint.afterCut);
    return true;
  }

  /// Tras el corte: borra el conjunto VIEJO de Drive POR LISTA (A5), en
  /// orden: respaldo viejo → puente → snapshot viejo → blobs. `files.delete`
  /// es permanente (con revisiones, S-04). Los de cuarentena (M6) no se
  /// borran: se renombran a `lost_*`. Antes de cada pasada, la guarda A5.
  Future<bool> _deletingOldCloud(RotationRecord rec) async {
    if (!await _accountOk(rec) || !await _networkOk()) return false;
    if (!await _oldSetIntact(rec)) return false;
    int rank(String kind) => switch (kind) {
      'backup' => 0,
      'bridge' => 1,
      'snapshot' => 2,
      _ => 3,
    };
    final old = await repo.oldFiles()
      ..sort((a, b) => rank(a.kind).compareTo(rank(b.kind)));
    var blobs = 0;
    for (final o in old) {
      if (_halted) throw const _Stop();
      if (o.quarantine && o.itemId != null) {
        try {
          await cloud.rename(
            o.driveId,
            CloudNames.quarantine(o.itemId!, rec.fromGen),
          );
        } on CloudNotFoundException {
          // ya no estaba
        }
      } else {
        try {
          await cloud.delete(o.driveId);
        } on CloudNotFoundException {
          // ya no estaba: objetivo cumplido
        }
      }
      await repo.removeOldFile(o.driveId);
      switch (o.kind) {
        case 'backup':
          _crash(RotationCrashPoint.oldBackupDeleted);
        case 'bridge':
          _crash(RotationCrashPoint.bridgeDeleted);
        case 'snapshot':
          _crash(RotationCrashPoint.oldSnapshotDeleted);
        default:
          if (blobs++ == 0) _crash(RotationCrashPoint.blobDeleted);
      }
    }
    await _setPhase(RotationPhase.finalizingLocal);
    VaultLog.d('Rotación: conjunto viejo borrado', category: 'rotation');
    return true;
  }

  /// Limpieza local: restos de la generación vieja, copia de la BD vieja,
  /// triggers y filas de la rotación y, AL FINAL, el registro.
  Future<bool> _finalizing(RotationRecord rec) async {
    for (final i in await items.getItemsByKeyGen(rec.toGen)) {
      final old = _resolve(AppPaths.vaultRelativePath(i.id, gen: rec.fromGen));
      if ((isInUse?.call(i.id) ?? false) && old.existsSync()) {
        _message('Cierra los archivos abiertos para terminar.');
        return false;
      }
    }
    await sweepLocalLeftovers(rec);
    await db.deleteRekeyLeftovers(rec.fromGen);
    _crash(RotationCrashPoint.finalizeSwept);
    await repo.clear();
    // El snapshot nuevo se tomó con las filas de la rotación: se publicará
    // uno limpio en la próxima sincronización.
    await prefs.markDirty(_now());
    _crash(RotationCrashPoint.finalizeBeforeRecord);
    final bio = await auth.finishRotation();
    status.value = RotationStatus(
      finished: true,
      offerBiometric: bio,
      message: 'Rotación terminada. Tu código anterior ya no abre nada.',
    );
    VaultLog.d('Rotación terminada', category: 'rotation');
    return false;
  }

  // ----------------------------------------------------------- guardas

  /// A3/C1: la BD es la de esta rotación y su cardinalidad cuadra.
  Future<bool> _guardDb(RotationRecord rec) async {
    final state = await repo.load();
    if (state == null || state.rotationId != rec.id) {
      await _block(
        RotationPhase.blockedForeign,
        'La BD no es de esta rotación',
      );
      return false;
    }
    final (n, f) = await repo.counts();
    if (n != state.expectedItems || f != state.expectedFolders) {
      await _block(
        RotationPhase.blockedCorrupt,
        'El índice no cuadra (faltan o sobran elementos)',
      );
      return false;
    }
    return true;
  }

  /// A5: el conjunto viejo sigue como se congeló (nadie más lo usa).
  Future<bool> _oldSetIntact(RotationRecord rec) async {
    final listing = await cloud.list();
    final old = {for (final o in await repo.oldFiles()) o.driveId: o};
    for (final f in listing) {
      final kind = _oldKind(f.name, rec.fromGen);
      if (kind == null) continue;
      final known = old[f.id];
      final changed =
          known == null ||
          ((kind == 'backup' || kind == 'snapshot') &&
              known.md5 != f.md5Checksum?.toLowerCase());
      if (changed) {
        await _block(
          RotationPhase.blockedCorrupt,
          'Otro dispositivo está usando esta bóveda en Drive',
        );
        return false;
      }
    }
    return true;
  }

  /// Tipo del archivo si pertenece al conjunto VIEJO ([fromGen]), o `null`.
  static String? _oldKind(String name, int fromGen) {
    final info = CloudNames.parse(name);
    if (info == null || info.gen != fromGen) return null;
    return switch (info.kind) {
      CloudNameKind.recoveryBackup => 'backup',
      CloudNameKind.bridgeBackup => 'bridge',
      CloudNameKind.dbSnapshot => 'snapshot',
      CloudNameKind.file => 'file',
      CloudNameKind.thumb => 'thumb',
      CloudNameKind.quarantine => null,
    };
  }

  /// M4: cada item de la generación nueva (no perdido) tiene su copia en
  /// Drive con el nombre `.kN` y el tamaño/MD5 registrados, y lo local
  /// coincide y abre con la llave nueva. Mientras tanto, sincroniza.
  Future<bool> _allUploaded(RotationRecord rec) async {
    var lastPending = -1;
    var stalled = 0;
    for (var round = 0; round < maxUploadRounds; round++) {
      if (_halted) throw const _Stop();
      final jobs = [
        for (final j in await queue.all())
          if (j.kind == SyncJobKind.file || j.kind == SyncJobKind.thumb) j,
      ];
      final waiting = jobs.where((j) => j.state != SyncJobState.error).length;
      if (jobs.isEmpty) {
        final missing = await _unverified(rec);
        if (missing == 0) return true;
        // Algo sin trabajo en la cola (p. ej. una fila cambió): reconcile.
      }
      if (jobs.isNotEmpty && waiting == 0) {
        _message('${jobs.length} archivo(s) no se pudieron subir. Reintenta.');
        return false;
      }
      await sync.run(manual: true);
      await refreshProgress();
      final phase = sync.summary.value.phase;
      if (phase == SyncPhase.offline ||
          phase == SyncPhase.waitingWifi ||
          phase == SyncPhase.needsSignIn) {
        _message(
          phase == SyncPhase.waitingWifi
              ? 'En pausa: esperando Wi-Fi.'
              : phase == SyncPhase.needsSignIn
              ? 'En pausa: inicia sesión de nuevo.'
              : 'En pausa: sin conexión.',
        );
        return false;
      }
      if (phase == SyncPhase.quotaFull) {
        await _block(RotationPhase.blockedQuota, 'Tu Google Drive está lleno');
        return false;
      }
      stalled = waiting == lastPending ? stalled + 1 : 0;
      lastPending = waiting;
      if (stalled >= 3) {
        _message('La subida no avanza. Reintenta en un momento.');
        return false;
      }
    }
    _message('La subida sigue en curso.');
    return false;
  }

  /// Cuántos items de la generación nueva aún no tienen su copia verificable.
  Future<int> _unverified(RotationRecord rec) async {
    final lost = await repo.quarantinedItemIds();
    final remote = {for (final f in await cloud.list()) f.id: f};
    var missing = 0;
    for (final i in await items.getItemsByKeyGen(rec.toGen)) {
      // Perdidos (M6) y, por la misma razón, cualquier fila sin ninguna copia
      // (nunca se podrá verificar; contarla atascaría la rotación).
      if (lost.contains(i.id) || _noCopyAnywhere(i)) continue;
      if (!await _verifiedItem(i, rec.toGen, remote)) missing++;
    }
    return missing;
  }

  Future<bool> _verifiedItem(
    VaultItemModel i,
    int gen,
    Map<String, CloudFile> remote,
  ) async {
    final f = i.driveFileId == null ? null : remote[i.driveFileId];
    if (f == null ||
        i.cloudMd5 == null ||
        f.name != CloudNames.file(i.id, gen: gen) ||
        f.size != i.cloudSize ||
        f.md5Checksum?.toLowerCase() != i.cloudMd5!.toLowerCase()) {
      return false;
    }
    if (i.thumbPath != null) {
      final t = i.thumbDriveFileId == null ? null : remote[i.thumbDriveFileId];
      if (t == null || t.name != CloudNames.thumb(i.id, gen: gen)) return false;
    }
    final local = _resolve(i.encryptedPath);
    if (local.existsSync()) {
      if (local.lengthSync() != i.cloudSize) return false;
      if (await md5OfFile(local) != i.cloudMd5!.toLowerCase()) return false;
      final k = session.filesKeyFor(gen, VaultSlot.primary); // D67
      if (k == null) return false;
      try {
        final reader = await _crypto.openReader(
          local,
          k,
          expectedFileId: i.fileId,
        );
        await reader.close();
      } on Object {
        return false;
      }
    }
    return true;
  }

  // ------------------------------------------------------------- ayudas

  /// Barre restos locales de un re-cifrado cortado (§5.7): `.part`, fuentes
  /// bajadas, archivos de la generación nueva de items aún viejos y los de
  /// la vieja de items ya nuevos (salvo en uso). Nunca hay claro en ellos.
  Future<void> sweepLocalLeftovers(RotationRecord rec) async {
    // Solo los `.part` del re-cifrado (`*.kN.vault.part`), no las descargas
    // del visor en curso (`*.vault.part` de otra generación).
    final partRe = RegExp('\\.k${rec.toGen}\\.(vault|thumb)\\.part\$');
    for (final dir in [AppPaths.vaultDir, AppPaths.thumbsDir]) {
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        if (partRe.hasMatch(f.path)) await _delete(f);
      }
    }
    final work = reencryptor.workDir();
    if (work.existsSync()) {
      for (final f in work.listSync().whereType<File>()) {
        await _delete(f);
      }
    }
    for (final i in await items.getItemsByKeyGen(rec.fromGen)) {
      await _delete(_resolve(AppPaths.vaultRelativePath(i.id, gen: rec.toGen)));
      await _delete(_resolve(AppPaths.thumbRelativePath(i.id, gen: rec.toGen)));
    }
    for (final i in await items.getItemsByKeyGen(rec.toGen)) {
      if (isInUse?.call(i.id) ?? false) continue;
      await _delete(
        _resolve(AppPaths.vaultRelativePath(i.id, gen: rec.fromGen)),
      );
      await _delete(
        _resolve(AppPaths.thumbRelativePath(i.id, gen: rec.fromGen)),
      );
    }
  }

  Future<int> _pendingLocalBytes(int gen) async {
    var n = 0;
    for (final i in await items.getItemsByKeyGen(gen)) {
      if (i.syncStatus != SyncStatus.pendiente &&
          i.syncStatus != SyncStatus.subiendo) {
        continue;
      }
      final f = _resolve(i.encryptedPath);
      if (f.existsSync()) n += f.lengthSync();
    }
    return n;
  }

  Future<bool> _remoteMatches(String? id, String? md5) async {
    if (id == null || md5 == null) return false;
    try {
      final f = await cloud.getMetadata(id);
      return f.md5Checksum?.toLowerCase() == md5;
    } on CloudNotFoundException {
      return false;
    }
  }

  Future<bool> _accountOk(RotationRecord rec) async {
    final email =
        cloud.currentAccountEmail ?? (await cloud.signInSilently())?.email;
    if (email == null) {
      _message('Inicia sesión con Google para continuar.');
      return false;
    }
    if (email != rec.accountEmail) {
      await _block(
        RotationPhase.blockedSignIn,
        'Inicia sesión con la cuenta de Google de siempre',
      );
      return false;
    }
    return true;
  }

  Future<bool> _networkOk() async {
    final net = await network.current();
    if (!net.isOnline) {
      _message('En pausa: sin conexión.');
      return false;
    }
    if (net == NetworkKind.mobile && await prefs.getWifiOnly()) {
      _message('En pausa: esperando Wi-Fi.');
      return false;
    }
    return true;
  }

  /// A4. Un item SIN NINGUNA copia (ni `.vault` local ni `driveFileId`) no
  /// cuenta como pendiente: nunca podrá subirse y esperar por él atascaría
  /// la rotación para siempre (p. ej. un perdido de una rotación anterior).
  /// Se decide sobre él al re-cifrar ("Continuar sin ellos", D64).
  Future<bool> _nothingPending() async {
    final noCopy = <String>{};
    for (final s in const [
      SyncStatus.pendiente,
      SyncStatus.subiendo,
      SyncStatus.error,
    ]) {
      for (final i in await items.getItemsBySyncStatus(s)) {
        if (!_noCopyAnywhere(i)) return false;
        noCopy.add(i.id);
      }
    }
    for (final j in await queue.all()) {
      if ((j.kind == SyncJobKind.file || j.kind == SyncJobKind.thumb) &&
          !noCopy.contains(j.itemId)) {
        return false;
      }
    }
    return true;
  }

  bool _noCopyAnywhere(VaultItemModel i) =>
      i.driveFileId == null && !_resolve(i.encryptedPath).existsSync();

  Future<bool> _waitSyncIdle() async {
    final deadline = _now() + syncIdleTimeout.inMilliseconds;
    while (sync.isRunning || sync.snapshotFlushInFlight) {
      if (_now() > deadline) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return true;
  }

  Future<void> _setPhase(RotationPhase phase) async {
    final cur = await _store.load();
    if (cur == null) return;
    _requireSameSession();
    await _store.save(cur.copyWith(phase: phase, updatedAt: _now()));
  }

  /// D67 (A1-6): dentro del bucle, si la sesión cambió (bloqueo, otra
  /// bóveda) no se escribe ninguna fase ni ningún bloqueo: se para.
  void _requireSameSession() {
    if (_running && !(_ticket?.isValid ?? false)) throw const _Stop();
  }

  Future<void> _block(RotationPhase phase, String why) async {
    final cur = await _store.load();
    if (cur == null) return;
    _requireSameSession();
    await _store.save(
      cur.copyWith(
        phase: phase,
        resumePhase: cur.effectivePhase,
        lastError: why,
        updatedAt: _now(),
      ),
    );
    _message(why);
  }

  File _resolve(String rel) => AppPaths.resolve(rel);

  static Future<void> _delete(File f) async {
    try {
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      // se reintenta en la próxima reanudación
    }
  }

  String? _lastMessage;

  void _message(String m) {
    _lastMessage = m;
    final s = status.value;
    status.value = RotationStatus(
      phase: s.phase,
      running: s.running,
      message: m,
      needsPin: s.needsPin,
      itemsDone: s.itemsDone,
      itemsTotal: s.itemsTotal,
    );
  }

  void _emit(RotationRecord rec, {required bool running}) {
    status.value = RotationStatus(
      phase: rec.phase,
      running: running,
      message: rec.lastError ?? _lastMessage,
    );
    unawaited(refreshProgress());
  }

  Future<void> _publish({bool keepMessage = false}) async {
    final rec = await _store.load();
    if (rec == null) {
      problems.value = null;
      progress.value = null;
      // Recién terminada: se conserva "Rotación terminada" para la UI.
      if (!status.value.finished) status.value = const RotationStatus();
      return;
    }
    status.value = RotationStatus(
      phase: rec.phase,
      message: rec.lastError ?? (keepMessage ? status.value.message : null),
      needsPin: status.value.needsPin,
    );
    await refreshProgress();
  }
}
