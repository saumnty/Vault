import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/vault_log.dart';
import '../../core/theme/app_spacing.dart';
import '../../data/models/folder_model.dart';
import '../../data/models/vault_item_model.dart';
import '../../data/sync/sync_service.dart';
import 'models/browser_entry.dart';
import 'vault_services.dart';

/// Estado y operaciones de una carpeta de la bóveda (la UI solo pinta).
class VaultBrowserController extends ChangeNotifier {
  VaultBrowserController({
    required this.services,
    required this.folderId,
    int columns = AppGrid.defaultColumns,
  }) : _columns = columns.clamp(AppGrid.minColumns, AppGrid.maxColumns) {
    // F5: cuando cambia la cola (un item pasa a en_nube/error...) se recarga
    // en silencio para que los íconos de estado se actualicen solos.
    final sync = services.sync;
    if (sync != null) {
      _lastSync = sync.summary.value;
      sync.summary.addListener(_onSyncChanged);
    }
  }

  SyncSummary? _lastSync;

  void _onSyncChanged() {
    final now = services.sync?.summary.value;
    final before = _lastSync;
    _lastSync = now;
    if (_disposed || now == null || before == null) return;
    if (now.counts != before.counts ||
        (before.phase == SyncPhase.running && now.phase != SyncPhase.running)) {
      load(silent: true);
    }
  }

  final VaultServices services;
  final String? folderId;

  List<FolderEntry> _folders = const [];
  List<FileEntry> _files = const [];
  List<FolderModel> _breadcrumbs = const [];
  final Set<String> _selection = {};
  bool _isLoading = true;
  Object? _error;
  String _query = '';
  int _columns;
  bool _disposed = false;

  bool get isLoading => _isLoading;
  Object? get error => _error;
  int get columns => _columns;
  String get query => _query;

  /// Cadena de carpetas de la raíz a la actual (vacía en la raíz).
  List<FolderModel> get breadcrumbs => _breadcrumbs;

  /// Carpetas primero, luego archivos; filtrado por la búsqueda.
  List<BrowserEntry> get entries {
    final q = _query.trim().toLowerCase();
    bool match(BrowserEntry e) => q.isEmpty || e.name.toLowerCase().contains(q);
    return [..._folders.where(match), ..._files.where(match)];
  }

  bool get hasAnyContent => _folders.isNotEmpty || _files.isNotEmpty;

  Set<String> get selection => Set.unmodifiable(_selection);
  bool get isSelecting => _selection.isNotEmpty;
  bool isSelected(BrowserEntry e) => _selection.contains(e.key);

  BrowserEntry? _byKey(String key) {
    for (final e in [..._folders, ..._files]) {
      if (e.key == key) return e;
    }
    return null;
  }

