import 'package:sqflite_sqlcipher/sqflite.dart';

import '../repositories/vault_database.dart';
import 'gallery_import_service.dart';
import 'video_compressor.dart';

/// Estado de un lote de importación (D86).
enum ImportBatchState {
  /// Encolando ids (antes de confirmar). Un lote así tras un cierre se
  /// descarta: el usuario nunca lo confirmó.
  preparing('preparing'),

  /// En marcha (o interrumpido por cierre/bloqueo: se reanuda solo).
  running('running'),

  /// En pausa por el usuario o por falta de espacio: espera a «Reanudar».
  paused('paused'),

  /// Cancelado: lo pendiente no se importa; queda el resumen.
  cancelled('cancelled'),

  /// Todos los archivos en estado final; queda el resumen.
  finished('finished');

  const ImportBatchState(this.db);
  final String db;

  static ImportBatchState fromDb(String? v) => ImportBatchState.values
      .firstWhere((s) => s.db == v, orElse: () => ImportBatchState.paused);

  /// Sigue habiendo trabajo (se puede reanudar).
  bool get isOpen => this == running || this == paused;
}

/// Estado de un archivo de la cola.
enum ImportJobState {
  pending('pending'),

  /// Empezado: [ImportJob.itemId] ya está fijado. Si la app muere aquí, al
  /// reanudar se mira si la fila de ese id llegó a la BD.
  running('running'),
  done('done'),

  /// Ya estaba en la bóveda (dedupe).
  duplicate('duplicate'),
  error('error');

  const ImportJobState(this.db);
  final String db;

  static ImportJobState fromDb(String? v) => ImportJobState.values.firstWhere(
    (s) => s.db == v,
    orElse: () => ImportJobState.pending,
  );

  bool get isFinal => this == done || this == duplicate || this == error;
}

/// Pausa por un motivo del sistema (no del usuario).
enum ImportPauseReason {
  user,
  noSpace;

  static ImportPauseReason? fromDb(String? v) {
    for (final r in values) {
      if (r.name == v) return r;
    }
    return null;
  }
}

class ImportBatch {
  const ImportBatch({
    required this.id,
    required this.state,
    required this.videoQuality,
    this.folderId,
    this.total = 0,
    this.estimatedBytes = 0,
    this.pauseReason,
    this.createdAt = 0,
  });

  final String id;
  final ImportBatchState state;
  final String? folderId;
  final VideoQualityOption videoQuality;
  final int total;
  final int estimatedBytes;
  final ImportPauseReason? pauseReason;
  final int createdAt;

  factory ImportBatch.fromMap(Map<String, Object?> m) => ImportBatch(
    id: m['id'] as String,
    state: ImportBatchState.fromDb(m['state'] as String?),
    folderId: m['folderId'] as String?,
    videoQuality: VideoQualityOption.values.firstWhere(
      (q) => q.name == m['videoQuality'],
      orElse: () => VideoQualityOption.original,
    ),
    total: (m['total'] as int?) ?? 0,
    estimatedBytes: (m['estimatedBytes'] as int?) ?? 0,
    pauseReason: ImportPauseReason.fromDb(m['pauseReason'] as String?),
    createdAt: (m['createdAt'] as int?) ?? 0,
  );
}

class ImportJob {
  const ImportJob({
    required this.batchId,
    required this.seq,
    required this.assetId,
    required this.state,
    this.itemId,
    this.error,
    this.name,
    this.attempts = 0,
  });

  final String batchId;
  final int seq;
  final String assetId;
  final ImportJobState state;
  final String? itemId;
  final ImportErrorCode? error;

  /// Nombre del archivo, solo para mostrar el motivo de un error en pantalla
  /// (la tabla está en la BD cifrada y no sale del teléfono).
  final String? name;
  final int attempts;

  factory ImportJob.fromMap(Map<String, Object?> m) => ImportJob(
    batchId: m['batchId'] as String,
    seq: m['seq'] as int,
    assetId: m['assetId'] as String,
    state: ImportJobState.fromDb(m['state'] as String?),
    itemId: m['itemId'] as String?,
    error: m['error'] == null
        ? null
        : ImportErrorCode.fromDb(m['error'] as String?),
    name: m['name'] as String?,
    attempts: (m['attempts'] as int?) ?? 0,
  );
}

/// Cuentas por estado de un lote.
class ImportCounts {
  const ImportCounts({
    this.pending = 0,
    this.running = 0,
    this.done = 0,
    this.duplicate = 0,
    this.error = 0,
  });

  final int pending;
  final int running;
  final int done;
  final int duplicate;
  final int error;

