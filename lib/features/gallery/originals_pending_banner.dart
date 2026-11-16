import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_buttons.dart';

/// Aviso discreto sobre la cuadrícula: hay originales cuya copia ya está en la
/// nube y se pueden borrar de la galería. "Borrar ahora" abre el flujo normal
/// (lista + confirmación); este widget nunca borra nada por sí mismo.
class OriginalsPendingBanner extends StatelessWidget {
  const OriginalsPendingBanner({
    super.key,
    required this.count,
    required this.onDelete,
  });

  final int count;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = count == 1
        ? '1 original ya está en la nube y se puede borrar de tu galería.'
        : '$count originales ya están en la nube y se pueden borrar de tu '
              'galería.';
    return Padding(
      padding: AppSpacing.pageHorizontal,
      child: Container(
        padding: const EdgeInsets.only(left: AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: AppRadii.mdAll,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_done_outlined, color: AppColors.accentLight),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(text, style: AppTypography.caption),
              ),
            ),
            AppTextButton(label: 'Borrar ahora', onPressed: onDelete),
          ],
        ),
      ),
    );
  }
}
