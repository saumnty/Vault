import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_buttons.dart';

/// Barra contextual del modo selección: cerrar, contador y acciones.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.count,
    required this.onClose,
    required this.onSelectAll,
    required this.onMove,
    required this.onOffline,
    required this.onDelete,
    this.onTags,
  });

  final int count;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onMove;

  /// "Disponible sin conexión"; `null` oculta la acción (bóveda sin nube).
  final VoidCallback? onOffline;
  final VoidCallback onDelete;

  /// Etiquetas de los archivos seleccionados; `null` oculta la acción.
  final VoidCallback? onTags;

  @override
  Widget build(BuildContext context) {
    final text = count == 1 ? '1 seleccionado' : '$count seleccionados';
    return Container(
      height: AppSizes.toolbar,
      color: AppColors.surfaceHigh,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        children: [
          AppIconButton(
            icon: Icons.close,
            label: 'Cancelar selección',
            onPressed: onClose,
          ),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(text, style: AppTypography.titleSmall),
            ),
          ),
          AppIconButton(
            icon: Icons.select_all,
            label: 'Seleccionar todo',
            onPressed: onSelectAll,
          ),
          if (onTags != null)
            AppIconButton(
              icon: Icons.label_outline,
              label: 'Etiquetas',
              onPressed: onTags,
            ),
          AppIconButton(
            icon: Icons.drive_file_move_outline,
            label: 'Mover',
            onPressed: onMove,
          ),
          if (onOffline != null)
            AppIconButton(
              icon: Icons.offline_pin_outlined,
              label: 'Disponible sin conexión',
              onPressed: onOffline,
            ),
          AppIconButton(
            icon: Icons.delete_outline,
            label: 'Eliminar',
            onPressed: onDelete,
            color: AppColors.danger,
          ),
        ],
      ),
    );
  }
}
