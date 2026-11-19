import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/key_recovery_service.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../cloud/cloud_storage.dart';
import '../repositories/vault_database.dart';
import '../sync/sync_preferences.dart';
import '../sync/sync_service.dart'
    show CloudNameInfo, CloudNameKind, CloudNames, md5OfFile;

/// Qué se encontró en la cuenta de Google al buscar un respaldo.
enum RestoreProbeResult {
  /// Hay respaldo de llaves y snapshot de la BD: se puede restaurar.
  found,

  /// Ni respaldo de llaves ni nada que restaurar en esta cuenta.
  noBackup,

  /// Hay llaves pero falta el índice de los archivos (nunca se subió el
  /// snapshot de la BD): no hay nada que mostrar.
  incomplete,

  /// El respaldo de llaves existe pero no es un respaldo válido de Vault.
  invalid,
}

/// D78 (parte B, §B.6): lo que hay en la cuenta de Google, calculado del
/// mismo `list()` del [RestoreService.probe]. SOLO conteos y tamaños: sin
/// nombres, ids ni correos.
@immutable
class CloudInventory {
  const CloudInventory({
    this.backups = 0,
    this.backupGens = const {},
    this.bridges = 0,
    this.snapshots = 0,
    this.snapshotGens = const {},
    this.snapshotBytes = 0,
    this.files = 0,
    this.fileBytes = 0,
    this.thumbs = 0,
    this.thumbBytes = 0,
    this.quarantine = 0,
    this.others = 0,
  });

  /// Respaldos de llaves (`recovery_backup[.kN].json`) y sus generaciones.
  final int backups;
  final Set<int> backupGens;

  /// Puentes de una rotación.
  final int bridges;

  /// Índices (snapshots de la BD), sus generaciones y bytes.
  final int snapshots;
  final Set<int> snapshotGens;
  final int snapshotBytes;
  final int files;
  final int fileBytes;
  final int thumbs;
  final int thumbBytes;

  /// Archivos en cuarentena (`lost_*`).
  final int quarantine;

  /// Archivos que no son de Kern/Vault.
  final int others;

  bool get isEmpty =>
      backups == 0 &&
      bridges == 0 &&
      snapshots == 0 &&
      files == 0 &&
      thumbs == 0 &&
      quarantine == 0;

  static CloudInventory of(Iterable<CloudFile> all) {
    var backups = 0, bridges = 0, snapshots = 0, snapBytes = 0;
    var files = 0, fileBytes = 0, thumbs = 0, thumbBytes = 0;
    var quarantine = 0, others = 0;
    final backupGens = <int>{};
    final snapGens = <int>{};
    for (final f in all) {
      final info = CloudNames.parse(f.name);
      switch (info?.kind) {
        case null:
          others++;
        case CloudNameKind.recoveryBackup:
          backups++;
          backupGens.add(info!.gen);
        case CloudNameKind.bridgeBackup:
          bridges++;
        case CloudNameKind.dbSnapshot:
          snapshots++;
          snapGens.add(info!.gen);
          snapBytes += f.size;
        case CloudNameKind.file:
          files++;
          fileBytes += f.size;
        case CloudNameKind.thumb:
          thumbs++;
          thumbBytes += f.size;
        case CloudNameKind.quarantine:
          quarantine++;
      }
    }
    return CloudInventory(
      backups: backups,
      backupGens: backupGens,
      bridges: bridges,
      snapshots: snapshots,
      snapshotGens: snapGens,
      snapshotBytes: snapBytes,
      files: files,
      fileBytes: fileBytes,
      thumbs: thumbs,
      thumbBytes: thumbBytes,
      quarantine: quarantine,
      others: others,
    );
  }

  /// Línea de diagnóstico: solo números.
  String get logLine =>
      'respaldos=$backups, puentes=$bridges, índices=$snapshots, '
      'archivos=$files, miniaturas=$thumbs, cuarentena=$quarantine, '
      'otros=$others';
}

/// Tamaño legible sin depender de la UI (KB/MB con una cifra).
String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _cifrados(int n) =>
    n == 1 ? '1 archivo cifrado' : '$n archivos cifrados';

