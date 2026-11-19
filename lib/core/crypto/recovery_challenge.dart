import 'dart:math';

import 'key_recovery_service.dart';

/// Desafío de confirmación del código de recuperación (F8): pide escribir
/// [count] caracteres del código elegidos al azar por POSICIÓN (p. ej. "el
/// 3.º, 9.º, 14.º y 22.º"), para comprobar que el usuario lo anotó sin
/// pedirle que lo reescriba entero (que invitaría a copiar y pegar).
///
/// * Las posiciones son distintas y están ORDENADAS, base 1.
/// * La comparación normaliza (mayúsculas; sin espacios, guiones, puntos ni
///   guiones bajos) y es de tiempo constante respecto al contenido.
class RecoveryCodeChallenge {
  RecoveryCodeChallenge._(this._code, this.positions);

  /// Elige las posiciones con [random] (inyectable para pruebas
  /// reproducibles; por defecto `Random.secure`). [code] puede venir en
  /// grupos ("ABCD-EFGH-...").
  factory RecoveryCodeChallenge.generate(
    String code, {
    Random? random,
    int count = defaultCount,
  }) {
    final normalized = RecoveryCode.normalize(code);
    if (normalized == null) {
      throw ArgumentError('Código de recuperación con formato inválido');
    }
    if (count < 1 || count > normalized.length) {
      throw ArgumentError.value(count, 'count', 'fuera de rango');
    }
    final rng = random ?? Random.secure();
    final all = List<int>.generate(normalized.length, (i) => i + 1)
      ..shuffle(rng);
    final positions = all.take(count).toList()..sort();
    return RecoveryCodeChallenge._(normalized, List.unmodifiable(positions));
  }

  static const int defaultCount = 4;

  final String _code;

  /// Posiciones pedidas (base 1, ascendentes, sin repetir).
  final List<int> positions;

  int get count => positions.length;

  /// "3.º, 9.º, 14.º y 22.º".
  String get positionsLabel {
    final labels = [for (final p in positions) '$p.º'];
    if (labels.length == 1) return labels.first;
    return '${labels.sublist(0, labels.length - 1).join(', ')} y ${labels.last}';
  }

  /// Normaliza lo que escribe el usuario.
  static String normalizeInput(String input) =>
      input.toUpperCase().replaceAll(RegExp(r'[\s\-_.]'), '');

  /// `true` si [input] son exactamente los caracteres pedidos, en orden.
  bool verify(String input) {
    final expected = [for (final p in positions) _code[p - 1]].join();
    return constantTimeEquals(normalizeInput(input), expected);
  }

  /// Comparación sin salida temprana: recorre siempre la longitud del mayor.
  static bool constantTimeEquals(String a, String b) {
    var diff = a.length ^ b.length;
    final n = max(a.length, b.length);
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a.codeUnitAt(i) : 0;
      final y = i < b.length ? b.codeUnitAt(i) : 0;
      diff |= x ^ y;
    }
    return diff == 0;
  }
}
