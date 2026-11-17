import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/vault_item_model.dart';
import '../repositories/vault_data_repository.dart';
import '../repositories/vault_database.dart';

/// Longitud máxima del nombre de una etiqueta.
const int kTagNameMax = 40;

class TagModel {
  const TagModel({required this.id, required this.name, this.itemCount = 0});

  final String id;
  final String name;

  /// Archivos (vivos, no en la papelera) con esta etiqueta.
  final int itemCount;
}

/// El nombre de la etiqueta no es válido (vacío o demasiado largo).
class InvalidTagNameException implements Exception {
  const InvalidTagNameException();
}

/// Ya existe otra etiqueta con ese nombre (sin distinguir mayúsculas).
class DuplicateTagException implements Exception {
  const DuplicateTagException(this.existing);
  final TagModel existing;
}

/// Tipo de archivo para filtrar.
enum KindFilter { photo, video, file }

/// Filtros combinables. Todo lo indicado debe cumplirse (Y):
/// * [text]: el nombre contiene el texto (sin distinguir mayúsculas);
/// * [tagIds]: el archivo tiene TODAS esas etiquetas;
/// * [kind]: foto / video / otro archivo;
/// * [from]/[to]: fecha de importación (día completo, ambos inclusive).
class ItemFilter {
  const ItemFilter({
    this.text = '',
    this.tagIds = const {},
    this.kind,
    this.from,
    this.to,
  });

  final String text;
  final Set<String> tagIds;
  final KindFilter? kind;
  final DateTime? from;
  final DateTime? to;

  /// Hay algún filtro distinto del texto.
  bool get hasFilters =>
      tagIds.isNotEmpty || kind != null || from != null || to != null;

  bool get isEmpty => text.trim().isEmpty && !hasFilters;

  ItemFilter copyWith({
    String? text,
    Set<String>? tagIds,
    KindFilter? Function()? kind,
    DateTime? Function()? from,
    DateTime? Function()? to,
  }) => ItemFilter(
    text: text ?? this.text,
    tagIds: tagIds ?? this.tagIds,
    kind: kind != null ? kind() : this.kind,
    from: from != null ? from() : this.from,
    to: to != null ? to() : this.to,
  );
}

/// Etiquetas por archivo y búsqueda con filtros (v9).
///
/// Las etiquetas viven en la BD cifrada (viajan en el snapshot de Drive y se
/// restauran con él). Borrar una etiqueta no borra archivos.
class TagRepository {
  TagRepository({Future<Database> Function()? dbProvider})
    : _dbProvider = dbProvider ?? (() => VaultDatabase.instance.database);

  final Future<Database> Function() _dbProvider;

  void _changed() {
    try {
      VaultDataRepository.onDataChanged?.call();
    } on Object {
      // nunca rompe la operación
    }
  }

  static String normalize(String name) {
    final n = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (n.isEmpty || n.length > kTagNameMax) {
      throw const InvalidTagNameException();
    }
    return n;
  }

  Future<List<TagModel>> list() async {
    final db = await _dbProvider();
    final rows = await db.rawQuery('''
      SELECT t.id, t.name, COUNT(i.id) AS n
        FROM tags t
        LEFT JOIN item_tags it ON it.tagId = t.id
        LEFT JOIN vault_items i ON i.id = it.itemId AND i.deletedAt IS NULL
       GROUP BY t.id
       ORDER BY t.name COLLATE NOCASE
    ''');
    return [
      for (final r in rows)
        TagModel(
          id: r['id'] as String,
          name: r['name'] as String,
          itemCount: (r['n'] as int?) ?? 0,
        ),
    ];
  }

  Future<TagModel?> _byName(DatabaseExecutor db, String name) async {
    final rows = await db.query(
      'tags',
      where: 'name = ? COLLATE NOCASE',
      whereArgs: [name],
    );
    if (rows.isEmpty) return null;
    return TagModel(
      id: rows.first['id'] as String,
      name: rows.first['name'] as String,
    );
  }

  /// Crea una etiqueta. [DuplicateTagException] si ya existe (sin distinguir
  /// mayúsculas); [InvalidTagNameException] si el nombre no vale.
  Future<TagModel> create(String name) async {
    final n = normalize(name);
    final db = await _dbProvider();
    final dup = await _byName(db, n);
    if (dup != null) throw DuplicateTagException(dup);
    final id = const Uuid().v4();
    await db.insert('tags', {
      'id': id,
      'name': n,
      'createdAt': DateTime.now().toIso8601String(),
    });
    _changed();
    return TagModel(id: id, name: n);
  }