/// D78 (§B.6): título y mensaje de «no se puede restaurar» que dicen QUÉ se
/// encontró (en vez del genérico «No hay respaldo»). Sin datos personales.
(String, String) describeRestoreProbe(
  RestoreProbeResult result,
  CloudInventory? inv,
) {
  const elsewhere =
      'Si tu bóveda sigue en otro teléfono, ábrela allí: se completará sola '
      'al comprobar la copia en la nube.';
  switch (result) {
    case RestoreProbeResult.found:
      return ('Respaldo encontrado', 'Esta cuenta tiene un respaldo completo.');
    case RestoreProbeResult.incomplete:
      final files = inv == null || inv.files == 0
          ? ''
          : ' Hay ${_cifrados(inv.files)}.';
      return (
        'El respaldo está incompleto',
        'Esta cuenta tiene el respaldo de tus llaves pero no el índice de tus '
            'archivos, así que no hay nada que mostrar todavía.$files '
            '$elsewhere',
      );
    case RestoreProbeResult.invalid:
      final n = inv?.backups ?? 0;
      return (
        'El respaldo no es válido',
        'Encontramos ${n <= 1 ? 'un respaldo de llaves' : '$n respaldos de llaves'} '
            'en esta cuenta, pero no se puede leer.',
      );
    case RestoreProbeResult.noBackup:
      if (inv == null || inv.isEmpty) {
        return (
          'No hay respaldo en esta cuenta de Google',
          'Esta cuenta no tiene ningún dato de Kern. Prueba con otra cuenta o '
              'crea una bóveda nueva.',
        );
      }
      final parts = <String>[
        if (inv.snapshots == 1)
          'una copia de la base de datos (${_size(inv.snapshotBytes)})'
        else if (inv.snapshots > 1)
          '${inv.snapshots} copias de la base de datos '
              '(${_size(inv.snapshotBytes)})',
        if (inv.files > 0) _cifrados(inv.files),
        if (inv.thumbs > 0)
          inv.thumbs == 1 ? '1 miniatura' : '${inv.thumbs} miniaturas',
      ];
      final found = parts.isEmpty
          ? 'algunos restos'
          : parts.length == 1
          ? parts.first
          : '${parts.sublist(0, parts.length - 1).join(', ')} y ${parts.last}';
      final only = inv.snapshots > 0 && inv.files == 0 && inv.thumbs == 0
          ? 'Solo hay '
          : 'Hay ';
      return (
        'Falta el respaldo de tus llaves',
        '$only$found en esta cuenta, pero falta el respaldo de la llave, así '
            'que no se puede restaurar desde aquí. $elsewhere',
      );
  }
}

/// Fases visibles de la restauración.
enum RestoreStage { downloadingDb, opening, thumbnails, installing }

class RestoreProgress {
  const RestoreProgress(this.stage, {this.done = 0, this.total = 0});
  final RestoreStage stage;
  final int done;
  final int total;
}

/// Resumen de una restauración terminada.
class RestoreResult {
  const RestoreResult({
    required this.items,
    required this.folders,
    required this.thumbnails,
    required this.lostItems,
    required this.adoptedItems,
    required this.missingThumbnails,
  });

  /// Archivos restaurados (con copia verificada en Drive).
  final int items;
  final int folders;

  /// Miniaturas descargadas.
  final int thumbnails;

  /// Archivos que figuran en el índice pero cuya copia no está en Drive (o
  /// no coincide): quedan en estado `error`, visibles, y no se pueden abrir.
  final int lostItems;

  /// Archivos sin MD5 registrado cuya copia sí está en Drive (se aceptan con
  /// los metadatos de Drive; el descifrado autentica cada bloque al abrirlos).
  final int adoptedItems;

  /// Miniaturas que faltaban en Drive (se mostrará el ícono genérico).
  final int missingThumbnails;
}

/// Fallo de la restauración con mensaje en español.
class RestoreException implements Exception {
  const RestoreException(this.message);
  final String message;
  @override
  String toString() => 'RestoreException: $message';
}

/// La BD descargada no se abre con la llave de este código, o está dañada.
class RestoreCorruptException extends RestoreException {
  const RestoreCorruptException()
    : super('El respaldo está dañado o no corresponde a este código.');
}

/// El respaldo es de una versión de la app con otro esquema de BD.
class RestoreIncompatibleException extends RestoreException {
  const RestoreIncompatibleException()
    : super('El respaldo es de una versión de Vault incompatible.');
}

/// S-14: un archivo de la nube supera el tope permitido (no se reintenta).
class RestoreTooLargeException extends RestoreException {
  const RestoreTooLargeException()
    : super('El respaldo en la nube es demasiado grande y se rechazó.');
}

/// Lo descargado no coincide con el tamaño/MD5 de Drive: se puede reintentar.
class RestoreDownloadMismatchException extends RestoreException {
  const RestoreDownloadMismatchException()
    : super(
        'La descarga no coincide con la copia de Drive. Inténtalo de nuevo.',
      );
}

