import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/app_spacing.dart';

/// Puntos del PIN: se llenan con una animación elástica al teclear; en rojo
/// si [hasError]; en acento brillante si [success].
class PinDots extends StatelessWidget {
  const PinDots({
    super.key,
    required this.length,
    required this.filled,
    this.hasError = false,
    this.success = false,
  });

  final int length;
  final int filled;
  final bool hasError;
  final bool success;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'PIN: $filled de $length dígitos',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < length; i++) ...[
            if (i > 0) const SizedBox(width: AppSizes.pinDotGap),
            _Dot(
              filled: success || i < filled,
              hasError: hasError,
              success: success,
            ),
          ],
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.filled,
    required this.hasError,
    required this.success,
  });

  final bool filled;
  final bool hasError;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final color = hasError
        ? AppColors.danger
        : success
        ? AppColors.accentLight
        : AppColors.accent;
    return AnimatedScale(
      scale: filled ? 1.25 : 1,
      duration: AppMotion.fast,
      curve: AppMotion.spring,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        width: AppSizes.pinDot,
        height: AppSizes.pinDot,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? color : AppColors.transparent,
          border: Border.all(
            color: filled || hasError ? color : AppColors.textSecondary,
            width: AppSizes.statusStroke,
          ),
          boxShadow: filled && !hasError ? AppShadows.glow : const [],
        ),
      ),
    );
  }
}
