import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/format.dart';
import '../models/browser_entry.dart';
import '../vault_services.dart';
import 'sync_status_icon.dart';
import 'thumbnail_view.dart';
import 'tile_frame.dart';

/// Fila de lista (vista de 1 columna) para carpetas y archivos.
class EntryRow extends StatelessWidget {
  const EntryRow({
    super.key,
    required this.entry,
    required this.thumbnailLoader,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    this.progress,
  });

  final BrowserEntry entry;
  final ThumbnailLoader thumbnailLoader;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final (String subtitle, String semantic) = switch (entry) {
      FolderEntry(:final folder) => (
        'Carpeta · ${formatIsoDate(folder.createdAt)}',
        'Carpeta ${folder.name}',
      ),
      FileEntry(:final item) => (
        '${formatBytes(item.fileSize)} · ${formatIsoDate(item.createdAt)}',
        '${labelForKind(fileKindOf(item))} ${item.name}, '
            '${formatBytes(item.fileSize)}, ${syncStatusLabel(item.syncStatus)}',
      ),
    };

    return Semantics(
      button: true,
      selected: selected,
      label: semantic,
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressHint: 'Seleccionar',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        color: selected ? AppColors.accentContainer : AppColors.background,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSizes.rowHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: AppSizes.rowThumb,
                    child: _leading(),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.body,
                        ),
                        Text(subtitle, style: AppTypography.caption),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  _trailing(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _leading() => switch (entry) {
    FolderEntry() => const DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.smAll,
      ),
      child: Icon(Icons.folder_rounded, color: AppColors.accentLight),
    ),
    final FileEntry file => Hero(
      tag: file.heroTag,
      child: ThumbnailView(
        item: file.item,
        loader: thumbnailLoader,
        radius: AppRadii.smAll,
      ),
    ),
  };

  Widget _trailing() {
    if (selectionMode) {
      return SelectionBadge(visible: true, selected: selected);
    }
    return switch (entry) {
      FileEntry(:final item) => SyncStatusIcon(
        status: item.syncStatus,
        progress: progress,
      ),
      FolderEntry() => const Icon(
        Icons.chevron_right,
        color: AppColors.textSecondary,
      ),
    };
  }
}