/// Restauración en un teléfono nuevo o instalación limpia (F9).
///
/// Orden (nada es visible para la app hasta el último paso):
///  1. [probe]: busca `recovery_backup.json` y `vault_db.snapshot` en
///     appDataFolder y descarga el respaldo de llaves (solo memoria).
///  2. [verifyCode]: deriva KEK_rec y desenvuelve la DEK (con límite de
///     intentos persistido). Sin escribir nada local.
///  3. [restore]: descarga el snapshot a `restore_staging/` (verifica
///     tamaño y MD5), lo abre con la llave SQLCipher derivada de la DEK,
///     reconcilia estados contra el listado de Drive, descarga TODAS las
///     miniaturas (en paralelo, reanudable) y solo entonces instala BD y
///     miniaturas con rutas relativas y consolida las llaves
///     ([AuthController.commitRestore], envoltura de PIN nueva en ESTE
///     dispositivo; la biometría anterior no se restaura).
///
/// Si algo falla ANTES de consolidar, no queda bóveda ni bandera: la zona de
/// preparación se conserva solo si el fallo es recuperable (red) para
/// reanudar; si falla la instalación se deshace todo lo copiado.
class RestoreService {
  RestoreService({
    required this.cloud,
    required this.auth,
    required this.prefs,
    DatabaseOpener? opener,
    String? dbPath,
    int parallelism = 4,
    int Function()? nowMs,
    int? maxSnapshotBytes,
  }) : _opener = opener ?? openSqlCipherDatabase,
       _dbPathOverride = dbPath,
       maxSnapshotBytes = maxSnapshotBytes ?? defaultMaxSnapshotBytes,
       _parallelism = parallelism < 1 ? 1 : parallelism,
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CloudStorage cloud;
  final AuthController auth;
  final SyncPreferences prefs;
  final DatabaseOpener _opener;
  final String? _dbPathOverride;
  final int _parallelism;
  final int Function() _now;

  /// Tope del snapshot (inyectable en pruebas).
  final int maxSnapshotBytes;

  static const String stagingDirName = 'restore_staging';

  /// S-14: tope de `recovery_backup.json` (el real mide ~1 KiB).
  static const int maxRecoveryBackupBytes = 4 * 1024;

  /// S-14: tope del snapshot de la BD cifrada. Una BD SQLCipher con decenas de
  /// miles de items (~1 KiB/fila) ocupa unas decenas de MiB; 256 MiB deja un
  /// margen amplio sin permitir que una cuenta ajena agote disco/memoria.
  static const int defaultMaxSnapshotBytes = 256 * 1024 * 1024;

  /// S-14: tope de una miniatura cifrada (~256 px JPEG, decenas de KiB).
  static const int maxThumbBytes = 8 * 1024 * 1024;

  /// Respaldos encontrados por [probe], en el orden en que se prueban.
  List<_BackupCandidate> _candidates = const [];

  /// Mayor generación con un conjunto principal completo (respaldo +
  /// snapshot) en la cuenta.
  int _latestGen = 1;

  /// El que abrió el código ([verifyCode]).
  _BackupCandidate? _chosen;
  RecoveryCandidate? _candidate;

  /// Qué abrió el último código correcto (M8: aviso si es un estado anterior
  /// al más reciente), o `null`.
  RestoreCodeMatch? get lastMatch {
    final c = _chosen;
    if (c == null) return null;
    return RestoreCodeMatch(
      gen: c.gen,
      viaBridge: c.bridge,
      latestGen: _latestGen,
    );
  }

  String get _dbPath => _dbPathOverride ?? VaultDatabase.defaultDbPath;

  static Directory get stagingDir =>
      Directory(p.join(AppPaths.baseDir.path, stagingDirName));

  /// Correo de la cuenta conectada (solo para mostrarlo en pantalla).
  String? get accountEmail => cloud.currentAccountEmail;

  // --------------------------------------------------------------- sesión

  /// Inicio de sesión interactivo en Google (el autobloqueo está suspendido
  /// por [GoogleDriveCloudStorage]). Lanza [CloudException].
  Future<CloudAccount> signIn() => cloud.signIn();

  Future<void> signOut() async {
    _forget();
    await cloud.signOut();
  }

  // ---------------------------------------------------------------- probe

  /// Busca el respaldo en la cuenta conectada. Lanza [CloudException] si no
  /// hay red/sesión.
  ///
  /// D61: tras una rotación de la DEK puede haber respaldos de varias
  /// generaciones (`recovery_backup[.kN].json`), el puente
  /// (`recovery_backup.bridge.kF.json`) y duplicados (M1). Se recogen TODOS
  /// los válidos y se emparejan con el snapshot de SU generación (el puente,
  /// con el de la generación que abre). Orden en que se prueban: principales
  /// de la mayor generación, puentes y principales menores.
  ///
  /// D78: deja en [lastInventory] lo que vio (solo conteos y tamaños) para
  /// que el mensaje diga qué encontró, y lo registra (solo números).
  Future<RestoreProbeResult> probe() async {
    _forget();
    final all = await cloud.list();
    final inventory = _inventory = CloudInventory.of(all);
    final result = await _probe(all);
    VaultLog.d(
      'Restauración: ${result.name}; ${inventory.logLine}',
      category: 'restore',
    );
    return result;
  }

