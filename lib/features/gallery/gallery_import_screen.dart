import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_album_source.dart';
import '../../data/gallery/gallery_asset_source.dart';
import '../../shared/navigation/app_page_route.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';
import '../../shared/widgets/empty_state.dart';
import 'gallery_picker_screen.dart';

/// «Importar de galería» con pestañas Fotos | Álbumes (v2.2, D86). Devuelve
/// un [GalleryPickResult] o `null` si se cancela.
class GalleryImportScreen extends StatefulWidget {
  const GalleryImportScreen({super.key, required this.source});

  final GalleryAlbumSource source;

  @override
  State<GalleryImportScreen> createState() => _GalleryImportScreenState();
}

class _GalleryImportScreenState extends State<GalleryImportScreen> {
  GalleryPermission? _permission;
  List<GalleryAlbum>? _albums;
  Object? _error;
  GalleryPickResult? _photos;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _albums = null;
    });
    try {
      final perm = await widget.source.requestPermission();
      if (!mounted) return;
      setState(() => _permission = perm);
      if (perm == GalleryPermission.denied) return;
      final albums = await widget.source.listAlbums();
      if (mounted) setState(() => _albums = albums);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  GalleryAlbum? get _allAlbum {
    for (final a in _albums ?? const <GalleryAlbum>[]) {
      if (a.isAll) return a;
    }
    return null;
  }

  Future<void> _openAlbum(GalleryAlbum album) async {
    final choice = await showAlbumActionSheet(context, album: album);
    if (choice == null || !mounted) return;
    if (choice == AlbumAction.importAll) {
      Navigator.of(context).pop(
        GalleryPickResult(
          album: album,
          allSelected: true,
          fromAlbumList: true,
        ),
      );
      return;
    }
    final picked = await Navigator.of(context).push<GalleryPickResult>(
      AppPageRoute<GalleryPickResult>(
        builder: (_) => GalleryPickerScreen(
          source: widget.source,
          album: album,
          fromAlbumList: true,
        ),
      ),
    );
    if (picked != null && picked.count > 0 && mounted) {
      Navigator.of(context).pop(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _photos?.count ?? 0;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            count == 0 ? 'Importar de la galería' : '$count seleccionados',
          ),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Fotos'),
              Tab(text: 'Álbumes'),
            ],
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
                    onPressed: () => Navigator.of(context).pop(_photos),
                  ),
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
            'Kern necesita permiso para leer tus fotos y videos. '
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
    final albums = _albums;
    if (albums == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final all = _allAlbum;
    return TabBarView(
      children: [
        // Fotos: toda la galería, con «Seleccionar todo» por exclusión.
        all == null
            ? const EmptyState(
                title: 'Galería vacía',
                message: 'No hay fotos ni videos para importar.',
              )
            : GalleryPickerView(
                source: widget.source,
                album: all,
                requestPermission: false,
                onChanged: (r) => setState(() => _photos = r),
              ),
        _AlbumList(albums: albums, onTap: _openAlbum),
      ],
    );
  }
}

class _AlbumList extends StatelessWidget {
  const _AlbumList({required this.albums, required this.onTap});

  final List<GalleryAlbum> albums;
  final ValueChanged<GalleryAlbum> onTap;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return const EmptyState(
        title: 'Sin álbumes',
        message: 'No hay álbumes con fotos o videos.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final a = albums[i];
        final n = a.count == 1 ? '1 elemento' : '${a.count} elementos';
        return Semantics(
          button: true,
          label: 'Álbum ${a.name}, $n',
          excludeSemantics: true,
          child: ListTile(
            minTileHeight: AppSizes.rowHeight,
            leading: Icon(
              a.isAll ? Icons.photo_library_outlined : Icons.photo_album_outlined,
              color: AppColors.accentLight,
            ),
            title: Text(a.name, style: AppTypography.body),
            subtitle: Text(n, style: AppTypography.caption),
            trailing: const Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
            ),
            onTap: () => onTap(a),
          ),
        );
      },
    );
  }
}

/// Qué hacer con un álbum.
enum AlbumAction { importAll, choose }

/// «Importar las N fotos/videos» o «Elegir». `null` si se cancela.
Future<AlbumAction?> showAlbumActionSheet(
  BuildContext context, {
  required GalleryAlbum album,
}) {
  final n = album.count;
  return showBlurSheet<AlbumAction>(
    context,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: album.name,
          message: n == 1 ? '1 foto o video' : '$n fotos y videos',
        ),
        AppFilledButton(
          label: n == 1 ? 'Importar 1 elemento' : 'Importar los $n',
          icon: Icons.lock_outline,
          onPressed: () => Navigator.of(context).pop(AlbumAction.importAll),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Elegir',
          onPressed: () => Navigator.of(context).pop(AlbumAction.choose),
        ),
        AppTextButton(
          label: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}
