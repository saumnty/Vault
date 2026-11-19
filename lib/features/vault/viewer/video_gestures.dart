import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';

/// Salto de cada doble toque.
const Duration kVideoSkip = Duration(seconds: 10);

/// Tras un salto, los toques SIMPLES siguientes (en este plazo) siguen
/// sumando saltos: +10, +20, +30…
const Duration kVideoSkipStreak = Duration(milliseconds: 700);

/// Tiempo para distinguir un toque simple de la primera mitad de un doble.
const Duration kVideoDoubleTap = Duration(milliseconds: 300);

/// Zoom máximo del video (pellizco).
const double kVideoMaxScale = 4;

/// Destino de un salto acumulado: [base] + [skips] × 10 s, acotado a
/// `[0, duration]` (respeta inicio y fin del video).
Duration skipTarget(Duration base, int skips, Duration duration) {
  final ms = base.inMilliseconds + skips * kVideoSkip.inMilliseconds;
  final max = duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds;
  return Duration(milliseconds: ms.clamp(0, max));
}

/// Capa de gestos del video:
/// * doble toque en la mitad izquierda = −10 s, en la derecha = +10 s; los
///   toques siguientes (≤ [kVideoSkipStreak]) acumulan (+10, +20, +30) con un
///   indicador animado y háptica;
/// * toque simple = [onTap] (mostrar/ocultar controles), tras
///   [kVideoDoubleTap] sin segundo toque;
/// * el doble toque NO hace zoom.
/// El pellizco/zoom lo resuelve [ZoomableVideo] por debajo.
class VideoGestureLayer extends StatefulWidget {
  const VideoGestureLayer({
    super.key,
    required this.controller,
    required this.onTap,
    required this.child,
    this.haptics = true,
  });

  final VideoPlayerController controller;
  final VoidCallback onTap;
  final Widget child;
  final bool haptics;

  @override
  State<VideoGestureLayer> createState() => _VideoGestureLayerState();
}

class _VideoGestureLayerState extends State<VideoGestureLayer> {
  Timer? _singleTimer;
  Timer? _streakTimer;
  Timer? _hideTimer;

  /// Primer toque de un posible doble (a la espera del segundo).
  bool _awaitingSecond = false;

  /// Saltos acumulados de la racha actual (con signo) y su posición base.
  int _skips = 0;
  Duration _base = Duration.zero;
  bool _streakActive = false;
  bool _forward = true;

  /// Lo que muestra el indicador (segundos efectivos) y si es visible.
  final ValueNotifier<_SkipIndicator?> _indicator =
      ValueNotifier<_SkipIndicator?>(null);

  @override
  void dispose() {
    _singleTimer?.cancel();
    _streakTimer?.cancel();
    _hideTimer?.cancel();
    _indicator.dispose();
    super.dispose();
  }

  void _onTapUp(TapUpDetails d) {
    final width = context.size?.width ?? 0;
    final forward = width <= 0 ? true : d.localPosition.dx >= width / 2;
    if (_streakActive) {
      // Racha en curso: cada toque suma, sin esperar al "doble".
      _skip(forward);
      return;
    }
    if (_awaitingSecond) {
      _singleTimer?.cancel();
      _awaitingSecond = false;
      _skip(forward);
      return;
    }
    _awaitingSecond = true;
    _singleTimer = Timer(kVideoDoubleTap, () {
      _awaitingSecond = false;
      widget.onTap();
    });
  }

  void _skip(bool forward) {
    final c = widget.controller;
    final v = c.value;
    if (!v.isInitialized) return;
    if (!_streakActive || forward != _forward) {
      // Racha nueva (o cambio de lado): la base es la posición actual.
      _base = v.position;
      _skips = 0;
      _forward = forward;
    }
    final next = _skips + (forward ? 1 : -1);
    final target = skipTarget(_base, next, v.duration);
    // En el inicio/fin ya no hay a dónde ir: no se acumula ni se muestra nada.
    if (target == skipTarget(_base, _skips, v.duration)) {
      if (_streakActive) _armStreak();
      return;
    }
    final effective = target - _base;
    _skips = next;
    _streakActive = true;
    unawaited(c.seekTo(target));
    if (widget.haptics) unawaited(HapticFeedback.selectionClick());
    _indicator.value = _SkipIndicator(
      forward: forward,
      seconds: (effective.inMilliseconds.abs() / 1000).round(),
      tick: (_indicator.value?.tick ?? 0) + 1,
    );
    _armStreak();
  }

