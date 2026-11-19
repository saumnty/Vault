import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';

/// Indicador de pasos ("Paso 2 de 6") con puntos; el activo es alargado.
class OnboardingProgress extends StatelessWidget {
  const OnboardingProgress({
    super.key,
    required this.current,
    required this.total,
  });

  /// Paso actual, base 1.
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Paso $current de $total',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 1; i <= total; i++)
              AnimatedContainer(
                duration: AppMotion.medium,
                curve: AppMotion.standard,
                margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                width: i == current ? AppSizes.stepDotActive : AppSizes.stepDot,
                height: AppSizes.stepDot,
                decoration: BoxDecoration(
                  borderRadius: AppRadii.pillAll,
                  color: i == current
                      ? AppColors.accentLight
                      : i < current
                      ? AppColors.accent
                      : AppColors.surfaceHighest,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Página de un paso del onboarding: título, texto, cuerpo desplazable y
/// pie con las acciones.
class OnboardingPage extends StatelessWidget {
  const OnboardingPage({
    super.key,
    required this.title,
    this.message,
    this.body = const [],
    this.footer = const [],
  });

  final String title;
  final String? message;
  final List<Widget> body;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSizes.contentMaxWidth),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: AppSpacing.page,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(title, style: AppTypography.title),
                    ),
                    if (message != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(message!, style: AppTypography.bodySecondary),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    ...body,
                  ],
                ),
              ),
            ),
            Padding(
              padding: AppSpacing.page,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: footer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta informativa: icono, título y texto. Un solo nodo semántico.
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
    this.color = AppColors.accentLight,
    this.border = AppColors.border,
  });

  final IconData icon;
  final String title;
  final String text;
  final Color color;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$title. $text',
      child: ExcludeSemantics(
        child: Container(
          padding: AppSpacing.page,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadii.lgAll,
            border: Border.all(color: border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: AppSizes.fabMini,
                height: AppSizes.fabMini,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accentContainer,
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.titleSmall),
                    const SizedBox(height: AppSpacing.xs),
                    Text(text, style: AppTypography.bodySecondary),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
