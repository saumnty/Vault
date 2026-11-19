import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Tipografía. Usa la fuente del sistema (Roboto en Android, SF en iOS):
/// no se descargan ni empaquetan fuentes.
abstract final class AppTypography {
  static const TextStyle display = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    height: 1.15,
    color: AppColors.textPrimary,
  );
  static const TextStyle title = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: AppColors.textPrimary,
  );
  static const TextStyle titleSmall = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.25,
    color: AppColors.textPrimary,
  );
  static const TextStyle body = TextStyle(
    fontSize: 16,
    height: 1.4,
    color: AppColors.textPrimary,
  );
  static const TextStyle bodySecondary = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: AppColors.textSecondary,
  );
  static const TextStyle label = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    color: AppColors.textSecondary,
  );
  static const TextStyle captionOnMedia = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );
  static const TextStyle pinDigit = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );
  static const TextStyle button = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.onAccent,
  );
  static const TextStyle code = TextStyle(
    fontSize: 18,
    fontFamily: 'monospace',
    letterSpacing: 1.4,
    height: 1.5,
    color: AppColors.textPrimary,
  );

  /// Líneas del registro de Diagnóstico (monoespaciado compacto).
  static const TextStyle log = TextStyle(
    fontSize: 11,
    fontFamily: 'monospace',
    height: 1.4,
    color: AppColors.textSecondary,
  );

  /// Campo donde se escribe el código completo (29 caracteres con guiones):
  /// más compacto que [code] para que quepa en una línea en el teléfono.
  static const TextStyle codeInput = TextStyle(
    fontSize: 15,
    fontFamily: 'monospace',
    letterSpacing: 0.4,
    height: 1.5,
    color: AppColors.textPrimary,
  );

  static const TextTheme textTheme = TextTheme(
    displaySmall: display,
    headlineSmall: title,
    titleMedium: titleSmall,
    bodyLarge: body,
    bodyMedium: bodySecondary,
    bodySmall: caption,
    labelLarge: label,
  );
}
