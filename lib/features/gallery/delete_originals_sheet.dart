import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../data/models/vault_item_model.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';

/// Muestra la hoja "Borrar originales" y devuelve cuántos originales se
/// borraron (0 si no hay nada, se cancela o falla). Nunca borra sin que el
/// usuario pulse el botón destructivo.
Future<int> showDeleteOriginalsSheet(
  BuildContext context, {
  required GalleryImportService service,
}) async {
  final n = await showBlurSheet<int>(
    context,
    builder: (context) => DeleteOriginalsContent(
      load: service.verifiedDeleteCandidates,
      confirm: (items) => service.deleteOriginalsConfirmedInCloud(
        candidates: items,
        userConfirmed: true,
      ),
    ),
  );
  return n ?? 0;
}

/// Contenido de la hoja: consulta a Drive qué copias están verificadas, lista
/// SOLO esos archivos, avisa de que no se puede deshacer y pide confirmación.
class DeleteOriginalsContent extends StatefulWidget {
  const DeleteOriginalsContent({
    super.key,
    required this.load,
    required this.confirm,
  });

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

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            title: 'Buscando originales…',
            message: 'Comprobando en tu Drive qué copias están verificadas.',
          ),
          Center(child: CircularProgressIndicator()),
          SizedBox(height: AppSpacing.lg),
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
              'la bóveda. Esta acción no se puede deshacer.',
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final i in items)
                Padding(
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
                ),
            ],
          ),
        ),
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
