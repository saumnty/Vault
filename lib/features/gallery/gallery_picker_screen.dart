import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_asset_source.dart';
import '../../shared/haptics.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/shimmer.dart';
import '../vault/widgets/tile_frame.dart';

/// Selector propio de galería (multi-selección) sobre [GalleryAssetSource].
/// Devuelve los assets elegidos en orden de selección (o `null` si se cancela).
///
/// Se eligió un selector propio, con los tokens del tema, en vez de
/// `wechat_assets_picker`: evita una dependencia pesada con su propio tema y
/// textos, y mantiene el aspecto y la accesibilidad coherentes con la app.
class GalleryPickerScreen extends StatefulWidget {
  const GalleryPickerScreen({super.key, required this.source});

  final GalleryAssetSource source;

  @override
  State<GalleryPickerScreen> createState() => _GalleryPickerScreenState();
}

class _GalleryPickerScreenState extends State<GalleryPickerScreen> {
  static const int _pageSize = 90;

  final ScrollController _scroll = ScrollController();
  final List<GalleryAsset> _assets = [];
  final Map<String, GalleryAsset> _selected = {}; // orden de inserción
  GalleryPermission? _permission;
  bool _loading = true;
  bool _hasMore = true;
  int _page = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _start();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final perm = await widget.source.requestPermission();
      if (!mounted) return;
      _permission = perm;
      if (perm == GalleryPermission.denied) {
        setState(() => _loading = false);
        return;
      }
      _assets.clear();
      _page = 0;
      _hasMore = true;
      await _loadMore();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.extentAfter < pos.viewportDimension) _loadMore();
  }

  bool _fetching = false;

  Future<void> _loadMore() async {
    if (_fetching || !_hasMore) return;
    _fetching = true;
    try {
      final next = await widget.source.listAssets(page: _page, size: _pageSize);
      if (!mounted) return;
      setState(() {
        _assets.addAll(next);
        _page++;
        _hasMore = next.length >= _pageSize;
        _loading = false;
      });
    } finally {
      _fetching = false;
    }
  }

  void _toggle(GalleryAsset a) {
    AppHaptics.selection();
    setState(() {
      if (_selected.remove(a.id) == null) _selected[a.id] = a;
    });
  }

  String _label(GalleryAsset a, int index, bool selected) {
    final kind = a.isVideo
        ? 'Video de ${a.duration.inSeconds} segundos'
        : 'Foto';
    return '$kind ${index + 1}${selected ? ', seleccionado' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final count = _selected.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          count == 0 ? 'Elegir de la galería' : '$count seleccionados',
        ),
      ),
      body: _body(),
      bottomNavigationBar: count == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: AppSpacing.page,
                child: AppFilledButton(
                  label: count == 1 ? 'Importar 1 elemento' : 'Importar $count',
                  icon: Icons.lock_outline,
                  onPressed: () =>
                      Navigator.of(context).pop(_selected.values.toList()),
                ),
              ),
            ),
    );
  }

  Widget _body() {
    if (_permission == GalleryPermission.denied) {
      return EmptyState(
        title: 'Sin acceso a la galería',
        message:
            'Vault necesita permiso para leer tus fotos y videos. '
            'Puedes concederlo en los ajustes del sistema.',
        actionLabel: 'Abrir ajustes',
        onAction: widget.source.openSettings,
      );
    }
    if (_error != null) {
      return EmptyState(
        title: 'No se pudo cargar la galería',
        message: 'Inténtalo de nuevo.',
        actionLabel: 'Reintentar',
        onAction: _start,
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_assets.isEmpty) {
      return const EmptyState(
        title: 'Galería vacía',
        message: 'No hay fotos ni videos para importar.',
      );
    }
    return Column(
      children: [
        if (_permission == GalleryPermission.limited)
          Padding(
            padding: AppSpacing.page,
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Solo ves las fotos que permitiste a Vault.',
                    style: AppTypography.bodySecondary,
                  ),
                ),
                AppTextButton(
                  label: 'Administrar',
                  onPressed: widget.source.openSettings,
                ),
              ],
            ),
          ),
        Expanded(
          child: GridView.builder(
            controller: _scroll,
            padding: AppSpacing.gridPage,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: AppSizes.pickerTileExtent,
              mainAxisSpacing: AppSpacing.xs,
              crossAxisSpacing: AppSpacing.xs,
            ),
            itemCount: _assets.length,
            itemBuilder: (context, i) {
              final a = _assets[i];
              final sel = _selected.containsKey(a.id);
              return TileFrame(
                semanticLabel: _label(a, i, sel),
                selected: sel,
                selectionMode: true,
                radius: AppRadii.smAll,
                onTap: () => _toggle(a),
                onLongPress: () => _toggle(a),
                child: _PickerThumb(
                  key: ValueKey(a.id),
                  asset: a,
                  source: widget.source,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PickerThumb extends StatefulWidget {
  const _PickerThumb({super.key, required this.asset, required this.source});

  final GalleryAsset asset;
  final GalleryAssetSource source;

  @override
  State<_PickerThumb> createState() => _PickerThumbState();
}

class _PickerThumbState extends State<_PickerThumb> {
  late final Future<Uint8List?> _future = widget.source.thumbnail(
    widget.asset.id,
    size: AppSizes.pickerThumbPx,
  );

  String _duration(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: AppRadii.smAll,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SkeletonBox(radius: AppRadii.smAll);
              }
              final data = snap.data;
              if (data == null) {
                return const ColoredBox(
                  color: AppColors.surfaceHigh,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: AppColors.textSecondary,
                  ),
                );
              }
              return Image.memory(
                data,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              );
            },
          ),
          if (widget.asset.isVideo)
            Positioned(
              right: AppSpacing.xs,
              bottom: AppSpacing.xs,
              child: Text(
                _duration(widget.asset.duration),
                style: AppTypography.captionOnMedia,
              ),
            ),
        ],
      ),
    );
  }
}
