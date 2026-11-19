import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'diagnostics_buffer.dart';

/// D83: estado del almacén persistente para la pantalla Diagnóstico. Solo
/// conteos y el NOMBRE del tipo del último error (nunca su mensaje: podría
/// llevar rutas). Nunca se registra en el búfer (sería recursivo).
@immutable
class DiagnosticsStoreHealth {
  const DiagnosticsStoreHealth({
    this.unsaved = 0,
    this.failures = 0,
    this.lastError,
    this.dropped = 0,
    this.readFailed = false,
  });

  static const ok = DiagnosticsStoreHealth();

  /// Eventos en memoria que no se pudieron guardar todavía.
  final int unsaved;

  /// Intentos de escritura fallidos seguidos (0 = el último fue bien).
  final int failures;

  /// Tipo del último fallo (`DatabaseException`, `tiempo agotado`, ...).
  final String? lastError;

  /// Eventos descartados por el límite mientras no se podía guardar.
  final int dropped;

  /// La última lectura de la tabla falló (la pantalla muestra solo memoria).
  final bool readFailed;

  bool get healthy => failures == 0 && dropped == 0 && !readFailed;

  /// Línea para la pantalla y el texto copiado (sin datos personales).
  String describe() {
    final parts = <String>[];
    if (failures > 0) {
      parts.add(
        'El diagnóstico no pudo guardar $unsaved '
        '${unsaved == 1 ? 'evento' : 'eventos'} '
        '(${lastError ?? 'error'}; $failures '
        '${failures == 1 ? 'intento' : 'intentos'}). Se reintenta solo.',
      );
    }
    if (dropped > 0) {
      parts.add('Descartados por el límite sin guardar: $dropped.');
    }
    if (readFailed) {
      parts.add('No se pudieron leer los eventos guardados: solo memoria.');
    }
    return parts.join(' ');
  }

  @override
  bool operator ==(Object other) =>
      other is DiagnosticsStoreHealth &&
      other.unsaved == unsaved &&
      other.failures == failures &&
      other.lastError == lastError &&
      other.dropped == dropped &&
      other.readFailed == readFailed;

