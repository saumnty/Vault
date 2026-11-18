import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../shared/haptics.dart';
import '../../shared/navigation/app_page_route.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/pinch_detector.dart';
import '../../data/gallery/gallery_asset_source.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../data/sync/sync_service.dart';
import '../gallery/delete_originals_sheet.dart';
import '../gallery/gallery_picker_screen.dart';
import '../gallery/import_options_sheet.dart';
import '../gallery/import_progress_sheet.dart';
import '../gallery/originals_pending_banner.dart';
import '../settings/key_rotation_screen.dart';
import '../settings/settings_environment.dart';
import '../settings/settings_screen.dart';
import '../sync/sync_cloud_button.dart';
import '../sync/sync_sheet.dart';
import 'models/browser_entry.dart';
import 'vault_browser_controller.dart';
import 'vault_media_viewer_screen.dart';
import 'vault_services.dart';
import 'widgets/active_filters_bar.dart';
import 'widgets/breadcrumb_bar.dart';
import 'widgets/expandable_fab.dart';
import 'widgets/filter_sheet.dart';
import 'widgets/swipe_action_row.dart';
import 'widgets/tags_sheet.dart';
import 'widgets/vault_grid.dart';
import 'widgets/vault_sheets.dart';
import 'widgets/vault_top_bar.dart';
import '../../shared/vault_ui_mode.dart';

/// Nombre de ruta de una carpeta (para que las migas de pan puedan volver a
/// ella con `popUntil`). La raíz es la ruta `/`.
String folderRouteName(String? folderId) =>
    folderId == null ? '/' : 'folder/$folderId';

final ValueNotifier<Map<String, double>> _noProgress = ValueNotifier(const {});

/// Explorador de una carpeta de la bóveda (null = raíz).
class HomeVaultScreen extends StatefulWidget {
  const HomeVaultScreen({
    super.key,
    this.currentFolderId,
    required this.currentFolderName,
    this.services,
    this.initialColumns = AppGrid.defaultColumns,
    this.onLock,
    this.settings,
  });

  final String? currentFolderId;
  final String currentFolderName;

  /// Inyectable para pruebas; por defecto los servicios reales.
  final VaultServices? services;
  final int initialColumns;

  /// "Bloquear ahora" (F7); `null` oculta el botón.
  final VoidCallback? onLock;

  /// Ajustes (F8): solo la raíz muestra el engranaje; `null` lo oculta.
  final SettingsEnvironment? settings;

  @override
  State<HomeVaultScreen> createState() => _HomeVaultScreenState();
}

class _HomeVaultScreenState extends State<HomeVaultScreen> {
  late final VaultServices _services = widget.services ?? VaultServices.real();
  late final VaultBrowserController _controller = VaultBrowserController(
    services: _services,
    folderId: widget.currentFolderId,
    columns: widget.initialColumns,
  )..load();

