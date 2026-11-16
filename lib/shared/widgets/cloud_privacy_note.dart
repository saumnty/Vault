import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// Texto corto, siempre visible, sobre qué pasa con lo que se sube a Drive.
const String cloudPrivacySummary =
    'Tus archivos se suben cifrados a una carpeta oculta de tu Google Drive. '
    'No se ven en Drive ni en Google Fotos, y nadie puede leerlos sin tu PIN '
    'o tu código de recuperación.';

/// Detalle expandible: cómo ver o borrar ese espacio y la recomendación de
/// seguridad de la cuenta.
const String cloudPrivacyViewDelete =
    'Para ver cuánto ocupa o borrarlo: entra a drive.google.com > '
    'Configuración (el engranaje) > Administrar aplicaciones > Vault.';
const String cloudPrivacyTwoStep =
    'Te recomendamos activar la verificación en dos pasos de tu cuenta de '
    'Google: protege tu cuenta, y con ella tu respaldo.';

/// Bloque informativo reutilizable (hoja de Sincronización y Ajustes): resumen
/// visible y detalle que se despliega al tocar "Más información".
class CloudPrivacyNote extends StatefulWidget {
  const CloudPrivacyNote({super.key, this.initiallyExpanded = false});

  final bool initiallyExpanded;

  @override
  State<CloudPrivacyNote> createState() => _CloudPrivacyNoteState();
}

class _CloudPrivacyNoteState extends State<CloudPrivacyNote> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: AppSpacing.card,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: AppRadii.mdAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.lock_outline,
                color: AppColors.accentLight,
                size: AppSizes.iconMd,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  cloudPrivacySummary,
                  style: AppTypography.bodySecondary,
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: AppMotion.fast,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          cloudPrivacyViewDelete,
                          style: AppTypography.caption,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        const Text(
                          cloudPrivacyTwoStep,
                          style: AppTypography.caption,
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              expanded: _expanded,
              label: _expanded ? 'Ocultar detalles' : 'Más información',
              excludeSemantics: true,
              onTap: () => setState(() => _expanded = !_expanded),
              child: InkWell(
                borderRadius: AppRadii.smAll,
                onTap: () => setState(() => _expanded = !_expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AppSizes.fabMini),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _expanded ? 'Ocultar detalles' : 'Más información',
                        style: AppTypography.label.copyWith(
                          color: AppColors.accentLight,
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        color: AppColors.accentLight,
                        size: AppSizes.iconMd,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
