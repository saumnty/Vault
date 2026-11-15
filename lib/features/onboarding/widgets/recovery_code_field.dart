import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/crypto/key_recovery_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';

/// Estado de lo escrito en el campo del código de recuperación.
enum CodeFieldState { empty, incomplete, invalidChars, valid }

/// Evalúa lo escrito: tolera minúsculas, espacios y guiones (se ignoran).
CodeFieldState evaluateRecoveryInput(String text) {
  final cleaned = _clean(text);
  if (cleaned.isEmpty) return CodeFieldState.empty;
  for (final ch in cleaned.split('')) {
    if (!RecoveryCode.alphabet.contains(ch)) return CodeFieldState.invalidChars;
  }
  return cleaned.length == RecoveryCode.length
      ? CodeFieldState.valid
      : CodeFieldState.incomplete;
}

/// Mensaje en vivo para un estado (`null` si no hace falta).
String? recoveryInputHint(String text) {
  final cleaned = _clean(text);
  switch (evaluateRecoveryInput(text)) {
    case CodeFieldState.empty:
    case CodeFieldState.valid:
      return null;
    case CodeFieldState.invalidChars:
      return 'Hay caracteres que no forman parte del código. Se usan letras '
          '(sin I, L ni O) y números del 2 al 9.';
    case CodeFieldState.incomplete:
      final missing = RecoveryCode.length - cleaned.length;
      return missing > 0
          ? 'Faltan $missing caracteres.'
          : 'Sobran ${-missing} caracteres.';
  }
}

String _clean(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[\s\-_.]'), '');

/// Formatea mientras se escribe: mayúsculas, sin separadores ni símbolos y en
/// grupos de 4 separados por guion. Tope de 24 caracteres.
class RecoveryCodeInputFormatter extends TextInputFormatter {
  const RecoveryCodeInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var cleaned = _clean(newValue.text).replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (cleaned.length > RecoveryCode.length) {
      cleaned = cleaned.substring(0, RecoveryCode.length);
    }
    final grouped = RecoveryCode.format(cleaned);
    return TextEditingValue(
      text: grouped,
      selection: TextSelection.collapsed(offset: grouped.length),
    );
  }
}

/// Campo del código de recuperación: no autocompleta, no aprende, no se
/// guarda ni se registra en ninguna parte.
class RecoveryCodeField extends StatelessWidget {
  const RecoveryCodeField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.error,
    this.enabled = true,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;

  /// Error del último intento ("Código incorrecto").
  final String? error;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final hasError = error != null;
    return Semantics(
      textField: true,
      label: 'Código de recuperación',
      child: TextField(
        key: const ValueKey('restore-code-field'),
        controller: controller,
        enabled: enabled,
        autofocus: true,
        textAlign: TextAlign.center,
        textCapitalization: TextCapitalization.characters,
        keyboardType: TextInputType.visiblePassword,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        style: AppTypography.codeInput,
        inputFormatters: const [RecoveryCodeInputFormatter()],
        onChanged: onChanged,
        onSubmitted: (_) => onSubmitted?.call(),
        decoration: InputDecoration(
          filled: true,
          fillColor: AppColors.surfaceHigh,
          contentPadding: AppSpacing.card,
          hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
          hintStyle: AppTypography.bodySecondary,
          border: OutlineInputBorder(
            borderRadius: AppRadii.mdAll,
            borderSide: BorderSide(
              color: hasError ? AppColors.danger : AppColors.border,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadii.mdAll,
            borderSide: BorderSide(
              color: hasError ? AppColors.danger : AppColors.accentLight,
            ),
          ),
        ),
      ),
    );
  }
}