  @override
  int get hashCode =>
      Object.hash(unsaved, failures, lastError, dropped, readFailed);
}

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
///
/// D83 (BUG-1, «el diagnóstico deja de mostrar eventos nuevos»): nunca un
/// fallo silencioso total ni una espera sin fin:
/// * cada operación con la BD tiene un tope ([opTimeout]); una escritura que
///   no termina ya no deja colgados para siempre los `flush()` siguientes,
///   ni la lectura de la pantalla, ni el paso «diagnóstico» del desbloqueo;
/// * si escribir falla, lo pendiente se conserva (hasta [capacity]) y se
///   reintenta con espera creciente (hasta [maxBackoff]);
/// * [health] expone «no pudo guardar N eventos» (conteos y tipo del error),
///   que la pantalla muestra; nunca se registra a sí mismo;
/// * escritura y lectura son exclusivas: un evento nunca queda «ni en la
///   tabla ni en pendientes» en lo que lee la pantalla.
class DiagnosticsStore {
  DiagnosticsStore({
    required this.buffer,
    required Future<Database> Function() dbProvider,
    required this.primaryOpen,
    required this.secondaryOpen,
    this.suspended,
    this.capacity = 500,
    this.flushDelay = const Duration(seconds: 2),
    this.opTimeout = const Duration(seconds: 10),
    this.maxBackoff = const Duration(minutes: 1),
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

  /// D83: tope de cada operación con la BD (abrir + escribir, o leer).
  final Duration opTimeout;

  /// D83: espera máxima entre reintentos tras fallos seguidos.
  final Duration maxBackoff;

  final List<DiagEntry> _pending = [];
  Timer? _timer;

  /// D83: operación con la BD en curso (escritura o lectura). Puede seguir
  /// viva después de superar [opTimeout]: mientras tanto no se empieza otra
  /// (nada de escrituras duplicadas) pero nadie la espera más del tope.
  Future<void>? _busy;

  /// D83: la operación en curso ya superó el tope (se da por colgada: los
  /// siguientes no esperan).
  bool _busyStuck = false;

  int _failures = 0;
  String? _lastError;
  int _dropped = 0;
  bool _readFailed = false;

  /// D83: estado para la pantalla (sin datos personales).
  final ValueNotifier<DiagnosticsStoreHealth> health =
      ValueNotifier<DiagnosticsStoreHealth>(DiagnosticsStoreHealth.ok);

  /// Entradas aún sin escribir (pruebas y pantalla).
  int get pendingCount => _pending.length;

  /// Engancha el almacén al búfer (idempotente). Recoge lo que el búfer
  /// registró sin destino (p. ej. el arranque antes de abrir). D83: solo eso:
  /// un almacén re-creado no duplica lo que el anterior ya recibió.
  void install() {
    final undelivered = buffer.takeUndelivered();
    buffer.sink = _onEntry;
    buffer.onSlotChanged = _dropPending;
    for (final e in undelivered) {
      _onEntry(e);
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
      // Solo cuenta como pérdida si no se puede escribir (con la sesión
      // bloqueada el límite es el normal del anillo).
      if (_failures > 0) _dropped++;
    }
    if (_failures > 0) _publish();
    _schedule();
  }

  void _dropPending() {
    _pending.clear();
    if (_failures > 0) _publish();
  }

  void _schedule([Duration? delay]) {
    if (_timer != null) return;
    _timer = Timer(delay ?? flushDelay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Espera tras [_failures] fallos seguidos: flushDelay·2^n, con tope.
  Duration get _backoff {
    final n = math.min(_failures, 16);
    final ms = flushDelay.inMilliseconds * (1 << n);
    return Duration(milliseconds: math.min(ms, maxBackoff.inMilliseconds));
  }

  void _publish() {
    final h = DiagnosticsStoreHealth(
      unsaved: _failures > 0 ? _pending.length : 0,
      failures: _failures,
      lastError: _failures > 0 ? _lastError : null,
      dropped: _dropped,
      readFailed: _readFailed,
    );
    if (health.value != h) health.value = h;
  }

  void _fail(String type) {
    _failures++;
    _lastError = type;
    _publish();
    _timer?.cancel();
    _timer = null;
    if (_pending.isNotEmpty) _schedule(_backoff);
  }

  void _succeed() {
    if (_failures == 0) return;
    _failures = 0;
    _lastError = null;
    _publish();
  }

  /// D83: espera a que no haya operación en curso, como mucho [opTimeout].
  /// `false` si sigue ocupada (colgada): el llamador no hace nada más.
  Future<bool> _acquire() async {
    while (_busy != null) {
      if (_busyStuck) return false;
      final b = _busy!;
      var timedOut = false;
      await b.timeout(opTimeout, onTimeout: () { timedOut = true; });
      if (timedOut && identical(_busy, b)) {
        _busyStuck = true;
        return false;
      }
    }
    return true;
  }

  /// Marca [op] como la operación en curso hasta que termine (aunque
  /// supere el tope).
  Future<void> _run(Future<void> op) {
    _busy = op;
    _busyStuck = false;
    op.whenComplete(() {
      if (identical(_busy, op)) {
        _busy = null;
        _busyStuck = false;
      }
    }).ignore();
    return op;
  }

  /// Escribe lo pendiente (si la principal está abierta). Serializado y
  /// acotado: nunca espera más de ~[opTimeout] (ni deja esperando a otros).
  Future<void> flush() async {
    if (!await _acquire()) {
      // Una operación anterior sigue colgada: se reintenta más tarde.
      if (_pending.isNotEmpty) _schedule(_backoff);
      return;
    }
    if (_pending.isEmpty) return;
    if (!primaryOpen()) return;
    if (suspended?.call() ?? false) {
      _schedule(); // se reintenta al terminar el re-cifrado o la copia
      return;
    }
    final batch = List<DiagEntry>.of(_pending);
    final op = _run(_write(batch));
    var timedOut = false;
    await op.timeout(opTimeout, onTimeout: () { timedOut = true; });
    if (timedOut && identical(_busy, op)) {
      // Sigue viva: si termina bien, quita su lote de pendientes (ver
      // [_write]); mientras, nadie la espera.
      _busyStuck = true;
      _fail('tiempo agotado');
    }
  }

  /// Escritura de [batch]. Nunca lanza: registra éxito/fallo en [health].
  Future<void> _write(List<DiagEntry> batch) async {
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
      _succeed();
      // Lo que llegó mientras tanto.
      if (_pending.isNotEmpty) _schedule();
    } on Object catch (e) {
      // Bloqueo a mitad (BD cerrada, sesión cambiada): no es un fallo del
      // diagnóstico; se escribe en el próximo desbloqueo. Nunca se registra
      // en el búfer (sería recursivo).
      if (!primaryOpen()) return;
      _fail(_errorType(e));
    }
  }

  /// Solo el NOMBRE del tipo (el mensaje podría llevar rutas).
  static String _errorType(Object e) =>
      e is TimeoutException ? 'tiempo agotado' : e.runtimeType.toString();

  /// Entradas persistidas + pendientes, de la más antigua a la más reciente.
  /// Sin la principal abierta, solo lo que hay en memoria. Acotado: si la BD
  /// no responde, devuelve lo pendiente y lo indica en [health].
  Future<List<DiagEntry>> entries() async {
    await flush();
    final out = <DiagEntry>[];
    if (primaryOpen() && await _acquire()) {
      final rows = <DiagEntry>[];
      var ok = false;
      final op = _run(() async {
        try {
          final db = await _db();
          final list = await db.query('diag_events', orderBy: 'id ASC');
          for (final r in list) {
            rows.add(
              DiagEntry(
                DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
                r['level'] == 'E' ? DiagLevel.error : DiagLevel.debug,
                r['category'] as String,
                r['message'] as String,
              ),
            );
          }
          ok = true;
        } on Object {
          // sin tabla o BD cerrada: abajo
        }
      }());
      var timedOut = false;
      await op.timeout(opTimeout, onTimeout: () { timedOut = true; });
      if (timedOut && identical(_busy, op)) _busyStuck = true;
      // Con la lectura terminada no ha corrido ninguna escritura entretanto:
      // lo leído y lo pendiente no se solapan ni dejan huecos.
      final failed = timedOut || (!ok && primaryOpen());
      if (failed != _readFailed) {
        _readFailed = failed;
        _publish();
      }
      if (ok && !timedOut) out.addAll(rows);
    }
    out.addAll(_pending);
    if (out.length > capacity) return out.sublist(out.length - capacity);
    return out;
  }

  /// «Borrar diagnóstico»: tabla, pendientes y memoria (y el estado).
  Future<void> clearAll() async {
    _pending.clear();
    buffer.clear();
    _dropped = 0;
    _readFailed = false;
    _failures = 0;
    _lastError = null;
    _publish();
    if (!primaryOpen()) return;
    if (!await _acquire()) return;
    final op = _run(() async {
      try {
        final db = await _db();
        await db.delete('diag_events');
      } on Object {
        // BD cerrada: se reintenta al volver a pulsar
      }
    }());
    var timedOut = false;
    await op.timeout(opTimeout, onTimeout: () { timedOut = true; });
    if (timedOut && identical(_busy, op)) _busyStuck = true;
  }
}
