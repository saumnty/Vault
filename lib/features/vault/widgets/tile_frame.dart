import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';

/// Marco común de celda: gestos, escala/borde al seleccionar, insignia de
/// selección y semántica (etiqueta en español + acción de mantener).
class TileFrame extends StatelessWidget {
  const TileFrame({
    super.key,
    required this.child,
    required this.semanticLabel,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    this.radius = AppRadii.mdAll,
  });

  final Widget child;
  final String semanticLabel;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressHint: 'Seleccionar',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedScale(
          scale: selected ? 0.92 : 1,
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              IgnorePointer(
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    color: selected
                        ? AppColors.accent.withValues(alpha: 0.28)
                        : AppColors.transparent,
                    border: Border.all(
                      color: selected
                          ? AppColors.accentLight
                          : AppColors.transparent,
                      width: AppSpacing.xxs,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: AppSpacing.sm,
                left: AppSpacing.sm,
                child: SelectionBadge(
                  visible: selectionMode,
                  selected: selected,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Círculo de selección (vacío o con check) que aparece en modo selección.
class SelectionBadge extends StatelessWidget {
  const SelectionBadge({
    super.key,
    required this.visible,
    required this.selected,
  });

  final bool visible;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: visible ? 1 : 0,
      duration: AppMotion.fast,
      curve: AppMotion.spring,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        width: AppSizes.selectBadge,
        height: AppSizes.selectBadge,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? AppColors.accent : AppColors.scrim,
          border: Border.all(
            color: selected ? AppColors.accentLight : AppColors.textPrimary,
            width: AppSizes.statusStroke,
          ),
        ),
        child: AnimatedOpacity(
          opacity: selected ? 1 : 0,
          duration: AppMotion.fast,
          child: const Icon(
            Icons.check,
            size: AppSizes.checkIcon,
            color: AppColors.onAccent,
          ),
        ),
      ),
    );
  }
}
