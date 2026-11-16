import 'package:sqflite_sqlcipher/sqflite.dart';

import '../repositories/vault_database.dart';

/// Qué se sube.
enum SyncJobKind {
  file('file'),
  thumb('thumb'),
  dbSnapshot('db_snapshot'),
  recoveryBackup('recovery_backup'),

  /// F6a: borrar de Drive la copia de un item eliminado. El `payload` guarda
  /// los ids remotos (la fila del item ya no existe en la BD).
  deleteRemote('delete_remote');

  const SyncJobKind(this.dbValue);
  final String dbValue;

  static SyncJobKind fromDb(String v) =>
      values.firstWhere((k) => k.dbValue == v);

  /// Orden de proceso: el respaldo de recuperación primero (es lo que evita
  /// perder la bóveda), el snapshot al final.
  int get priority => switch (this) {
    recoveryBackup => 0,
    deleteRemote => 1,
    file => 2,
    thumb => 3,
    dbSnapshot => 4,
  };
}

enum SyncJobState {
  pendiente('pendiente'),
  subiendo('subiendo'),
  error('error');

  const SyncJobState(this.dbValue);
  final String dbValue;

  static SyncJobState fromDb(String v) =>
      values.firstWhere((s) => s.dbValue == v);
}

/// Fila de la cola de sincronización.
class SyncJob {
  const SyncJob({
    required this.id,
    required this.itemId,
    required this.kind,
    required this.state,
    required this.attempts,
    required this.nextAttemptAt,
    required this.createdAt,
    this.lastError,
    this.payload,
  });

  final int id;

  /// Id del item, o [SyncQueueRepository.noItem] para respaldos.
  final String itemId;
  final SyncJobKind kind;
  final SyncJobState state;
  final int attempts;

  /// Epoch ms a partir del cual se puede reintentar.
  final int nextAttemptAt;
  final String? lastError;
  final int createdAt;

  /// Datos propios del trabajo (JSON); hoy solo `delete_remote`.
  final String? payload;

  factory SyncJob.fromMap(Map<String, Object?> m) => SyncJob(
    id: m['id'] as int,
    itemId: m['itemId'] as String,
    kind: SyncJobKind.fromDb(m['kind'] as String),
    state: SyncJobState.fromDb(m['state'] as String),
    attempts: m['attempts'] as int,
    nextAttemptAt: m['nextAttemptAt'] as int,
    lastError: m['lastError'] as String?,
    createdAt: m['createdAt'] as int,
    payload: m['payload'] as String?,
  );
}

/// Conteos de la cola (para la UI).
class SyncCounts {
  const SyncCounts({this.pending = 0, this.uploading = 0, this.errors = 0});
  final int pending;
  final int uploading;
  final int errors;

  int get total => pending + uploading + errors;

  @override
  bool operator ==(Object other) =>
      other is SyncCounts &&
      other.pending == pending &&
      other.uploading == uploading &&
      other.errors == errors;

  @override
  int get hashCode => Object.hash(pending, uploading, errors);
}

/// Acceso a la tabla `sync_queue` (SQLCipher).
class SyncQueueRepository {
  SyncQueueRepository({Future<Database> Function()? dbProvider})
    : _dbProvider = dbProvider ?? (() => VaultDatabase.instance.database);

  final Future<Database> Function() _dbProvider;

  /// `itemId` de los trabajos que no pertenecen a un item.
  static const String noItem = '_';

