import 'dart:async';

import 'package:flutter/widgets.dart';

import 'security_preferences.dart';

/// Suspensión del autobloqueo: las funciones que abren UI del sistema
/// (prompt biométrico, permisos de fotos, selector de archivos, inicio de
/// sesión de Google...) envuelven su llamada en [run]. Mientras haya alguna en
/// curso, pasar a segundo plano NO inicia la cuenta del autobloqueo.
///
/// Revisión de seguridad (S-01): la suspensión ya NO desactiva el autobloqueo
/// sin límite. Si la app pasa a segundo plano con una suspensión activa:
/// * al terminar la suspensión con la app aún en segundo plano (p. ej. una
///   petición de token de Google de la sincronización, o el usuario pulsó
///   HOME y el diálogo se cerró) se arma el autobloqueo normal desde ese
///   instante ([AutoLockController.rearmGrace] como mínimo);
/// * si la app vuelve tras más de [AutoLockController.maxSuspendedBackground]
///   (o del tiempo configurado, si es mayor) se bloquea igualmente, aunque la
///   suspensión siga activa (el usuario salió a HOME desde el selector).
class AutoLockSuspension {
  AutoLockSuspension();

  /// Instancia global de la app.
  static final AutoLockSuspension instance = AutoLockSuspension();

  int _count = 0;
  final List<void Function()> _idleListeners = [];

  bool get isSuspended => _count > 0;
  int get depth => _count;

  /// [listener] se invoca cada vez que la última suspensión activa termina.
  void addIdleListener(void Function() listener) {
    if (!_idleListeners.contains(listener)) _idleListeners.add(listener);
  }

  void removeIdleListener(void Function() listener) =>
      _idleListeners.remove(listener);

  /// Ejecuta [action] con el autobloqueo suspendido (reentrante).
  Future<T> run<T>(Future<T> Function() action) async {
    _count++;
    try {
      return await action();
    } finally {
      _count--;
      if (_count == 0) {
        for (final l in List.of(_idleListeners)) {
          l();
        }
      }
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

  /// Tope de tiempo en segundo plano con una suspensión activa (diálogo del
  /// sistema abierto por la app). Pasado este tiempo (o el configurado, si es
  /// mayor) se bloquea al volver aunque la suspensión siga activa (S-01).
  static const Duration maxSuspendedBackground = Duration(minutes: 5);

  /// Margen mínimo al rearmar cuando la suspensión termina con la app todavía
  /// en segundo plano: la respuesta del selector/diálogo suele llegar justo
  /// antes del `resumed`; con "inmediato" no debe bloquear en ese instante.
  static const Duration rearmGrace = Duration(seconds: 3);

  AutoLockDelay _delay;
  AutoLockStamp? _pausedAt;
  Timer? _timer;
  bool _attached = false;
  bool _backgrounded = false;

  /// Se pasó a segundo plano con una suspensión activa (límite
  /// [_suspendedLimit] en vez del tiempo configurado).
  bool _pausedSuspended = false;

  /// Se rearmó al terminar la suspensión en segundo plano (límite
  /// [_rearmedLimit]).
  bool _rearmed = false;

  Duration get _suspendedLimit => _delay.duration > maxSuspendedBackground
      ? _delay.duration
      : maxSuspendedBackground;

  Duration get _rearmedLimit =>
      _delay.duration > rearmGrace ? _delay.duration : rearmGrace;

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
    _suspension.removeIdleListener(_onSuspensionIdle);
  }

  /// Bloqueo manual ("Bloquear ahora").
  void lockNow() {
    _cancelTimer();
    _pausedAt = null;
    _pausedSuspended = false;
    _rearmed = false;
    _suspension.removeIdleListener(_onSuspensionIdle);
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
    _pausedAt = _clock.stamp();
    _rearmed = false;
    // Diálogo/actividad del sistema abierto por la propia app: no aplica el
    // tiempo configurado, pero SÍ un tope ([maxSuspendedBackground]) y, si la
    // suspensión termina con la app en segundo plano, el autobloqueo normal.
    if (_suspension.isSuspended) {
      _pausedSuspended = true;
      _suspension.addIdleListener(_onSuspensionIdle);
      _timer = _timerFactory(_suspendedLimit, _onTimer);
      return;
    }
    _pausedSuspended = false;
    if (_delay == AutoLockDelay.immediate) {
      lockNow();
      return;
    }
    _timer = _timerFactory(_delay.duration, _onTimer);
  }

  /// La última suspensión terminó. Si la app sigue en segundo plano, desde
  /// ahora es un segundo plano normal (con [rearmGrace] como mínimo).
  void _onSuspensionIdle() {
    _suspension.removeIdleListener(_onSuspensionIdle);
    if (!_backgrounded || !_pausedSuspended || _pausedAt == null) return;
    _pausedSuspended = false;
    _rearmed = true;
    _cancelTimer();
    _pausedAt = _clock.stamp();
    _timer = _timerFactory(_rearmedLimit, _onTimer);
  }

  void _onTimer() {
    _timer = null;
    if (_pausedAt == null) return;
    lockNow();
  }

  void _onResumed() {
    _backgrounded = false;
    _cancelTimer();
    _suspension.removeIdleListener(_onSuspensionIdle);
    final at = _pausedAt;
    final limit = _pausedSuspended
        ? _suspendedLimit
        : (_rearmed ? _rearmedLimit : _delay.duration);
    _pausedAt = null;
    _pausedSuspended = false;
    _rearmed = false;
    if (at == null) return;
    if (_clock.elapsedSince(at) >= limit) onLock();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
