import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/shimmer.dart';
import '../../../shared/widgets/staggered_appear.dart';
import '../models/browser_entry.dart';
import '../vault_services.dart';
import 'entry_row.dart';
import 'file_tile.dart';
import 'folder_tile.dart';
import 'swipe_action_row.dart';

/// Cuadrícula (o lista, con 1 columna) de carpetas y archivos con aparición
/// escalonada, pull-to-refresh y estado vacío/cargando.
class VaultGrid extends StatefulWidget {
  const VaultGrid({
    super.key,
    required this.entries,
    required this.columns,
    required this.isLoading,
    required this.thumbnailLoader,
    required this.isSelected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onRefresh,
    required this.empty,
    this.swipeActionsFor,
    this.uploadProgress = const {},
    this.downloadProgress = const {},
    this.scrollLocked = false,
  });

  final List<BrowserEntry> entries;
  final int columns;
  final bool isLoading;
  final ThumbnailLoader thumbnailLoader;
  final bool Function(BrowserEntry) isSelected;
  final bool selectionMode;
  final ValueChanged<BrowserEntry> onTap;
  final ValueChanged<BrowserEntry> onLongPress;
  final Future<void> Function() onRefresh;
  final Widget empty;

  /// Acciones de deslizamiento (solo en la vista de lista).
  final List<SwipeAction> Function(BrowserEntry)? swipeActionsFor;

  /// Progreso de subida por id de item (0..1).
  final Map<String, double> uploadProgress;

  /// Progreso de descarga ("sin conexión") por id de item (0..1).
  final Map<String, double> downloadProgress;

  /// Bloquea el scroll (mientras dura un pellizco).
  final bool scrollLocked;

  @override
  State<VaultGrid> createState() => _VaultGridState();
}

class _VaultGridState extends State<VaultGrid> {
  /// Claves que ya hicieron su animación de entrada (no se repite al volver
  /// a hacer scroll).
  final Set<String> _appeared = {};

  static const int _skeletonCount = 12;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.accentLight,
      backgroundColor: AppColors.surfaceHigh,
      onRefresh: widget.onRefresh,
      child: CustomScrollView(
        physics: widget.scrollLocked
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        slivers: _slivers(),
      ),
    );
  }

  List<Widget> _slivers() {
    if (widget.isLoading && widget.entries.isEmpty) {
      return [
        SliverPadding(
          padding: AppSpacing.gridPage,
          sliver: SliverGrid.builder(
            gridDelegate: _delegate(),
            itemCount: _skeletonCount,
            itemBuilder: (context, i) => const SkeletonBox(),
          ),
        ),
      ];
    }
    if (widget.entries.isEmpty) {
      return [SliverFillRemaining(hasScrollBody: false, child: widget.empty)];
    }
    if (widget.columns == 1) {
      return [
        SliverPadding(
          padding: const EdgeInsets.only(bottom: AppSizes.fabClearance),
          sliver: SliverList.builder(
            itemCount: widget.entries.length,
            itemBuilder: (context, i) => _staggered(i, _row(widget.entries[i])),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: AppSpacing.gridPage,
        sliver: SliverGrid.builder(
          gridDelegate: _delegate(),
          itemCount: widget.entries.length,
          itemBuilder: (context, i) => _staggered(i, _tile(widget.entries[i])),
        ),
      ),
    ];
  }

  SliverGridDelegate _delegate() => SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: widget.columns,
    mainAxisSpacing: AppGrid.gap,
    crossAxisSpacing: AppGrid.gap,
  );

  Widget _staggered(int index, Widget child) {
    final key = widget.entries[index].key;
    return StaggeredAppear(
      key: ValueKey(key),
      index: index,
      animate: _appeared.add(key),
      child: child,
    );
  }

  Widget _tile(BrowserEntry e) => switch (e) {
    FolderEntry() => FolderTile(
      entry: e,
      selected: widget.isSelected(e),
      selectionMode: widget.selectionMode,
      onTap: () => widget.onTap(e),
      onLongPress: () => widget.onLongPress(e),
    ),
    FileEntry() => FileTile(
      entry: e,
      thumbnailLoader: widget.thumbnailLoader,
      selected: widget.isSelected(e),
      selectionMode: widget.selectionMode,
      progress:
          widget.uploadProgress[e.item.id] ??
          widget.downloadProgress[e.item.id],
      downloading:
          widget.uploadProgress[e.item.id] == null &&
          widget.downloadProgress[e.item.id] != null,
      onTap: () => widget.onTap(e),
      onLongPress: () => widget.onLongPress(e),
    ),
  };

  Widget _row(BrowserEntry e) {
    final row = EntryRow(
      entry: e,
      thumbnailLoader: widget.thumbnailLoader,
      selected: widget.isSelected(e),
      selectionMode: widget.selectionMode,
      progress: e is FileEntry
          ? (widget.uploadProgress[e.item.id] ??
                widget.downloadProgress[e.item.id])
          : null,
      downloading:
          e is FileEntry &&
          widget.uploadProgress[e.item.id] == null &&
          widget.downloadProgress[e.item.id] != null,
      onTap: () => widget.onTap(e),
      onLongPress: () => widget.onLongPress(e),
    );
    final actions = widget.swipeActionsFor?.call(e);
    if (actions == null) return row;
    return SwipeActionRow(
      enabled: !widget.selectionMode,
      actions: actions,
      child: row,
    );
  }
}