  int get total => pending + running + done + duplicate + error;
  int get finished => done + duplicate + error;
  int get remaining => pending + running;
}

/// Cola persistente de importación (D86), en la BD cifrada de SU bóveda
/// (`import_batches`, `import_queue`; v12). Escribe directo en la BD: los
/// cambios de la cola no marcan «sucio» el snapshot (la cola no viaja).
class ImportQueueRepository {
  ImportQueueRepository({Future<Database> Function()? dbProvider})
    : _db = dbProvider ?? (() => VaultDatabase.instance.database);

  final Future<Database> Function() _db;

  /// El lote más reciente que no se ha cerrado con «Listo» (cualquiera que
  /// no sea `preparing`), o `null`.
  Future<ImportBatch?> currentBatch() async {
    final db = await _db();
    final rows = await db.query(
      'import_batches',
      where: 'state != ?',
      whereArgs: [ImportBatchState.preparing.db],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : ImportBatch.fromMap(rows.first);
  }

  Future<ImportBatch?> batch(String id) async {
    final db = await _db();
    final rows = await db.query(
      'import_batches',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : ImportBatch.fromMap(rows.first);
  }

  Future<void> createBatch(ImportBatch b, {required int now}) async {
    final db = await _db();
    await db.insert('import_batches', {
      'id': b.id,
      'state': b.state.db,
      'folderId': b.folderId,
      'videoQuality': b.videoQuality.name,
      'total': b.total,
      'estimatedBytes': b.estimatedBytes,
      'pauseReason': b.pauseReason?.name,
      'createdAt': now,
      'updatedAt': now,
    });
  }

  /// Añade [assetIds] a partir de [firstSeq] (en una transacción; un id
  /// repetido en el mismo lote se ignora). Devuelve cuántos entraron.
  Future<int> addJobs(
    String batchId,
    int firstSeq,
    List<String> assetIds,
  ) async {
    final db = await _db();
    var added = 0;
    await db.transaction((txn) async {
      var seq = firstSeq;
      for (final id in assetIds) {
        final n = await txn.rawInsert(
          'INSERT OR IGNORE INTO import_queue (batchId, seq, assetId, state) '
          'VALUES (?, ?, ?, ?)',
          [batchId, seq, id, ImportJobState.pending.db],
        );
        if (n > 0) {
          added++;
          seq++;
        }
      }
    });
    return added;
  }

  Future<void> updateBatch(
    String id, {
    ImportBatchState? state,
    int? total,
    int? estimatedBytes,
    ImportPauseReason? pauseReason,
    bool clearPauseReason = false,
    String? folderId,
    required int now,
  }) async {
    final db = await _db();
    await db.update(
      'import_batches',
      {
        'state': ?state?.db,
        'folderId': ?folderId,
        'total': ?total,
        'estimatedBytes': ?estimatedBytes,
        if (pauseReason != null) 'pauseReason': pauseReason.name,
        if (clearPauseReason) 'pauseReason': null,
        'updatedAt': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Siguiente archivo a procesar: primero uno que quedó `running` (un
  /// cierre a mitad), después el `pending` de menor `seq`. Lee UNA fila.
  Future<ImportJob?> nextJob(String batchId) async {
    final db = await _db();
    final rows = await db.query(
      'import_queue',
      where: 'batchId = ? AND state IN (?, ?)',
      whereArgs: [batchId, ImportJobState.running.db, ImportJobState.pending.db],
      orderBy: "CASE state WHEN 'running' THEN 0 ELSE 1 END, seq",
      limit: 1,
    );
    return rows.isEmpty ? null : ImportJob.fromMap(rows.first);
  }

  /// Marca [seq] en curso con su [itemId] fijado y cuenta el intento
  /// ([ImportJob.attempts] = intentos que NO terminaron limpiamente; con
  /// [resetAttempts] vuelve a 1: el anterior lo cortó un bloqueo).
  Future<void> markRunning(
    String batchId,
    int seq,
    String itemId, {
    bool resetAttempts = false,
    required int now,
  }) async {
    final db = await _db();
    await db.rawUpdate(
      'UPDATE import_queue SET state = ?, itemId = ?, '
      'attempts = ${resetAttempts ? '1' : 'attempts + 1'}, updatedAt = ? '
      'WHERE batchId = ? AND seq = ?',
      [ImportJobState.running.db, itemId, now, batchId, seq],
    );
  }

  Future<void> markFinal(
    String batchId,
    int seq,
    ImportJobState state, {
    String? itemId,
    ImportErrorCode? error,
    String? name,
    required int now,
  }) async {
    assert(state.isFinal);
    final db = await _db();
    await db.update(
      'import_queue',
      {
        'state': state.db,
        'itemId': ?itemId,
        'error': error?.name,
        'name': state == ImportJobState.error ? name : null,
        'updatedAt': now,
      },
      where: 'batchId = ? AND seq = ?',
      whereArgs: [batchId, seq],
    );
  }

  /// Devuelve [seq] a `pending` (pausa o cancelación a mitad): el próximo
  /// intento usará otro id. Terminó limpiamente: los intentos vuelven a 0.
  Future<void> markPending(String batchId, int seq, {required int now}) async {
    final db = await _db();
    await db.update(
      'import_queue',
      {
        'state': ImportJobState.pending.db,
        'itemId': null,
        'attempts': 0,
        'updatedAt': now,
      },
      where: 'batchId = ? AND seq = ?',
      whereArgs: [batchId, seq],
    );
  }

  Future<ImportCounts> counts(String batchId) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM import_queue WHERE batchId = ? '
      'GROUP BY state',
      [batchId],
    );
    int n(ImportJobState s) {
      for (final r in rows) {
        if (r['state'] == s.db) return r['n'] as int;
      }
      return 0;
    }

    return ImportCounts(
      pending: n(ImportJobState.pending),
      running: n(ImportJobState.running),
      done: n(ImportJobState.done),
      duplicate: n(ImportJobState.duplicate),
      error: n(ImportJobState.error),
    );
  }

  /// Archivos con error (para el resumen), como mucho [limit].
  Future<List<ImportJob>> errors(String batchId, {int limit = 50}) async {
    final db = await _db();
    final rows = await db.query(
      'import_queue',
      where: 'batchId = ? AND state = ?',
      whereArgs: [batchId, ImportJobState.error.db],
      orderBy: 'seq',
      limit: limit,
    );
    return [for (final r in rows) ImportJob.fromMap(r)];
  }

  /// Último `seq` usado (para seguir encolando).
  Future<int> maxSeq(String batchId) async {
    final db = await _db();
    final r = await db.rawQuery(
      'SELECT MAX(seq) AS m FROM import_queue WHERE batchId = ?',
      [batchId],
    );
    return (r.first['m'] as int?) ?? -1;
  }

  /// Borra el lote y su cola.
  Future<void> deleteBatch(String batchId) async {
    final db = await _db();
    await db.transaction((txn) async {
      await txn.delete(
        'import_queue',
        where: 'batchId = ?',
        whereArgs: [batchId],
      );
      await txn.delete(
        'import_batches',
        where: 'id = ?',
        whereArgs: [batchId],
      );
    });
  }

  /// Lotes `preparing` (restos de un cierre antes de confirmar).
  Future<List<String>> preparingBatchIds() async {
    final db = await _db();
    final rows = await db.query(
      'import_batches',
      columns: ['id'],
      where: 'state = ?',
      whereArgs: [ImportBatchState.preparing.db],
    );
    return [for (final r in rows) r['id'] as String];
  }

  /// `true` si la carpeta existe y no está en la Papelera.
  Future<bool> folderAlive(String folderId) async {
    final db = await _db();
    final r = await db.query(
      'folders',
      columns: ['id'],
      where: 'id = ? AND deletedAt IS NULL',
      whereArgs: [folderId],
      limit: 1,
    );
    return r.isNotEmpty;
  }

  // ------------------------------------------------------------ dedupe

  /// `true` si existe en `vault_items` una fila con ese id (viva o no).
  Future<bool> itemExists(String itemId) async {
    final db = await _db();
    final r = await db.query(
      'vault_items',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    return r.isNotEmpty;
  }

  /// ¿Hay algún item VIVO (fuera de la Papelera) de ese asset?
  Future<bool> hasLiveItemForAsset(String assetId) async {
    final db = await _db();
    final r = await db.query(
      'vault_items',
      columns: ['id'],
      where: 'sourceAssetId = ? AND deletedAt IS NULL',
      whereArgs: [assetId],
      limit: 1,
    );
    return r.isNotEmpty;
  }

  /// Id de un item VIVO del asset cuya huella del original coincide
  /// (`sourceHash`, o `contentHash` en filas anteriores a v12 / sin
  /// compresión). Lo de la Papelera no cuenta: reimportarlo es lo esperado.
  Future<String?> findDuplicate(String assetId, String sourceHash) async {
    final db = await _db();
    final r = await db.query(
      'vault_items',
      columns: ['id'],
      where:
          'sourceAssetId = ? AND deletedAt IS NULL AND '
          '(sourceHash = ? OR contentHash = ?)',
      whereArgs: [assetId, sourceHash, sourceHash],
      limit: 1,
    );
    return r.isEmpty ? null : r.first['id'] as String;
  }
}
