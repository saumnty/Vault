import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session/vault_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/vault_item_model.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';
import 'models/browser_entry.dart';
import 'vault_services.dart';
import 'viewer/media_opener.dart';
import 'viewer/photo_page.dart';
import 'viewer/video_page.dart';
import 'viewer/viewer_dismiss.dart';
import 'widgets/sync_status_icon.dart';

/// Visor a pantalla completa: navega entre los archivos de la carpeta
/// (PageView), fotos con zoom/desplazamiento y videos con reproductor propio.
///
/// * Las imágenes se descifran en memoria (nada en claro en disco).
/// * Un toque oculta/muestra la barra; "Cerrar" vuelve a la cuadrícula.
/// * Si la bóveda se bloquea ([VaultSession.clear]) el visor se cierra y los
///   temporales descifrados se borran.
class VaultMediaViewerScreen extends StatefulWidget {
  const VaultMediaViewerScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.mediaOpener,
    this.thumbnailLoader,
    this.session,
  }) : assert(items.length > 0);

  /// Archivos de la carpeta en el orden de la cuadrícula.
  final List<VaultItemModel> items;
  final int initialIndex;
  final MediaOpener mediaOpener;
  final ThumbnailLoader? thumbnailLoader;

  /// Sesión a vigilar (por defecto la global; inyectable en pruebas).
  final VaultSession? session;

  @override
  State<VaultMediaViewerScreen> createState() => _VaultMediaViewerScreenState();
}

