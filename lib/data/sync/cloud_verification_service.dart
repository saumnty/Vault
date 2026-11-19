import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/logging/vault_log.dart';
import '../../core/session/session_ticket.dart';
import '../cloud/cloud_storage.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import 'cloud_account_tag.dart';
import 'network_monitor.dart';
import 'sync_preferences.dart';
import 'sync_service.dart';

/// Resultado global de «Verificar copia en la nube».
enum CloudVerificationOutcome {
  /// Terminó: los conteos dicen qué se encontró.
  done,

  /// Sin sesión de Google: no se comprobó nada.
  noSession,

  /// Bóveda bloqueada (o no es la principal): no se comprobó nada.
  locked,

  /// Hay un cambio de llave maestra registrado (D61).
  rotationActive,

  /// Hay un cambio de cuenta de Google sin terminar.
  migrationActive,

  /// Sin conexión.
  offline,

  /// «Solo Wi-Fi» activo y con datos móviles.
  waitingWifi,

  /// Ya hay una verificación (o una sincronización que no termina) en curso.
  busy,

  /// La cuenta tiene el respaldo de recuperación de OTRA bóveda: no se toca
  /// nada (como `blockedOtherVault` de la migración).
  blockedOtherVault,

  /// La sesión cambió de cuenta a mitad: el resultado no vale.
  accountChanged,

  /// Error de la nube (red, 5xx...): se reintenta más tarde.
  failed,
}

/// Lo que vio y decidió una verificación. Solo conteos: sin nombres, ids ni
/// correos ([accountEmail] es solo para la pantalla; nunca se registra).
@immutable
class CloudVerificationResult {
  const CloudVerificationResult(
    this.outcome, {
    this.checked = 0,
    this.repaired = 0,
    this.reupload = 0,
    this.thumbsReupload = 0,
    this.noCopy = 0,
    this.backupQueued = false,
    this.snapshotQueued = false,
    this.accountEmail,
    this.finishedAt,
  });

  final CloudVerificationOutcome outcome;

  /// `.vault` comprobados en la cuenta actual (incluye [repaired]).
  final int checked;

  /// Adoptados por nombre (mismo tamaño y MD5, id distinto).
  final int repaired;

  /// `.vault` que faltaban y están en el teléfono: vuelven a subirse.
  final int reupload;

  /// Miniaturas que vuelven a subirse o se regeneran.
  final int thumbsReupload;

  /// Archivos sin copia en ninguna parte (ni en la cuenta ni en el teléfono).
  /// La fila NO se borra.
  final int noCopy;

  /// El respaldo de recuperación faltaba: se sube.
  final bool backupQueued;

  /// El índice (snapshot) faltaba o era de otra cuenta: se sube al final.
  final bool snapshotQueued;

  /// Correo de la cuenta comprobada: SOLO para mostrarlo en pantalla.
  final String? accountEmail;
  final int? finishedAt;

  /// Texto para la pantalla (en español, sin correos).
  String get summary => switch (outcome) {
    CloudVerificationOutcome.done =>
      [
        'Comprobados $checked',
        if (reupload > 0) '$reupload vuelven a subirse',
        if (noCopy > 0) '$noCopy sin copia en ninguna parte',
        if (thumbsReupload > 0) '$thumbsReupload miniaturas se rehacen',
        if (backupQueued) 'se sube el respaldo de tus llaves',
        if (snapshotQueued) 'se sube el índice',
      ].join(' · '),
    CloudVerificationOutcome.noSession =>
      'Sin cuenta de Google: inicia sesión para comprobar tu copia.',
    CloudVerificationOutcome.locked => 'La bóveda está bloqueada.',
    CloudVerificationOutcome.rotationActive =>
      'Hay un cambio de llave maestra en curso. Espera a que termine.',
    CloudVerificationOutcome.migrationActive =>
      'Hay un cambio de cuenta sin terminar. Termínalo o cancélalo primero.',
    CloudVerificationOutcome.offline => 'Sin conexión. Se comprobará después.',
    CloudVerificationOutcome.waitingWifi =>
      'Esperando Wi-Fi («Solo Wi-Fi» está activo).',
    CloudVerificationOutcome.busy =>
      'Ya hay una comprobación o una sincronización en curso. Reintenta en '
          'un momento.',
    CloudVerificationOutcome.blockedOtherVault =>
      'Esta cuenta ya guarda el respaldo de OTRA bóveda. No se subió ni se '
          'cambió nada. Usa otra cuenta de Google.',
    CloudVerificationOutcome.accountChanged =>
      'La cuenta de Google cambió durante la comprobación. Vuelve a '
          'intentarlo.',
    CloudVerificationOutcome.failed =>
      'No se pudo comprobar ahora (error de la nube). Se reintentará.',
  };

