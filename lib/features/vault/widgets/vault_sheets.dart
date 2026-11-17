import 'package:flutter/material.dart';

import '../services/trash_service.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/models/folder_model.dart';
import '../../../data/repositories/vault_data_repository.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/blur_sheet.dart';

/// Confirma la importación de un archivo. NUNCA elimina el original: el
/// selector de archivos entrega una copia y el borrado de originales solo
/// existe tras verificar la copia en la nube (Ajustes > Importación).
/// `false` = importar (conservando el original), `null` = cancelar.
Future<bool?> showImportConfirmSheet(BuildContext context) {
  return showBlurSheet<bool>(
    context,
    builder: (context) => const ImportConfirmContent(),
  );
}

class ImportConfirmContent extends StatelessWidget {
  const ImportConfirmContent({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader(
          title: 'Importar al Vault',
          message:
              'Se cifrará una copia en la bóveda y tu archivo original no se '
              'toca. Si quieres liberar espacio, activa "Borrar originales '
              'cuando estén en la nube" en Ajustes: solo se borran con su '
              'copia verificada en Drive y tras tu confirmación.',
        ),
        AppFilledButton(
          label: 'Cifrar e importar',
          icon: Icons.lock_outline,
          onPressed: () => Navigator.of(context).pop(false),
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

/// Pide el nombre de una carpeta nueva. `null` si se cancela.
Future<String?> showNewFolderSheet(BuildContext context) {
  return showBlurSheet<String>(
    context,
    builder: (context) => const NewFolderContent(),
  );
}

class NewFolderContent extends StatefulWidget {
  const NewFolderContent({super.key});

  @override
  State<NewFolderContent> createState() => _NewFolderContentState();
}

class _NewFolderContentState extends State<NewFolderContent> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _name.text.trim();
    if (value.isNotEmpty) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader(title: 'Nueva carpeta'),
        Semantics(
          textField: true,
          label: 'Nombre de la carpeta',
          child: TextField(
            controller: _name,
            autofocus: true,
            // S-13: el teclado no aprende ni sugiere nombres de la bóveda.
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            style: AppTypography.body,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              hintText: 'Nombre de la carpeta',
              hintStyle: AppTypography.bodySecondary,
              filled: true,
              fillColor: AppColors.surfaceHigh,
              border: OutlineInputBorder(
                borderRadius: AppRadii.mdAll,
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppFilledButton(label: 'Crear', onPressed: _submit),
      ],
    );
  }
}

/// Confirma la eliminación. `true` si el usuario acepta. Con [toTrash] el
/// texto es el de la papelera (restaurable 30 días); sin ella, el del borrado
/// directo (permanente, también en Drive).
Future<bool> showConfirmDeleteSheet(
  BuildContext context, {
  required int count,
  required bool includesFolders,
  bool toTrash = false,
}) async {
  final String title;
  final String message;
  if (toTrash) {
    title = count == 1
        ? '¿Mover 1 elemento a la Papelera?'
        : '¿Mover $count elementos a la Papelera?';
    message =
        '${includesFolders ? 'Las carpetas van con todo su contenido. ' : ''}'
        'Podrás restaurarlo desde Ajustes > Papelera durante '
        '$kTrashRetentionDays días. Después se eliminará de forma '
        'permanente, también de la nube (Google Drive).';
  } else {
    title = count == 1
        ? '¿Eliminar 1 elemento?'
        : '¿Eliminar $count elementos?';
    message = includesFolders
        ? 'Las carpetas se eliminan con todo su contenido. También se '
              'eliminará de la nube (Google Drive). Esta acción no se '
              'puede deshacer.'
        : 'También se eliminará de la nube (Google Drive). Esta '
              'acción no se puede deshacer.';
  }
  final result = await showBlurSheet<bool>(
    context,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: title, message: message),
        AppFilledButton(
          label: toTrash ? 'Mover a la Papelera' : 'Eliminar',
          icon: Icons.delete_outline,
          destructive: !toTrash,
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Destino elegido en el selector de carpeta (`id == null` = raíz).
class FolderPick {
  const FolderPick(this.id);

  final String? id;
}

Future<FolderPick?> showMoveSheet(
  BuildContext context, {
  required VaultDataRepository repository,
  required Set<String> excludeFolderIds,
}) {
  return showBlurSheet<FolderPick>(
    context,
    builder: (context) =>
        MoveSheetContent(repository: repository, exclude: excludeFolderIds),
  );
}

/// Navega por el árbol de carpetas y devuelve la elegida.
class MoveSheetContent extends StatefulWidget {
  const MoveSheetContent({
    super.key,
    required this.repository,
    required this.exclude,
  });

  final VaultDataRepository repository;
  final Set<String> exclude;

  @override
  State<MoveSheetContent> createState() => _MoveSheetContentState();
}

class _MoveSheetContentState extends State<MoveSheetContent> {
  FolderModel? _current;
  List<FolderModel> _children = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _open(null);
  }

  Future<void> _open(FolderModel? folder) async {
    setState(() => _loading = true);
    final children = await widget.repository.getFoldersByParent(folder?.id);
    if (!mounted) return;
    setState(() {
      _current = folder;
      _children = children
          .where((f) => !widget.exclude.contains(f.id))
          .toList();
      _loading = false;
    });
  }

  Future<void> _up() async {
    final parentId = _current?.parentId;
    _open(
      parentId == null ? null : await widget.repository.getFolder(parentId),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: 'Mover a…',
          message: _current == null ? 'Mi Bóveda' : _current!.name,
        ),
        if (_current != null)
          SheetActionTile(
            icon: Icons.arrow_upward,
            label: 'Subir un nivel',
            onTap: _up,
          ),
        if (_loading)
          const Padding(
            padding: AppSpacing.page,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_children.isEmpty)
          const Padding(
            padding: AppSpacing.page,
            child: Text(
              'No hay subcarpetas aquí.',
              style: AppTypography.bodySecondary,
            ),
          )
        else
          for (final f in _children)
            SheetActionTile(
              icon: Icons.folder_rounded,
              label: f.name,
              onTap: () => _open(f),
            ),
        const SizedBox(height: AppSpacing.md),
        AppFilledButton(
          label: 'Mover aquí',
          icon: Icons.drive_file_move_outline,
          onPressed: () => Navigator.of(context).pop(FolderPick(_current?.id)),
        ),
      ],
    );
  }
}