class _VaultMediaViewerScreenState extends State<VaultMediaViewerScreen> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex.clamp(0, widget.items.length - 1),
  );
  late int _index = widget.initialIndex.clamp(0, widget.items.length - 1);
  late final VaultSession _session = widget.session ?? VaultSession();
  bool _chrome = true;
  bool _zoomed = false;
  bool _fullscreen = false;

  /// Progreso (0..1) del gesto de cerrar deslizando hacia abajo.
  final ValueNotifier<double> _dismiss = ValueNotifier<double>(0);

  VaultItemModel get _item => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _session.addOnClear(_onLock);
  }

  @override
  void dispose() {
    _session.removeOnClear(_onLock);
    _pages.dispose();
    _dismiss.dispose();
    super.dispose();
  }

  // Se guarda el Navigator: al bloquear, este callback puede ejecutarse cuando
  // el elemento ya está desactivado (visor cerrándose) y `Navigator.of(context)`
  // lanzaría "Looking up a deactivated widget's ancestor is unsafe".
  NavigatorState? _navigator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  void _onLock() {
    // Cierra el visor: al desmontar las páginas se liberan temporales y bytes.
    _navigator?.popUntil((r) => r.isFirst);
  }

  void _toggleChrome() => setState(() => _chrome = !_chrome);

  void _onPageChanged(int i) {
    setState(() {
      _index = i;
      _zoomed = false;
      _chrome = true;
    });
  }

  Future<void> _showInfo() async {
    await showBlurSheet<void>(
      context,
      builder: (_) => ViewerInfoContent(item: _item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showBars = _chrome && !_fullscreen;
    // El fondo (y las barras) se desvanecen según la distancia del arrastre.
    return ValueListenableBuilder<double>(
      valueListenable: _dismiss,
      builder: (context, p, _) => Scaffold(
        key: const ValueKey('viewer-scaffold'),
        backgroundColor: AppColors.viewerBackground.withValues(alpha: 1 - p),
        body: Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              onDismiss: () => Navigator.of(context).maybePop(),
              child: ViewerDismissible(
                progress: _dismiss,
                enabled: !_zoomed,
                onDismiss: () => Navigator.of(context).maybePop(),
                child: PageView.builder(
                  key: const ValueKey('viewer-pages'),
                  controller: _pages,
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: widget.items.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, i) => _page(widget.items[i]),
                ),
              ),
            ),
            Opacity(
              opacity: 1 - p,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: _fade(
                      showBars,
                      _TopBar(item: _item, onInfo: _showInfo),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _fade(
                      showBars && fileKindOf(_item) != FileKind.video,
                      _BottomBar(
                        item: _item,
                        position: _index + 1,
                        total: widget.items.length,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fade(bool visible, Widget child) => AnimatedOpacity(
    duration: AppMotion.fast,
    opacity: visible ? 1 : 0,
    child: IgnorePointer(ignoring: !visible, child: child),
  );

  Widget _page(VaultItemModel item) {
    final tag = FileEntry.heroTagFor(item.id);
    final kind = fileKindOf(item);
    Widget page = switch (kind) {
      FileKind.image => PhotoPage(
        key: ValueKey('page-${item.id}'),
        item: item,
        opener: widget.mediaOpener,
        heroTag: tag,
        thumbnailLoader: widget.thumbnailLoader,
        onTap: _toggleChrome,
        onZoomChanged: (z) {
          if (item.id == _item.id && z != _zoomed) {
            setState(() {
              _zoomed = z;
              if (z) _chrome = false;
            });
          }
        },
      ),
      FileKind.video => VideoPage(
        key: ValueKey('page-${item.id}'),
        item: item,
        opener: widget.mediaOpener,
        heroTag: tag,
        thumbnailLoader: widget.thumbnailLoader,
        chromeVisible: _chrome,
        onTap: _toggleChrome,
        onFullscreenChanged: (v) => setState(() => _fullscreen = v),
      ),
      _ => Hero(
        tag: tag,
        child: Material(
          type: MaterialType.transparency,
          child: ViewerMessage(
            key: ValueKey('page-${item.id}'),
            icon: iconForKind(kind),
            title: item.name,
            message: 'Vista previa no disponible para este tipo de archivo.',
          ),
        ),
      ),
    };
    return page;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.item, required this.onInfo});

  final VaultItemModel item;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.scrim, AppColors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppSizes.toolbar,
          child: Row(
            children: [
              const SizedBox(width: AppSpacing.xs),
              AppIconButton(
                icon: Icons.close,
                label: 'Cerrar',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.titleSmall,
                ),
              ),
              AppIconButton(
                icon: Icons.info_outline,
                label: 'Información del archivo',
                onPressed: onInfo,
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.item,
    required this.position,
    required this.total,
  });

  final VaultItemModel item;
  final int position;
  final int total;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: AppSpacing.page,
        child: Semantics(
          container: true,
          label:
              'Archivo $position de $total, ${formatBytes(item.fileSize)}, '
              '${syncStatusLabel(item.syncStatus)}',
          child: ExcludeSemantics(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: AppColors.scrim,
                borderRadius: AppRadii.pillAll,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SyncStatusIcon(status: item.syncStatus),
                    const SizedBox(width: AppSpacing.sm),
                    Flexible(
                      child: Text(
                        '$position / $total · ${formatBytes(item.fileSize)} · '
                        '${syncStatusLabel(item.syncStatus)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Metadatos básicos del archivo (hoja de información).
class ViewerInfoContent extends StatelessWidget {
  const ViewerInfoContent({super.key, required this.item});

  final VaultItemModel item;

  @override
  Widget build(BuildContext context) {
    final kind = fileKindOf(item);
    final rows = <(String, String)>[
      ('Tipo', labelForKind(kind)),
      ('Tamaño', formatBytes(item.fileSize)),
      ('Fecha', formatIsoDate(item.createdAt)),
      ('Estado', syncStatusLabel(item.syncStatus)),
      if (item.durationMs != null)
        ('Duración', formatDuration(Duration(milliseconds: item.durationMs!))),
      if (item.isOffline) ('Sin conexión', 'Siempre disponible'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: item.name),
        for (final (k, v) in rows)
          Semantics(
            container: true,
            label: '$k: $v',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(k, style: AppTypography.bodySecondary),
                    ),
                    Text(v, style: AppTypography.body),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        AppTextButton(
          label: 'Cerrar',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
