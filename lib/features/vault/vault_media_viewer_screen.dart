import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/vault_item_model.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/empty_state.dart';
import 'models/browser_entry.dart';
import 'vault_services.dart';
import 'widgets/sync_status_icon.dart';

/// Visor a pantalla completa. El contenido comparte `Hero` con la celda.
class VaultMediaViewerScreen extends StatefulWidget {
  const VaultMediaViewerScreen({
    super.key,
    required this.item,
    required this.heroTag,
    required this.mediaLoader,
    this.imageProviderFor = FileImage.new,
  });

  final VaultItemModel item;
  final String heroTag;
  final MediaLoader mediaLoader;

  /// Proveedor de imagen para el archivo descifrado. Inyectable en pruebas
  /// (la lectura de archivos reales no se resuelve bajo `FakeAsync`).
  final ImageProvider Function(File) imageProviderFor;

  @override
  State<VaultMediaViewerScreen> createState() => _VaultMediaViewerScreenState();
}

class _VaultMediaViewerScreenState extends State<VaultMediaViewerScreen> {
  bool _isLoading = true;
  File? _plainFile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    File? file;
    try {
      file = await widget.mediaLoader(widget.item);
    } on Object {
      file = null;
    }
    if (!mounted) return;
    setState(() {
      _plainFile = file;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Scaffold(
      backgroundColor: AppColors.viewerBackground,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: AppColors.transparent,
        leading: AppIconButton(
          icon: Icons.arrow_back,
          label: 'Volver',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.titleSmall,
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Hero(
            tag: widget.heroTag,
            child: Material(
              type: MaterialType.transparency,
              child: AnimatedSwitcher(
                duration: AppMotion.medium,
                child: _content(),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: AppSpacing.page,
                child: _InfoPill(item: item),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    final kind = fileKindOf(widget.item);
    if (_isLoading) {
      return const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(),
      );
    }
    final file = _plainFile;
    if (file == null) {
      return const EmptyState(
        key: ValueKey('error'),
        title: 'No se pudo abrir',
        message:
            'No hay una copia disponible. Conéctate a internet o marca el '
            'archivo como disponible sin conexión.',
      );
    }
    return switch (kind) {
      FileKind.image => InteractiveViewer(
        key: const ValueKey('image'),
        maxScale: 6,
        child: SizedBox.expand(
          child: Image(
            image: widget.imageProviderFor(file),
            fit: BoxFit.contain,
            semanticLabel: 'Imagen ${widget.item.name}',
          ),
        ),
      ),
      // TODO(F6): reproductor de video con lectura por rangos.
      _ => Center(
        key: const ValueKey('preview'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              iconForKind(kind),
              size: AppSizes.iconHero,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text(
              'Vista previa no disponible para este tipo de archivo.',
              style: AppTypography.bodySecondary,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    };
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.item});

  final VaultItemModel item;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label:
          '${formatBytes(item.fileSize)}, ${syncStatusLabel(item.syncStatus)}',
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
                Text(
                  '${formatBytes(item.fileSize)} · ${syncStatusLabel(item.syncStatus)}',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
