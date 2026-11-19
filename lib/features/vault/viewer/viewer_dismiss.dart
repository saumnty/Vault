import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';

/// Distancia (px) a partir de la cual soltar cierra el visor.
const double kViewerDismissDistance = 120;

/// Fracción de la altura que también cierra (el menor de ambos umbrales gana).
const double kViewerDismissFraction = 0.15;

/// Velocidad (px/s, hacia abajo) a partir de la cual soltar cierra.
const double kViewerDismissVelocity = 700;

/// Fracción de la altura con la que el fondo ya está totalmente transparente.
const double kViewerDismissFadeFraction = 0.5;

/// Reducción máxima de escala de la imagen al arrastrar.
const double kViewerDismissMinScale = 0.8;

/// Cuánto más vertical que horizontal debe ser el arrastre para activarse.
const double kViewerDismissAxisRatio = 1.2;

/// Marca compartida: una zona (barra de progreso, controles) la activa al
/// recibir el toque para que el arrastre vertical NO inicie el cierre.
class ViewerDismissBlock {
  bool blocked = false;
}

class _BlockScope extends InheritedWidget {
  const _BlockScope({required this.block, required super.child});
  final ViewerDismissBlock block;

  @override
  bool updateShouldNotify(_BlockScope old) => block != old.block;
}

/// Envuelve una zona sobre la que el gesto de cerrar deslizando se ignora
/// (p. ej. los controles del video).
class ViewerDismissBlocker extends StatelessWidget {
  const ViewerDismissBlocker({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_BlockScope>();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => scope?.block.blocked = true,
      child: child,
    );
  }
}

enum _Phase { idle, undecided, dragging, ignored }

/// Cierra el visor al deslizar hacia abajo (gesto típico de galería).
///
/// Observa los punteros con un [Listener] (sin entrar en la arena de gestos,
/// así no choca con el pellizco/zoom ni con el PageView): solo se activa si el
/// movimiento es claramente vertical hacia abajo y de un solo dedo. El
/// contenido sigue al dedo (con ligera reducción de escala) y el progreso
/// (0..1) se publica en [progress] para desvanecer el fondo. Al soltar, si se
/// supera la distancia o la velocidad se llama a [onDismiss]; si no, vuelve a
/// su sitio con animación. Con [enabled] en `false` (zoom activo) no actúa.
class ViewerDismissible extends StatefulWidget {
  const ViewerDismissible({
    super.key,
    required this.progress,
    required this.onDismiss,
    required this.child,
    this.enabled = true,
  });

  final ValueNotifier<double> progress;
  final VoidCallback onDismiss;
  final bool enabled;
  final Widget child;

  @override
  State<ViewerDismissible> createState() => _ViewerDismissibleState();
}

class _ViewerDismissibleState extends State<ViewerDismissible>
    with SingleTickerProviderStateMixin {
  final ViewerDismissBlock _block = ViewerDismissBlock();
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );
  final Set<int> _pointers = {};
  _Phase _phase = _Phase.idle;
  int _primary = -1;
  Offset _start = Offset.zero;
  double _baseY = 0;
  VelocityTracker? _tracker;
  double _dy = 0;
  double _from = 0;
  double _height = 1;

  @override
  void initState() {
    super.initState();
    _back.addListener(() {
      _set(_from * (1 - AppMotion.standard.transform(_back.value)));
    });
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _set(double dy) {
    if (!mounted) return;
    _dy = dy;
    widget.progress.value = _progressOf(dy);
    setState(() {});
  }

  double _progressOf(double dy) =>
      (dy / (_height * kViewerDismissFadeFraction)).clamp(0.0, 1.0);

  void _down(PointerDownEvent e) {
    final blocked = _block.blocked;
    _block.blocked = false;
    _pointers.add(e.pointer);
    if (_pointers.length > 1) {
      // Segundo dedo (pellizco): no es un cierre.
      _abort();
      return;
    }
    if (blocked || !widget.enabled) {
      _phase = _Phase.ignored;
      return;
    }
    _back.stop();
    _primary = e.pointer;
    _start = e.position;
    _phase = _Phase.undecided;
    _tracker = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.position);
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _primary) return;
    if (_phase != _Phase.undecided && _phase != _Phase.dragging) return;
    _tracker?.addPosition(e.timeStamp, e.position);
    if (_phase == _Phase.undecided) {
      final d = e.position - _start;
      if (d.distance <= kTouchSlop) return;
      if (d.dy > 0 && d.dy > d.dx.abs() * kViewerDismissAxisRatio) {
        _phase = _Phase.dragging;
        _baseY = e.position.dy - _dy; // continuidad, sin salto
      } else {
        _phase = _Phase.ignored;
        return;
      }
    }
    _set(math.max(0, e.position.dy - _baseY));
  }

  void _up(PointerUpEvent e) {
    final wasPrimary = e.pointer == _primary;
    final dragging = _phase == _Phase.dragging && wasPrimary;
    _tracker?.addPosition(e.timeStamp, e.position);
    final v = _tracker?.getVelocity().pixelsPerSecond.dy ?? 0;
    _release(e.pointer);
    if (!dragging) return;
    final far =
        _dy >=
        math.min(kViewerDismissDistance, _height * kViewerDismissFraction);
    if (far || v > kViewerDismissVelocity) {
      widget.onDismiss();
    } else {
      _snapBack();
    }
  }

  void _cancel(PointerCancelEvent e) {
    final dragging = _phase == _Phase.dragging;
    _release(e.pointer);
    if (dragging) _snapBack();
  }

  void _release(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty) {
      _phase = _Phase.idle;
      _primary = -1;
      _tracker = null;
    }
  }

  void _abort() {
    if (_phase == _Phase.dragging) _snapBack();
    _phase = _Phase.ignored;
  }

  void _snapBack() {
    _from = _dy;
    if (_from == 0) return;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return _BlockScope(
      block: _block,
      child: LayoutBuilder(
        builder: (context, c) {
          _height = c.maxHeight.isFinite && c.maxHeight > 0 ? c.maxHeight : 1;
          final scale = 1 - (1 - kViewerDismissMinScale) * _progressOf(_dy);
          return Listener(
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _cancel,
            child: Transform.translate(
              offset: Offset(0, _dy),
              child: Transform.scale(scale: scale, child: widget.child),
            ),
          );
        },
      ),
    );
  }
}
