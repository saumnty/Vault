import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/models/vault_item_model.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../vault_services.dart';
import 'media_opener.dart';

/// Zoom máximo del pellizco y del doble toque.
const double kViewerMaxScale = 6;
const double kViewerDoubleTapScale = 2.5;

/// Página de foto: descifra en MEMORIA (nada en claro en disco), con zoom y
/// desplazamiento (pellizco, doble toque).
class PhotoPage extends StatefulWidget {
  const PhotoPage({
    super.key,
    required this.item,
    required this.opener,
    required this.heroTag,
    required this.onZoomChanged,
    required this.onTap,
    this.thumbnailLoader,
  });

  final VaultItemModel item;
  final MediaOpener opener;
  final String heroTag;

  /// `true` mientras la imagen está ampliada (el PageView no debe deslizar).
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onTap;
  final ThumbnailLoader? thumbnailLoader;

  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _tc = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );
  Animation<Matrix4>? _zoomAnim;
  Offset _doubleTapAt = Offset.zero;
  bool _zoomed = false;

  Uint8List? _bytes;
  MediaOpenError? _error;
  MediaProgress? _progress;
  ImageProvider? _thumb;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
    _anim.addListener(() {
      final a = _zoomAnim;
      if (a != null) _tc.value = a.value;
    });
    unawaited(_loadThumb());
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _tc.removeListener(_onTransform);
    _tc.dispose();
    _anim.dispose();
    // Libera la referencia a los bytes en claro.
    _bytes = null;
    super.dispose();
  }

  Future<void> _loadThumb() async {
    final loader = widget.thumbnailLoader;
    if (loader == null || widget.item.thumbPath == null) return;
    try {
      final t = await loader(widget.item);
      if (!_disposed && mounted && _bytes == null) setState(() => _thumb = t);
    } on Object {
      // sin miniatura: se queda el fondo
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _progress = null;
    });
    try {
      final bytes = await widget.opener.loadImage(
        widget.item,
        onProgress: (p) {
          if (!_disposed && mounted) setState(() => _progress = p);
        },
      );
      if (_disposed || !mounted) return;
      setState(() => _bytes = bytes);
    } on Object catch (e) {
      if (_disposed || !mounted) return;
      setState(() => _error = describeMediaError(e));
    }
  }

  void _onTransform() {
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.02;
    if (zoomed != _zoomed) {
      _zoomed = zoomed;
      widget.onZoomChanged(zoomed);
    }
  }

  void _onDoubleTap() {
    final Matrix4 end;
    if (_tc.value.getMaxScaleOnAxis() > 1.02) {
      end = Matrix4.identity();
    } else {
      const s = kViewerDoubleTapScale;
      end = Matrix4.identity()
        ..translateByDouble(
          -_doubleTapAt.dx * (s - 1),
          -_doubleTapAt.dy * (s - 1),
          0,
          1,
        )
        ..scaleByDouble(s, s, 1, 1);
    }
    _zoomAnim = Matrix4Tween(
      begin: _tc.value,
      end: end,
    ).animate(CurvedAnimation(parent: _anim, curve: AppMotion.standard));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final label = 'Imagen ${widget.item.name}';
    return Hero(
      tag: widget.heroTag,
      child: Material(type: MaterialType.transparency, child: _body(label)),
    );
  }

  Widget _body(String label) {
    final bytes = _bytes;
    if (bytes != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
        onDoubleTap: _onDoubleTap,
        child: Semantics(
          image: true,
          label: label,
          hint: 'Pellizca o toca dos veces para ampliar',
          child: InteractiveViewer(
            key: const ValueKey('photo-zoom'),
            transformationController: _tc,
            maxScale: kViewerMaxScale,
            child: SizedBox.expand(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                errorBuilder: (context, error, stack) => const ViewerMessage(
                  key: ValueKey('photo-decode-error'),
                  icon: Icons.broken_image_outlined,
                  title: 'No se pudo mostrar la imagen',
                  message:
                      'El formato no es compatible o el archivo está dañado.',
                ),
              ),
            ),
          ),
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return ViewerMessage(
        key: const ValueKey('photo-error'),
        icon: Icons.cloud_off_outlined,
        title: 'No se pudo abrir',
        message: error.message,
        actionLabel: error.canRetry ? 'Reintentar' : null,
        onAction: error.canRetry ? _load : null,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_thumb != null)
            Image(
              image: _thumb!,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
            ),
          Center(
            key: const ValueKey('photo-loading'),
            child: ViewerProgress(progress: _progress, idleLabel: 'Abriendo…'),
          ),
        ],
      ),
    );
  }
}

/// Texto + barra de progreso del visor (descarga/descifrado).
class ViewerProgress extends StatelessWidget {
  const ViewerProgress({super.key, this.progress, this.idleLabel});

  final MediaProgress? progress;
  final String? idleLabel;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final text = switch (p?.phase) {
      MediaPhase.downloading => 'Descargando de Drive…',
      MediaPhase.decrypting => 'Descifrando…',
      null => idleLabel ?? 'Abriendo…',
    };
    final f = p?.fraction;
    final percent = f == null ? '' : ' ${(f * 100).round()} %';
    return Semantics(
      liveRegion: true,
      label: '$text$percent',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.scrim,
            borderRadius: AppRadii.lgAll,
          ),
          child: Padding(
            padding: AppSpacing.page,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$text$percent', style: AppTypography.body),
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  width: AppSizes.viewerProgressWidth,
                  child: LinearProgressIndicator(
                    value: f,
                    minHeight: AppSizes.progressBarHeight,
                    color: AppColors.accentLight,
                    backgroundColor: AppColors.overlayLight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mensaje centrado con acción opcional (errores, tipos sin vista previa).
class ViewerMessage extends StatelessWidget {
  const ViewerMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppSpacing.page,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppSizes.iconHero, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.md),
            Semantics(
              header: true,
              child: Text(
                title,
                style: AppTypography.title,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              style: AppTypography.bodySecondary,
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: AppSpacing.lg),
              AppFilledButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}
