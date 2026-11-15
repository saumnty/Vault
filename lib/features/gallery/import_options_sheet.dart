import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_asset_source.dart';
import '../../data/gallery/video_compressor.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';

/// Elecciones del usuario antes de importar.
class ImportChoices {
  const ImportChoices({
    required this.videoQuality,
    required this.deleteOriginalsWhenInCloud,
  });

  final VideoQualityOption videoQuality;

  /// Solo se guarda como preferencia; el borrado real exige confirmación
  /// aparte (ver `GalleryImportService.deleteOriginalsConfirmedInCloud`).
  final bool deleteOriginalsWhenInCloud;
}

/// Hoja de opciones: calidad de video (con tamaño estimado) y preferencia de
/// borrado de originales. `null` si se cancela.
Future<ImportChoices?> showImportOptionsSheet(
  BuildContext context, {
  required List<GalleryAsset> assets,
  required bool deleteOriginalsWhenInCloud,
  VideoQualityOption initialQuality = VideoQualityOption.original,
}) {
  return showBlurSheet<ImportChoices>(
    context,
    builder: (context) => ImportOptionsContent(
      assets: assets,
      initialDeleteOriginals: deleteOriginalsWhenInCloud,
      initialQuality: initialQuality,
    ),
  );
}

class ImportOptionsContent extends StatefulWidget {
  const ImportOptionsContent({
    super.key,
    required this.assets,
    required this.initialDeleteOriginals,
    this.initialQuality = VideoQualityOption.original,
  });

  final List<GalleryAsset> assets;
  final bool initialDeleteOriginals;

  /// Calidad por defecto (Ajustes > Importación).
  final VideoQualityOption initialQuality;

  @override
  State<ImportOptionsContent> createState() => _ImportOptionsContentState();
}

class _ImportOptionsContentState extends State<ImportOptionsContent> {
  late VideoQualityOption _quality = widget.initialQuality;
  late bool _delete = widget.initialDeleteOriginals;

  List<GalleryAsset> get _videos =>
      widget.assets.where((a) => a.isVideo).toList();

  /// Texto de tamaño para una calidad: estimado y, si se conoce, original.
  String _sizeText(VideoQualityOption q) {
    final videos = _videos;
    final knownOriginal = videos.every((v) => v.sizeBytes != null)
        ? videos.fold<int>(0, (s, v) => s + v.sizeBytes!)
        : null;
    final totalDuration = videos.fold<Duration>(
      Duration.zero,
      (s, v) => s + v.duration,
    );
    final estimate = estimateVideoBytes(
      duration: totalDuration,
      quality: q,
      originalBytes: knownOriginal,
    );
    if (q == VideoQualityOption.original) {
      return knownOriginal == null
          ? 'Sin recompresión'
          : formatBytes(knownOriginal);
    }
    final after = estimate == null ? '' : '≈ ${formatBytes(estimate)}';
    if (knownOriginal != null) {
      return 'Antes ${formatBytes(knownOriginal)} · Después $after';
    }
    return 'Tamaño estimado $after';
  }

  @override
  Widget build(BuildContext context) {
    final hasVideos = _videos.isNotEmpty;
    final n = widget.assets.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: n == 1 ? 'Importar 1 elemento' : 'Importar $n elementos',
          message: hasVideos
              ? 'Elige la calidad de los ${_videos.length} video(s). '
                    'El tamaño real se muestra durante la importación.'
              : 'Se cifrarán y guardarán en la bóveda.',
        ),
        if (hasVideos)
          for (final q in VideoQualityOption.values)
            _QualityTile(
              label: q.label,
              detail: _sizeText(q),
              selected: q == _quality,
              onTap: () => setState(() => _quality = q),
            ),
        const SizedBox(height: AppSpacing.sm),
        MergeSemantics(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _delete,
            onChanged: (v) => setState(() => _delete = v),
            title: const Text(
              'Borrar originales cuando estén en la nube',
              style: AppTypography.body,
            ),
            subtitle: const Text(
              'Solo se guarda la preferencia. Nunca se borra nada sin tu '
              'confirmación y sin verificar la copia en la nube.',
              style: AppTypography.caption,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppFilledButton(
          label: 'Cifrar e importar',
          icon: Icons.lock_outline,
          onPressed: () => Navigator.of(context).pop(
            ImportChoices(
              videoQuality: _quality,
              deleteOriginalsWhenInCloud: _delete,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _QualityTile extends StatelessWidget {
  const _QualityTile({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: 'Calidad $label. $detail',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: AppRadii.mdAll,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.rowHeight),
          child: Padding(
            padding: AppSpacing.card,
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? AppColors.accentLight
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: AppTypography.body),
                      Text(detail, style: AppTypography.caption),
                    ],
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