  /// Línea de diagnóstico: solo números.
  String get logLine =>
      'Verificación: ${outcome.name}; comprobados=$checked, '
      'reparados=$repaired, resubir=$reupload, miniaturas=$thumbsReupload, '
      'sinCopia=$noCopy, respaldo=${backupQueued ? 1 : 0}, '
      'indice=${snapshotQueued ? 1 : 0}';
}

/// Progreso para la UI (`null` = no hay verificación en curso).
@immutable
class CloudVerificationProgress {
  const CloudVerificationProgress(this.done, this.total);
  final int done;
  final int total;
}

/// «Verificar copia en la nube» (D75, `docs/DISENO_MIGRACION_ATASCADA.md`
/// §B.2): comprueba en la cuenta ACTUAL, con un solo `list()`, que existen
/// (con su tamaño y MD5) el respaldo de recuperación, el índice y cada
/// `.vault`/`.thumb` que la BD da por subido, y fija su tag de cuenta.
///
/// **Nunca borra, renombra ni mueve nada** (ni en Drive ni en el teléfono):
/// solo lee la nube y escribe filas de la BD de forma condicional (misma
/// generación, ruta e id remoto que al leerlas). Lo que falta y está en el
/// teléfono pasa a `pendiente` (sin referencias) y lo re-sube la
/// sincronización normal con su verificación habitual; lo que falta en
/// todas partes queda en `error` (la fila no se borra).
///
/// No corre con la bóveda bloqueada o la adicional abierta ([sessionTicket]),
/// con una rotación registrada ni con un cambio de cuenta sin terminar.
/// Mientras dura, la sincronización normal espera
/// (`SyncService.pausedForVerification`) y al terminar se relanza.
class CloudVerificationService {
  CloudVerificationService({
    required this.cloud,
    required this.items,
    required this.sync,
    required this.prefs,
    required this.network,
    required this.tagger,
    required Future<Database> Function() dbProvider,
    required this.resolvePath,
    required this.recoveryBackupProvider,
    this.sessionTicket,
    this.rotationActive,
    this.migrationActive,
    int Function()? nowMs,
    this.batchSize = 50,
    this.syncWait = const Duration(seconds: 30),
  }) : _db = dbProvider,
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CloudStorage cloud;
  final VaultDataRepository items;
  final SyncService sync;
  final SyncPreferences prefs;
  final NetworkMonitor network;
  final CloudAccountTagger tagger;
  final Future<Database> Function() _db;
  final File Function(String relativePath) resolvePath;
  final Future<String?> Function() recoveryBackupProvider;

  /// Ticket de la sesión PRINCIPAL abierta, o `null` (bloqueada o con la
  /// adicional abierta). `null` como proveedor (pruebas) = sin esta guarda.
  final SessionTicket? Function()? sessionTicket;
  final Future<bool> Function()? rotationActive;
  final Future<bool> Function()? migrationActive;
  final int Function() _now;
  final int batchSize;

  /// Cuánto se espera a que termine una sincronización en curso.
  final Duration syncWait;