  /// Encola (si ya existe la fila, no hace nada). Devuelve `true` si insertó.
  Future<bool> enqueue(
    String itemId,
    SyncJobKind kind, {
    required int now,
    String? payload,
  }) async {
    final db = await _dbProvider();
    final id = await db.insert('sync_queue', {
      'payload': payload,
      'itemId': itemId,
      'kind': kind.dbValue,
      'state': SyncJobState.pendiente.dbValue,
      'attempts': 0,
      'nextAttemptAt': 0,
      'createdAt': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return id > 0;
  }

  Future<SyncJob?> get(int id) async {
    final db = await _dbProvider();
    final rows = await db.query('sync_queue', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : SyncJob.fromMap(rows.first);
  }

  Future<SyncJob?> find(String itemId, SyncJobKind kind) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'sync_queue',
      where: 'itemId = ? AND kind = ?',
      whereArgs: [itemId, kind.dbValue],
    );
    return rows.isEmpty ? null : SyncJob.fromMap(rows.first);
  }

  Future<List<SyncJob>> all() async {
    final db = await _dbProvider();
    final rows = await db.query('sync_queue', orderBy: 'createdAt, id');
    return rows.map(SyncJob.fromMap).toList();
  }

  /// Siguiente trabajo `pendiente` ya vencido ([now] >= nextAttemptAt), por
  /// prioridad de tipo y antigüedad. `null` si no hay.
  Future<SyncJob?> nextDue(int now, {Set<int> skip = const {}}) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'sync_queue',
      where: 'state = ? AND nextAttemptAt <= ?',
      whereArgs: [SyncJobState.pendiente.dbValue, now],
      orderBy: 'createdAt, id',
    );
    SyncJob? best;
    for (final r in rows) {
      final job = SyncJob.fromMap(r);
      if (skip.contains(job.id)) continue;
      if (best == null || job.kind.priority < best.kind.priority) best = job;
    }
    return best;
  }

  /// Menor `nextAttemptAt` de los pendientes aplazados (para programar el
  /// próximo intento), o `null`.
  Future<int?> earliestPendingAt() async {
    final db = await _dbProvider();
    final rows = await db.rawQuery(
      'SELECT MIN(nextAttemptAt) AS t FROM sync_queue WHERE state = ?',
      [SyncJobState.pendiente.dbValue],
    );
    return rows.first['t'] as int?;
  }

  Future<void> markUploading(int id) async {
    final db = await _dbProvider();
    await db.update(
      'sync_queue',
      {'state': SyncJobState.subiendo.dbValue},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Vuelve a pendiente con los [attempts] y la espera dadas.
  Future<void> markPending(
    int id, {
    required int attempts,
    required int nextAttemptAt,
    String? lastError,
  }) async {
    final db = await _dbProvider();
    await db.update(
      'sync_queue',
      {
        'state': SyncJobState.pendiente.dbValue,
        'attempts': attempts,
        'nextAttemptAt': nextAttemptAt,
        'lastError': lastError,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markError(int id, {required int attempts, String? error}) async {
    final db = await _dbProvider();
    await db.update(
      'sync_queue',
      {
        'state': SyncJobState.error.dbValue,
        'attempts': attempts,
        'lastError': error,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> remove(int id) async {
    final db = await _dbProvider();
    await db.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> removeForItem(String itemId) async {
    final db = await _dbProvider();
    // Los borrados remotos NO se quitan: son justo lo que sigue al borrar.
    await db.delete(
      'sync_queue',
      where: 'itemId = ? AND kind != ?',
      whereArgs: [itemId, SyncJobKind.deleteRemote.dbValue],
    );
  }

  /// Reanudación tras cierre/bloqueo: lo que quedó `subiendo` vuelve a
  /// `pendiente` (sin contar intento). Devuelve cuántos.
  Future<int> resetStuck() async {
    final db = await _dbProvider();
    return db.update(
      'sync_queue',
      {'state': SyncJobState.pendiente.dbValue},
      where: 'state = ?',
      whereArgs: [SyncJobState.subiendo.dbValue],
    );
  }

  /// Reintento manual: errores (o [onlyId]) vuelven a pendiente, intentos a 0
  /// y sin espera. Devuelve cuántos. Si [onlyId] es null también quita la
  /// espera de los pendientes ("Sincronizar ahora").
  Future<int> retryErrors({int? onlyId}) async {
    final db = await _dbProvider();
    return db.update(
      'sync_queue',
      {
        'state': SyncJobState.pendiente.dbValue,
        'attempts': 0,
        'nextAttemptAt': 0,
        'lastError': null,
      },
      where: onlyId == null ? 'state = ?' : 'id = ?',
      whereArgs: [onlyId ?? SyncJobState.error.dbValue],
    );
  }

  /// "Sincronizar ahora": los pendientes aplazados por backoff se adelantan.
  /// Vacía la cola entera (cambio de cuenta: los ids de la cuenta vieja no
  /// valen en la nueva).
  Future<void> clearAll() async {
    final db = await _dbProvider();
    await db.delete('sync_queue');
  }

  Future<void> clearBackoff() async {
    final db = await _dbProvider();
    await db.update(
      'sync_queue',
      {'nextAttemptAt': 0},
      where: 'state = ?',
      whereArgs: [SyncJobState.pendiente.dbValue],
    );
  }

  Future<SyncCounts> counts() async {
    final db = await _dbProvider();
    final rows = await db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM sync_queue GROUP BY state',
    );
    var p = 0, u = 0, e = 0;
    for (final r in rows) {
      final n = r['n'] as int;
      switch (SyncJobState.fromDb(r['state'] as String)) {
        case SyncJobState.pendiente:
          p = n;
        case SyncJobState.subiendo:
          u = n;
        case SyncJobState.error:
          e = n;
      }
    }
    return SyncCounts(pending: p, uploading: u, errors: e);
  }

  Future<List<SyncJob>> errors({int limit = 5}) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'sync_queue',
      where: 'state = ?',
      whereArgs: [SyncJobState.error.dbValue],
      orderBy: 'createdAt, id',
      limit: limit,
    );
    return rows.map(SyncJob.fromMap).toList();
  }
}
