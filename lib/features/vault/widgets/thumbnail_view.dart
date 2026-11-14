import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../data/models/vault_item_model.dart';
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
