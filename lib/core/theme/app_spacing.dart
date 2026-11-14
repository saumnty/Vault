import 'package:flutter/widgets.dart';

/// Escala de espaciado (múltiplos de 4).
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;

  static const EdgeInsets page = EdgeInsets.all(lg);
  static const EdgeInsets pageHorizontal = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets card = EdgeInsets.all(md);
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(lg, sm, lg, lg);
  static const EdgeInsets gridPage = EdgeInsets.fromLTRB(
    lg,
    sm,
    lg,
    AppSizes.fabClearance,
  );
}

/// Tamaños fijos de componentes.
abstract final class AppSizes {
  /// Área táctil mínima (accesibilidad).
  static const double minTouch = 44;

  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;
  static const double iconXl = 32;
  static const double iconHero = 48;

  static const double statusBadge = 22;
  static const double statusStroke = 2;
  static const double selectBadge = 24;
  static const double checkIcon = 16;

  static const double keypadKey = 72;
  static const double keypadGap = 16;
  static const double pinDot = 14;
  static const double pinDotGap = 16;
  static const double pinMaxWidth = 320;

  static const double fab = 56;
  static const double fabMini = 48;
  static const double fabClearance = 112;
  static const double toolbar = 56;

  static const double rowHeight = 72;
  static const double rowThumb = 52;
  static const double swipeAction = 84;
  static const double sheetHandleWidth = 40;
  static const double sheetHandleHeight = 4;

  static const double illustration = 176;
  static const double searchMaxWidth = 480;
  static const double breadcrumbHeight = 36;
  static const double progressStroke = 3;
}

/// Rejilla de archivos.
abstract final class AppGrid {
  static const int minColumns = 1;
  static const int maxColumns = 5;
  static const int defaultColumns = 3;
  static const double gap = AppSpacing.sm;

  /// Escala acumulada del gesto de pellizco que dispara un cambio de columnas.
  static const double pinchZoomIn = 1.25;
  static const double pinchZoomOut = 0.8;
}
