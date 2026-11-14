import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/format.dart';
import '../models/browser_entry.dart';
import '../vault_services.dart';
import 'sync_status_icon.dart';
import 'thumbnail_view.dart';
import 'tile_frame.dart';

/// Celda de archivo para la cuadrícula.
class FileTile extends StatelessWidget {
  const FileTile({
    super.key,
    required this.entry,
    required this.thumbnailLoader,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    this.progress,
  });

  final FileEntry entry;
  final ThumbnailLoader thumbnailLoader;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// Progreso de subida 0..1 (solo si está `subiendo`).
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    return TileFrame(
      selected: selected,
      selectionMode: selectionMode,
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel:
          '${labelForKind(fileKindOf(item))} ${item.name}, '
          '${formatBytes(item.fileSize)}, ${syncStatusLabel(item.syncStatus)}',
      child: Hero(
        tag: entry.heroTag,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ThumbnailView(item: item, loader: thumbnailLoader),
              const _NameGradient(),
              Positioned(
                left: AppSpacing.sm,
                right: AppSpacing.sm,
                bottom: AppSpacing.sm,
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.captionOnMedia,
                ),
              ),
              Positioned(
                top: AppSpacing.sm,
                right: AppSpacing.sm,
                child: SyncStatusIcon(
                  status: item.syncStatus,
                  progress: progress,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NameGradient extends StatelessWidget {
  const _NameGradient();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: 0.4,
        widthFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.vertical(
              bottom: Radius.circular(AppRadii.md),
            ),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.transparent, AppColors.thumbGradientEnd],
            ),
          ),
        ),
      ),
    );
  }
}