  void _armStreak() {
    _streakTimer?.cancel();
    _streakTimer = Timer(kVideoSkipStreak, () {
      _streakActive = false;
      _skips = 0;
    });
    _hideTimer?.cancel();
    _hideTimer = Timer(kVideoSkipStreak, () => _indicator.value = null);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('video-gestures'),
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          IgnorePointer(
            child: ValueListenableBuilder<_SkipIndicator?>(
              valueListenable: _indicator,
              builder: (context, ind, _) => _SkipOverlay(indicator: ind),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkipIndicator {
  const _SkipIndicator({
    required this.forward,
    required this.seconds,
    required this.tick,
  });
  final bool forward;
  final int seconds;
  final int tick;
}

class _SkipOverlay extends StatelessWidget {
  const _SkipOverlay({required this.indicator});

  final _SkipIndicator? indicator;

  @override
  Widget build(BuildContext context) {
    final ind = indicator;
    return Row(
      children: [
        Expanded(child: _half(ind != null && !ind.forward ? ind : null, false)),
        Expanded(child: _half(ind != null && ind.forward ? ind : null, true)),
      ],
    );
  }

  Widget _half(_SkipIndicator? ind, bool forward) {
    return AnimatedOpacity(
      duration: AppMotion.fast,
      opacity: ind == null ? 0 : 1,
      child: Center(
        child: ind == null
            ? const SizedBox.shrink()
            : _Bubble(
                key: ValueKey('skip-${forward ? 'fwd' : 'back'}'),
                indicator: ind,
              ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({super.key, required this.indicator});

  final _SkipIndicator indicator;

  @override
  Widget build(BuildContext context) {
    final f = indicator.forward;
    return Semantics(
      liveRegion: true,
      label:
          '${f ? 'Adelantado' : 'Retrocedido'} ${indicator.seconds} segundos',
      child: ExcludeSemantics(
        // El rebote se dispara con cada toque nuevo (cambia el tick).
        child: TweenAnimationBuilder<double>(
          key: ValueKey(indicator.tick),
          tween: Tween(begin: 0.85, end: 1),
          duration: AppMotion.fast,
          curve: Curves.easeOutBack,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: AppColors.scrim,
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    f ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                    color: AppColors.textPrimary,
                  ),
                  Text(
                    '${f ? '+' : '−'}${indicator.seconds} s',
                    style: AppTypography.caption,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pellizco 1x–[kVideoMaxScale] sobre el video. Con zoom > 1x el arrastre
/// mueve la imagen ([onZoomChanged] avisa al visor para que NO cierre ni
/// cambie de página); a 1x todo vuelve a funcionar como antes.
class ZoomableVideo extends StatefulWidget {
  const ZoomableVideo({
    super.key,
    required this.onZoomChanged,
    required this.child,
  });

  final ValueChanged<bool> onZoomChanged;
  final Widget child;

  @override
  State<ZoomableVideo> createState() => _ZoomableVideoState();
}

class _ZoomableVideoState extends State<ZoomableVideo> {
  final TransformationController _tc = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
  }

  @override
  void dispose() {
    _tc.removeListener(_onTransform);
    _tc.dispose();
    if (_zoomed) {
      // El video se liberó con zoom: el visor debe volver a 1x (paginar y
      // cerrar deslizando). No se puede avisar durante el desmontaje.
      final cb = widget.onZoomChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => cb(false));
    }
    super.dispose();
  }

  void _onTransform() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed) {
      _zoomed = z;
      widget.onZoomChanged(z);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      key: const ValueKey('video-zoom'),
      transformationController: _tc,
      maxScale: kVideoMaxScale,
      child: SizedBox.expand(child: widget.child),
    );
  }
}
