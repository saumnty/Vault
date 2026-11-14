import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_radii.dart';

/// Brillo deslizante (propio, sin paquetes) para esqueletos de carga.
/// Con "reducir animaciones" activo queda estático.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.shimmer,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            colors: const [
              AppColors.shimmerBase,
              AppColors.shimmerHighlight,
              AppColors.shimmerBase,
            ],
            stops: const [0.35, 0.5, 0.65],
            transform: _SlideTransform(_controller.value),
          ).createShader(bounds),
          child: child,
        ),
      ),
    );
  }
}

class _SlideTransform extends GradientTransform {
  const _SlideTransform(this.progress);

  final double progress;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (progress * 2 - 1), 0, 0);
}

/// Rectángulo esqueleto con shimmer.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.radius = AppRadii.mdAll});

  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.shimmerBase,
          borderRadius: radius,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}
