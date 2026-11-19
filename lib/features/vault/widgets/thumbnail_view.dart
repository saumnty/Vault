import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/models/vault_item_model.dart';
import '../../../shared/format.dart';
import '../../../shared/widgets/shimmer.dart';
import '../models/browser_entry.dart';
import '../vault_services.dart';

/// Miniatura de un archivo: skeleton con shimmer mientras carga, imagen con
/// fundido cuando llega, o ícono por tipo si no hay miniatura.
class ThumbnailView extends StatefulWidget {
  const ThumbnailView({
    super.key,
    required this.item,
    required this.loader,
    this.radius = AppRadii.mdAll,
  });

  final VaultItemModel item;
  final ThumbnailLoader loader;
  final BorderRadius radius;

  @override
  State<ThumbnailView> createState() => _ThumbnailViewState();
}

/// Insignia de video: ▶ y, si se conoce, la duración.
class _VideoBadge extends StatelessWidget {
  const _VideoBadge({required this.durationMs});
  final int? durationMs;

  @override
  Widget build(BuildContext context) {
    final ms = durationMs;
    final label = ms == null || ms <= 0
        ? null
        : formatVideoDuration(Duration(milliseconds: ms));
    return Semantics(
      label: label == null ? 'Video' : 'Video, $label',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.scrim,
          borderRadius: AppRadii.smAll,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.play_arrow_rounded,
                size: AppSizes.iconSm,
                color: AppColors.textPrimary,
              ),
              if (label != null) ...[
                const SizedBox(width: AppSpacing.xxs),
                Text(label, style: AppTypography.captionOnMedia),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbnailViewState extends State<ThumbnailView> {
  Future<ImageProvider?>? _future;

  @override
  void initState() {
    super.initState();
    // Sin miniatura cifrada registrada no hay nada que esperar.
    if (widget.item.thumbPath != null) _future = widget.loader(widget.item);
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb();
    // Videos: ícono de reproducción + duración SIEMPRE (si la miniatura falló
    // o falta, es lo que identifica al video en la cuadrícula).
    if (fileKindOf(widget.item) != FileKind.video) return thumb;
    return Stack(
      fit: StackFit.expand,
      children: [
        thumb,
        Positioned(
          left: AppSpacing.sm,
          top: AppSpacing.sm,
          child: _VideoBadge(durationMs: widget.item.durationMs),
        ),
      ],
    );
  }

  Widget _thumb() {
    final future = _future;
    if (future == null) return _placeholder();
    return FutureBuilder<ImageProvider?>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SkeletonBox(radius: widget.radius);
        }
        final image = snap.data;
        if (image == null) return _placeholder();
        return ClipRRect(
          borderRadius: widget.radius,
          child: Image(
            image: image,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            excludeFromSemantics: true,
            frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
              opacity: frame == null && !sync ? 0 : 1,
              duration: AppMotion.medium,
              curve: AppMotion.standard,
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: widget.radius,
      ),
      child: Center(
        child: Icon(
          iconForKind(fileKindOf(widget.item)),
          size: AppSizes.iconXl,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
