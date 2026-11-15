import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'app_buttons.dart';
import 'blur_sheet.dart';

/// Una opción de [showChoiceSheet].
class ChoiceOption<T> {
  const ChoiceOption({required this.value, required this.label, this.detail});

  final T value;
  final String label;
  final String? detail;
}

/// Hoja con opciones excluyentes (radio). Devuelve el valor elegido o `null`
/// si se cierra sin elegir.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  String? message,
  required List<ChoiceOption<T>> options,
  required T? selected,
}) {
  return showBlurSheet<T>(
    context,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: title, message: message),
        for (final o in options)
          ChoiceTile(
            label: o.label,
            detail: o.detail,
            selected: o.value == selected,
            onTap: () => Navigator.of(context).pop(o.value),
          ),
      ],
    ),
  );
}

/// Fila radio (>= 56 px) con etiqueta semántica "Etiqueta. Detalle".
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: detail == null ? label : '$label. $detail',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: AppRadii.mdAll,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.rowHeight),
          child: Padding(
            padding: AppSpacing.card,
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? AppColors.accentLight
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: AppTypography.body),
                      if (detail != null)
                        Text(detail!, style: AppTypography.caption),
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

/// Hoja de confirmación. `true` si se confirma.
Future<bool> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  IconData? icon,
  String cancelLabel = 'Cancelar',
}) async {
  final result = await showBlurSheet<bool>(
    context,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: title, message: message),
        AppFilledButton(
          label: confirmLabel,
          icon: icon,
          destructive: destructive,
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: cancelLabel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    ),
  );
  return result ?? false;
}
