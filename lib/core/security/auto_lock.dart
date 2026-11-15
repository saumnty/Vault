import 'dart:async';

import 'package:flutter/widgets.dart';

import 'security_preferences.dart';

/// Suspensión del autobloqueo: las funciones que abren UI del sistema
/// (prompt biométrico, permisos de fotos, selector de archivos, inicio de
/// sesión de Google...) envuelven su llamada en [run]. Mientras haya alguna en
/// curso, pasar a segundo plano NO inicia la cuenta del autobloqueo.
///
/// Limitación conocida: si el usuario sale de la app DURANTE ese diálogo
/// (HOME), el autobloqueo no se arma hasta la siguiente transición de ciclo
/// de vida.
class AutoLockSuspension {
  AutoLockSuspension();

  /// Instancia global de la app.
  static final AutoLockSuspension instance = AutoLockSuspension();

  int _count = 0;

  bool get isSuspended => _count > 0;
  int get depth => _count;

  /// Ejecuta [action] con el autobloqueo suspendido (reentrante).
  Future<T> run<T>(Future<T> Function() action) async {
    _count++;
    try {
      return await action();
    } finally {
      _count--;
    }
  }
}

/// Reloj del autobloqueo. Se leen DOS relojes y se usa el mayor transcurrido:
/// * monotónico (`Stopwatch`): inmune a cambios de hora del usuario, pero en
///   Android/Linux NO avanza mientras el dispositivo duerme (suspensión);
/// * de pared (`DateTime`): avanza durante el sueño, pero el usuario puede
///   cambiar la hora (hacia atrás daría un valor negativo, que se ignora; hacia
///   adelante solo provoca un bloqueo extra, que es seguro).
/// Así el fallo de uno lo cubre el otro.
class AutoLockClock {
  AutoLockClock({Duration Function()? monotonic, DateTime Function()? wall})
    : _monotonic = monotonic ?? _stopwatchMonotonic(),
      _wall = wall ?? DateTime.now;

  final Duration Function() _monotonic;
  final DateTime Function() _wall;

  static Duration Function() _stopwatchMonotonic() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  AutoLockStamp stamp() => AutoLockStamp(_monotonic(), _wall());

  /// Tiempo transcurrido desde [since] (el mayor de los dos relojes; nunca < 0).
  Duration elapsedSince(AutoLockStamp since) {
    final mono = _monotonic() - since.monotonic;
    final wall = _wall().difference(since.wall);
    final best = mono > wall ? mono : wall;
    return best.isNegative ? Duration.zero : best;
  }
}

class AutoLockStamp {
  const AutoLockStamp(this.monotonic, this.wall);
  final Duration monotonic;
  final DateTime wall;
}

typedef AutoLockTimerFactory = Timer Function(Duration d, void Function() cb);

/// Autobloqueo al pasar a segundo plano.
///
/// Registra el instante al pasar a `hidden`/`paused` (NO a `inactive`, que
/// también ocurre con diálogos del sistema y la cortina de notificaciones).
/// Al volver (`resumed`), si transcurrió >= el tiempo configurado, bloquea. Un
/// `Timer` bloquea además mientras el proceso sigue vivo en segundo plano;
/// puede no dispararse (Android congela procesos), por eso la comprobación al
/// reanudar es la garantía.
class AutoLockController with WidgetsBindingObserver {
  AutoLockController({
    required this.onLock,
    AutoLockPreferences? preferences,
    AutoLockClock? clock,
    AutoLockSuspension? suspension,
    AutoLockTimerFactory? timerFactory,
    AutoLockDelay initialDelay = AutoLockDelay.defaultValue,
  }) : _prefs = preferences,
       _clock = clock ?? AutoLockClock(),
       _suspension = suspension ?? AutoLockSuspension.instance,
       _timerFactory = timerFactory ?? Timer.new,
       _delay = initialDelay;

  /// Ejecuta el bloqueo (cerrar sesión + volver a la pantalla de PIN).
  final void Function() onLock;
  final AutoLockPreferences? _prefs;
  final AutoLockClock _clock;
  final AutoLockSuspension _suspension;
  final AutoLockTimerFactory _timerFactory;

  AutoLockDelay _delay;
  AutoLockStamp? _pausedAt;
  Timer? _timer;
  bool _attached = false;
  bool _backgrounded = false;

  AutoLockDelay get delay => _delay;

  /// `true` mientras hay una marca de "pasó a segundo plano" pendiente.
  bool get isArmed => _pausedAt != null;

  /// Carga la preferencia persistida.
  Future<void> load() async {
    final prefs = _prefs;
    if (prefs == null) return;
    _delay = await prefs.getDelay();
  }

  /// Cambia y persiste el tiempo (API para ajustes, F8).
  Future<void> setDelay(AutoLockDelay value) async {
    _delay = value;
    await _prefs?.setDelay(value);
  }

  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimer();
  }

  /// Bloqueo manual ("Bloquear ahora").
  void lockNow() {
    _cancelTimer();
    _pausedAt = null;
    onLock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _onBackground();
      case AppLifecycleState.resumed:
        _onResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onBackground() {
    // `hidden` y luego `paused`: se decide una sola vez por ida a segundo plano.
    if (_backgrounded) return;
    _backgrounded = true;
    // Diálogo/actividad del sistema abierto por la propia app: no cuenta.
    if (_suspension.isSuspended) return;
    _pausedAt = _clock.stamp();
    if (_delay == AutoLockDelay.immediate) {
      lockNow();
      return;
    }
    _timer = _timerFactory(_delay.duration, _onTimer);
  }

  void _onTimer() {
    _timer = null;
    if (_pausedAt == null) return;
    lockNow();
  }

  void _onResumed() {
    _backgrounded = false;
    _cancelTimer();
    final at = _pausedAt;
    _pausedAt = null;
    if (at == null) return;
    if (_clock.elapsedSince(at) >= _delay.duration) onLock();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