  /// Progreso de la verificación en curso (`null` = ninguna).
  final ValueNotifier<CloudVerificationProgress?> progress = ValueNotifier(
    null,
  );

  /// Último resultado (en memoria; el diagnóstico persistente es la parte B).
  final ValueNotifier<CloudVerificationResult?> last = ValueNotifier(null);

  bool _running = false;
  bool get isRunning => _running;

  static const List<String> _inCloud = ['en_nube', 'en_cache', 'sin_conexion'];

  /// Cuántos items «en la nube» NO están comprobados en la cuenta [tag]
  /// (`.vault` o `.thumb` con tag nulo o distinto). Sin sesión, todos los que
  /// tienen referencias.
  Future<int> unverifiedCount({String? tag}) async {
    final db = await _db();
    final t = tag ?? await tagger.current();
    final marks = List.filled(_inCloud.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM vault_items WHERE '
      '(driveFileId IS NOT NULL AND syncStatus IN ($marks) AND '
      '(cloudAccountTag IS NULL OR cloudAccountTag != ?)) OR '
      '(thumbDriveFileId IS NOT NULL AND '
      '(thumbAccountTag IS NULL OR thumbAccountTag != ?))',
      [..._inCloud, t ?? '', t ?? ''],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// `true` si hay sesión y algún item «en la nube» sin comprobar en la
  /// cuenta actual (tras actualizar a v11, todos: la primera apertura con
  /// sesión verifica todo).
  Future<bool> needsVerification() async {
    final tag = await tagger.current();
    if (tag == null) return false;
    return await unverifiedCount(tag: tag) > 0;
  }

  /// Ejecuta la verificación. Pone la pausa de la sincronización de forma
  /// SÍNCRONA antes del primer `await` (así un `sync.run()` lanzado justo
  /// después no corre con referencias sin comprobar) y siempre la quita.
  Future<CloudVerificationResult> verify() async {
    if (_running) {
      return const CloudVerificationResult(CloudVerificationOutcome.busy);
    }
    _running = true;
    sync.pausedForVerification = true;
    var relaunchSync = true;
    CloudVerificationResult result;
    try {
      result = await _verify();
    } on StateError {
      // Bóveda bloqueada a mitad (BD cerrada): lo escrito es coherente.
      relaunchSync = false;
      result = const CloudVerificationResult(CloudVerificationOutcome.locked);
    } on CloudException catch (e) {
      VaultLog.e('Verificación con error de la nube', e, 'sync');
      result = const CloudVerificationResult(CloudVerificationOutcome.failed);
    } finally {
      sync.pausedForVerification = false;
      _running = false;
      progress.value = null;
    }
    if (result.outcome == CloudVerificationOutcome.locked) {
      relaunchSync = false;
    }
    last.value = result;
    VaultLog.d(result.logLine, category: 'sync');
    if (relaunchSync) unawaited(sync.run(manual: true));
    return result;
  }

  Future<CloudVerificationResult> _verify() async {
    final provider = sessionTicket;
    final SessionTicket? ticket = provider?.call();
    if (provider != null && ticket == null) {
      return const CloudVerificationResult(CloudVerificationOutcome.locked);
    }
    bool stale() => ticket != null && !ticket.isValid;
    if (await rotationActive?.call() ?? false) {
      return const CloudVerificationResult(
        CloudVerificationOutcome.rotationActive,
      );
    }
    if (await migrationActive?.call() ?? false) {
      return const CloudVerificationResult(
        CloudVerificationOutcome.migrationActive,
      );
    }
    if (cloud.currentAccountEmail == null) await cloud.signInSilently();
    final email = cloud.currentAccountEmail;
    final tag = await tagger.current();
    if (email == null || tag == null) {
      return const CloudVerificationResult(CloudVerificationOutcome.noSession);
    }
    final net = await network.current();
    if (!net.isOnline) {
      return CloudVerificationResult(
        CloudVerificationOutcome.offline,
        accountEmail: email,
      );
    }
    if (net == NetworkKind.mobile && await prefs.getWifiOnly()) {
      return CloudVerificationResult(
        CloudVerificationOutcome.waitingWifi,
        accountEmail: email,
      );
    }
    // La sincronización normal ya no puede empezar (pausa); se espera a que
    // termine la que esté en marcha.
    final deadline = _now() + syncWait.inMilliseconds;
    while (sync.isRunning) {
      if (_now() >= deadline) {
        return CloudVerificationResult(
          CloudVerificationOutcome.busy,
          accountEmail: email,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (stale()) throw StateError('La bóveda está bloqueada');

    // ---- 1. Un solo listado (solo lee).
    final listing = await cloud.list();
    if (stale()) throw StateError('La bóveda está bloqueada');
    final byId = <String, CloudFile>{for (final f in listing) f.id: f};
    final byName = <String, List<CloudFile>>{};
    for (final f in listing) {
      (byName[f.name] ??= []).add(f);
    }

    // ---- 2. Respaldo de recuperación.
    final gen = await sync.currentKeyGen();
    var backupQueued = false;
    final backup = await recoveryBackupProvider();
    if (backup != null) {
      final bytes = utf8.encode(backup);
      final localMd5 = md5OfBytes(bytes);
      final same = byName[CloudNames.recoveryBackupFor(gen)] ?? const [];
      if (same.isEmpty) {
        // Falta: se vuelve a subir (la sincronización lo encola).
        await prefs.setRecoveryUploadedSha('');
        backupQueued = true;
      } else if (same.any((f) => f.md5Checksum?.toLowerCase() == localMd5)) {
        await prefs.setRecoveryUploadedSha(
          crypto.sha256.convert(bytes).toString(),
        );
        await prefs.setRecoveryUploadedTag(tag);
        if (sync.recoveryBackupBlockedTag == tag) {
          sync.recoveryBackupBlockedTag = null;
        }
      } else {
        // OTRA bóveda con el mismo nombre: no se toca nada (ni filas).
        sync.recoveryBackupBlockedTag = tag;
        VaultLog.d('Verificación: respaldo de otra bóveda', category: 'sync');
        return CloudVerificationResult(
          CloudVerificationOutcome.blockedOtherVault,
          accountEmail: email,
        );
      }
    }

    // ---- 3. Cada item (Papelera incluida).
    final all = await items.getAllItems();
    final ops = <_Op>[];
    var checked = 0, repaired = 0, reupload = 0, thumbs = 0, noCopy = 0;
    for (final i in all) {
      final file = _checkFile(i, byId, byName, tag);
      if (file != null) {
        ops.add(file);
        if (file.kind == _OpKind.tagFile) checked++;
        if (file.kind == _OpKind.adoptFile) {
          checked++;
          repaired++;
        }
        if (file.kind == _OpKind.resetFile) reupload++;
        if (file.kind == _OpKind.noCopy) noCopy++;
      } else if (i.driveFileId != null &&
          _inCloud.contains(i.syncStatus.dbValue)) {
        checked++; // ya comprobado en esta cuenta
      }
      final thumb = await _checkThumb(i, byId, byName, tag);
      if (thumb != null) {
        ops.add(thumb);
        if (thumb.kind == _OpKind.resetThumb ||
            thumb.kind == _OpKind.dropThumb) {
          thumbs++;
        }
      }
    }
    if (stale()) throw StateError('La bóveda está bloqueada');

    // ---- 4. Escrituras condicionales en lotes con transacción.
    var changed = false;
    for (var start = 0; start < ops.length; start += batchSize) {
      if (stale()) throw StateError('La bóveda está bloqueada');
      if (await tagger.current() != tag) {
        return CloudVerificationResult(
          CloudVerificationOutcome.accountChanged,
          accountEmail: email,
        );
      }
      final end = (start + batchSize).clamp(0, ops.length);
      final db = await _db();
      final n = await db.transaction((txn) async {
        var applied = 0;
        for (final op in ops.sublist(start, end)) {
          applied += await op.apply(txn);
        }
        return applied;
      });
      if (n > 0) changed = true;
      progress.value = CloudVerificationProgress(end, ops.length);
    }

    // ---- 5. Índice: falta, es de otra cuenta o la BD cambió -> «sucio»; la
    // sincronización lo sube al FINAL (cuando las referencias ya son
    // correctas).
    final snap = byName[CloudNames.dbSnapshotFor(gen)] ?? const [];
    final snapshotQueued =
        snap.isEmpty || await prefs.getSnapshotUploadedTag() != tag;
    if (snapshotQueued || changed) await prefs.markDirty(_now());

    // ---- 6. La cuenta no cambió durante todo el proceso.
    if (await tagger.current() != tag) {
      return CloudVerificationResult(
        CloudVerificationOutcome.accountChanged,
        accountEmail: email,
      );
    }
    return CloudVerificationResult(
      CloudVerificationOutcome.done,
      checked: checked,
      repaired: repaired,
      reupload: reupload,
      thumbsReupload: thumbs,
      noCopy: noCopy,
      backupQueued: backupQueued,
      snapshotQueued: snapshotQueued,
      accountEmail: email,
      finishedAt: _now(),
    );
  }

  /// Decide qué hacer con el `.vault` de [i] (`null` = no se da por subido).
  _Op? _checkFile(
    VaultItemModel i,
    Map<String, CloudFile> byId,
    Map<String, List<CloudFile>> byName,
    String tag,
  ) {
    final driveId = i.driveFileId;
    if (driveId == null || !_inCloud.contains(i.syncStatus.dbValue)) {
      return null;
    }
    final md5 = i.cloudMd5?.toLowerCase();
    final size = i.cloudSize;
    bool matches(CloudFile f) =>
        md5 != null &&
        size != null &&
        f.size == size &&
        f.md5Checksum?.toLowerCase() == md5;
    final base = _Op(i, driveId: driveId);
    final byIdFile = byId[driveId];
    if (byIdFile != null && matches(byIdFile)) {
      return i.cloudAccountTag == tag
          ? null
          : base.copy(_OpKind.tagFile, tag: tag);
    }
    // Reparable: mismo nombre esperado, tamaño y MD5 (el MD5 de la fila se
    // comprobó contra la copia local al subir). Con duplicados, el primero
    // que coincide; los demás no se tocan.
    final name = CloudNames.file(i.id, gen: i.keyGen);
    for (final f in byName[name] ?? const <CloudFile>[]) {
      if (matches(f)) {
        return base.copy(_OpKind.adoptFile, tag: tag, newDriveId: f.id);
      }
    }
    if (resolvePath(i.encryptedPath).existsSync()) {
      return base.copy(_OpKind.resetFile);
    }
    return base.copy(_OpKind.noCopy);
  }

  /// Decide qué hacer con la miniatura de [i] (`null` = nada).
  Future<_Op?> _checkThumb(
    VaultItemModel i,
    Map<String, CloudFile> byId,
    Map<String, List<CloudFile>> byName,
    String tag,
  ) async {
    final driveId = i.thumbDriveFileId;
    final thumbPath = i.thumbPath;
    if (driveId == null || thumbPath == null) return null;
    final local = resolvePath(thumbPath);
    final hasLocal = local.existsSync();
    final localMd5 = hasLocal ? await md5OfFile(local) : null;
    final base = _Op(i, thumbDriveId: driveId);
    final f = byId[driveId];
    if (f != null &&
        (localMd5 == null || f.md5Checksum?.toLowerCase() == localMd5)) {
      return i.thumbAccountTag == tag
          ? null
          : base.copy(_OpKind.tagThumb, tag: tag);
    }
    if (localMd5 != null) {
      final name = CloudNames.thumb(i.id, gen: i.keyGen);
      for (final c in byName[name] ?? const <CloudFile>[]) {
        if (c.md5Checksum?.toLowerCase() == localMd5) {
          return base.copy(_OpKind.adoptThumb, tag: tag, newDriveId: c.id);
        }
      }
      return base.copy(_OpKind.resetThumb);
    }
    // Sin copia local ni remota: la regeneración la rehace desde el `.vault`.
    return base.copy(_OpKind.dropThumb);
  }
}

enum _OpKind {
  tagFile,
  adoptFile,
  resetFile,
  noCopy,
  tagThumb,
  adoptThumb,
  resetThumb,
  dropThumb,
}

/// Escritura condicional de la verificación: solo si la fila sigue igual que
/// al leerla (generación, ruta y el id remoto que se comprobó).
class _Op {
  _Op(
    this.item, {
    this.kind = _OpKind.tagFile,
    this.driveId,
    this.thumbDriveId,
    this.tag,
    this.newDriveId,
  });

  final VaultItemModel item;
  final _OpKind kind;
  final String? driveId;
  final String? thumbDriveId;
  final String? tag;
  final String? newDriveId;

  _Op copy(_OpKind kind, {String? tag, String? newDriveId}) => _Op(
    item,
    kind: kind,
    driveId: driveId,
    thumbDriveId: thumbDriveId,
    tag: tag,
    newDriveId: newDriveId,
  );

  Future<int> apply(Transaction txn) {
    const fileWhere =
        'id = ? AND keyGen = ? AND encryptedPath = ? AND driveFileId = ?';
    const thumbWhere =
        'id = ? AND keyGen = ? AND thumbPath = ? AND thumbDriveFileId = ?';
    final fileArgs = [item.id, item.keyGen, item.encryptedPath, driveId];
    final thumbArgs = [item.id, item.keyGen, item.thumbPath, thumbDriveId];
    Future<int> upd(Map<String, Object?> v, String where, List<Object?> a) =>
        txn.update('vault_items', v, where: where, whereArgs: a);
    return switch (kind) {
      _OpKind.tagFile => upd({'cloudAccountTag': tag}, fileWhere, fileArgs),
      _OpKind.adoptFile => upd(
        {'driveFileId': newDriveId, 'cloudAccountTag': tag},
        fileWhere,
        fileArgs,
      ),
      // Falta en la cuenta y está en el teléfono: se sube de nuevo con la
      // verificación habitual (tamaño + MD5).
      _OpKind.resetFile => upd(
        {
          'syncStatus': SyncStatus.pendiente.dbValue,
          'driveFileId': null,
          'cloudMd5': null,
          'cloudSize': null,
          'cloudAccountTag': null,
        },
        fileWhere,
        fileArgs,
      ),
      // Sin copia en ninguna parte: error visible; la fila (y sus
      // referencias, por si la copia reaparece) se conservan.
      _OpKind.noCopy => upd(
        {'syncStatus': SyncStatus.error.dbValue, 'cloudAccountTag': null},
        fileWhere,
        fileArgs,
      ),
      _OpKind.tagThumb => upd({'thumbAccountTag': tag}, thumbWhere, thumbArgs),
      _OpKind.adoptThumb => upd(
        {'thumbDriveFileId': newDriveId, 'thumbAccountTag': tag},
        thumbWhere,
        thumbArgs,
      ),
      // La recoge `getItemsNeedingThumbUpload` (thumbDriveFileId NULL).
      _OpKind.resetThumb => upd(
        {'thumbDriveFileId': null, 'thumbAccountTag': null},
        thumbWhere,
        thumbArgs,
      ),
      // No hay archivo local que borrar: solo se olvida la referencia para
      // que la regeneración (thumbPath NULL) la rehaga.
      _OpKind.dropThumb => upd(
        {'thumbPath': null, 'thumbDriveFileId': null, 'thumbAccountTag': null},
        thumbWhere,
        thumbArgs,
      ),
    };
  }
}
