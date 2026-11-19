import 'dart:async';

import 'package:sqflite_sqlcipher/sqflite.dart';

import 'diagnostics_buffer.dart';

/// D78 (parte B, `docs/DISENO_MIGRACION_ATASCADA.md` §B.5): diagnóstico
/// PERSISTENTE. Guarda las últimas [capacity] entradas del
/// [DiagnosticsBuffer] en la tabla `diag_events` de la BD de la bóveda
/// principal (SQLCipher: cifrada en disco). Sobrevive a bloquear y a
/// reiniciar la app.
///
/// Reglas:
/// * Mismas reglas de privacidad que el búfer: recibe las entradas YA
///   saneadas (`DiagnosticsBuffer.sanitize`) y nunca escribe otra cosa.
/// * Solo con la bóveda PRINCIPAL abierta. Con la adicional abierta las
///   entradas se descartan (D70: nada de la adicional llega a la principal).
///   Con la sesión bloqueada se guardan en memoria y se escriben en el
///   siguiente desbloqueo de la principal; si la siguiente apertura es de
///   OTRA bóveda (cambio de bóveda) se descartan ([DiagnosticsBuffer.slotChanged]).
/// * Escribe en lotes (cada [flushDelay]), serializados, directamente con la
///   BD: nunca pasa por `VaultDataRepository`, así que no marca «sucio» el
///   snapshot.
/// * Suspendido ([suspended]) mientras la BD se re-cifra o se copia para el
///   snapshot (la verificación de `rekeyTo` cuenta filas por tabla).
/// * Fuera de la nube: `exportEncryptedSnapshot` vacía la tabla en la COPIA
///   y la restauración la vacía.
/// * Un error al escribir se ignora (y nunca se registra a sí mismo).
class DiagnosticsStore {
  DiagnosticsStore({
    required this.buffer,
    required Future<Database> Function() dbProvider,
    required this.primaryOpen,
    required this.secondaryOpen,
    this.suspended,
    this.capacity = 500,
    this.flushDelay = const Duration(seconds: 2),
  }) : _db = dbProvider;

  /// Instancia de la app (la crea `VaultServices` para la principal). `null`
  /// = sin persistencia (pruebas antiguas, adicional).
  static DiagnosticsStore? instance;

  final DiagnosticsBuffer buffer;
  final Future<Database> Function() _db;

  /// `true` con la bóveda principal abierta.
  final bool Function() primaryOpen;

  /// `true` con la bóveda adicional abierta.
  final bool Function() secondaryOpen;

  /// `true` mientras no se debe escribir (re-cifrado, copia del snapshot).
  final bool Function()? suspended;
  final int capacity;
  final Duration flushDelay;

  final List<DiagEntry> _pending = [];
  Timer? _timer;
  Future<void>? _flushing;

  /// Entradas aún sin escribir (pruebas y pantalla).
  int get pendingCount => _pending.length;

  bool _installed = false;

  /// Engancha el almacén al búfer (idempotente). La primera vez recoge lo
  /// que el búfer ya tenía en memoria (p. ej. el arranque antes de abrir).
  void install() {
    buffer.sink = _onEntry;
    buffer.onSlotChanged = _dropPending;
    if (_installed) return;
    _installed = true;
    if (!secondaryOpen()) {
      for (final e in buffer.entries) {
        _onEntry(e);
      }
    }
  }

  /// Lo desengancha (pruebas).
  void uninstall() {
    if (buffer.sink == _onEntry) buffer.sink = null;
    if (buffer.onSlotChanged == _dropPending) buffer.onSlotChanged = null;
    _timer?.cancel();
    _timer = null;
  }

  void _onEntry(DiagEntry e) {
    if (secondaryOpen()) return; // D70
    _pending.add(e);
    while (_pending.length > capacity) {
      _pending.removeAt(0);
    }
    _schedule();
  }

  void _dropPending() {
    _pending.clear();
  }

  void _schedule() {
    if (_timer != null) return;
    _timer = Timer(flushDelay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Escribe lo pendiente (si la principal está abierta). Serializado.
  Future<void> flush() async {
    while (_flushing != null) {
      await _flushing;
    }
    final f = _flushing = _doFlush();
    try {
      await f;
    } finally {
      if (identical(_flushing, f)) _flushing = null;
    }
  }

  Future<void> _doFlush() async {
    if (_pending.isEmpty) return;
    if (!primaryOpen()) return;
    if (suspended?.call() ?? false) {
      _schedule(); // se reintenta al terminar el re-cifrado o la copia
      return;
    }
    final batch = List<DiagEntry>.of(_pending);
    try {
      final db = await _db();
      if (!primaryOpen()) return;
      await db.transaction((txn) async {
        final b = txn.batch();
        for (final e in batch) {
          b.insert('diag_events', {
            'at': e.time.millisecondsSinceEpoch,
            'level': e.level == DiagLevel.error ? 'E' : 'D',
            'category': e.category,
            'message': e.message,
          });
        }
        await b.commit(noResult: true);
        // Anillo: solo las últimas [capacity].
        await txn.rawDelete(
          'DELETE FROM diag_events WHERE id <= '
          '(SELECT MAX(id) FROM diag_events) - ?',
          [capacity],
        );
      });
      final written = Set<DiagEntry>.identity()..addAll(batch);
      _pending.removeWhere(written.contains);
    } on Object {
      // BD cerrada o tabla ausente: se reintenta con la próxima entrada o
      // en el próximo desbloqueo. Nunca se registra (sería recursivo).
    }
  }

  /// Entradas persistidas + pendientes, de la más antigua a la más reciente.
  /// Sin la principal abierta, solo lo que hay en memoria.
  Future<List<DiagEntry>> entries() async {
    await flush();
    final out = <DiagEntry>[];
    if (primaryOpen()) {
      try {
        final db = await _db();
        final rows = await db.query('diag_events', orderBy: 'id ASC');
        for (final r in rows) {
          out.add(
            DiagEntry(
              DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
              r['level'] == 'E' ? DiagLevel.error : DiagLevel.debug,
              r['category'] as String,
              r['message'] as String,
            ),
          );
        }
      } on Object {
        // sin tabla o BD cerrada
      }
    }
    out.addAll(_pending);
    if (out.length > capacity) return out.sublist(out.length - capacity);
    return out;
  }

  /// «Borrar diagnóstico»: tabla, pendientes y memoria.
  Future<void> clearAll() async {
    _pending.clear();
    buffer.clear();
    if (!primaryOpen()) return;
    try {
      final db = await _db();
      await db.delete('diag_events');
    } on Object {
      // BD cerrada: se reintenta al volver a pulsar
    }
  }
}