  CloudInventory? _inventory;

  /// D78: inventario del último [probe] (`null` = aún no se buscó).
  CloudInventory? get lastInventory => _inventory;

  Future<RestoreProbeResult> _probe(List<CloudFile> all) async {
    final backups = <(CloudFile, CloudNameInfo)>[
      for (final f in all)
        if (CloudNames.parse(f.name) case final info?
            when info.kind == CloudNameKind.recoveryBackup ||
                info.kind == CloudNameKind.bridgeBackup)
          (f, info),
    ];
    if (backups.isEmpty) return RestoreProbeResult.noBackup;
    final snapshots = <int, CloudFile?>{};
    Future<CloudFile?> snapshotFor(int gen) async => snapshots.containsKey(gen)
        ? snapshots[gen]
        : snapshots[gen] = await cloud.findByName(
            CloudNames.dbSnapshotFor(gen),
          );
    final valid = <_BackupCandidate>[];
    for (final (meta, info) in backups) {
      // S-14: el respaldo real mide ~1 KiB; se rechaza por tamaño declarado y
      // por bytes recibidos ANTES de decodificar ni parsear nada.
      if (meta.size > maxRecoveryBackupBytes) continue;
      final String json;
      try {
        final bytes = await cloud.downloadBytes(
          meta.id,
          maxBytes: maxRecoveryBackupBytes,
        );
        if (bytes.length > maxRecoveryBackupBytes) continue;
        json = utf8.decode(bytes);
        RecoveryBackup.parse(json);
      } on CloudTooLargeException {
        continue;
      } on FormatException {
        continue;
      }
      valid.add(
        _BackupCandidate(
          json: json,
          gen: info.gen,
          bridge: info.kind == CloudNameKind.bridgeBackup,
          snapshot: await snapshotFor(info.gen),
        ),
      );
    }
    if (valid.isEmpty) return RestoreProbeResult.invalid;
    final complete = [
      for (final c in valid)
        if (c.snapshot != null) c,
    ];
    if (complete.isEmpty) return RestoreProbeResult.incomplete;
    final mains = complete.where((c) => !c.bridge).toList()
      ..sort((a, b) => b.gen.compareTo(a.gen));
    final bridges = complete.where((c) => c.bridge).toList()
      ..sort((a, b) => b.gen.compareTo(a.gen));
    _latestGen = mains.isEmpty ? bridges.first.gen : mains.first.gen;
    _candidates = [
      ...mains.where((c) => c.gen == _latestGen),
      ...bridges,
      ...mains.where((c) => c.gen != _latestGen),
    ];
    return RestoreProbeResult.found;
  }

  void _forget() {
    _candidate?.destroy();
    _candidate = null;
    _candidates = const [];
    _chosen = null;
    _latestGen = 1;
  }

  /// Libera llaves en memoria (al salir del flujo sin restaurar).
  void dispose() => _forget();

  // ----------------------------------------------------------------- código

  /// Tiempo de espera restante por códigos incorrectos, o `null`.
  Future<Duration?> lockoutRemaining() => auth.restoreLockoutRemaining();

  /// Verifica el código de recuperación. `true` si abre el respaldo; `false`
  /// si es incorrecto (cuenta un intento). Lanza [PinLockedOutException] si
  /// hay que esperar. El código no se guarda ni se registra.
  ///
  /// Se prueba contra todos los respaldos de [probe] (cuenta como UN
  /// intento). Si abre un estado anterior al más reciente, [lastMatch] lo
  /// dice (aviso M8 en la UI).
  Future<bool> verifyCode(String code) async {
    final candidates = _candidates;
    if (candidates.isEmpty) {
      throw StateError('Falta buscar el respaldo (probe)');
    }
    final match = await auth.verifyRecoveryCodeAny(
      recoveryCode: code,
      recoveryBackupJsons: [for (final c in candidates) c.json],
    );
    if (match == null) return false;
    _candidate?.destroy();
    _candidate = match.$2;
    _chosen = candidates[match.$1];
    return true;
  }

  // ---------------------------------------------------------------- restore

