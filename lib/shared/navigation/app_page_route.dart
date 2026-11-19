import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';

/// Transición de página compartida: fundido + ligero deslizamiento lateral.
/// Compatible con `Hero` (el visor usa el mismo `tag` que la miniatura).
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: AppMotion.medium,
        reverseTransitionDuration: AppMotion.medium,
        pageBuilder: (context, animation, secondary) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: AppMotion.standard,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(AppSpacing.xs / 100, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      );
}