  @override
  void initState() {
    super.initState();
    // Reanudación: al abrir/desbloquear la bóveda se procesa la cola.
    if (widget.currentFolderId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _services.sync?.run();
        // F6a: barre temporales descifrados, reconcilia "sin conexión" y
        // aplica el límite de la caché.
        unawaited(_services.onUnlocked?.call());
      });
    }
    if (_services.gallery != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_refreshPendingOriginals()),
      );
      _services.sync?.summary.addListener(_onSyncSummary);
    }
  }

  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  bool _pinching = false;

  /// id -> nombre de las etiquetas (chips de filtros activos).
  Map<String, String> _tagNames = const {};

  /// Originales ya en la nube pendientes de borrar (aviso sobre la cuadrícula;
  /// 0 si el borrado está apagado).
  int _pendingOriginals = 0;
  SyncPhase? _lastPhase;

  void _onSyncSummary() {
    final phase = _services.sync?.summary.value.phase;
    if (phase == _lastPhase) return;
    _lastPhase = phase;
    if (phase == SyncPhase.idle) unawaited(_refreshPendingOriginals());
  }

  Future<void> _refreshPendingOriginals() async {
    final gallery = _services.gallery;
    if (gallery == null) return;
    int n;
    try {
      n = await gallery.service.pendingOriginalsCount();
    } on Object {
      n = 0; // bóveda bloqueada u otro fallo: sin aviso
    }
    if (mounted && n != _pendingOriginals) {
      setState(() => _pendingOriginals = n);
    }
  }

  /// Mismo flujo de Ajustes: lista verificada + confirmación del sistema.
  /// Banner del cambio de llave maestra (S-11): abre su pantalla.
  Future<void> _openRotation() async {
    final rotation = _services.rotation;
    if (rotation == null) return;
    await Navigator.of(context).push<void>(
      AppPageRoute<void>(builder: (_) => KeyRotationScreen(service: rotation)),
    );
  }

  Future<void> _deleteOriginalsNow() async {
    final gallery = _services.gallery;
    if (gallery == null) return;
    final n = await showDeleteOriginalsSheet(context, service: gallery.service);
    if (n > 0) {
      _snack(
        n == 1
            ? 'Se borró 1 original del dispositivo'
            : 'Se borraron $n originales del dispositivo',
      );
    }
    await _refreshPendingOriginals();
  }

  @override
  void dispose() {
    _services.sync?.summary.removeListener(_onSyncSummary);
    _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- helpers

  void _snack(String message) {
    if (!mounted) return;
    try {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      // Widget desactivado a mitad de una transición: el aviso es opcional.
    }
  }

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (!_searching) {
      _search.clear();
      _controller.setQuery('');
    }
  }

  void _toggleView() {
    AppHaptics.selection();
    _controller.setColumns(
      _controller.columns == 1 ? AppGrid.defaultColumns : 1,
    );
  }

  void _onPinch(int delta) {
    final before = _controller.columns;
    _controller.stepColumns(delta);
    if (_controller.columns != before) AppHaptics.selection();
  }

  // ------------------------------------------------------------ interacción

  void _onTap(BrowserEntry e) {
    if (_controller.isSelecting) {
      AppHaptics.selection();
      _controller.toggleSelection(e);
      return;
    }
    switch (e) {
      case FolderEntry():
        Navigator.of(context).push(
          AppPageRoute<void>(
            settings: RouteSettings(name: folderRouteName(e.folder.id)),
            builder: (_) => HomeVaultScreen(
              currentFolderId: e.folder.id,
              currentFolderName: e.folder.name,
              services: _services,
              initialColumns: _controller.columns,
              onLock: widget.onLock,
            ),
          ),
        );
      case FileEntry():
        final files = [
          for (final x in _controller.entries)
            if (x is FileEntry) x.item,
        ];
        Navigator.of(context)
            .push(
              AppPageRoute<void>(
                builder: (_) => VaultMediaViewerScreen(
                  items: files,
                  initialIndex: files.indexWhere((i) => i.id == e.item.id),
                  mediaOpener: _services.mediaOpener,
                  mediaExporter: _services.mediaExporter,
                  thumbnailLoader: _services.thumbnailLoader,
                ),
              ),
            )
            .then((_) => _controller.load(silent: true));
    }
  }

  void _onLongPress(BrowserEntry e) {
    AppHaptics.selection();
    _controller.toggleSelection(e);
  }

  void _openSettings() {
    final env = widget.settings;
    if (env == null) return;
    Navigator.of(context)
        .push(
          AppPageRoute<void>(
            builder: (_) => SettingsScreen(env: env, services: _services),
          ),
        )
        // Ajustes puede cambiar el contenido (restaurar de la Papelera).
        .then((_) {
          if (mounted) _controller.load(silent: true);
        });
  }

  void _onCrumbTap(Crumb crumb) {
    final target = folderRouteName(crumb.id);
    Navigator.of(
      context,
    ).popUntil((r) => r.settings.name == target || r.isFirst);
  }

  // ---------------------------------------------------------------- acciones

  Future<void> _delete(List<BrowserEntry> targets) async {
    if (targets.isEmpty) return;
    final ok = await showConfirmDeleteSheet(
      context,
      count: targets.length,
      includesFolders: targets.any((e) => e is FolderEntry),
      toTrash: _services.trash != null,
    );
    if (!ok || !mounted) return;
    AppHaptics.destructive();
    await _controller.delete(targets);
    _snack(targets.length == 1 ? 'Elemento eliminado' : 'Elementos eliminados');
  }

  Future<void> _move(List<BrowserEntry> targets) async {
    if (targets.isEmpty) return;
    final pick = await showMoveSheet(
      context,
      repository: _services.repository,
      excludeFolderIds: {
        for (final e in targets)
          if (e is FolderEntry) e.folder.id,
      },
    );
    if (pick == null || !mounted) return;
    try {
      await _controller.move(targets, pick.id);
      _snack('Movido');
    } on Object {
      // moveFolder rechaza mover una carpeta dentro de sí misma.
      _snack('No se pudo mover a esa carpeta');
    }
  }

  /// Alterna "disponible sin conexión": si todo lo seleccionado ya lo está,
  /// lo quita (no borra nada: solo vuelve purgable la copia local).
  Future<void> _offline(List<BrowserEntry> targets) async {
    if (targets.isEmpty) return;
    final remove = targets.every(_controller.isOffline);
    final failures = await _controller.setOffline(targets, !remove);
    _snack(
      failures > 0
          ? 'No se pudo cambiar $failures elemento(s)'
          : remove
          ? 'Ya no se mantiene sin conexión'
          : 'Disponible sin conexión (se descargará lo que falte)',
    );
  }

  Future<void> _openFilters() async {
    final tags = _services.tags;
    if (tags == null) return;
    final result = await showFilterSheet(
      context,
      tags: tags,
      current: _controller.filter,
    );
    if (result == null || !mounted) return;
    await _controller.setFilter(result);
    await _loadTagNames();
  }

  Future<void> _loadTagNames() async {
    final tags = _services.tags;
    if (tags == null) return;
    try {
      final list = await tags.list();
      if (mounted) {
        setState(() => _tagNames = {for (final t in list) t.id: t.name});
      }
    } on Object {
      // sin nombres: los chips muestran "Etiqueta"
    }
  }

  Future<void> _tagSelection(List<BrowserEntry> targets) async {
    if (!targets.any((e) => e is FileEntry)) return;
    await showTagsSheet(context, controller: _controller, targets: targets);
    if (mounted) await _loadTagNames();
  }

  Future<void> _importFile() async {
    final deleteOriginal = await showImportConfirmSheet(context);
    if (deleteOriginal == null || !mounted) return;
    final ok = await _controller.importFile(deleteOriginal: deleteOriginal);
    if (ok) {
      _services.sync?.run();
      unawaited(_services.afterOpen?.call());
    }
    _snack(
      ok
          ? 'Archivo importado y cifrado'
          : 'Importación cancelada o bóveda bloqueada',
    );
  }

  Future<void> _importFromGallery() async {
    final gallery = _services.gallery;
    if (gallery == null) {
      _snack('Importar desde galería no está disponible');
      return;
    }
    final picked = await Navigator.of(context).push<List<GalleryAsset>>(
      AppPageRoute<List<GalleryAsset>>(
        builder: (_) => GalleryPickerScreen(source: gallery.source),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final prefDelete = await gallery.preferences
        .getDeleteOriginalsWhenInCloud();
    final prefQuality = await gallery.preferences.getVideoQuality();
    if (!mounted) return;
    final choices = await showImportOptionsSheet(
      context,
      assets: picked,
      deleteOriginalsWhenInCloud: prefDelete,
      initialQuality: prefQuality,
    );
    if (choices == null || !mounted) return;
    await gallery.preferences.setDeleteOriginalsWhenInCloud(
      choices.deleteOriginalsWhenInCloud,
    );
    if (!mounted) return;
    final result = await showImportProgressSheet(
      context,
      service: gallery.service,
      assets: picked,
      options: ImportOptions(
        folderId: widget.currentFolderId,
        videoQuality: choices.videoQuality,
      ),
      deleteOriginalsEnabled: choices.deleteOriginalsWhenInCloud,
    );
    await _controller.load();
    unawaited(_refreshPendingOriginals());
    _services.sync?.run(); // sube lo recién importado
    unawaited(_services.afterOpen?.call());
    if (result == null) return;
    AppHaptics.success();
    _snack(
      result.failed == 0 && !result.cancelled
          ? 'Importación completa'
          : '${result.succeeded} importado(s), ${result.failed} con error',
    );
  }

  Future<void> _newFolder() async {
    final name = await showNewFolderSheet(context);
    if (name == null || !mounted) return;
    await _controller.createFolder(name);
  }

  List<SwipeAction> _swipeActions(BrowserEntry e) => [
    SwipeAction(
      icon: Icons.drive_file_move_outline,
      label: 'Mover',
      color: AppColors.accent,
      onTap: () => _move([e]),
    ),
    if (!VaultUiMode.cloudless)
      SwipeAction(
        icon: Icons.offline_pin_outlined,
        label: _controller.isOffline(e)
            ? 'Quitar sin conexión'
            : 'Sin conexión',
        color: AppColors.surfaceHighest,
        onTap: () => _offline([e]),
      ),
    SwipeAction(
      icon: Icons.delete_outline,
      label: 'Eliminar',
      color: AppColors.dangerFill,
      onTap: () => _delete([e]),
    ),
  ];

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        return PopScope(
          canPop: !c.isSelecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) c.clearSelection();
          },
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    VaultTopBar(
                      title: c.isFiltering
                          ? 'Resultados en toda la bóveda'
                          : widget.currentFolderName,
                      crumbs: [
                        const Crumb(id: null, label: 'Mi Bóveda'),
                        if (!c.isFiltering)
                          for (final f in c.breadcrumbs)
                            Crumb(id: f.id, label: f.name),
                      ],
                      canGoBack: Navigator.of(context).canPop(),
                      onBack: () => Navigator.of(context).maybePop(),
                      onCrumbTap: _onCrumbTap,
                      searching: _searching,
                      searchController: _search,
                      onSearchChanged: c.setQuery,
                      onSearchToggle: _toggleSearch,
                      isListView: c.columns == 1,
                      onToggleView: _toggleView,
                      selectionCount: c.selection.length,
                      onClearSelection: c.clearSelection,
                      onSelectAll: c.selectAll,
                      onMove: () => _move(c.selectedEntries),
                      onOffline: VaultUiMode.cloudless
                          ? null
                          : () => _offline(c.selectedEntries),
                      onDelete: () => _delete(c.selectedEntries),
                      onFilters: _services.tags == null ? null : _openFilters,
                      filterCount: activeFilterCount(c.filter),
                      onTags:
                          _services.tags != null &&
                              c.selectedEntries.any((e) => e is FileEntry)
                          ? () => _tagSelection(c.selectedEntries)
                          : null,
                      onLock: widget.onLock,
                      onSettings:
                          widget.currentFolderId == null &&
                              widget.settings != null
                          ? _openSettings
                          : null,
                      trailing: _services.sync == null
                          ? null
                          : SyncCloudButton(
                              sync: _services.sync!,
                              onTap: () =>
                                  showSyncSheet(context, _services.sync!),
                            ),
                    ),
                    if (c.isFiltering && !c.isSelecting)
                      ActiveFiltersBar(
                        filter: c.filter,
                        tagNames: _tagNames,
                        onChanged: (f) async {
                          await c.setFilter(f);
                        },
                        onClear: c.clearFilters,
                      ),
                    if (_services.rotation != null && !c.isSelecting)
                      RotationBanner(
                        record: _services.rotation!.auth.rotationStore.record,
                        progress: _services.rotation!.progress,
                        onTap: _openRotation,
                      ),
                    if (_pendingOriginals > 0 && !c.isSelecting)
                      OriginalsPendingBanner(
                        count: _pendingOriginals,
                        onDelete: _deleteOriginalsNow,
                      ),
                    Expanded(
                      child: PinchDetector(
                        onStep: _onPinch,
                        onPinchingChanged: (v) => setState(() => _pinching = v),
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            _services.sync?.progress ?? _noProgress,
                            _services.downloadProgress ?? _noProgress,
                          ]),
                          builder: (context, _) => VaultGrid(
                            uploadProgress:
                                (_services.sync?.progress ?? _noProgress).value,
                            downloadProgress:
                                (_services.downloadProgress ?? _noProgress)
                                    .value,
                            entries: c.entries,
                            columns: c.columns,
                            isLoading: c.isLoading,
                            thumbnailLoader: _services.thumbnailLoader,
                            isSelected: c.isSelected,
                            selectionMode: c.isSelecting,
                            onTap: _onTap,
                            onLongPress: _onLongPress,
                            onRefresh: c.refresh,
                            scrollLocked: _pinching,
                            swipeActionsFor: _swipeActions,
                            empty: _emptyState(c),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                AnimatedSwitcher(
                  duration: AppMotion.fast,
                  child: c.isSelecting
                      ? const SizedBox.shrink()
                      : ExpandableFab(
                          actions: [
                            FabAction(
                              icon: Icons.create_new_folder_outlined,
                              label: 'Nueva carpeta',
                              onTap: _newFolder,
                            ),
                            FabAction(
                              icon: Icons.upload_file_outlined,
                              label: 'Importar archivo',
                              onTap: _importFile,
                            ),
                            FabAction(
                              icon: Icons.photo_library_outlined,
                              label: 'Importar desde galería',
                              onTap: _importFromGallery,
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _emptyState(VaultBrowserController c) {
    if (c.error != null) {
      return EmptyState(
        title: 'No se pudo cargar',
        message: 'Revisa que la bóveda esté desbloqueada e inténtalo de nuevo.',
        actionLabel: 'Reintentar',
        onAction: c.load,
      );
    }
    if (c.isFiltering) {
      return const EmptyState(
        kind: EmptyKind.search,
        title: 'Nada coincide con los filtros',
        message: 'Prueba quitando algún filtro. Se busca en toda la bóveda.',
      );
    }
    if (c.query.isNotEmpty) {
      return const EmptyState(
        kind: EmptyKind.search,
        title: 'Sin resultados',
        message: 'Ningún elemento de esta carpeta coincide con tu búsqueda.',
      );
    }
    return EmptyState(
      title: widget.currentFolderId == null
          ? 'Tu bóveda está vacía'
          : 'Esta carpeta está vacía',
      message:
          'Toca + para importar fotos, videos o archivos. '
          'Todo se cifra en tu dispositivo antes de guardarse.',
      actionLabel: 'Importar archivo',
      onAction: _importFile,
    );
  }
}
