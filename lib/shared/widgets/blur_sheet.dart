import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// Muestra un bottom sheet con fondo desenfocado (BackdropFilter).
Future<T?> showBlurSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    backgroundColor: AppColors.transparent,
    barrierColor: AppColors.scrimSoft,
    builder: (context) => BlurSheet(child: builder(context)),
  );
}

/// Contenedor del sheet: esquinas redondeadas, cristal esmerilado, asa y
/// espacio para el teclado.
class BlurSheet extends StatelessWidget {
  const BlurSheet({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return ClipRRect(
      borderRadius: AppRadii.sheetTop,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AppShadows.sheetBlur,
          sigmaY: AppShadows.sheetBlur,
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.sheetSurface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: AppSpacing.sheet.copyWith(
                bottom: AppSpacing.sheet.bottom + insets,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [const _Handle(), child],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Center(
        child: Container(
          width: AppSizes.sheetHandleWidth,
          height: AppSizes.sheetHandleHeight,
          margin: const EdgeInsets.only(bottom: AppSpacing.lg),
          decoration: const BoxDecoration(
            color: AppColors.border,
            borderRadius: AppRadii.pillAll,
          ),
        ),
      ),
    );
  }
}

/// Título + texto de apoyo de un sheet.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title, this.message});

  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: AppTypography.title),
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(message!, style: AppTypography.bodySecondary),
          ],
        ],
      ),
    );
  }
}

/// Fila de acción (>= 56 px de alto) para sheets.
class SheetActionTile extends StatelessWidget {
  const SheetActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.description,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String? description;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.danger : AppColors.accentLight;
    return Semantics(
      button: true,
      label: description == null ? label : '$label. $description',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: AppRadii.mdAll,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AppSizes.rowHeight - AppSpacing.lg,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: AppTypography.body.copyWith(
                          color: destructive ? AppColors.danger : null,
                        ),
                      ),
                      if (description != null)
                        Text(description!, style: AppTypography.caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