  /// Descarga, valida, reconcilia e instala. Requiere [probe] y
  /// [verifyCode] correctos. Reintentable tras un fallo de red.
  Future<RestoreResult> restore({
    required String newPin,
    void Function(RestoreProgress progress)? onProgress,
    CloudCancelToken? cancel,
  }) async {
    final candidate = _candidate;
    final chosen = _chosen;
    final snapshotMeta = chosen?.snapshot;
    if (candidate == null || chosen == null || snapshotMeta == null) {
      throw StateError('Falta verificar el código de recuperación');
    }
    final json = chosen.json;
    final setGen = chosen.gen;
    if (await auth.hasVault()) {
      throw StateError('Ya existe una bóveda en este dispositivo');
    }
    VaultLog.d('Restauración iniciada', category: 'restore');
    await AppPaths.init();
    final staging = stagingDir..createSync(recursive: true);
    final stagedThumbs = Directory(p.join(staging.path, 'thumbs'))
      ..createSync(recursive: true);
    final stagedDb = File(p.join(staging.path, 'db.snapshot'));

    // 1. Snapshot de la BD.
    onProgress?.call(const RestoreProgress(RestoreStage.downloadingDb));
    final fresh = await cloud.getMetadata(snapshotMeta.id);
    await _downloadVerified(fresh, stagedDb, cancel, maxSnapshotBytes);

    // 2. Abrir con la llave derivada de la DEK y reconciliar.
    onProgress?.call(const RestoreProgress(RestoreStage.opening));
    final remote = {
      for (final f in await cloud.list())
        if (!_isMeta(f.name)) f.name: f,
    };
    final _Reconciled summary;
    try {
      summary = await _reconcileStaged(stagedDb, candidate, remote);
    } on RestoreException {
      // Un snapshot que no abre no se arregla reintentando la descarga.
      try {
        if (stagedDb.existsSync()) await stagedDb.delete();
      } on FileSystemException {
        // mejor esfuerzo
      }
      rethrow;
    }

    // 3. Miniaturas (reanudable: las ya verificadas en staging se saltan).
    var done = 0;
    final total = summary.thumbs.length;
    onProgress?.call(RestoreProgress(RestoreStage.thumbnails, total: total));
    var missing = summary.missingThumbs;
    var downloaded = 0;
    await _runPool(summary.thumbs, cancel, (job) async {
      final ok = await _downloadThumb(job, stagedThumbs, cancel);
      if (ok) {
        downloaded++;
      } else {
        missing++;
      }
      done++;
      onProgress?.call(
        RestoreProgress(RestoreStage.thumbnails, done: done, total: total),
      );
    });

    // 4. Instalar y consolidar (todo o nada).
    onProgress?.call(const RestoreProgress(RestoreStage.installing));
    if (cancel?.isCancelled ?? false) throw const CloudCancelledException();
    await _install(
      candidate: candidate,
      newPin: newPin,
      stagedDb: stagedDb,
      stagedThumbs: stagedThumbs,
      thumbs: [for (final t in summary.thumbs) (t.itemId, t.keyGen)],
      keyGen: setGen,
    );
    // Restaurado con el PUENTE (D61): el respaldo local es el del código
    // nuevo para la generación vieja; se sube en lugar del de entonces (S-04
    // borra el que abría el código viejo). Si no, es el mismo de Drive.
    await prefs.setRecoveryUploadedSha(
      chosen.bridge ? '' : crypto.sha256.convert(utf8.encode(json)).toString(),
    );
    await prefs.markSnapshotDone(_now());
    // D61: en una generación > 1 se barren después las anteriores de Drive
    // (por si el teléfono original no terminó la limpieza).
    if (setGen > 1) await prefs.setGenerationSweepPending(true);
    await discardStaging();
    _candidate = null; // las llaves pasaron a la sesión
    VaultLog.d('Restauración terminada', category: 'restore');
    return RestoreResult(
      items: summary.items - summary.lost,
      folders: summary.folders,
      thumbnails: downloaded,
      lostItems: summary.lost,
      adoptedItems: summary.adopted,
      missingThumbnails: missing,
    );
  }

  /// Respaldos de llaves (de cualquier generación, también los puente) y
  /// snapshots: no son archivos de items.
  static bool _isMeta(String name) => switch (CloudNames.parse(name)?.kind) {
    CloudNameKind.recoveryBackup ||
    CloudNameKind.bridgeBackup ||
    CloudNameKind.dbSnapshot => true,
    _ => false,
  };

  /// Borra la zona de preparación (al abandonar la restauración).
  static Future<void> discardStaging() async {
    if (!AppPaths.isInitialized) return;
    try {
      final d = stagingDir;
      if (d.existsSync()) await d.delete(recursive: true);
    } on FileSystemException {
      // se limpiará en el próximo intento
    }
  }

