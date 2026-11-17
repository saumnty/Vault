import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import '../repositories/vault_database.dart';

/// Elemento raíz de la papelera: un archivo, o una carpeta (con todo su
/// contenido, que entró con ella).
class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.isFolder,
    required this.name,
    required this.deletedAt,
    required this.itemCount,
    required this.bytes,
  });

  /// Id del archivo o de la carpeta (= `trashRoot`).
  final String id;
  final bool isFolder;
  final String name;

  /// Epoch ms en que entró a la papelera.
  final int deletedAt;

  /// Archivos que contiene (1 para un archivo).
  final int itemCount;
  final int bytes;
}

/// Acceso a datos de la papelera (v8: `deletedAt` + `trashRoot`).
///
/// * Mover a la papelera NO borra nada: solo marca filas (el archivo local,
///   la copia de Drive y las miniaturas siguen donde estaban).
/// * Una carpeta marca ella, sus subcarpetas y sus archivos con el MISMO
///   `trashRoot` (su id): se restaura o se elimina todo junto.
/// * Lo que ya estaba en la papelera por su cuenta conserva su propia raíz.
class TrashRepository {
  TrashRepository({Future<Database> Function()? dbProvider})
    : _dbProvider = dbProvider ?? (() => VaultDatabase.instance.database);

  final Future<Database> Function() _dbProvider;

  void _changed() {
    try {
      VaultDataRepository.onDataChanged?.call();
    } on Object {
      // nunca rompe la operación
    }
  }

  Future<List<String>> _folderTree(DatabaseExecutor db, String rootId) async {
    final rows = await db.rawQuery(
      '''
      WITH RECURSIVE sub(id) AS (
        SELECT id FROM folders WHERE id = ?
        UNION
        SELECT f.id FROM folders f JOIN sub s ON f.parentId = s.id
      )
      SELECT id FROM sub
      ''',
      [rootId],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  /// Manda un archivo a la papelera. `false` si no existe o ya estaba.
  Future<bool> trashItem(String id, {required int now}) async {
    final db = await _dbProvider();
    final n = await db.update(
      'vault_items',
      {'deletedAt': now, 'trashRoot': id},
      where: 'id = ? AND deletedAt IS NULL',
      whereArgs: [id],
    );
    if (n > 0) _changed();
    return n > 0;
  }

  /// Manda una carpeta (y todo lo que contiene) a la papelera.
  Future<bool> trashFolder(String id, {required int now}) async {
    final db = await _dbProvider();
    final done = await db.transaction((txn) async {
      final root = await txn.query(
        'folders',
        where: 'id = ? AND deletedAt IS NULL',
        whereArgs: [id],
      );
      if (root.isEmpty) return false;
      final ids = await _folderTree(txn, id);
      final marks = List.filled(ids.length, '?').join(',');
      final values = {'deletedAt': now, 'trashRoot': id};
      await txn.update(
        'folders',
        values,
        where: 'id IN ($marks) AND deletedAt IS NULL',
        whereArgs: ids,
      );
      await txn.update(
        'vault_items',
        values,
        where: 'folderId IN ($marks) AND deletedAt IS NULL',
        whereArgs: ids,
      );
      return true;
    });
    if (done) _changed();
    return done;
  }

  /// Raíces de la papelera, las más recientes primero.
  Future<List<TrashEntry>> list() async {
    final db = await _dbProvider();
    final out = <TrashEntry>[];
    final folders = await db.query(
      'folders',
      where: 'deletedAt IS NOT NULL AND trashRoot = id',
    );
    for (final f in folders) {
      final id = f['id'] as String;
      final agg = await db.rawQuery(
        'SELECT COUNT(*) AS n, COALESCE(SUM(fileSize), 0) AS b '
        'FROM vault_items WHERE trashRoot = ?',
        [id],
      );
      out.add(
        TrashEntry(
          id: id,
          isFolder: true,
          name: f['name'] as String,
          deletedAt: f['deletedAt'] as int,
          itemCount: (agg.first['n'] as int?) ?? 0,
          bytes: (agg.first['b'] as int?) ?? 0,
        ),
      );
    }
    final items = await db.query(
      'vault_items',
      where: 'deletedAt IS NOT NULL AND trashRoot = id',
    );
    for (final i in items) {
      out.add(
        TrashEntry(
          id: i['id'] as String,
          isFolder: false,
          name: i['name'] as String,
          deletedAt: i['deletedAt'] as int,
          itemCount: 1,
          bytes: (i['fileSize'] as int?) ?? 0,
        ),
      );
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  Future<int> count() async {
    final db = await _dbProvider();
    final a = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM folders WHERE deletedAt IS NOT NULL '
        'AND trashRoot = id',
      ),
    );
    final b = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM vault_items WHERE deletedAt IS NOT NULL '
        'AND trashRoot = id',
      ),
    );
    return (a ?? 0) + (b ?? 0);
  }

