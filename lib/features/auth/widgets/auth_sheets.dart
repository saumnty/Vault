import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/blur_sheet.dart';

/// Muestra el código de recuperación UNA sola vez. No se puede cerrar sin
/// pulsar el botón (ni con el gesto atrás).
Future<void> showRecoveryCodeSheet(BuildContext context, String code) {
  return showBlurSheet<void>(
    context,
    dismissible: false,
    builder: (context) => RecoveryCodeContent(code: code),
  );
}

/// Parte el código (`XXXX-XXXX-...`) en filas de 3 grupos.
List<List<String>> _groupRows(String code) {
  final groups = code.split('-').where((g) => g.isNotEmpty).toList();
  return [
    for (var i = 0; i < groups.length; i += 3)
      groups.sublist(i, i + 3 > groups.length ? groups.length : i + 3),
  ];
}

class RecoveryCodeContent extends StatelessWidget {
  const RecoveryCodeContent({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(
            title: 'Código de recuperación',
            message:
                'Anótalo y guárdalo fuera del teléfono. Es la única forma de '
                'recuperar tu bóveda si olvidas el PIN o cambias de teléfono. '
                'No se volverá a mostrar.',
          ),
          Container(
            padding: AppSpacing.page,
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: AppRadii.mdAll,
              border: Border.all(color: AppColors.accent),
            ),
            child: Semantics(
              label: 'Código de recuperación: $code',
              // Cada grupo de 4 caracteres es un widget indivisible: nunca se
              // parte entre líneas. Se muestran 3 grupos por fila.
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final row in _groupRows(code))
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final group in row)
                            Padding(
                              padding: AppSpacing.recoveryGroup,
                              child: SelectableText(
                                group,
                                maxLines: 1,
                                style: AppTypography.code,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          // Sin botón "Copiar" a propósito: el portapapeles es legible por
          // otras apps y por la sincronización de portapapeles del sistema.
          AppFilledButton(
            label: 'Ya lo guardé',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Ofrece activar el desbloqueo biométrico. `true` = activar.
Future<bool> showBiometricOfferSheet(BuildContext context) async {
  final result = await showBlurSheet<bool>(
    context,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader(
          title: 'Desbloqueo biométrico',
          message: '¿Quieres desbloquear Vault con tu huella o rostro?',
        ),
        AppFilledButton(
          label: 'Activar',
          icon: Icons.fingerprint,
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Ahora no',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    ),
  );
  return result ?? false;
}