  /// Sin bóveda en el dispositivo no puede haber BD ni miniaturas válidas:
  /// restos de una restauración interrumpida durante la instalación. Se
  /// limpian al arrancar (la zona de preparación se conserva para reanudar).
  static Future<void> sweepOrphans({String? dbPath}) async {
    if (!AppPaths.isInitialized) return;
    try {
      final base = dbPath ?? VaultDatabase.defaultDbPath;
      for (final suffix in ['', '-wal', '-shm', '-journal', '.snapshot']) {
        final f = File('$base$suffix');
        if (f.existsSync()) await f.delete();
      }
      final thumbs = AppPaths.thumbsDir;
      if (thumbs.existsSync()) {
        for (final f in thumbs.listSync().whereType<File>()) {
          await f.delete();
        }
      }
    } on FileSystemException {
      // mejor esfuerzo
    }
  }

  // ------------------------------------------------------------- descargas

  Future<void> _downloadVerified(
    CloudFile meta,
    File target,
    CloudCancelToken? cancel,
    int maxBytes,
  ) async {
    // S-14: tope por tamaño declarado (antes de descargar) y por bytes
    // recibidos (la nube corta la descarga al excederlo).
    if (meta.size > maxBytes) throw const RestoreTooLargeException();
    final part = File('${target.path}.part');
    try {
      if (part.existsSync()) await part.delete();
      try {
        await cloud.download(meta.id, part, cancel: cancel, maxBytes: maxBytes);
      } on CloudTooLargeException {
        throw const RestoreTooLargeException();
      }
      final size = await part.length();
      final md5 = await md5OfFile(part);
      final expectedMd5 = meta.md5Checksum?.toLowerCase();
      if (size != meta.size || (expectedMd5 != null && md5 != expectedMd5)) {
        throw const RestoreDownloadMismatchException();
      }
      if (target.existsSync()) await target.delete();
      await part.rename(target.path);
    } catch (_) {
      try {
        if (part.existsSync()) await part.delete();
      } on FileSystemException {
        // mejor esfuerzo
      }
      rethrow;
    }
  }

  /// `true` si la miniatura quedó en staging; `false` si ya no existe en
  /// Drive (404). Otros fallos se propagan (reanudable).
  Future<bool> _downloadThumb(
    _ThumbJob job,
    Directory stagedThumbs,
    CloudCancelToken? cancel,
  ) async {
    final target = File(p.join(stagedThumbs.path, '${job.itemId}.thumb'));
    if (target.existsSync() &&
        await target.length() == job.remote.size &&
        (job.remote.md5Checksum == null ||
            await md5OfFile(target) == job.remote.md5Checksum!.toLowerCase())) {
      return true; // ya descargada en un intento anterior
    }
    try {
      await _downloadVerified(job.remote, target, cancel, maxThumbBytes);
    } on CloudNotFoundException {
      return false;
    } on RestoreTooLargeException {
      // Miniatura desproporcionada (S-14): se trata como perdida.
      return false;
    }
    // S-09: la miniatura de Drive debe ser la que el snapshot registró (otra
    // miniatura auténtica de la bóveda, o un snapshot viejo, no vale): se
    // descarta y cuenta como miniatura perdida.
    final expected = job.expectedFileId;
    if (expected != null) {
      String? got;
      try {
        got = await CryptoService.fileIdOfFile(target);
      } on Object {
        got = null;
      }
      if (got != expected) {
        try {
          await target.delete();
        } on FileSystemException {
          // staging: se limpia al terminar
        }
        return false;
      }
    }
    return true;
  }

  /// Ejecuta [work] sobre [jobs] con hasta [_parallelism] a la vez. Al primer
  /// error deja de lanzar trabajos nuevos y lo relanza cuando acaban los
  /// que estaban en curso.
  Future<void> _runPool<T>(
    List<T> jobs,
    CloudCancelToken? cancel,
    Future<void> Function(T job) work,
  ) async {
    var next = 0;
    Object? error;
    StackTrace? stack;
    Future<void> worker() async {
      while (error == null && next < jobs.length) {
        if (cancel?.isCancelled ?? false) {
          error ??= const CloudCancelledException();
          return;
        }
        final job = jobs[next++];
        try {
          await work(job);
        } catch (e, st) {
          error ??= e;
          stack ??= st;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < _parallelism && i < jobs.length; i++) worker(),
    ]);
    final e = error;
    if (e != null) Error.throwWithStackTrace(e, stack ?? StackTrace.current);
  }

  // --------------------------------------------------------- reconciliación

