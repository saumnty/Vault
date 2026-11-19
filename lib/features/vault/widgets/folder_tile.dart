import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../models/browser_entry.dart';
import 'tile_frame.dart';

/// Celda de carpeta para la cuadrícula.
class FolderTile extends StatelessWidget {
  const FolderTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  final FolderEntry entry;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final folder = entry.folder;
    return TileFrame(
      selected: selected,
      selectionMode: selectionMode,
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel:
          'Carpeta ${folder.name}${folder.isOffline ? ', disponible sin conexión' : ''}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadii.mdAll,
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.folder_rounded,
                    size: AppSizes.iconHero,
                    color: AppColors.accentLight,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    folder.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppTypography.captionOnMedia,
                  ),
                ],
              ),
              if (folder.isOffline)
                const Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(
                    Icons.offline_pin_outlined,
                    size: AppSizes.iconSm,
                    color: AppColors.success,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
