import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/sync_status.dart';
import '../repositories/vault_database.dart';

/// Fases del cambio de cuenta de Google (persistidas en `migration_state`).
///
/// Orden normal: downloading -> signInNew -> checkingNew -> uploading ->
/// finalizing -> askDeleteOld -> (fila borrada). Los `blocked*` detienen el
/// flujo SIN subir nada a la cuenta nueva.
enum MigrationPhase {
  /// Bajar de la cuenta vieja lo que no está en el teléfono.
  downloading('downloading'),

  /// Esperando que el usuario elija la cuenta NUEVA.
  signInNew('sign_in_new'),

  /// Comprobando la cuenta nueva (otra bóveda, cuota).
  checkingNew('checking_new'),

  /// Subiendo todo a la cuenta nueva (con la verificación habitual).
  uploading('uploading'),

  /// Respaldo de recuperación y snapshot en la cuenta nueva.
  finalizing('finalizing'),

  /// Listo: se ofrece borrar (o conservar) los datos de la cuenta vieja.
  askDeleteOld('ask_delete_old'),

  /// La cuenta nueva ya tiene el respaldo de OTRA bóveda: no se sobrescribe.
  blockedOtherVault('blocked_other_vault'),

  /// La cuenta nueva no tiene espacio suficiente.
  blockedQuota('blocked_quota'),

  /// D76: valor guardado que esta versión no reconoce (p. ej. de una versión
  /// más nueva). Antes caía en `downloading` en silencio; ahora no se ejecuta
  /// nada y solo se ofrece «Cancelar y quedarme». Nunca se escribe.
  unknown('?');

  const MigrationPhase(this.dbValue);
  final String dbValue;

  static MigrationPhase fromDb(String v) => MigrationPhase.values.firstWhere(
    (p) => p.dbValue == v && p != MigrationPhase.unknown,
    orElse: () => MigrationPhase.unknown,
  );

  /// `true` si ya se cambió (o se está cambiando) a la cuenta nueva.
  bool get switchedAccount =>
      this != MigrationPhase.downloading && this != MigrationPhase.signInNew;
}

class MigrationState {
  const MigrationState({
    required this.phase,
    this.oldEmail,
    this.newEmail,
    required this.startedAt,
    required this.updatedAt,
    this.neededBytes = 0,
    this.downloadTotal = 0,
    this.downloadDone = 0,
    this.lastError,
  });

  final MigrationPhase phase;
  final String? oldEmail;
  final String? newEmail;
  final int startedAt;
  final int updatedAt;

  /// Bytes estimados que hay que subir a la cuenta nueva.
  final int neededBytes;

  /// Bytes a bajar de la cuenta vieja / ya bajados (barra de la fase 1).
  final int downloadTotal;
  final int downloadDone;
  final String? lastError;

  factory MigrationState.fromMap(Map<String, Object?> m) => MigrationState(
    phase: MigrationPhase.fromDb(m['phase'] as String),
    oldEmail: m['oldEmail'] as String?,
    newEmail: m['newEmail'] as String?,
    startedAt: m['startedAt'] as int,
    updatedAt: m['updatedAt'] as int,
    neededBytes: (m['neededBytes'] as int?) ?? 0,
    downloadTotal: (m['downloadTotal'] as int?) ?? 0,
    downloadDone: (m['downloadDone'] as int?) ?? 0,
    lastError: m['lastError'] as String?,
  );
}

/// Referencias a la nube de la cuenta anterior de un item (para restaurarlas
/// al cancelar).
class OldCloudRefs {
  const OldCloudRefs({
    required this.itemId,
    required this.oldStatus,
    this.driveFileId,
    this.cloudMd5,
    this.cloudSize,
    this.thumbDriveFileId,
  });
  final String itemId;
  final SyncStatus oldStatus;
  final String? driveFileId;
  final String? cloudMd5;
  final int? cloudSize;
  final String? thumbDriveFileId;
}

/// Estado persistido del cambio de cuenta (sobrevive a matar la app y a
/// bloquear: vive en la BD cifrada).
class MigrationRepository {
  MigrationRepository({Future<Database> Function()? dbProvider})
    : _dbProvider = dbProvider ?? (() => VaultDatabase.instance.database);

  final Future<Database> Function() _dbProvider;

  Future<MigrationState?> load() async {
    final db = await _dbProvider();
    final rows = await db.query('migration_state', where: 'id = 1');
    return rows.isEmpty ? null : MigrationState.fromMap(rows.first);
  }

