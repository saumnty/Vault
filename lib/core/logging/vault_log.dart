import 'package:flutter/foundation.dart';

/// S-12: logger central. En depuración imprime el mensaje; en release NO emite
/// nada (logcat/Console son legibles por otros procesos con adb). Para errores
/// ([error]) solo se registra el `runtimeType`, nunca `toString()`: una
/// `FileSystemException` incluye rutas/nombres de archivo.
class VaultLog {
  VaultLog._();

  /// Indica si se debe emitir salida. Inyectable en pruebas.
  static bool Function() isDebug = () => kDebugMode;

  /// Destino de la salida. Inyectable en pruebas.
  static void Function(String message) sink = _defaultSink;

  static void _defaultSink(String message) => debugPrint(message);

  /// Mensaje fijo (sin datos del usuario). Silencioso en release.
  static void d(String message) {
    if (!isDebug()) return;
    sink(message);
  }

  /// Registra [message] y, si hay [error], solo su `runtimeType`.
  static void e(String message, [Object? error]) {
    if (!isDebug()) return;
    sink(error == null ? message : '$message (${error.runtimeType})');
  }

  /// Solo pruebas: restaura valores por defecto.
  @visibleForTesting
  static void reset() {
    isDebug = () => kDebugMode;
    sink = _defaultSink;
  }
}
