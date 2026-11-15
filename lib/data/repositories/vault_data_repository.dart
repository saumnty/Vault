import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/folder_model.dart';
import '../models/sync_status.dart';
import '../models/vault_item_model.dart';
import 'vault_database.dart';

/// CRUD de carpetas e items sobre la BD de la bóveda.
///
/// Todas las rutas que entran/salen son RELATIVAS (ver `AppPaths`); insertar un
/// item con ruta absoluta lanza [ArgumentError].
class VaultDataRepository {
  /// [dbProvider] por defecto abre `VaultDatabase.instance` (exige sesión
  /// desbloqueada).
  VaultDataRepository({Future<Database> Function()? dbProvider})
    : _dbProvider = dbProvider ?? (() => VaultDatabase.instance.database);

  final Future<Database> Function() _dbProvider;

  /// F9: se invoca tras CADA cambio de datos que el snapshot de la BD debe
  /// reflejar (items, carpetas, nombres, movidas, borrados, "sin conexión",
  /// ids de Drive). NO se invoca para `syncStatus` ni `lastAccessedAt`
  /// (estado derivado). Estático porque hay varias instancias del repositorio
  /// y la app tiene un único `SyncService`.
  static void Function()? onDataChanged;

  void _changed() {
    try {
      onDataChanged?.call();
    } on Object {
      // Nunca debe romper la operación de datos.
    }
  }

  // ---------------------------------------------------------------- carpetas

  Future<void> createFolder(FolderModel folder) async {
    final db = await _dbProvider();
    await db.insert('folders', folder.toMap());
    _changed();
  }

