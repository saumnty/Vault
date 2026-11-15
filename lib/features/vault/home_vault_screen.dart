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
import '../gallery/gallery_picker_screen.dart';
import '../gallery/import_options_sheet.dart';
import '../gallery/import_progress_sheet.dart';
import '../sync/sync_cloud_button.dart';
import '../sync/sync_sheet.dart';
import 'models/browser_entry.dart';
import 'vault_browser_controller.dart';
import 'vault_media_viewer_screen.dart';
import 'vault_services.dart';
import 'widgets/breadcrumb_bar.dart';
import 'widgets/expandable_fab.dart';
import 'widgets/swipe_action_row.dart';
import 'widgets/vault_grid.dart';
import 'widgets/vault_sheets.dart';
import 'widgets/vault_top_bar.dart';

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
  });

  final String? currentFolderId;
  final String currentFolderName;

  /// Inyectable para pruebas; por defecto los servicios reales.
  final VaultServices? services;
  final int initialColumns;

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
      });
    }
  }

  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  bool _pinching = false;

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- helpers

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
            ),
          ),
        );
      case FileEntry():
        Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => VaultMediaViewerScreen(
              item: e.item,
              heroTag: e.heroTag,
              mediaLoader: _services.mediaLoader,
            ),
          ),
        );
    }
  }

  void _onLongPress(BrowserEntry e) {
    AppHaptics.selection();
    _controller.toggleSelection(e);
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

  Future<void> _offline(List<BrowserEntry> targets) async {
    if (targets.isEmpty) return;
    final failures = await _controller.setOffline(targets, true);
    _snack(
      failures == 0
          ? 'Disponible sin conexión'
          : 'No se pudo guardar $failures elemento(s) sin conexión',
    );
  }

  Future<void> _importFile() async {
    final deleteOriginal = await showImportConfirmSheet(context);
    if (deleteOriginal == null || !mounted) return;
    final ok = await _controller.importFile(deleteOriginal: deleteOriginal);
    if (ok) _services.sync?.run();
    _snack(
      ok
          ? (deleteOriginal
                ? 'Archivo cifrado y original eliminado'
                : 'Archivo importado y cifrado')
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
    if (!mounted) return;
    final choices = await showImportOptionsSheet(
      context,
      assets: picked,
      deleteOriginalsWhenInCloud: prefDelete,
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
    );
    await _controller.load();
    _services.sync?.run(); // sube lo recién importado
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
    SwipeAction(
      icon: Icons.offline_pin_outlined,
      label: 'Sin conexión',
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
                      title: widget.currentFolderName,
                      crumbs: [
                        const Crumb(id: null, label: 'Mi Bóveda'),
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
                      onOffline: () => _offline(c.selectedEntries),
                      onDelete: () => _delete(c.selectedEntries),
                      trailing: _services.sync == null
                          ? null
                          : SyncCloudButton(
                              sync: _services.sync!,
                              onTap: () =>
                                  showSyncSheet(context, _services.sync!),
                            ),
                    ),
                    Expanded(
                      child: PinchDetector(
                        onStep: _onPinch,
                        onPinchingChanged: (v) => setState(() => _pinching = v),
                        child: ValueListenableBuilder<Map<String, double>>(
                          valueListenable:
                              _services.sync?.progress ?? _noProgress,
                          builder: (context, progress, _) => VaultGrid(
                            uploadProgress: progress,
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
