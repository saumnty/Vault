import 'package:flutter/services.dart';

/// Háptica centralizada. En plataformas sin motor háptico (escritorio, web)
/// `HapticFeedback` no hace nada.
abstract final class AppHaptics {
  /// Selección / cambio de modo.
  static Future<void> selection() => HapticFeedback.selectionClick();

  /// PIN correcto.
  static Future<void> success() => HapticFeedback.mediumImpact();

  /// PIN incorrecto.
  static Future<void> error() => HapticFeedback.heavyImpact();

  /// Eliminar.
  static Future<void> destructive() => HapticFeedback.vibrate();
}
