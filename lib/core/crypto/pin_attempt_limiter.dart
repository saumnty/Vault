import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'secure_kv_store.dart';

typedef Clock = DateTime Function();

/// Lectura de un reloj monotónico del sistema (S-07).
///
/// [elapsedMs] cuenta desde el arranque del teléfono (incluye el sueño) y NO
/// depende de la hora de pared: cambiar la fecha en Ajustes no lo altera.
/// [boot] identifica el arranque (Android: `Settings.Global.BOOT_COUNT`;
/// `-1` si no se conoce).
class MonotonicReading {
  const MonotonicReading({required this.elapsedMs, this.boot = -1});
  final int elapsedMs;
  final int boot;
}

/// Fuente del reloj monotónico; `null` = no disponible (entonces solo se usa
/// la hora de pared, como antes de S-07).
abstract class MonotonicClock {
  Future<MonotonicReading?> read();
}

/// Reloj monotónico nativo por el canal `vault/security` (método `monotonic`).
/// Android: `SystemClock.elapsedRealtime` + `BOOT_COUNT`.
/// iOS: `mach_continuous_time` (// iOS: sin probar en dispositivo).
class PlatformMonotonicClock implements MonotonicClock {
  PlatformMonotonicClock({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vault/security');
  final MethodChannel _channel;

  @override
  Future<MonotonicReading?> read() async {
    // Solo móvil (S-07): en tests/escritorio no hay canal y, bajo FakeAsync,
    // esperar a un canal sin implementar cuelga los tests de widgets.
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('monotonic');
      final e = m?['elapsedMs'];
      if (e is! int || e < 0) return null;
      final b = m?['boot'];
      return MonotonicReading(elapsedMs: e, boot: b is int ? b : -1);
    } catch (_) {
      // Canal ausente (tests/escritorio) o error nativo: sin reloj monotónico.
      return null;
    }
  }
}

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
/// RELOJES (S-07): la espera se guarda con la hora de pared Y con un reloj
/// monotónico nativo (ver [MonotonicClock]) y hay que cumplir AMBAS: adelantar
/// la fecha del sistema ya no quita la espera. Si el reloj de pared se atrasa,
/// la espera se limita al retraso del nivel actual (no queda bloqueado de por
/// vida). Tras un REINICIO el monotónico no mide el tiempo apagado: solo se
/// abona el tiempo transcurrido desde el arranque (nunca de más; fail-closed),
/// así reiniciar no sirve para saltarse la espera. Sin reloj monotónico
/// (escritorio/tests) solo se usa la hora de pared. La defensa real contra
/// fuerza bruta offline sigue siendo Argon2id + que la envoltura del PIN no
/// sale del teléfono.
class PinAttemptLimiter {
  PinAttemptLimiter(
    this._store, {
    Clock? clock,
    this.key = storageKey,
    MonotonicClock? monotonic,
  }) : _clock = clock ?? DateTime.now,
       _mono = monotonic ?? PlatformMonotonicClock();

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
  final MonotonicClock _mono;

  /// Clave de almacenamiento propia (F9: el límite de intentos del código de
  /// recuperación es independiente del del PIN).
  final String key;

  /// Retraso que se impone tras acumular [failures] fallos consecutivos.
  static Duration delayForFailures(int failures) {
    if (failures < freeAttempts) return Duration.zero;
    final index = failures - freeAttempts;
    return schedule[index < schedule.length ? index : schedule.length - 1];
  }

  Future<_AttemptState> _load() async {
    final raw = await _store.read(key);
    if (raw == null) return const _AttemptState(0, 0);
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return _AttemptState(
        json['failures'] as int,
        json['lockedUntil'] as int,
        lockElapsedMs: json['lockElapsed'] as int?,
        lockBoot: (json['lockBoot'] as int?) ?? -1,
        lockDurMs: json['lockDur'] as int?,
      );
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
    key,
    jsonEncode({
      'failures': state.failures,
      'lockedUntil': state.lockedUntilMs,
      'updatedAt': _clock().millisecondsSinceEpoch,
      if (state.lockElapsedMs != null) ...{
        'lockElapsed': state.lockElapsedMs,
        'lockBoot': state.lockBoot,
        'lockDur': state.lockDurMs,
      },
    }),
  );

  /// Fallos consecutivos registrados.
  Future<int> failures() async => (await _load()).failures;

  /// Tiempo de espera restante, o `null` si se puede intentar ya.
  Future<Duration?> remainingLockout() async {
    final state = await _load();
    final now = _clock().millisecondsSinceEpoch;
    // Si el reloj de pared se atrasó, no bloquear más de lo que toca a este
    // nivel.
    final cap = delayForFailures(state.failures).inMilliseconds;
    var remainingMs = state.lockedUntilMs - now;
    if (remainingMs > cap) remainingMs = cap;

    // S-07: además, el monotónico. Se exigen AMBOS: manda el mayor.
    final lockElapsed = state.lockElapsedMs;
    final lockDur = state.lockDurMs;
    if (lockElapsed != null && lockDur != null && state.lockedUntilMs > 0) {
      final cur = await _mono.read();
      if (cur != null) {
        final rebooted =
            cur.boot != state.lockBoot || cur.elapsedMs < lockElapsed;
        // Mismo arranque: tiempo real transcurrido. Reinicio: solo se abona
        // el tiempo desde el arranque (cota inferior del real).
        final passed = rebooted ? cur.elapsedMs : cur.elapsedMs - lockElapsed;
        var monoRemaining = lockDur - passed;
        if (monoRemaining > cap) monoRemaining = cap;
        if (monoRemaining > remainingMs) remainingMs = monoRemaining;
      }
    }
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
    if (delay == Duration.zero) {
      await _save(_AttemptState(failures, 0));
      return;
    }
    final mono = await _mono.read();
    await _save(
      _AttemptState(
        failures,
        lockedUntil,
        lockElapsedMs: mono?.elapsedMs,
        lockBoot: mono?.boot ?? -1,
        lockDurMs: mono == null ? null : delay.inMilliseconds,
      ),
    );
  }

  Future<void> reset() => _store.delete(key);
}

class _AttemptState {
  const _AttemptState(
    this.failures,
    this.lockedUntilMs, {
    this.lockElapsedMs,
    this.lockBoot = -1,
    this.lockDurMs,
  });
  final int failures;
  final int lockedUntilMs;

  /// Lectura monotónica al imponer el bloqueo (S-07), su arranque y su
  /// duración. `null` si no había reloj monotónico.
  final int? lockElapsedMs;
  final int lockBoot;
  final int? lockDurMs;
}