  Future<FolderModel?> getFolder(String id) async {
    final db = await _dbProvider();
    final rows = await db.query('folders', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : FolderModel.fromMap(rows.first);
  }

  /// Subcarpetas de [parentId] (`null` = raíz), más recientes primero.
  Future<List<FolderModel>> getFoldersByParent(String? parentId) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'folders',
      where: parentId == null ? 'parentId IS NULL' : 'parentId = ?',
      whereArgs: parentId == null ? null : [parentId],
      orderBy: 'createdAt DESC',
    );
    return rows.map(FolderModel.fromMap).toList();
  }

  Future<void> renameFolder(String id, String name) async {
    final db = await _dbProvider();
    await db.update(
      'folders',
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  /// Mueve una carpeta. Lanza [ArgumentError] si el destino es ella misma o
  /// una de sus descendientes (ciclo).
  Future<void> moveFolder(String id, String? newParentId) async {
    final db = await _dbProvider();
    if (newParentId != null) {
      final descendants = await _descendantFolderIds(db, id);
      if (newParentId == id || descendants.contains(newParentId)) {
        throw ArgumentError('No se puede mover una carpeta dentro de sí misma');
      }
    }
    await db.update(
      'folders',
      {'parentId': newParentId},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  Future<void> setFolderOffline(String id, bool isOffline) async {
    final db = await _dbProvider();
    await db.update(
      'folders',
      {'isOffline': isOffline ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  /// Ruta de migas de pan: de la raíz hasta [folderId] INCLUIDA (la última es
  /// la propia carpeta). Los ancestros son todos menos la última. Vacía si la
  /// carpeta no existe.
  Future<List<FolderModel>> getBreadcrumbs(String folderId) async {
    final db = await _dbProvider();
    final rows = await db.rawQuery(
      '''
      WITH RECURSIVE chain(id, name, parentId, createdAt, isOffline, depth) AS (
        SELECT id, name, parentId, createdAt, isOffline, 0
          FROM folders WHERE id = ?
        UNION ALL
        SELECT f.id, f.name, f.parentId, f.createdAt, f.isOffline, c.depth + 1
          FROM folders f JOIN chain c ON f.id = c.parentId
         WHERE c.depth < 1000
      )
      SELECT id, name, parentId, createdAt, isOffline FROM chain
       ORDER BY depth DESC
      ''',
      [folderId],
    );
    return rows.map(FolderModel.fromMap).toList();
  }

  /// Borra la carpeta, sus subcarpetas y todos sus items (transacción).
  /// Devuelve los ids de los items borrados para que el llamador elimine los
  /// archivos (`vault/<id>.vault`, miniaturas, copia en Drive).
  Future<List<String>> deleteFolderRecursive(String folderId) async {
    final db = await _dbProvider();
    final deleted = await db.transaction((txn) async {
      final folderIds = [
        folderId,
        ...await _descendantFolderIds(txn, folderId),
      ];
      final marks = List.filled(folderIds.length, '?').join(',');
      final rows = await txn.rawQuery(
        'SELECT id FROM vault_items WHERE folderId IN ($marks)',
        folderIds,
      );
      final itemIds = rows.map((r) => r['id'] as String).toList();
      await txn.delete(
        'vault_items',
        where: 'folderId IN ($marks)',
        whereArgs: folderIds,
      );
      await txn.delete(
        'folders',
        where: 'id IN ($marks)',
        whereArgs: folderIds,
      );
      return itemIds;
    });
    _changed();
    return deleted;
  }

  Future<List<String>> _descendantFolderIds(
    DatabaseExecutor db,
    String folderId,
  ) async {
    final rows = await db.rawQuery(
      '''
      WITH RECURSIVE sub(id) AS (
        SELECT id FROM folders WHERE parentId = ?
        UNION
        SELECT f.id FROM folders f JOIN sub s ON f.parentId = s.id
      )
      SELECT id FROM sub
      ''',
      [folderId],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  // ------------------------------------------------------------------- items

  Future<void> insertItem(VaultItemModel item) async {
    final map = item.toMap(); // valida rutas relativas antes de tocar la BD
    final db = await _dbProvider();
    await db.insert('vault_items', map);
    _changed();
  }

  Future<VaultItemModel?> getItem(String id) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'vault_items',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : VaultItemModel.fromMap(rows.first);
  }

  /// Items de [folderId] (`null` = raíz), más recientes primero.
  Future<List<VaultItemModel>> getItemsByFolder(String? folderId) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'vault_items',
      where: folderId == null ? 'folderId IS NULL' : 'folderId = ?',
      whereArgs: folderId == null ? null : [folderId],
      orderBy: 'createdAt DESC',
    );
    return rows.map(VaultItemModel.fromMap).toList();
  }

  Future<List<VaultItemModel>> getItemsBySyncStatus(SyncStatus status) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'vault_items',
      where: 'syncStatus = ?',
      whereArgs: [status.dbValue],
      orderBy: 'createdAt ASC',
    );
    return rows.map(VaultItemModel.fromMap).toList();
  }

  /// Items con miniatura cifrada que aún no está verificada en la nube.
  Future<List<VaultItemModel>> getItemsNeedingThumbUpload() async {
    final db = await _dbProvider();
    final rows = await db.query(
      'vault_items',
      where: 'thumbPath IS NOT NULL AND thumbDriveFileId IS NULL',
      orderBy: 'createdAt ASC',
    );
    return rows.map(VaultItemModel.fromMap).toList();
  }

  /// Items con copia local recuperable (estado `en_cache`), el menos usado
  /// recientemente primero (los nunca abiertos van antes).
  Future<List<VaultItemModel>> getCachedItemsLru() async {
    final db = await _dbProvider();
    final rows = await db.query(
      'vault_items',
      where: 'syncStatus = ?',
      whereArgs: [SyncStatus.enCache.dbValue],
      orderBy: 'lastAccessedAt ASC',
    );
    return rows.map(VaultItemModel.fromMap).toList();
  }

  /// Items con copia verificada en la nube (driveFileId + MD5 + tamaño) en
  /// estado `en_nube`, `en_cache` o `sin_conexion`: los únicos que se pueden
  /// descargar de nuevo sin perder datos. (Tras subir, un item queda `en_nube`
  /// CON copia local; tras purgar, `en_nube` SIN ella.)
  Future<List<VaultItemModel>> getCloudVerifiedItems() async {
    final db = await _dbProvider();
    final rows = await db.query(
      'vault_items',
      where:
          'driveFileId IS NOT NULL AND cloudMd5 IS NOT NULL AND '
          'cloudSize IS NOT NULL AND syncStatus IN (?, ?, ?)',
      whereArgs: [
        SyncStatus.enNube.dbValue,
        SyncStatus.enCache.dbValue,
        SyncStatus.sinConexion.dbValue,
      ],
    );
    return rows.map(VaultItemModel.fromMap).toList();
  }

  /// Todos los items de [folderId] y de sus subcarpetas (para encolar el
  /// borrado remoto ANTES de eliminar la carpeta).
  Future<List<VaultItemModel>> getItemsInFolderTree(String folderId) async {
    final db = await _dbProvider();
    final folderIds = [folderId, ...await _descendantFolderIds(db, folderId)];
    final marks = List.filled(folderIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM vault_items WHERE folderId IN ($marks)',
      folderIds,
    );
    return rows.map(VaultItemModel.fromMap).toList();
  }

  Future<void> renameItem(String id, String name) =>
      _updateItem(id, {'name': name});

  /// Mueve un item a otra carpeta (`null` = raíz). [ArgumentError] si la
  /// carpeta destino no existe.
  Future<void> moveItem(String itemId, String? folderId) async {
    if (folderId != null && await getFolder(folderId) == null) {
      throw ArgumentError.value(folderId, 'folderId', 'La carpeta no existe');
    }
    await _updateItem(itemId, {'folderId': folderId});
  }

  Future<void> updateSyncStatus(
    String id,
    SyncStatus status, {
    String? driveFileId,
  }) => _updateItem(id, {
    'syncStatus': status.dbValue,
    'driveFileId': ?driveFileId,
  }, notify: false);

  /// Marca el item como `en_nube` SOLO tras verificar tamaño y MD5 de la
  /// copia remota (F5). Guarda id, MD5 y tamaño verificados.
  Future<void> markCloudVerified(
    String id, {
    required String driveFileId,
    required String md5,
    required int size,
  }) => _updateItem(id, {
    'syncStatus': SyncStatus.enNube.dbValue,
    'driveFileId': driveFileId,
    'cloudMd5': md5,
    'cloudSize': size,
  });

  Future<void> setThumbDriveFileId(String id, String? thumbDriveFileId) =>
      _updateItem(id, {'thumbDriveFileId': thumbDriveFileId});

  Future<void> setDriveFileId(String id, String? driveFileId) =>
      _updateItem(id, {'driveFileId': driveFileId});

  /// [thumbPath] debe ser relativa.
  Future<void> setThumbPath(String id, String? thumbPath) async {
    if (thumbPath != null) {
      // Misma validación que el modelo.
      VaultItemModel(
        id: id,
        name: '',
        encryptedPath: 'x',
        fileSize: 0,
        mimeType: '',
        createdAt: '',
        thumbPath: thumbPath,
      ).toMap();
    }
    await _updateItem(id, {'thumbPath': thumbPath});
  }

  /// Marca el acceso (para LRU). [at] por defecto: ahora.
  Future<void> touchLastAccessed(String id, {DateTime? at}) => _updateItem(id, {
    'lastAccessedAt': (at ?? DateTime.now()).millisecondsSinceEpoch,
  }, notify: false);

  Future<void> setItemOffline(String id, bool isOffline) =>
      _updateItem(id, {'isOffline': isOffline ? 1 : 0});

  Future<void> setItemFavorite(String id, bool isFavorite) =>
      _updateItem(id, {'isFavorite': isFavorite ? 1 : 0});

  Future<void> deleteItem(String id) async {
    final db = await _dbProvider();
    await db.delete('vault_items', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  Future<void> _updateItem(
    String id,
    Map<String, Object?> values, {
    bool notify = true,
  }) async {
    final db = await _dbProvider();
    final n = await db.update(
      'vault_items',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (n == 0) throw StateError('El item $id no existe');
    if (notify) _changed();
  }

  // ------------------------------------------------------- offline heredado

  /// "Offline efectivo": el item está marcado, o alguna carpeta ancestra lo
  /// está. `false` si el item no existe.
  Future<bool> isEffectivelyOffline(String itemId) async {
    final db = await _dbProvider();
    final rows = await db.rawQuery(
      '''
      WITH RECURSIVE anc(id, parentId, isOffline) AS (
        SELECT f.id, f.parentId, f.isOffline FROM folders f
         WHERE f.id = (SELECT folderId FROM vault_items WHERE id = ?)
        UNION
        SELECT f.id, f.parentId, f.isOffline
          FROM folders f JOIN anc a ON f.id = a.parentId
      )
      SELECT
        COALESCE((SELECT isOffline FROM vault_items WHERE id = ?), 0)
        OR EXISTS (SELECT 1 FROM anc WHERE isOffline = 1) AS eff
      ''',
      [itemId, itemId],
    );
    return rows.isNotEmpty && rows.first['eff'] == 1;
  }

  /// "Liberar espacio sin conexión" (F8): quita la marca "sin conexión" de
  /// los items con copia VERIFICADA en la nube y de todas las carpetas (la
  /// marca solo es una promesa de conservar la copia local; no borra nada).
  /// NO toca items `pendiente`, `subiendo` ni `error`: conservan su marca
  /// propia (su copia local sigue siendo la única). Devuelve cuántos items
  /// cambiaron de marca.
  Future<int> clearOfflineFlagsForVerified() async {
    final db = await _dbProvider();
    final changed = await db.update(
      'vault_items',
      {'isOffline': 0},
      where:
          'isOffline = 1 AND driveFileId IS NOT NULL AND cloudMd5 IS NOT NULL '
          'AND cloudSize IS NOT NULL AND syncStatus IN (?, ?, ?)',
      whereArgs: [
        SyncStatus.enNube.dbValue,
        SyncStatus.enCache.dbValue,
        SyncStatus.sinConexion.dbValue,
      ],
    );
    await db.update('folders', {'isOffline': 0}, where: 'isOffline = 1');
    _changed();
    return changed;
  }

  /// Ids de todos los items offline efectivos (propios o por carpeta ancestra).
  Future<Set<String>> getEffectiveOfflineItemIds() async {
    final db = await _dbProvider();
    final rows = await db.rawQuery('''
      WITH RECURSIVE off(id) AS (
        SELECT id FROM folders WHERE isOffline = 1
        UNION
        SELECT f.id FROM folders f JOIN off o ON f.parentId = o.id
      )
      SELECT id FROM vault_items
       WHERE isOffline = 1 OR folderId IN (SELECT id FROM off)
    ''');
    return rows.map((r) => r['id'] as String).toSet();
  }
}
