import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// Botón de icono con área táctil >= 44 px y etiqueta accesible obligatoria
/// (sirve de tooltip y de `Semantics.label`).
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color = AppColors.textPrimary,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: label,
      onPressed: onPressed,
      constraints: const BoxConstraints(
        minWidth: AppSizes.minTouch,
        minHeight: AppSizes.minTouch,
      ),
    );
  }
}

/// Botón principal (relleno morado).
class AppFilledButton extends StatelessWidget {
  const AppFilledButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    this.busy = false,
  });

  final String label;
  final bool busy;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: destructive ? AppColors.dangerFill : AppColors.accent,
      foregroundColor: AppColors.onAccent,
      disabledBackgroundColor: AppColors.surfaceHighest,
      disabledForegroundColor: AppColors.textSecondary,
      minimumSize: const Size(AppSizes.minTouch, AppSizes.fabMini),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.lgAll),
    );
    if (busy) {
      return FilledButton(
        onPressed: null,
        style: style,
        child: const SizedBox.square(
          dimension: AppSizes.iconMd,
          child: CircularProgressIndicator(strokeWidth: AppSizes.statusStroke),
        ),
      );
    }
    return icon == null
        ? FilledButton(
            onPressed: onPressed,
            style: style,
            child: Text(label, style: AppTypography.button),
          )
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: AppSizes.iconMd),
            label: Text(label, style: AppTypography.button),
          );
  }
}

/// Botón secundario (solo texto).
class AppTextButton extends StatelessWidget {
  const AppTextButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentLight,
        minimumSize: const Size(AppSizes.minTouch, AppSizes.fabMini),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),
      child: Text(label, style: AppTypography.label),
    );
  }
}
