import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/theme/app_spacing.dart';

/// Detecta el pellizco de dos dedos SIN competir con el desplazamiento del
/// hijo: usa `Listener` (eventos crudos, no entra en la arena de gestos).
///
/// Cada vez que la escala acumulada supera [AppGrid.pinchZoomIn] llama a
/// [onStep] con `-1` (acercar: menos columnas); por debajo de
/// [AppGrid.pinchZoomOut], con `+1`. Tras cada paso se reinicia la base.
/// Mientras hay dos dedos, [onPinchingChanged] avisa para bloquear el scroll.
class PinchDetector extends StatefulWidget {
  const PinchDetector({
    super.key,
    required this.onStep,
    required this.child,
    this.onPinchingChanged,
  });

  final ValueChanged<int> onStep;
  final ValueChanged<bool>? onPinchingChanged;
  final Widget child;

  @override
  State<PinchDetector> createState() => _PinchDetectorState();
}

class _PinchDetectorState extends State<PinchDetector> {
  final Map<int, Offset> _pointers = {};
  double? _baseDistance;
  bool _pinching = false;

  double get _distance {
    final p = _pointers.values.take(2).toList();
    return (p[0] - p[1]).distance;
  }

  void _setPinching(bool value) {
    if (_pinching == value) return;
    _pinching = value;
    widget.onPinchingChanged?.call(value);
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      _baseDistance = math.max(_distance, 1);
      _setPinching(true);
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final base = _baseDistance;
    if (_pointers.length < 2 || base == null) return;
    final scale = _distance / base;
    if (scale >= AppGrid.pinchZoomIn) {
      widget.onStep(-1);
      _baseDistance = math.max(_distance, 1);
    } else if (scale <= AppGrid.pinchZoomOut) {
      widget.onStep(1);
      _baseDistance = math.max(_distance, 1);
    }
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) {
      _baseDistance = null;
      _setPinching(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.child,
    );
  }
}
