import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_radii.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// Tema global de Vault (oscuro OLED + acento morado).
abstract final class AppTheme {
  static const ColorScheme _scheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.accentLight,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    error: AppColors.danger,
    outline: AppColors.border,
  );

  /// Barra de estado/navegación transparente con iconos claros.
  static const SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle(
    statusBarColor: AppColors.transparent,
    statusBarIconBrightness: Brightness.light,
    // iOS: statusBarBrightness describe el FONDO (dark = iconos claros).
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: AppColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
  );

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: _scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    textTheme: AppTypography.textTheme,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: overlayStyle,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHighest,
      contentTextStyle: AppTypography.body,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.mdAll),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accentLight,
    ),
    iconTheme: const IconThemeData(
      color: AppColors.textPrimary,
      size: AppSizes.iconLg,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.accentLight,
      selectionColor: AppColors.accentContainer,
    ),
  );
}
