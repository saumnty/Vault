import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/cloud/cloud_storage.dart';
import '../../shared/format.dart';

/// Barra de espacio de Drive (usado/total). Compartida por la hoja de
/// sincronización y Ajustes. `null` = consultando.
class QuotaBar extends StatelessWidget {
  const QuotaBar({super.key, required this.quota});

  final CloudQuota? quota;

  @override
  Widget build(BuildContext context) {
    final q = quota;
    if (q == null) {
      return const Text(
        'Espacio de Drive: consultando…',
        style: AppTypography.bodySecondary,
      );
    }
    final text = q.limitBytes == null
        ? '${formatBytes(q.usedBytes)} usados en Drive'
        : '${formatBytes(q.usedBytes)} de ${formatBytes(q.limitBytes!)} usados';
    return Semantics(
      label: 'Espacio de Drive: $text',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: AppTypography.bodySecondary),
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: AppRadii.pillAll,
              child: LinearProgressIndicator(
                value: q.fraction ?? 0,
                minHeight: AppSizes.progressBarHeight,
                color: (q.fraction ?? 0) > 0.9
                    ? AppColors.danger
                    : AppColors.accent,
                backgroundColor: AppColors.surfaceHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
