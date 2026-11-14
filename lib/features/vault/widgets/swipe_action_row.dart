import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/haptics.dart';

class SwipeAction {
  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

/// Fila deslizable hacia la izquierda que revela acciones rápidas.
///
/// Implementación propia (sin paquetes). Para lectores de pantalla las
/// acciones se exponen como `customSemanticsActions` de la fila.
class SwipeActionRow extends StatefulWidget {
  const SwipeActionRow({
    super.key,
    required this.child,
    required this.actions,
    this.enabled = true,
  });

  final Widget child;
  final List<SwipeAction> actions;
  final bool enabled;

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with SingleTickerProviderStateMixin {
  /// 0 = cerrada, 1 = abierta del todo.
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );

  double get _extent => AppSizes.swipeAction * widget.actions.length;

  /// Velocidad (px/s) que basta para abrir/cerrar sin llegar a la mitad.
  static const double _flingVelocity = 700;

  void _drag(DragUpdateDetails d) {
    _open.value = (_open.value - d.primaryDelta! / _extent).clamp(0.0, 1.0);
  }

  void _end(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final shouldOpen = v < -_flingVelocity
        ? true
        : v > _flingVelocity
        ? false
        : _open.value > 0.5;
    if (shouldOpen && _open.value < 1) AppHaptics.selection();
    _open.animateTo(
      shouldOpen ? 1 : 0,
      curve: AppMotion.standard,
      duration: AppMotion.medium,
    );
  }

  void _close() => _open.animateTo(0, curve: AppMotion.standard);

  @override
  void didUpdateWidget(SwipeActionRow old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && _open.value > 0) _open.value = 0;
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      customSemanticsActions: {
        for (final a in widget.actions)
          CustomSemanticsAction(label: a.label): a.onTap,
      },
      child: Stack(
        children: [
          Positioned(
            top: 0,
            bottom: 0,
            right: rtl ? null : 0,
            left: rtl ? 0 : null,
            child: AnimatedBuilder(
              animation: _open,
              builder: (context, _) => _open.value == 0
                  ? const SizedBox.shrink()
                  : _ActionStrip(actions: widget.actions, onDone: _close),
            ),
          ),
          AnimatedBuilder(
            animation: _open,
            child: GestureDetector(
              onHorizontalDragUpdate: _drag,
              onHorizontalDragEnd: _end,
              child: ColoredBox(
                color: AppColors.background,
                child: widget.child,
              ),
            ),
            builder: (context, child) => Transform.translate(
              offset: Offset(_open.value * _extent * (rtl ? 1 : -1), 0),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionStrip extends StatelessWidget {
  const _ActionStrip({required this.actions, required this.onDone});

  final List<SwipeAction> actions;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in actions)
          Semantics(
            button: true,
            label: a.label,
            excludeSemantics: true,
            onTap: () {
              onDone();
              a.onTap();
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                onDone();
                a.onTap();
              },
              child: Container(
                width: AppSizes.swipeAction,
                color: a.color,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      a.icon,
                      color: AppColors.onAccent,
                      size: AppSizes.iconLg,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      a.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption.copyWith(
                        color: AppColors.onAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
