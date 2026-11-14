import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';

/// Aparición escalonada (fundido + deslizamiento) según [index].
///
/// Un único controlador por celda (sin temporizadores): el retraso va dentro
/// del `Interval`. Si [animate] es falso o hay "reducir animaciones", aparece
/// directamente.
class StaggeredAppear extends StatefulWidget {
  const StaggeredAppear({
    super.key,
    required this.index,
    required this.child,
    this.animate = true,
  });

  final int index;
  final bool animate;
  final Widget child;

  @override
  State<StaggeredAppear> createState() => _StaggeredAppearState();
}

class _StaggeredAppearState extends State<StaggeredAppear>
    with SingleTickerProviderStateMixin {
  late final Duration _delay =
      AppMotion.stagger *
      widget.index.clamp(0, AppMotion.maxStaggerSteps).toInt();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _delay + AppMotion.medium,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      _delay.inMicroseconds / _controller.duration!.inMicroseconds,
      1,
      curve: AppMotion.standard,
    ),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.animate && !MediaQuery.disableAnimationsOf(context)) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(
          offset: Offset(0, AppSpacing.lg * (1 - _curve.value)),
          child: child,
        ),
      ),
    );
  }
}
