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
/// * [text]: el nombre del archivo O el nombre de alguna de sus etiquetas
///   contiene el texto (sin distinguir mayúsculas ni acentos, v2.1 D85);
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

  /// Minúsculas y sin acentos, para comparar texto escrito por el usuario
  /// (`Canción` == `cancion`). `ñ` se trata como letra distinta de `n`.
  static String fold(String s) {
    final lower = s.toLowerCase();
    final b = StringBuffer();
    for (final r in lower.runes) {
      if (r >= 0x300 && r <= 0x36F) continue; // marca combinante suelta
      final c = String.fromCharCode(r);
      b.write(_foldMap[c] ?? c);
    }
    return b.toString();
  }

  static const Map<String, String> _foldMap = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'ý': 'y',
    'ÿ': 'y',
  };

  /// Ids de los archivos vivos (no en la Papelera) con alguna etiqueta cuyo
  /// nombre contiene [text] (sin mayúsculas ni acentos). Vacío si [text] lo
  /// está.
  Future<Set<String>> itemIdsByTagText(String text) async {
    final q = fold(text.trim());
    if (q.isEmpty) return const {};
    final db = await _dbProvider();
    final tags = await db.query('tags', columns: ['id', 'name']);
    final tagIds = [
      for (final t in tags)
        if (fold(t['name'] as String).contains(q)) t['id'] as String,
    ];
    if (tagIds.isEmpty) return const {};
    final marks = List.filled(tagIds.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT DISTINCT it.itemId AS id FROM item_tags it
        JOIN vault_items i ON i.id = it.itemId AND i.deletedAt IS NULL
       WHERE it.tagId IN ($marks)
      ''', tagIds);
    return {for (final r in rows) r['id'] as String};
  }

  /// Archivos (vivos, de TODAS las carpetas) que cumplen [filter], los más
  /// recientes primero. Con un filtro vacío devuelve todos.
  Future<List<VaultItemModel>> search(
    ItemFilter filter, {
    bool Function(VaultItemModel item)? kindMatcher,
  }) async {
    final db = await _dbProvider();
    final where = <String>['i.deletedAt IS NULL'];
    final args = <Object?>[];
    // El texto se compara en Dart (sin acentos): se piden los nombres de las
    // etiquetas junto a cada archivo, solo si hay texto.
    final text = fold(filter.text.trim());
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
    final tagNames = text.isEmpty
        ? ''
        : ", (SELECT group_concat(t.name, char(10)) FROM item_tags it "
              'JOIN tags t ON t.id = it.tagId WHERE it.itemId = i.id) '
              'AS matchTagNames';
    var rows = await db.rawQuery(
      'SELECT i.*$tagNames FROM vault_items i WHERE ${where.join(' AND ')} '
      'ORDER BY i.createdAt DESC',
      args,
    );
    if (text.isNotEmpty) {
      rows = rows.where((r) {
        if (fold(r['name'] as String? ?? '').contains(text)) return true;
        final names = r['matchTagNames'] as String?;
        if (names == null) return false;
        return names.split('\n').any((n) => fold(n).contains(text));
      }).toList();
    }
    var items = rows.map(VaultItemModel.fromMap).toList();
    final k = filter.kind;
    if (k != null && kindMatcher != null) {
      items = items.where(kindMatcher).toList();
    }
    return items;
  }
}