  /// Raíces cuya fecha de entrada es anterior o igual a [cutoffMs].
  Future<List<String>> expiredRoots(int cutoffMs) async {
    final db = await _dbProvider();
    final f = await db.query(
      'folders',
      columns: ['id'],
      where: 'deletedAt IS NOT NULL AND trashRoot = id AND deletedAt <= ?',
      whereArgs: [cutoffMs],
    );
    final i = await db.query(
      'vault_items',
      columns: ['id'],
      where: 'deletedAt IS NOT NULL AND trashRoot = id AND deletedAt <= ?',
      whereArgs: [cutoffMs],
    );
    return [
      for (final r in [...f, ...i]) r['id'] as String,
    ];
  }

  /// Saca de la papelera la raíz [rootId] con todo lo que entró con ella. Si
  /// su carpeta de origen ya no existe (o también está en la papelera) vuelve
  /// a la raíz de la bóveda. Devuelve `false` si no estaba en la papelera.
  Future<bool> restore(String rootId) async {
    final db = await _dbProvider();
    final done = await db.transaction((txn) async {
      final f = await txn.query(
        'folders',
        where: 'id = ? AND trashRoot = id AND deletedAt IS NOT NULL',
        whereArgs: [rootId],
      );
      final it = f.isEmpty
          ? await txn.query(
              'vault_items',
              where: 'id = ? AND trashRoot = id AND deletedAt IS NOT NULL',
              whereArgs: [rootId],
            )
          : const <Map<String, Object?>>[];
      if (f.isEmpty && it.isEmpty) return false;
      final clear = {'deletedAt': null, 'trashRoot': null};
      await txn.update(
        'folders',
        clear,
        where: 'trashRoot = ?',
        whereArgs: [rootId],
      );
      await txn.update(
        'vault_items',
        clear,
        where: 'trashRoot = ?',
        whereArgs: [rootId],
      );
      // ¿El origen sigue disponible?
      final parent = f.isNotEmpty
          ? f.first['parentId'] as String?
          : it.first['folderId'] as String?;
      if (parent != null) {
        final alive = await txn.query(
          'folders',
          columns: ['id'],
          where: 'id = ? AND deletedAt IS NULL',
          whereArgs: [parent],
        );
        if (alive.isEmpty) {
          if (f.isNotEmpty) {
            await txn.update(
              'folders',
              {'parentId': null},
              where: 'id = ?',
              whereArgs: [rootId],
            );
          } else {
            await txn.update(
              'vault_items',
              {'folderId': null},
              where: 'id = ?',
              whereArgs: [rootId],
            );
          }
        }
      }
      return true;
    });
    if (done) _changed();
    return done;
  }

  /// Archivos que entraron con [rootId] (para leer sus ids de Drive ANTES de
  /// borrar las filas).
  Future<List<VaultItemModel>> itemsOf(String rootId) async {
    final db = await _dbProvider();
    final rows = await db.query(
      'vault_items',
      where: 'trashRoot = ?',
      whereArgs: [rootId],
    );
    return rows.map(VaultItemModel.fromMap).toList();
  }

  /// Elimina las filas de la raíz [rootId]. Devuelve los ids de los archivos.
  /// El llamador borra archivos locales y encola el borrado en Drive.
  Future<List<String>> deleteRows(String rootId) async {
    final db = await _dbProvider();
    final ids = await db.transaction((txn) async {
      final rows = await txn.query(
        'vault_items',
        columns: ['id'],
        where: 'trashRoot = ? AND deletedAt IS NOT NULL',
        whereArgs: [rootId],
      );
      await txn.delete(
        'vault_items',
        where: 'trashRoot = ? AND deletedAt IS NOT NULL',
        whereArgs: [rootId],
      );
      await txn.delete(
        'folders',
        where: 'trashRoot = ? AND deletedAt IS NOT NULL',
        whereArgs: [rootId],
      );
      return [for (final r in rows) r['id'] as String];
    });
    _changed();
    return ids;
  }
}
