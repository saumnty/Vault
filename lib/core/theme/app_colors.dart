import 'package:flutter/painting.dart';

/// Paleta de Vault. Identidad: fondo OLED y acento morado neón.
///
/// Contraste (WCAG) sobre [background]: [textPrimary] ~18:1, [textSecondary]
/// ~7.7:1, [accentLight] ~7:1. [accent] (~3.1:1) es solo para rellenos y
/// elementos grandes; el texto sobre [accent] es [onAccent] (~6.4:1).
abstract final class AppColors {
  // Superficies
  static const Color background = Color(0xFF0B0B0E);
  static const Color surface = Color(0xFF16161B);
  static const Color surfaceHigh = Color(0xFF1F1F26);
  static const Color surfaceHighest = Color(0xFF2A2A33);
  static const Color border = Color(0xFF2E2E38);
  static const Color viewerBackground = Color(0xFF000000);

  // Acento
  static const Color accent = Color(0xFF7C3AED);
  static const Color accentLight = Color(0xFFA78BFA);
  static const Color accentContainer = Color(0xFF2A1A52);
  static const Color onAccent = Color(0xFFFFFFFF);

  // Texto
  static const Color textPrimary = Color(0xFFF4F4F5);
  static const Color textSecondary = Color(0xFFA1A1AA);

  // Semánticos (legibles sobre fondo oscuro)
  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);
  static const Color dangerFill = Color(0xFFDC2626);
  static const Color info = Color(0xFF60A5FA);

  // Utilidades
  static const Color transparent = Color(0x00000000);
  static const Color scrim = Color(0xB3000000);
  static const Color scrimSoft = Color(0x80000000);
  static const Color sheetSurface = Color(0xC71F1F26);
  static const Color shadow = Color(0x66000000);
  static const Color glow = Color(0x667C3AED);
  static const Color overlayLight = Color(0x1FFFFFFF);
  static const Color thumbGradientEnd = Color(0xCC000000);
  static const Color shimmerBase = surface;
  static const Color shimmerHighlight = surfaceHighest;
}
