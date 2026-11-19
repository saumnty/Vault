import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/haptics.dart';

class FabAction {
  const FabAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// Botón flotante que se expande en acciones con etiqueta y velo de fondo.
/// Debe colocarse como hijo de un `Stack` que ocupe toda la pantalla.
class ExpandableFab extends StatefulWidget {
  const ExpandableFab({super.key, required this.actions});

  final List<FabAction> actions;

  @override
  State<ExpandableFab> createState() => _ExpandableFabState();
}

class _ExpandableFabState extends State<ExpandableFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );
  bool _open = false;

  void _toggle() {
    AppHaptics.selection();
    setState(() => _open = !_open);
    if (_open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _run(FabAction action) {
    setState(() => _open = false);
    _controller.reverse();
    action.onTap();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _controller,
      curve: AppMotion.standard,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // Velo: solo captura toques mientras está abierto.
        IgnorePointer(
          ignoring: !_open,
          child: GestureDetector(
            onTap: _toggle,
            behavior: HitTestBehavior.opaque,
            child: FadeTransition(
              opacity: curve,
              child: const ColoredBox(color: AppColors.scrimSoft),
            ),
          ),
        ),
        Positioned(
          right: AppSpacing.lg,
          bottom: AppSpacing.lg,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < widget.actions.length; i++)
                  _MiniAction(
                    action: widget.actions[i],
                    animation: CurvedAnimation(
                      parent: _controller,
                      curve: Interval(
                        0.1 * (widget.actions.length - 1 - i),
                        1,
                        curve: AppMotion.spring,
                      ),
                    ),
                    open: _open,
                    onTap: () => _run(widget.actions[i]),
                  ),
                Semantics(
                  button: true,
                  label: _open ? 'Cerrar menú de añadir' : 'Añadir',
                  excludeSemantics: true,
                  onTap: _toggle,
                  child: GestureDetector(
                    onTap: _toggle,
                    child: Container(
                      width: AppSizes.fab,
                      height: AppSizes.fab,
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: AppRadii.lgAll,
                        boxShadow: AppShadows.fab,
                      ),
                      child: RotationTransition(
                        turns: Tween<double>(
                          begin: 0,
                          end: 0.125,
                        ).animate(curve),
                        child: const Icon(
                          Icons.add,
                          color: AppColors.onAccent,
                          size: AppSizes.iconXl,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.action,
    required this.animation,
    required this.open,
    required this.onTap,
  });

  final FabAction action;
  final Animation<double> animation;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value.clamp(0.0, 1.0);
        if (t == 0 && !open) return const SizedBox.shrink();
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, AppSpacing.xl * (1 - t)),
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Semantics(
                button: true,
                label: action.label,
                excludeSemantics: true,
                onTap: onTap,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        constraints: const BoxConstraints(
                          minHeight: AppSizes.minTouch,
                        ),
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: AppColors.surfaceHighest,
                          borderRadius: AppRadii.mdAll,
                          boxShadow: AppShadows.card,
                        ),
                        child: Text(action.label, style: AppTypography.label),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Container(
                        width: AppSizes.fabMini,
                        height: AppSizes.fabMini,
                        decoration: const BoxDecoration(
                          color: AppColors.surfaceHighest,
                          shape: BoxShape.circle,
                          boxShadow: AppShadows.card,
                        ),
                        child: Icon(action.icon, color: AppColors.accentLight),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
