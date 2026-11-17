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
import '../sync/sync_service.dart' show CloudNameKind, CloudNames, md5OfFile;

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

  String? _backupJson;
  CloudFile? _snapshotMeta;
  RecoveryCandidate? _candidate;

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
  Future<RestoreProbeResult> probe() async {
    _forget();
    final keyMeta = await cloud.findByName(CloudNames.recoveryBackup);
    if (keyMeta == null) return RestoreProbeResult.noBackup;
    final snapshot = await cloud.findByName(CloudNames.dbSnapshot);
    // S-14: el respaldo real mide ~1 KiB; se rechaza por tamaño declarado y
    // por bytes recibidos ANTES de decodificar ni parsear nada.
    if (keyMeta.size > maxRecoveryBackupBytes) {
      return RestoreProbeResult.invalid;
    }
    final String json;
    try {
      final bytes = await cloud.downloadBytes(
        keyMeta.id,
        maxBytes: maxRecoveryBackupBytes,
      );
      if (bytes.length > maxRecoveryBackupBytes) {
        return RestoreProbeResult.invalid;
      }
      json = utf8.decode(bytes);
      RecoveryBackup.parse(json);
    } on CloudTooLargeException {
      return RestoreProbeResult.invalid;
    } on FormatException {
      return RestoreProbeResult.invalid;
    }
    _backupJson = json;
    if (snapshot == null) return RestoreProbeResult.incomplete;
    _snapshotMeta = snapshot;
    return RestoreProbeResult.found;
  }

  void _forget() {
    _candidate?.destroy();
    _candidate = null;
    _backupJson = null;
    _snapshotMeta = null;
  }

  /// Libera llaves en memoria (al salir del flujo sin restaurar).
  void dispose() => _forget();

  // ----------------------------------------------------------------- código

  /// Tiempo de espera restante por códigos incorrectos, o `null`.
  Future<Duration?> lockoutRemaining() => auth.restoreLockoutRemaining();

  /// Verifica el código de recuperación. `true` si abre el respaldo; `false`
  /// si es incorrecto (cuenta un intento). Lanza [PinLockedOutException] si
  /// hay que esperar. El código no se guarda ni se registra.
  Future<bool> verifyCode(String code) async {
    final json = _backupJson;
    if (json == null) throw StateError('Falta buscar el respaldo (probe)');
    final candidate = await auth.verifyRecoveryCode(
      recoveryCode: code,
      recoveryBackupJson: json,
    );
    if (candidate == null) return false;
    _candidate?.destroy();
    _candidate = candidate;
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
    final json = _backupJson;
    final snapshotMeta = _snapshotMeta;
    if (candidate == null || json == null || snapshotMeta == null) {
      throw StateError('Falta verificar el código de recuperación');
    }
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
      thumbIds: [for (final t in summary.thumbs) t.itemId],
    );
    await prefs.setRecoveryUploadedSha(
      crypto.sha256.convert(utf8.encode(json)).toString(),
    );
    await prefs.markSnapshotDone(_now());
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
      for (final r in rows) {
        final id = r['id'] as String;
        // S-15: el id acaba en nombres de archivo locales (`<id>.thumb`): solo
        // se aceptan UUID v4 (nada de `/`, `..`, mayúsculas, etc.).
        if (!AppPaths.isValidItemId(id)) throw const RestoreCorruptException();
        final file = remote[CloudNames.file(id)];
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
          final thumb = remote[CloudNames.thumb(id)];
          if (thumb != null) {
            thumbs.add(_ThumbJob(id, thumb, r['thumbFileId'] as String?));
            batch.update(
              'vault_items',
              {'thumbDriveFileId': thumb.id},
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
    required List<String> thumbIds,
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
      for (final id in thumbIds) {
        final src = File(p.join(stagedThumbs.path, '$id.thumb'));
        if (!src.existsSync()) continue; // 404 durante la descarga
        final dst = AppPaths.resolve(AppPaths.thumbRelativePath(id));
        if (dst.existsSync()) await dst.delete();
        await src.rename(dst.path);
        moved.add(dst);
      }
      await stagedDb.rename(target.path);
      moved.add(target);
      await auth.commitRestore(candidate, newPin);
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
  const _ThumbJob(this.itemId, this.remote, this.expectedFileId);

  /// S-09: fileId registrado en el snapshot para esta miniatura.
  final String? expectedFileId;
  final String itemId;
  final CloudFile remote;
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
