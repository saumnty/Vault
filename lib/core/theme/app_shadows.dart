import 'package:flutter/painting.dart';

import 'app_colors.dart';

abstract final class AppShadows {
  static const List<BoxShadow> card = [
    BoxShadow(color: AppColors.shadow, blurRadius: 12, offset: Offset(0, 4)),
  ];

  static const List<BoxShadow> fab = [
    BoxShadow(color: AppColors.glow, blurRadius: 24, offset: Offset(0, 8)),
  ];

  static const List<BoxShadow> glow = [
    BoxShadow(color: AppColors.glow, blurRadius: 32, spreadRadius: 2),
  ];

  /// Desenfoque del fondo de las hojas modales.
  static const double sheetBlur = 24;
}
