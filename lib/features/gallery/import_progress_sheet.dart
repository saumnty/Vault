import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_asset_source.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';

/// Ejecuta el lote mostrando progreso. No se puede cerrar mientras corre
/// (solo "Cancelar"). Devuelve el resultado, o `null` si falló al empezar.
Future<ImportBatchResult?> showImportProgressSheet(
  BuildContext context, {
  required GalleryImportService service,
  required List<GalleryAsset> assets,
  required ImportOptions options,
}) {
  return showBlurSheet<ImportBatchResult>(
    context,
    dismissible: false,
    builder: (context) => ImportProgressContent(
      service: service,
      assets: assets,
      options: options,
    ),
  );
}

String stageLabel(ImportStage s) => switch (s) {
  ImportStage.queued => 'Preparando',
  ImportStage.downloading => 'Descargando de iCloud',
  ImportStage.compressing => 'Comprimiendo video',
  ImportStage.hashing => 'Verificando contenido',
  ImportStage.encrypting => 'Cifrando',
  ImportStage.thumbnail => 'Creando miniatura',
  ImportStage.done => 'Listo',
  ImportStage.failed => 'Error',
  ImportStage.cancelled => 'Cancelado',
};

class ImportProgressContent extends StatefulWidget {
  const ImportProgressContent({
    super.key,
    required this.service,
    required this.assets,
    required this.options,
  });

  final GalleryImportService service;
  final List<GalleryAsset> assets;
  final ImportOptions options;

  @override
  State<ImportProgressContent> createState() => _ImportProgressContentState();
}

class _ImportProgressContentState extends State<ImportProgressContent> {
  final ImportCancelToken _token = ImportCancelToken();
  ImportBatchResult? _result;
  String? _startError;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final r = await widget.service.importAssets(
        widget.assets,
        widget.options,
        cancelToken: _token,
      );
      if (mounted) setState(() => _result = r);
    } on Object catch (e) {
      if (mounted) setState(() => _startError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final finished = _result != null || _startError != null;
    return PopScope(
      canPop: finished,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_startError != null) ...[
            const SheetHeader(
              title: 'No se pudo importar',
              message: 'Comprueba que la bóveda esté desbloqueada.',
            ),
            AppFilledButton(
              label: 'Cerrar',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ] else if (_result != null)
            ..._summary(_result!)
          else
            ..._running(),
        ],
      ),
    );
  }

  List<Widget> _running() {
    return [
      ValueListenableBuilder<ImportBatchProgress>(
        valueListenable: widget.service.progress,
        builder: (context, p, _) {
          final total = widget.assets.length;
          final n = (p.currentIndex + 1).clamp(1, total);
          final detail = StringBuffer(stageLabel(p.stage));
          if (p.originalBytes != null) {
            detail.write(' · Original ${formatBytes(p.originalBytes!)}');
            if (p.compressedBytes != null) {
              detail.write(' → ${formatBytes(p.compressedBytes!)}');
            }
          }
          final overall = total == 0
              ? null
              : (p.completed + p.failed + (p.fraction ?? 0)) / total;
          return Semantics(
            liveRegion: true,
            label: 'Importando $n de $total. $detail',
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Importando $n de $total', style: AppTypography.title),
                  const SizedBox(height: AppSpacing.sm),
                  Text(detail.toString(), style: AppTypography.bodySecondary),
                  const SizedBox(height: AppSpacing.lg),
                  ClipRRect(
                    borderRadius: AppRadii.pillAll,
                    child: LinearProgressIndicator(
                      value: overall?.clamp(0.0, 1.0),
                      minHeight: AppSizes.progressBarHeight,
                      backgroundColor: AppColors.surfaceHighest,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      const SizedBox(height: AppSpacing.xl),
      AppTextButton(label: 'Cancelar', onPressed: _token.cancel),
    ];
  }

  List<Widget> _summary(ImportBatchResult r) {
    final failed = r.items.where((i) => i.stage == ImportStage.failed).toList();
    final String title;
    if (r.cancelled) {
      title = 'Importación cancelada';
    } else if (failed.isEmpty) {
      title = 'Importación completa';
    } else {
      title = 'Importación terminada con errores';
    }
    final saved = r.items
        .where((i) => i.compressed)
        .fold<int>(0, (s, i) => s + (i.originalBytes! - i.storedBytes!));
    final parts = <String>[
      '${r.succeeded} importado(s)',
      if (failed.isNotEmpty) '${failed.length} con error',
      if (r.notProcessed > 0) '${r.notProcessed} sin procesar',
      if (saved > 0) 'ahorro de ${formatBytes(saved)} por compresión',
    ];
    return [
      SheetHeader(title: title, message: parts.join(' · ')),
      for (final f in failed.take(3))
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: Text(
            '${f.assetId}: ${f.error}',
            style: AppTypography.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      const SizedBox(height: AppSpacing.md),
      AppFilledButton(
        label: 'Listo',
        onPressed: () => Navigator.of(context).pop(r),
      ),
    ];
  }
}
