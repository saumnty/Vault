import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_album_source.dart';
import '../../data/gallery/gallery_asset_source.dart';
import '../../shared/haptics.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/shimmer.dart';
import '../vault/widgets/tile_frame.dart';

/// Lo elegido en la cuadrícula (D86). Con [allSelected] la selección es «todo
/// el álbum menos [excluded]» y NO hace falta tener cargados sus assets (un
/// álbum de 1000 nunca se carga entero en memoria).
class GalleryPickResult {
  const GalleryPickResult({
    this.album,
    this.allSelected = false,
    this.excluded = const {},
    this.assets = const [],
    this.fromAlbumList = false,
  });

  final GalleryAlbum? album;
  final bool allSelected;
  final Set<String> excluded;

  /// Selección explícita (en orden de selección) si no es [allSelected].
  final List<GalleryAsset> assets;

  /// Elegido desde la pestaña «Álbumes» (por defecto va a una carpeta con su
  /// nombre); desde «Fotos» va a la carpeta actual.
  final bool fromAlbumList;

  int get count =>
      allSelected ? (album?.count ?? 0) - excluded.length : assets.length;
}

/// Selector propio de galería (multi-selección) sobre [GalleryAssetSource].
/// Devuelve los assets elegidos en orden de selección (o `null` si se cancela).
///
/// Se eligió un selector propio, con los tokens del tema, en vez de
/// `wechat_assets_picker`: evita una dependencia pesada con su propio tema y
/// textos, y mantiene el aspecto y la accesibilidad coherentes con la app.
///
/// Con [album] (D86) pagina ese álbum, ofrece «Seleccionar todo» y devuelve
/// un [GalleryPickResult].
class GalleryPickerScreen extends StatefulWidget {
  const GalleryPickerScreen({
    super.key,
    required this.source,
    this.album,
    this.fromAlbumList = false,
  });

  final GalleryAssetSource source;
  final GalleryAlbum? album;
  final bool fromAlbumList;

  @override
  State<GalleryPickerScreen> createState() => _GalleryPickerScreenState();
}

class _GalleryPickerScreenState extends State<GalleryPickerScreen> {
  int _count = 0;
  GalleryPickResult? _current;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _count == 0
              ? (album?.name ?? 'Elegir de la galería')
              : '$_count seleccionados',
        ),
      ),
      body: GalleryPickerView(
        source: widget.source,
        album: album,
        requestPermission: album == null,
        fromAlbumList: widget.fromAlbumList,
        onChanged: (r) => setState(() {
          _current = r;
          _count = r.count;
        }),
      ),
      bottomNavigationBar: _count == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: AppSpacing.page,
                child: AppFilledButton(
                  label: _count == 1 ? 'Importar 1 elemento' : 'Importar $_count',
                  icon: Icons.lock_outline,
                  onPressed: () {
                    final r = _current!;
                    // Sin álbum, el contrato de siempre: la lista elegida.
                    Navigator.of(context).pop(album == null ? r.assets : r);
                  },
                ),
              ),
            ),
    );
  }
}

/// Cuadrícula paginada con selección (cuerpo del selector; también se usa
/// en la pestaña «Fotos» de [GalleryImportScreen]).
class GalleryPickerView extends StatefulWidget {
  const GalleryPickerView({
    super.key,
    required this.source,
    required this.onChanged,
    this.album,
    this.requestPermission = true,
    this.fromAlbumList = false,
  });

  final GalleryAssetSource source;
  final GalleryAlbum? album;

  /// `false` si el permiso ya se pidió fuera (pestañas).
  final bool requestPermission;
  final bool fromAlbumList;
  final ValueChanged<GalleryPickResult> onChanged;

  @override
  State<GalleryPickerView> createState() => _GalleryPickerViewState();
}

class _GalleryPickerViewState extends State<GalleryPickerView> {
  static const int _pageSize = 90;

  final ScrollController _scroll = ScrollController();
  final List<GalleryAsset> _assets = [];
  final Map<String, GalleryAsset> _selected = {}; // orden de inserción
  bool _allSelected = false;
  final Set<String> _excluded = {};
  GalleryPermission? _permission;
  bool _loading = true;
  bool _hasMore = true;
  int _page = 0;
  Object? _error;

  GalleryAlbumSource? get _albumSource {
    final s = widget.source;
    return s is GalleryAlbumSource ? s : null;
  }

  /// «Seleccionar todo» por exclusión solo con álbum (si no, selecciona lo
  /// cargado).
  bool get _albumMode => widget.album != null && _albumSource != null;

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
      if (widget.requestPermission) {
        final perm = await widget.source.requestPermission();
        if (!mounted) return;
        _permission = perm;
        if (perm == GalleryPermission.denied) {
          setState(() => _loading = false);
          return;
        }
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
      final album = widget.album;
      final src = _albumSource;
      final next = album != null && src != null
          ? await src.listAlbumAssets(album.id, page: _page, size: _pageSize)
          : await widget.source.listAssets(page: _page, size: _pageSize);
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

  bool _isSelected(GalleryAsset a) =>
      _allSelected ? !_excluded.contains(a.id) : _selected.containsKey(a.id);

  void _publish() {
    widget.onChanged(
      GalleryPickResult(
        album: widget.album,
        allSelected: _allSelected,
        excluded: Set.of(_excluded),
        assets: _selected.values.toList(),
        fromAlbumList: widget.fromAlbumList,
      ),
    );
  }

  void _toggle(GalleryAsset a) {
    AppHaptics.selection();
    setState(() {
      if (_allSelected) {
        if (!_excluded.remove(a.id)) _excluded.add(a.id);
        // Todo excluido = nada seleccionado.
        if (_excluded.length >= (widget.album?.count ?? 0)) {
          _allSelected = false;
          _excluded.clear();
        }
      } else if (_selected.remove(a.id) == null) {
        _selected[a.id] = a;
      }
    });
    _publish();
  }

  bool get _everythingSelected => _albumMode
      ? _allSelected && _excluded.isEmpty
      : _assets.isNotEmpty && _selected.length == _assets.length && !_hasMore;

  void _toggleAll() {
    AppHaptics.selection();
    setState(() {
      if (_everythingSelected) {
        _allSelected = false;
        _excluded.clear();
        _selected.clear();
      } else if (_albumMode) {
        _allSelected = true;
        _excluded.clear();
        _selected.clear();
      } else {
        for (final a in _assets) {
          _selected[a.id] = a;
        }
      }
    });
    _publish();
  }

  String _label(GalleryAsset a, int index, bool selected) {
    final kind = a.isVideo
        ? 'Video de ${a.duration.inSeconds} segundos'
        : 'Foto';
    return '$kind ${index + 1}${selected ? ', seleccionado' : ''}';
  }

  @override
  Widget build(BuildContext context) {
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
    final showSelectAll = _albumMode;
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
        if (showSelectAll)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.album!.count == 1
                        ? '1 elemento'
                        : '${widget.album!.count} elementos',
                    style: AppTypography.bodySecondary,
                  ),
                ),
                AppTextButton(
                  label: _everythingSelected
                      ? 'Quitar selección'
                      : 'Seleccionar todo',
                  onPressed: _toggleAll,
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
              final sel = _isSelected(a);
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
