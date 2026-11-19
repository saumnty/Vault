import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Nivel de una entrada de diagnóstico.
enum DiagLevel { debug, error }

/// Entrada del búfer: solo datos no sensibles.
@immutable
class DiagEntry {
  const DiagEntry(this.time, this.level, this.category, this.message);

  final DateTime time;
  final DiagLevel level;
  final String category;
  final String message;

  String format() {
    final t = time.toUtc().toIso8601String();
    final l = level == DiagLevel.error ? 'E' : 'D';
    return '$t $l [$category] $message';
  }
}

/// Búfer circular en memoria (~500 líneas) para la pantalla de Diagnóstico.
/// Registra SIEMPRE (también en release) pero nunca sale del proceso salvo
/// que el usuario lo copie. Solo mensajes fijos y `runtimeType` de errores;
/// además [sanitize] redacta por regex lo que parezca dato del usuario
/// (red de seguridad). Se vacía al bloquear la bóveda.
class DiagnosticsBuffer {
  DiagnosticsBuffer({this.capacity = 500, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Instancia global (inyectable en pruebas).
  static DiagnosticsBuffer instance = DiagnosticsBuffer();

  final int capacity;
  final DateTime Function() _clock;
  final Queue<DiagEntry> _entries = Queue<DiagEntry>();

  /// Cambia al añadir o borrar (la pantalla se refresca).
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<DiagEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// D78 (parte B): destino persistente (`DiagnosticsStore`). Recibe cada
  /// entrada YA saneada. Nunca debe registrar nada (sería recursivo).
  void Function(DiagEntry entry)? sink;

  /// D78: se llama al cambiar de bóveda (B5): lo que el destino persistente
  /// tenga aún sin escribir se descarta (podría venir de la otra bóveda).
  void Function()? onSlotChanged;

  void add(DiagLevel level, String category, String message) {
    final entry = DiagEntry(
      _clock(),
      level,
      sanitize(category, max: 16),
      sanitize(message),
    );
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    revision.value++;
    final s = sink;
    if (s != null) {
      try {
        s(entry);
      } on Object {
        // el destino persistente nunca rompe el registro
      }
    }
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    revision.value++;
  }

  /// D78: cambio de bóveda (lo llama `AuthController`, B5): vacía la memoria
  /// y descarta lo pendiente de persistir.
  void slotChanged() {
    clear();
    try {
      onSlotChanged?.call();
    } on Object {
      // ignorado
    }
  }

  /// Texto exportable (una línea por entrada).
  String export() => _entries.map((e) => e.format()).join('\n');

  static final RegExp _email = RegExp(r'\S+@\S+');
  static final RegExp _uuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  );
  static final RegExp _path = RegExp(r'\S*[\\/]\S*');
  static final RegExp _token = RegExp(r'[A-Za-z0-9+/=_\-]{24,}');

  /// Redacta correos, rutas, UUID y tokens largos; recorta a [max] chars.
  static String sanitize(String input, {int max = 200}) {
    var s = input
        .replaceAll(_email, '<redacted>')
        .replaceAll(_uuid, '<redacted>')
        .replaceAll(_path, '<redacted>')
        .replaceAll(_token, '<redacted>')
        .replaceAll(RegExp(r'[\r\n]+'), ' ');
    if (s.length > max) s = s.substring(0, max);
    return s;
  }
}