  /// Abre la copia en staging con la llave de [candidate] y deja los estados
  /// coherentes con Drive. Lanza [RestoreCorruptException] /
  /// [RestoreIncompatibleException].
  Future<_Reconciled> _reconcileStaged(
    File stagedDb,
    RecoveryCandidate candidate,
    Map<String, CloudFile> remote,
  ) async {
    Database? db;
    try {
      try {
        db = await _opener(
          stagedDb.path,
          password: VaultDatabase.passwordFor(candidate.keys),
          options: OpenDatabaseOptions(),
        );
        final tables = (await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        )).map((r) => r['name']).toSet();
        if (!tables.containsAll(['vault_items', 'folders', 'sync_queue'])) {
          throw const RestoreCorruptException();
        }
      } on RestoreException {
        rethrow;
      } on Object {
        // Llave que no abre el archivo ("file is not a database") o archivo
        // dañado: no hay forma de distinguirlos, ni hace falta.
        throw const RestoreCorruptException();
      }
      final version = Sqflite.firstIntValue(
        await db.rawQuery('PRAGMA user_version'),
      );
      // v6 (anterior al cambio de cuenta) se acepta: al abrirla la app la
      // actualiza de forma incremental. Más nuevas o más viejas: incompatible.
      if (version == null ||
          version < VaultSchema.minUpgradableVersion ||
          version > VaultSchema.version) {
        throw const RestoreIncompatibleException();
      }

      final rows = await db.query('vault_items');
      final folders =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM folders'),
          ) ??
          0;
      var lost = 0;
      var adopted = 0;
      var missingThumbs = 0;
      final thumbs = <_ThumbJob>[];
      final batch = db.batch();
      if (version >= 7) {
        // Un cambio de cuenta a medias en la copia NO se hereda: el estado de
        // una migración pertenece al teléfono que la hizo.
        batch.delete('migration_items');
        batch.delete('migration_state');
      }
      // Lo mismo con una rotación de la DEK a medias (v10, D62): ni su estado
      // ni sus triggers de cardinalidad pasan al teléfono restaurado.
      for (final t in VaultSchema.rotationTriggerNames) {
        batch.execute('DROP TRIGGER IF EXISTS $t');
      }
      if (version >= 10) {
        batch.delete('rotation_old_files');
        batch.delete('rotation_state');
      }
      if (version >= 11) {
        // D75: el diagnóstico del otro teléfono no viaja, y los tags de cuenta
        // quedan «sin comprobar»: la verificación del primer desbloqueo los
        // fija con la cuenta de este teléfono (la sal de `vault_meta` sí se
        // conserva). Un snapshot < v11 se actualiza al abrirlo (todo NULL).
        batch.delete('diag_events');
        batch.update('vault_items', {
          'cloudAccountTag': null,
          'thumbAccountTag': null,
        });
      }
      if (version >= 12) {
        // D86: la cola de importación es de la fototeca del OTRO teléfono (la
        // copia subida ya la vacía; esto cubre un snapshot de otra versión).
        batch.delete('import_queue');
        batch.delete('import_batches');
      }
      for (final r in rows) {
        final id = r['id'] as String;
        // S-15: el id acaba en nombres de archivo locales (`<id>.thumb`): solo
        // se aceptan UUID v4 (nada de `/`, `..`, mayúsculas, etc.).
        if (!AppPaths.isValidItemId(id)) throw const RestoreCorruptException();
        // D60: los nombres en Drive llevan la generación de llave del item
        // (snapshots anteriores a v10: generación 1).
        final keyGen = (r['keyGen'] as int?) ?? 1;
        if (keyGen < 1 || keyGen > AppPaths.maxKeyGen) {
          throw const RestoreCorruptException();
        }
        final file = remote[CloudNames.file(id, gen: keyGen)];
        final md5 = r['cloudMd5'] as String?;
        final size = r['cloudSize'] as int?;
        final hasRecord = md5 != null && size != null;
        final matches =
            file != null &&
            (hasRecord
                ? file.size == size &&
                      file.md5Checksum?.toLowerCase() == md5.toLowerCase()
                : file.md5Checksum != null);
        if (matches) {
          if (!hasRecord) adopted++;
          batch.update(
            'vault_items',
            {
              'syncStatus': 'en_nube',
              'driveFileId': file.id,
              'cloudMd5': file.md5Checksum!.toLowerCase(),
              'cloudSize': file.size,
            },
            where: 'id = ?',
            whereArgs: [id],
          );
        } else {
          lost++;
          batch.update(
            'vault_items',
            {'syncStatus': 'error'},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        if (r['thumbPath'] != null) {
          final thumb = remote[CloudNames.thumb(id, gen: keyGen)];
          if (thumb != null) {
            thumbs.add(
              _ThumbJob(id, thumb, r['thumbFileId'] as String?, keyGen),
            );
            batch.update(
              'vault_items',
              {
                'thumbDriveFileId': thumb.id,
                // Donde se instala (misma generación que su `.vault`).
                'thumbPath': AppPaths.thumbRelativePath(id, gen: keyGen),
              },
              where: 'id = ?',
              whereArgs: [id],
            );
          } else {
            missingThumbs++;
            batch.update(
              'vault_items',
              {'thumbPath': null, 'thumbDriveFileId': null},
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        }
      }
      // La cola del otro teléfono no aplica aquí: se rehace desde el estado
      // de los items. Solo se conservan los borrados remotos pendientes.
      batch.delete('sync_queue', where: "kind != 'delete_remote'");
      batch.update('sync_queue', {
        'state': 'pendiente',
        'attempts': 0,
        'nextAttemptAt': 0,
        'lastError': null,
      });
      await batch.commit(noResult: true);
      return _Reconciled(
        items: rows.length,
        folders: folders,
        lost: lost,
        adopted: adopted,
        thumbs: thumbs,
        missingThumbs: missingThumbs,
      );
    } finally {
      try {
        await db?.close();
      } on Object {
        // ya cerrada
      }
    }
  }

  // -------------------------------------------------------------- instalar

  Future<void> _install({
    required RecoveryCandidate candidate,
    required String newPin,
    required File stagedDb,
    required Directory stagedThumbs,
    required List<(String, int)> thumbs,
    required int keyGen,
  }) async {
    final target = File(_dbPath);
    if (!target.parent.existsSync()) target.parent.createSync(recursive: true);
    final moved = <File>[];
    try {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final f = File('${target.path}$suffix');
        if (f.existsSync()) await f.delete();
      }
      AppPaths.thumbsDir.createSync(recursive: true);
      for (final (id, gen) in thumbs) {
        final src = File(p.join(stagedThumbs.path, '$id.thumb'));
        if (!src.existsSync()) continue; // 404 durante la descarga
        final dst = AppPaths.resolve(AppPaths.thumbRelativePath(id, gen: gen));
        if (dst.existsSync()) await dst.delete();
        await src.rename(dst.path);
        moved.add(dst);
      }
      await stagedDb.rename(target.path);
      moved.add(target);
      // D60: la generación del conjunto restaurado (la del nombre del
      // respaldo; con el puente, la que abre).
      await auth.commitRestore(candidate, newPin, keyGen: keyGen);
    } catch (e) {
      // Deshace todo lo local de la restauración para poder reintentar.
      for (final f in moved) {
        try {
          if (f.existsSync()) await f.delete();
        } on FileSystemException {
          // mejor esfuerzo
        }
      }
      if (kDebugMode) debugPrint('[restore] instalación revertida: $e');
      rethrow;
    }
    // C1 (D62): la BD instalada es la de esta bóveda; si faltara después, no
    // se crea una vacía. Mejor esfuerzo: si falla, la marca la escribe la
    // primera apertura de la BD.
    try {
      await auth.markDatabaseCreated();
    } on Object catch (e) {
      if (kDebugMode) debugPrint('[restore] marca de BD pendiente: $e');
    }
  }
}

class _ThumbJob {
  const _ThumbJob(this.itemId, this.remote, this.expectedFileId, this.keyGen);

