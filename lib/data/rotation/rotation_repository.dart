import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/services/app_paths.dart';
import '../repositories/vault_database.dart';

/// Fila de `rotation_state` (§2.2): la rotación tal como la ve la BD. Ata la
/// BD a la rotación del almacén seguro (A3: `rotationId`) y guarda la
/// cardinalidad congelada y las huellas del conjunto viejo de Drive (A5).
class RotationDbState {
  const RotationDbState({
    required this.rotationId,
    required this.fromGen,
    required this.toGen,
    required this.frozenAt,
    required this.frozenItems,
    required this.frozenFolders,
    required this.itemsInserted,
    required this.itemsDeleted,
    required this.foldersInserted,
    required this.foldersDeleted,
    this.oldBackupDriveId,
    this.oldBackupMd5,
    this.oldSnapshotDriveId,
    this.oldSnapshotMd5,
    this.bridgeDriveId,
  });

  factory RotationDbState.fromMap(Map<String, Object?> m) => RotationDbState(
    rotationId: m['rotationId'] as String,
    fromGen: m['fromGen'] as int,
    toGen: m['toGen'] as int,
    frozenAt: m['frozenAt'] as int,
    frozenItems: m['frozenItems'] as int,
    frozenFolders: m['frozenFolders'] as int,
    itemsInserted: m['itemsInserted'] as int,
    itemsDeleted: m['itemsDeleted'] as int,
    foldersInserted: m['foldersInserted'] as int,
    foldersDeleted: m['foldersDeleted'] as int,
    oldBackupDriveId: m['oldBackupDriveId'] as String?,
    oldBackupMd5: m['oldBackupMd5'] as String?,
    oldSnapshotDriveId: m['oldSnapshotDriveId'] as String?,
    oldSnapshotMd5: m['oldSnapshotMd5'] as String?,
    bridgeDriveId: m['bridgeDriveId'] as String?,
  );

  final String rotationId;
  final int fromGen;
  final int toGen;
  final int frozenAt;
  final int frozenItems;
  final int frozenFolders;
  final int itemsInserted;
  final int itemsDeleted;
  final int foldersInserted;
  final int foldersDeleted;
  final String? oldBackupDriveId;
  final String? oldBackupMd5;
  final String? oldSnapshotDriveId;
  final String? oldSnapshotMd5;
  final String? bridgeDriveId;

  int get expectedItems => frozenItems + itemsInserted - itemsDeleted;
  int get expectedFolders => frozenFolders + foldersInserted - foldersDeleted;
}

/// Un archivo del conjunto VIEJO de Drive (lista exacta, A5).
class RotationOldFile {
  const RotationOldFile({
    required this.driveId,
    required this.name,
    required this.kind,
    this.md5,
    this.itemId,
    this.quarantine = false,
  });

  factory RotationOldFile.fromMap(Map<String, Object?> m) => RotationOldFile(
    driveId: m['driveId'] as String,
    name: m['name'] as String,
    kind: m['kind'] as String,
    md5: m['md5'] as String?,
    itemId: m['itemId'] as String?,
    quarantine: (m['quarantine'] as int? ?? 0) == 1,
  );

  final String driveId;
  final String name;

  /// `backup` | `bridge` | `snapshot` | `file` | `thumb`.
  final String kind;
  final String? md5;
  final String? itemId;
  final bool quarantine;
}

/// Lado BD de la rotación de la DEK: `rotation_state`, `rotation_old_files`
/// y los triggers de cardinalidad (§2.2). Todo vive en la BD cifrada y viaja
/// con ella al re-cifrarla.
class RotationRepository {
  RotationRepository({Future<Database> Function()? dbProvider})
    : _dbProvider = dbProvider ?? (() => VaultDatabase.instance.database);

  final Future<Database> Function() _dbProvider;

  static const String _triggers = '''
CREATE TRIGGER IF NOT EXISTS rot_items_ins AFTER INSERT ON vault_items BEGIN
  UPDATE rotation_state SET itemsInserted = itemsInserted + 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS rot_items_del AFTER DELETE ON vault_items BEGIN
  UPDATE rotation_state SET itemsDeleted = itemsDeleted + 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS rot_folders_ins AFTER INSERT ON folders BEGIN
  UPDATE rotation_state SET foldersInserted = foldersInserted + 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS rot_folders_del AFTER DELETE ON folders BEGIN
  UPDATE rotation_state SET foldersDeleted = foldersDeleted + 1 WHERE id = 1; END;
''';

  Future<RotationDbState?> load() async {
    final db = await _dbProvider();
    final rows = await db.query('rotation_state', where: 'id = 1');
    return rows.isEmpty ? null : RotationDbState.fromMap(rows.first);
  }

