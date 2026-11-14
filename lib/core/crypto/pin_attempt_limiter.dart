import 'dart:convert';

import 'secure_kv_store.dart';

typedef Clock = DateTime Function();

/// Se lanza cuando hay que esperar antes de volver a probar un PIN.
class PinLockedOutException implements Exception {
  const PinLockedOutException(this.remaining);
  final Duration remaining;

  @override
  String toString() => 'PinLockedOutException: espera ${remaining.inSeconds} s';
}

/// Retraso creciente tras PIN incorrecto, persistido en almacenamiento seguro.
///
/// * Los primeros [freeAttempts] - 1 fallos no bloquean.
/// * El fallo nº 5 bloquea 30 s; después 60 s, 2 min, 5 min, 10 min, 30 min
///   y, a partir de ahí, 1 h por cada fallo (tope).
/// * Un acierto lo resetea.
///
/// El intento se cuenta de forma PESIMISTA: se registra como fallo ANTES de
/// verificar el PIN y se borra si resulta correcto. Así, matar la app durante
/// la derivación Argon2id no regala intentos.
///
/// LIMITACIÓN: Flutter no expone un reloj monotónico que sobreviva al cierre
/// de la app, así que se guarda la hora de pared (epoch ms). Si el usuario
/// adelanta el reloj del sistema puede acortar la espera. Si lo atrasa, la
/// espera se limita al retraso del nivel actual (no queda bloqueado de por
/// vida). La defensa real contra fuerza bruta offline es Argon2id + que la
/// envoltura del PIN nunca sale del teléfono.
class PinAttemptLimiter {
  PinAttemptLimiter(this._store, {Clock? clock})
    : _clock = clock ?? DateTime.now;

  static const String storageKey = 'vault.v1.pin_attempts';
  static const int freeAttempts = 5;
  static const List<Duration> schedule = [
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 30),
    Duration(hours: 1),
  ];

  final SecureKeyValueStore _store;
  final Clock _clock;

  /// Retraso que se impone tras acumular [failures] fallos consecutivos.
  static Duration delayForFailures(int failures) {
    if (failures < freeAttempts) return Duration.zero;
    final index = failures - freeAttempts;
    return schedule[index < schedule.length ? index : schedule.length - 1];
  }

  Future<_AttemptState> _load() async {
    final raw = await _store.read(storageKey);
    if (raw == null) return const _AttemptState(0, 0);
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return _AttemptState(json['failures'] as int, json['lockedUntil'] as int);
    } catch (_) {
      // Estado corrupto: fallar cerrado (como si hubiera 5 fallos ahora).
      final now = _clock().millisecondsSinceEpoch;
      return _AttemptState(
        freeAttempts,
        now + delayForFailures(freeAttempts).inMilliseconds,
      );
    }
  }

  Future<void> _save(_AttemptState state) => _store.write(
    storageKey,
    jsonEncode({
      'failures': state.failures,
      'lockedUntil': state.lockedUntilMs,
      'updatedAt': _clock().millisecondsSinceEpoch,
    }),
  );

  /// Fallos consecutivos registrados.
  Future<int> failures() async => (await _load()).failures;

  /// Tiempo de espera restante, o `null` si se puede intentar ya.
  Future<Duration?> remainingLockout() async {
    final state = await _load();
    final now = _clock().millisecondsSinceEpoch;
    var remainingMs = state.lockedUntilMs - now;
    if (remainingMs <= 0) return null;
    // Si el reloj se atrasó, no bloquear más de lo que toca a este nivel.
    final cap = delayForFailures(state.failures).inMilliseconds;
    if (remainingMs > cap) remainingMs = cap;
    if (remainingMs <= 0) return null;
    return Duration(milliseconds: remainingMs);
  }

  /// Lanza [PinLockedOutException] si todavía hay que esperar.
  Future<void> ensureNotLocked() async {
    final remaining = await remainingLockout();
    if (remaining != null) throw PinLockedOutException(remaining);
  }

  /// Registra un fallo y, si corresponde, programa el bloqueo.
  Future<void> registerFailure() async {
    final state = await _load();
    final failures = state.failures + 1;
    final delay = delayForFailures(failures);
    final lockedUntil = delay == Duration.zero
        ? 0
        : _clock().millisecondsSinceEpoch + delay.inMilliseconds;
    await _save(_AttemptState(failures, lockedUntil));
  }

  Future<void> reset() => _store.delete(storageKey);
}

class _AttemptState {
  const _AttemptState(this.failures, this.lockedUntilMs);
  final int failures;
  final int lockedUntilMs;
}
