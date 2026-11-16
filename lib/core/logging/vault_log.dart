import 'package:flutter/foundation.dart';

import 'diagnostics_buffer.dart';

/// S-12: logger central. En depuración imprime el mensaje; en release NO emite
/// nada por consola (logcat/Console son legibles por otros procesos con adb).
/// Para errores ([error]) solo se registra el `runtimeType`, nunca
/// `toString()`: una `FileSystemException` incluye rutas/nombres de archivo.
///
/// Además, SIEMPRE (también en release) alimenta el [DiagnosticsBuffer] en
/// memoria que muestra Ajustes > Acerca de > Diagnóstico. [category] es una
/// etiqueta corta fija (import, thumbs, sync, migration, auth, ui...).
class VaultLog {
  VaultLog._();

  /// Indica si se debe emitir salida. Inyectable en pruebas.
  static bool Function() isDebug = () => kDebugMode;

  /// Destino de la salida. Inyectable en pruebas.
  static void Function(String message) sink = _defaultSink;

  static void _defaultSink(String message) => debugPrint(message);

  /// Mensaje fijo (sin datos del usuario). Consola solo en depuración; el
  /// búfer de diagnóstico siempre.
  static void d(String message, {String category = 'app'}) {
    DiagnosticsBuffer.instance.add(DiagLevel.debug, category, message);
    if (!isDebug()) return;
    sink(message);
  }

  /// Registra [message] y, si hay [error], solo su `runtimeType`.
  static void e(String message, [Object? error, String category = 'app']) {
    final line = error == null ? message : '$message (${error.runtimeType})';
    DiagnosticsBuffer.instance.add(DiagLevel.error, category, line);
    if (!isDebug()) return;
    sink(line);
  }

  /// Solo pruebas: restaura valores por defecto.
  @visibleForTesting
  static void reset() {
    isDebug = () => kDebugMode;
    sink = _defaultSink;
  }
}