  /// Congela (§3 freezing c): en UNA transacción cuenta items y carpetas,
  /// crea la fila con [rotationId] y los triggers. Idempotente para el mismo
  /// [rotationId]; devuelve `false` si ya hay una fila de OTRA rotación.
  Future<bool> freeze({
    required String rotationId,
    required int fromGen,
    required int toGen,
    required int nowMs,
  }) async {
    final db = await _dbProvider();
    return db.transaction((txn) async {
      final rows = await txn.query('rotation_state', where: 'id = 1');
      if (rows.isNotEmpty) return rows.first['rotationId'] == rotationId;
      final items =
          (await txn.rawQuery(
                'SELECT COUNT(*) AS n FROM vault_items',
              )).first['n']
              as int;
      final folders =
          (await txn.rawQuery('SELECT COUNT(*) AS n FROM folders')).first['n']
              as int;
      await txn.insert('rotation_state', {
        'id': 1,
        'rotationId': rotationId,
        'fromGen': fromGen,
        'toGen': toGen,
        'frozenAt': nowMs,
        'frozenItems': items,
        'frozenFolders': folders,
      });
      for (final stmt in _triggers.split('END;')) {
        if (stmt.trim().isEmpty) continue;
        await txn.execute('$stmt END;');
      }
      return true;
    });
  }

  Future<void> setFingerprints({
    String? oldBackupDriveId,
    String? oldBackupMd5,
    String? oldSnapshotDriveId,
    String? oldSnapshotMd5,
    String? bridgeDriveId,
  }) async {
    final db = await _dbProvider();
    await db.update('rotation_state', {
      'oldBackupDriveId': ?oldBackupDriveId,
      'oldBackupMd5': ?oldBackupMd5,
      'oldSnapshotDriveId': ?oldSnapshotDriveId,
      'oldSnapshotMd5': ?oldSnapshotMd5,
      'bridgeDriveId': ?bridgeDriveId,
    }, where: 'id = 1');
  }

  /// Rehace la lista exacta del conjunto viejo (§3 freezing f). Conserva las
  /// marcas de cuarentena de lo que ya estaba.
  Future<void> replaceOldFiles(List<RotationOldFile> files) async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      final quarantined = {
        for (final r in await txn.query(
          'rotation_old_files',
          where: 'quarantine = 1',
        ))
          r['driveId'],
      };
      await txn.delete('rotation_old_files');
      for (final f in files) {
        await txn.insert('rotation_old_files', {
          'driveId': f.driveId,
          'name': f.name,
          'md5': f.md5,
          'itemId': f.itemId,
          'kind': f.kind,
          'quarantine': quarantined.contains(f.driveId) || f.quarantine ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<RotationOldFile>> oldFiles() async {
    final db = await _dbProvider();
    return [
      for (final r in await db.query('rotation_old_files'))
        RotationOldFile.fromMap(r),
    ];
  }

  /// M6: el blob viejo de [itemId] no se borra (se renombra a `lost_*`).
  Future<void> quarantineItem(String itemId) async {
    final db = await _dbProvider();
    await db.update(
      'rotation_old_files',
      {'quarantine': 1},
      where: "itemId = ? AND kind = 'file'",
      whereArgs: [itemId],
    );
  }

  /// M6 ("Omitir"): el item queda PERDIDO en la generación nueva (`error`,
  /// sin archivo ni copia en la nube) y sin trabajos de subida. Solo si
  /// sigue en [fromGen].
  Future<void> markItemLost(
    String itemId, {
    required int fromGen,
    required int toGen,
  }) async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      final n = await txn.update(
        'vault_items',
        {
          'keyGen': toGen,
          'encryptedPath': AppPaths.vaultRelativePath(itemId, gen: toGen),
          'thumbPath': null,
          'thumbFileId': null,
          'driveFileId': null,
          'cloudMd5': null,
          'cloudSize': null,
          'thumbDriveFileId': null,
          'syncStatus': 'error',
        },
        where: 'id = ? AND keyGen = ?',
        whereArgs: [itemId, fromGen],
      );
      if (n == 0) return;
      await txn.delete(
        'sync_queue',
        where: "itemId = ? AND kind IN ('file', 'thumb')",
        whereArgs: [itemId],
      );
    });
  }

  /// Ids de items en cuarentena.
  Future<Set<String>> quarantinedItemIds() async {
    final db = await _dbProvider();
    return {
      for (final r in await db.query(
        'rotation_old_files',
        columns: ['itemId'],
        where: 'quarantine = 1 AND itemId IS NOT NULL',
      ))
        r['itemId'] as String,
    };
  }

  Future<void> removeOldFile(String driveId) async {
    final db = await _dbProvider();
    await db.delete(
      'rotation_old_files',
      where: 'driveId = ?',
      whereArgs: [driveId],
    );
  }

  /// Cuentas actuales (para la guarda de cardinalidad, C1).
  Future<(int, int)> counts() async {
    final db = await _dbProvider();
    final items =
        (await db.rawQuery('SELECT COUNT(*) AS n FROM vault_items')).first['n']
            as int;
    final folders =
        (await db.rawQuery('SELECT COUNT(*) AS n FROM folders')).first['n']
            as int;
    return (items, folders);
  }

  /// Quita triggers, la fila y la lista (cancelar o terminar).
  Future<void> clear() async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      for (final t in VaultSchema.rotationTriggerNames) {
        await txn.execute('DROP TRIGGER IF EXISTS $t');
      }
      await txn.delete('rotation_old_files');
      await txn.delete('rotation_state');
    });
  }
}
