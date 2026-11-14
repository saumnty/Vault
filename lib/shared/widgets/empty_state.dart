import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'app_buttons.dart';

enum EmptyKind { vault, search }

/// Estado vacío: ilustración (CustomPainter) + mensaje útil + acción opcional.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.kind = EmptyKind.vault,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final EmptyKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: AppSpacing.page,
        child: Semantics(
          container: true,
          label: '$title. $message',
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: AppSizes.illustration,
                  child: CustomPaint(painter: EmptyIllustrationPainter(kind)),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  title,
                  style: AppTypography.titleSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  style: AppTypography.bodySecondary,
                  textAlign: TextAlign.center,
                ),
                if (actionLabel != null) ...[
                  const SizedBox(height: AppSpacing.xl),
                  AppFilledButton(label: actionLabel!, onPressed: onAction),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Ilustración simple: caja fuerte con resplandor (bóveda) o lupa (búsqueda).
class EmptyIllustrationPainter extends CustomPainter {
  const EmptyIllustrationPainter(this.kind);

  final EmptyKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    // Resplandor.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          colors: [AppColors.glow, AppColors.transparent],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.03
      ..strokeCap = StrokeCap.round
      ..color = AppColors.accentLight;
    final fill = Paint()..color = AppColors.surfaceHigh;

    if (kind == EmptyKind.search) {
      final lens = Rect.fromCircle(
        center: c.translate(-r * 0.08, -r * 0.08),
        radius: r * 0.42,
      );
      canvas.drawCircle(lens.center, lens.width / 2, fill);
      canvas.drawCircle(lens.center, lens.width / 2, stroke);
      final a = lens.center + Offset.fromDirection(math.pi / 4, lens.width / 2);
      canvas.drawLine(
        a,
        a + Offset.fromDirection(math.pi / 4, r * 0.42),
        stroke..strokeWidth = size.width * 0.06,
      );
      return;
    }

    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: r * 1.25, height: r * 1.15),
      Radius.circular(r * 0.16),
    );
    canvas.drawRRect(body, fill);
    canvas.drawRRect(body, stroke);
    // Puerta interior.
    final door = body.deflate(r * 0.12);
    canvas.drawRRect(door, stroke..strokeWidth = size.width * 0.015);
    // Dial.
    canvas.drawCircle(c, r * 0.2, Paint()..color = AppColors.accent);
    canvas.drawCircle(c, r * 0.2, stroke..color = AppColors.accentLight);
    canvas.drawCircle(c, r * 0.05, Paint()..color = AppColors.onAccent);
    // Patas.
    final foot = Paint()..color = AppColors.border;
    for (final dx in [-0.45, 0.45]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(c.dx + r * dx, body.bottom + r * 0.06),
            width: r * 0.22,
            height: r * 0.1,
          ),
          Radius.circular(r * 0.03),
        ),
        foot,
      );
    }
    // Destellos.
    final spark = Paint()..color = AppColors.accentLight;
    canvas.drawCircle(c.translate(r * 0.72, -r * 0.62), r * 0.05, spark);
    canvas.drawCircle(c.translate(-r * 0.78, -r * 0.4), r * 0.035, spark);
  }

  @override
  bool shouldRepaint(EmptyIllustrationPainter old) => old.kind != kind;
}