  /// S-09: fileId registrado en el snapshot para esta miniatura.
  final String? expectedFileId;
  final String itemId;
  final CloudFile remote;

  /// D60: generación de llave del item (nombre local de la miniatura).
  final int keyGen;
}

/// Un respaldo de llaves encontrado en Drive con el snapshot de SU conjunto.
class _BackupCandidate {
  const _BackupCandidate({
    required this.json,
    required this.gen,
    required this.bridge,
    required this.snapshot,
  });

  final String json;

  /// Generación del conjunto que abre (en el puente, la VIEJA).
  final int gen;
  final bool bridge;
  final CloudFile? snapshot;
}

/// Qué abrió el código de recuperación (M8).
class RestoreCodeMatch {
  const RestoreCodeMatch({
    required this.gen,
    required this.viaBridge,
    required this.latestGen,
  });

  /// Generación del conjunto que se restaurará.
  final int gen;

  /// Se abrió con el respaldo PUENTE de una rotación (código nuevo, estado
  /// de antes de la rotación).
  final bool viaBridge;

  /// Mayor generación completa que hay en la cuenta.
  final int latestGen;

  /// Restaura un estado anterior al más reciente de la cuenta: la UI pide
  /// confirmación (M8).
  bool get olderThanLatest => viaBridge || gen < latestGen;
}

class _Reconciled {
  const _Reconciled({
    required this.items,
    required this.folders,
    required this.lost,
    required this.adopted,
    required this.thumbs,
    required this.missingThumbs,
  });
  final int items;
  final int folders;
  final int lost;
  final int adopted;
  final List<_ThumbJob> thumbs;
  final int missingThumbs;
}
