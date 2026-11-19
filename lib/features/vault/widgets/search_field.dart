import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_buttons.dart';

/// Campo de búsqueda de la barra superior (aparece con animación de tamaño).
class VaultSearchField extends StatelessWidget {
  const VaultSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSizes.minTouch,
      decoration: const BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: AppRadii.pillAll,
      ),
      child: Row(
        children: [
          const SizedBox(width: AppSpacing.md),
          const ExcludeSemantics(
            child: Icon(
              Icons.search,
              size: AppSizes.iconMd,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Semantics(
              textField: true,
              label: 'Buscar en esta carpeta',
              child: TextField(
                controller: controller,
                autofocus: true,
                // S-13: la búsqueda no entra en el aprendizaje del teclado.
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                onChanged: onChanged,
                style: AppTypography.body,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Buscar en esta carpeta',
                  hintStyle: AppTypography.bodySecondary,
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
          AppIconButton(
            icon: Icons.close,
            label: 'Cerrar búsqueda',
            onPressed: onClose,
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }
}
