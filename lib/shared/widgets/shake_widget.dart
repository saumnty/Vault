import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';

/// Sacude horizontalmente a su hijo cada vez que [shakeCount] aumenta.
class ShakeWidget extends StatefulWidget {
  const ShakeWidget({super.key, required this.shakeCount, required this.child});

  final int shakeCount;
  final Widget child;

  @override
  State<ShakeWidget> createState() => _ShakeWidgetState();
}

class _ShakeWidgetState extends State<ShakeWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.shake,
  );

  /// Oscilaciones completas durante la sacudida.
  static const int _swings = 3;

  @override
  void didUpdateWidget(ShakeWidget old) {
    super.didUpdateWidget(old);
    if (widget.shakeCount > old.shakeCount &&
        !MediaQuery.disableAnimationsOf(context)) {
      _controller.forward(from: 0);
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
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        final dx =
            math.sin(t * _swings * 2 * math.pi) * (1 - t) * AppSpacing.xl;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}