  List<BrowserEntry> get selectedEntries => [
    for (final k in _selection) ?_byKey(k),
  ];

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    services.sync?.summary.removeListener(_onSyncChanged);
    super.dispose();
  }

  // ------------------------------------------------------------------ carga

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      _isLoading = true;
      _error = null;
      notifyListeners();
    }
    try {
      final repo = services.repository;
      final folders = await repo.getFoldersByParent(folderId);
      final items = await repo.getItemsByFolder(folderId);
      final crumbs = folderId == null
          ? const <FolderModel>[]
          : await repo.getBreadcrumbs(folderId!);
      _folders = folders.map(FolderEntry.new).toList();
      _files = items.map(FileEntry.new).toList();
      _breadcrumbs = crumbs;
      // Descarta de la selección lo que ya no existe.
      _selection.removeWhere((k) => _byKey(k) == null);
    } catch (e) {
      if (!silent) _error = e;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Pull-to-refresh: sincroniza y recarga.
  Future<void> refresh() async {
    try {
      await services.syncRunner();
    } catch (e) {
      // La sincronización es best-effort; se mostrará el estado por archivo.
      VaultLog.e('Sincronización fallida', e);
    }
    await load();
  }

  // ------------------------------------------------------------- vista

  void setColumns(int value) {
    final v = value.clamp(AppGrid.minColumns, AppGrid.maxColumns);
    if (v == _columns) return;
    _columns = v;
    notifyListeners();
  }

  /// Pellizco: `-1` acerca (menos columnas), `+1` aleja.
  void stepColumns(int delta) => setColumns(_columns + delta);

  void setQuery(String value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }

  // -------------------------------------------------------------- selección

  void toggleSelection(BrowserEntry e) {
    if (!_selection.remove(e.key)) _selection.add(e.key);
    notifyListeners();
  }

  void selectAll() {
    _selection
      ..clear()
      ..addAll(entries.map((e) => e.key));
    notifyListeners();
  }

  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------- acciones

  Future<void> createFolder(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await services.repository.createFolder(
      FolderModel(
        id: const Uuid().v4(),
        name: trimmed,
        parentId: folderId,
        createdAt: DateTime.now().toIso8601String(),
      ),
    );
    await load();
  }

  Future<bool> importFile({required bool deleteOriginal}) async {
    final ok = await services.importFile(
      folderId: folderId,
      deleteOriginal: deleteOriginal,
    );
    if (ok) await load();
    return ok;
  }

  /// Manda las entradas a la papelera (carpetas con todo su contenido). Sin
  /// papelera (pruebas) elimina directo: fila de BD, archivos locales
  /// y, si hay nube, encola el borrado de la copia en Drive con los ids
  /// leídos ANTES de borrar la fila (ver `SyncJobKind.deleteRemote`).
  Future<void> delete(Iterable<BrowserEntry> targets) async {
    final trash = services.trash;
    if (trash != null) {
      // v2 fase 5: a la papelera (restaurable); el borrado real y el de Drive
      // ocurren al vaciar/vencer (TrashService).
      await trash.trash(targets.toList());
      _selection.clear();
      await load();
      return;
    }
    final repo = services.repository;
    final itemIds = <String>[];
    final remote = <RemoteDeleteTarget>[];
    RemoteDeleteTarget targetOf(VaultItemModel i) => RemoteDeleteTarget(
      i.id,
      driveFileId: i.driveFileId,
      thumbDriveFileId: i.thumbDriveFileId,
    );
    for (final e in targets) {
      switch (e) {
        case FileEntry():
          // Fila más reciente: la subida pudo terminar tras cargar la vista.
          final fresh = await repo.getItem(e.item.id) ?? e.item;
          remote.add(targetOf(fresh));
          await repo.deleteItem(e.item.id);
          itemIds.add(e.item.id);
        case FolderEntry():
          remote.addAll(
            (await repo.getItemsInFolderTree(e.folder.id)).map(targetOf),
          );
          itemIds.addAll(await repo.deleteFolderRecursive(e.folder.id));
      }
    }
    await services.fileCleaner(itemIds);
    // Después de limpiar la cola local (que quita subidas del item).
    await services.remoteDeleter?.call(remote);
    _selection.clear();
    await load();
  }

  /// Mueve las entradas a [targetFolderId] (`null` = raíz).
  Future<void> move(
    Iterable<BrowserEntry> targets,
    String? targetFolderId,
  ) async {
    final repo = services.repository;
    for (final e in targets) {
      switch (e) {
        case FileEntry():
          await repo.moveItem(e.item.id, targetFolderId);
        case FolderEntry():
          await repo.moveFolder(e.folder.id, targetFolderId);
      }
    }
    _selection.clear();
    await load();
  }

  /// `true` si la entrada está marcada sin conexión (el item, o la carpeta).
  bool isOffline(BrowserEntry e) => switch (e) {
    FileEntry() => e.item.isOffline,
    FolderEntry() => e.folder.isOffline,
  };

  /// Marca/desmarca "disponible sin conexión". Devuelve cuántas fallaron.
  /// Quitarlo no borra nada: solo vuelve purgable la copia local.
  Future<int> setOffline(Iterable<BrowserEntry> targets, bool value) async {
    var failures = 0;
    for (final e in targets) {
      switch (e) {
        case FileEntry():
          if (!await services.offlineToggler(e.item.id, value)) failures++;
        case FolderEntry():
          try {
            final t = services.folderOfflineToggler;
            if (t != null) {
              await t(e.folder.id, value);
            } else {
              await services.repository.setFolderOffline(e.folder.id, value);
            }
          } on Object {
            failures++;
          }
      }
    }
    _selection.clear();
    await load();
    return failures;
  }
}