  Future<void> begin({
    required String oldEmail,
    required int neededBytes,
    required int downloadTotal,
    required int now,
  }) async {
    final db = await _dbProvider();
    await db.insert('migration_state', {
      'id': 1,
      'phase': MigrationPhase.downloading.dbValue,
      'oldEmail': oldEmail,
      'newEmail': null,
      'startedAt': now,
      'updatedAt': now,
      'neededBytes': neededBytes,
      'downloadTotal': downloadTotal,
      'downloadDone': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> update({
    MigrationPhase? phase,
    String? newEmail,
    int? downloadDone,
    int? downloadTotal,
    int? neededBytes,
    String? lastError,
    bool clearError = false,
    required int now,
  }) async {
    final db = await _dbProvider();
    await db.update('migration_state', {
      'phase': ?phase?.dbValue,
      'newEmail': ?newEmail,
      'downloadDone': ?downloadDone,
      'downloadTotal': ?downloadTotal,
      'neededBytes': ?neededBytes,
      if (lastError != null || clearError) 'lastError': lastError,
      'updatedAt': now,
    }, where: 'id = 1');
  }

  /// Borra el estado y las referencias guardadas (fin o cancelación).
  Future<void> clear() async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      await txn.delete('migration_items');
      await txn.delete('migration_state');
    });
  }

  // ---------------------------------------------------------- referencias

  Future<bool> hasSavedRefs() async {
    final db = await _dbProvider();
    final n = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM migration_items'),
    );
    return (n ?? 0) > 0;
  }

  /// Guarda las referencias antiguas y reinicia las de la nube de los items
  /// para subirlos a la cuenta nueva, todo en una transacción:
  /// * [localItemIds]: tienen su `.vault` en el teléfono -> `pendiente` sin
  ///   referencias a la nube (los sube la sincronización normal, con
  ///   verificación tamaño+MD5).
  /// * el resto (perdidos en la cuenta vieja): `error` sin referencias.
  /// También vacía la cola de sincronización y pasa a [MigrationPhase.uploading].
  Future<void> resetForUpload({
    required Set<String> localItemIds,
    required int now,
  }) async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      final rows = await txn.query('vault_items');
      await txn.delete('migration_items');
      for (final r in rows) {
        final id = r['id'] as String;
        await txn.insert('migration_items', {
          'itemId': id,
          'oldStatus': r['syncStatus'] as String,
          'oldDriveFileId': r['driveFileId'],
          'oldCloudMd5': r['cloudMd5'],
          'oldCloudSize': r['cloudSize'],
          'oldThumbDriveFileId': r['thumbDriveFileId'],
        });
        await txn.update(
          'vault_items',
          {
            'syncStatus': localItemIds.contains(id)
                ? SyncStatus.pendiente.dbValue
                : SyncStatus.error.dbValue,
            'driveFileId': null,
            'cloudMd5': null,
            'cloudSize': null,
            'thumbDriveFileId': null,
            'cloudAccountTag': null,
            'thumbAccountTag': null,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await txn.delete('sync_queue');
      await txn.update('migration_state', {
        'phase': MigrationPhase.uploading.dbValue,
        'updatedAt': now,
      }, where: 'id = 1');
    });
  }

  /// Deshace [resetForUpload] (cancelación): restaura las referencias de la
  /// cuenta anterior y vacía la cola.
  Future<void> restoreOldRefs({required Set<String> localItemIds}) async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      final rows = await txn.query('migration_items');
      for (final r in rows) {
        final id = r['itemId'] as String;
        final old = SyncStatus.fromDb(r['oldStatus'] as String?);
        // Un item que ya estaba subido vuelve a `en_cache`/`en_nube` según
        // tenga copia local; los demás conservan su estado anterior.
        final status =
            (old == SyncStatus.enNube ||
                old == SyncStatus.enCache ||
                old == SyncStatus.sinConexion)
            ? (localItemIds.contains(id) && old == SyncStatus.enNube
                  ? SyncStatus.enCache
                  : old)
            : old;
        await txn.update(
          'vault_items',
          {
            'syncStatus': status.dbValue,
            'driveFileId': r['oldDriveFileId'],
            'cloudMd5': r['oldCloudMd5'],
            'cloudSize': r['oldCloudSize'],
            'thumbDriveFileId': r['oldThumbDriveFileId'],
            // D75: restauradas pero SIN comprobar: la verificación decide si
            // siguen existiendo en la cuenta de la sesión.
            'cloudAccountTag': null,
            'thumbAccountTag': null,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await txn.delete('sync_queue');
    });
  }

  /// D76 (`abandonStayOnCurrent` con la sesión en OTRA cuenta): termina el
  /// cambio de cuenta conservando las referencias ACTUALES de los items (las
  /// de la cuenta en la que nos quedamos) y sin restaurar nada. Si nunca se
  /// llegó a `resetForUpload` ([markAllUnverified]), las referencias son de
  /// la cuenta anterior: se marcan todas «sin comprobar» (tags a `NULL`) para
  /// que la verificación decida. No borra ninguna fila de `vault_items`.
  Future<void> finishKeepingCurrentRefs({required bool markAllUnverified}) async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      if (markAllUnverified) {
        await txn.update('vault_items', {
          'cloudAccountTag': null,
          'thumbAccountTag': null,
        });
      }
      await txn.delete('migration_items');
      await txn.delete('migration_state');
    });
  }
}