  Future<void> rename(String id, String name) async {
    final n = normalize(name);
    final db = await _dbProvider();
    final dup = await _byName(db, n);
    if (dup != null && dup.id != id) throw DuplicateTagException(dup);
    await db.update('tags', {'name': n}, where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Borra la etiqueta y sus asignaciones (no los archivos).
  Future<void> delete(String id) async {
    final db = await _dbProvider();
    await db.transaction((txn) async {
      await txn.delete('item_tags', where: 'tagId = ?', whereArgs: [id]);
      await txn.delete('tags', where: 'id = ?', whereArgs: [id]);
    });
    _changed();
  }

  Future<List<TagModel>> tagsOfItem(String itemId) async {
    final db = await _dbProvider();
    final rows = await db.rawQuery(
      '''
      SELECT t.id, t.name FROM tags t
        JOIN item_tags it ON it.tagId = t.id
       WHERE it.itemId = ?
       ORDER BY t.name COLLATE NOCASE
      ''',
      [itemId],
    );
    return [
      for (final r in rows)
        TagModel(id: r['id'] as String, name: r['name'] as String),
    ];
  }

  /// Etiquetas de varios archivos a la vez: itemId -> etiquetas.
  Future<Map<String, List<TagModel>>> tagsOfItems(
    Iterable<String> itemIds,
  ) async {
    final ids = itemIds.toList();
    if (ids.isEmpty) return {};
    final db = await _dbProvider();
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT it.itemId AS itemId, t.id AS id, t.name AS name
        FROM item_tags it JOIN tags t ON t.id = it.tagId
       WHERE it.itemId IN ($marks)
       ORDER BY t.name COLLATE NOCASE
      ''', ids);
    final out = <String, List<TagModel>>{};
    for (final r in rows) {
      out
          .putIfAbsent(r['itemId'] as String, () => [])
          .add(TagModel(id: r['id'] as String, name: r['name'] as String));
    }
    return out;
  }

  /// Añade [tagId] a todos los [itemIds] (idempotente).
  Future<void> addTag(Iterable<String> itemIds, String tagId) async {
    final db = await _dbProvider();
    final batch = db.batch();
    for (final id in itemIds) {
      batch.insert('item_tags', {
        'itemId': id,
        'tagId': tagId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
    _changed();
  }

  Future<void> removeTag(Iterable<String> itemIds, String tagId) async {
    final ids = itemIds.toList();
    if (ids.isEmpty) return;
    final db = await _dbProvider();
    final marks = List.filled(ids.length, '?').join(',');
    await db.delete(
      'item_tags',
      where: 'tagId = ? AND itemId IN ($marks)',
      whereArgs: [tagId, ...ids],
    );
    _changed();
  }

  /// Inicio de día como texto comparable con `createdAt` (ISO 8601 con o sin
  /// fracción): `AAAA-MM-DDT00:00:00` (sin `.000`, que ordenaría después).
  static String _dayStart(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}'
        'T00:00:00';
  }

  /// Escapa `%`, `_` y `\` para usar el texto en un `LIKE ... ESCAPE '\'`.
  static String likeEscape(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// Archivos (vivos, de TODAS las carpetas) que cumplen [filter], los más
  /// recientes primero. Con un filtro vacío devuelve todos.
  Future<List<VaultItemModel>> search(
    ItemFilter filter, {
    bool Function(VaultItemModel item)? kindMatcher,
  }) async {
    final db = await _dbProvider();
    final where = <String>['i.deletedAt IS NULL'];
    final args = <Object?>[];
    final text = filter.text.trim();
    if (text.isNotEmpty) {
      where.add(r"i.name LIKE ? ESCAPE '\' COLLATE NOCASE");
      args.add('%${likeEscape(text)}%');
    }
    if (filter.from != null) {
      final d = filter.from!;
      where.add('i.createdAt >= ?');
      args.add(_dayStart(DateTime(d.year, d.month, d.day)));
    }
    if (filter.to != null) {
      final d = filter.to!;
      where.add('i.createdAt < ?');
      args.add(_dayStart(DateTime(d.year, d.month, d.day + 1)));
    }
    if (filter.tagIds.isNotEmpty) {
      final marks = List.filled(filter.tagIds.length, '?').join(',');
      where.add('''
        (SELECT COUNT(DISTINCT it.tagId) FROM item_tags it
          WHERE it.itemId = i.id AND it.tagId IN ($marks)) = ?
      ''');
      args
        ..addAll(filter.tagIds)
        ..add(filter.tagIds.length);
    }
    final rows = await db.rawQuery(
      'SELECT i.* FROM vault_items i WHERE ${where.join(' AND ')} '
      'ORDER BY i.createdAt DESC',
      args,
    );
    var items = rows.map(VaultItemModel.fromMap).toList();
    final k = filter.kind;
    if (k != null && kindMatcher != null) {
      items = items.where(kindMatcher).toList();
    }
    return items;
  }
}
