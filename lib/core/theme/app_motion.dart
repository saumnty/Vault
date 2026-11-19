import 'package:flutter/animation.dart';

/// Duraciones y curvas de animación.
abstract final class AppMotion {
  static const Duration instant = Duration(milliseconds: 80);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 450);

  /// Desfase entre celdas de la cuadrícula al aparecer.
  static const Duration stagger = Duration(milliseconds: 45);
  static const int maxStaggerSteps = 10;

  static const Duration shimmer = Duration(milliseconds: 1400);
  static const Duration shake = Duration(milliseconds: 420);
  static const Duration unlock = Duration(milliseconds: 380);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve spring = Curves.easeOutBack;
}
