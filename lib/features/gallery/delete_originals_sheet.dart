import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../data/models/vault_item_model.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';

/// Texto aclaratorio del interruptor "Borrar originales cuando estén en la
/// nube" (hoja de importación y Ajustes).
const String deleteOriginalsExplanation =
    'Apagado por defecto. Solo se borran los originales cuya copia ya está '
    'verificada en la nube, y el sistema te pedirá confirmación antes de '
    'borrar.';

/// Muestra la hoja "Borrar originales" y devuelve cuántos originales se
/// borraron (0 si no hay nada, se cancela o falla). Nunca borra sin que el
/// usuario pulse el botón destructivo.
Future<int> showDeleteOriginalsSheet(
  BuildContext context, {
  required GalleryImportService service,
}) async {
  // D87: con cientos de archivos cada uno se comprueba contra Drive: se
  // muestra «Comprobando N de M».
  final progress = ValueNotifier<(int, int)?>(null);
  try {
    final n = await showBlurSheet<int>(
      context,
      builder: (context) => DeleteOriginalsContent(
        progress: progress,
        load: () => service.verifiedDeleteCandidates(
          onProgress: (d, t) => progress.value = (d, t),
        ),
        confirm: (items) {
          progress.value = null;
          return service.deleteOriginalsConfirmedInCloud(
            candidates: items,
            userConfirmed: true,
            onProgress: (d, t) => progress.value = (d, t),
          );
        },
      ),
    );
    return n ?? 0;
  } finally {
    progress.dispose();
  }
}

/// Contenido de la hoja: consulta a Drive qué copias están verificadas, lista
/// SOLO esos archivos, avisa de que no se puede deshacer y pide confirmación.
class DeleteOriginalsContent extends StatefulWidget {
  const DeleteOriginalsContent({
    super.key,
    required this.load,
    required this.confirm,
    this.progress,
  });

  /// D87: avance de la comprobación (hecho, total), si se conoce.
  final ValueListenable<(int, int)?>? progress;

  /// Candidatos con la copia en la nube verificada ahora mismo.
  final Future<List<VaultItemModel>> Function() load;

  /// Borra los originales de la lista; devuelve los ids borrados. Solo se
  /// llama tras pulsar el botón destructivo.
  final Future<List<String>> Function(List<VaultItemModel> items) confirm;

  @override
  State<DeleteOriginalsContent> createState() => _DeleteOriginalsContentState();
}

class _DeleteOriginalsContentState extends State<DeleteOriginalsContent> {
  List<VaultItemModel>? _items;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<VaultItemModel> items;
    try {
      items = await widget.load();
    } on Object {
      items = const [];
    }
    if (mounted) setState(() => _items = items);
  }

  Future<void> _confirm() async {
    final items = _items;
    if (items == null || items.isEmpty || _deleting) return;
    setState(() => _deleting = true);
    var deleted = 0;
    try {
      final ids = await widget.confirm(items);
      deleted = ids.length;
    } on Object {
      deleted = 0;
    }
    if (mounted) Navigator.of(context).pop(deleted);
  }

  Widget _progressText() {
    final p = widget.progress;
    if (p == null) return const SizedBox.shrink();
    return ValueListenableBuilder<(int, int)?>(
      valueListenable: p,
      builder: (context, v, _) => v == null || v.$2 < 2
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                'Comprobando ${v.$1} de ${v.$2}',
                style: AppTypography.caption,
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(
            title: 'Buscando originales…',
            message: 'Comprobando en tu Drive qué copias están verificadas.',
          ),
          _progressText(),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: AppSpacing.lg),
        ],
      );
    }
    if (items.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(
            title: 'No hay originales para borrar',
            message:
                'Solo se pueden borrar los originales cuya copia cifrada '
                'está verificada en tu Google Drive. Los demás se conservan.',
          ),
          AppTextButton(
            label: 'Cerrar',
            onPressed: () => Navigator.of(context).pop(0),
          ),
        ],
      );
    }
    final total = items.fold<int>(0, (sum, i) => sum + i.fileSize);
    // D87: hasta `deleteChunkSize` originales, UNA confirmación del sistema.
    const chunk = GalleryImportService.deleteChunkSize;
    final prompts = (items.length + chunk - 1) ~/ chunk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: items.length == 1
              ? '¿Borrar 1 original del dispositivo?'
              : '¿Borrar ${items.length} originales del dispositivo?',
          message:
              'Se borrarán de tu galería (${formatBytes(total)}). Su copia '
              'cifrada está verificada en tu Google Drive y se conserva en '
              'la bóveda. Esta acción no se puede deshacer.'
              '${prompts > 1 ? ' El sistema te pedirá confirmar $prompts veces (de $chunk en $chunk).' : ''}',
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, n) {
              final i = items[n];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        i.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body,
                      ),
                    ),
                    Text(
                      formatBytes(i.fileSize),
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (_deleting) _progressText(),
        const SizedBox(height: AppSpacing.lg),
        AppFilledButton(
          label: items.length == 1
              ? 'Borrar original'
              : 'Borrar ${items.length} originales',
          icon: Icons.delete_outline,
          destructive: true,
          busy: _deleting,
          onPressed: _deleting ? null : _confirm,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Cancelar',
          onPressed: _deleting ? null : () => Navigator.of(context).pop(0),
        ),
      ],
    );
  }
}
