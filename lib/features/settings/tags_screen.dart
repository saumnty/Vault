import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/tags/tag_repository.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';
import '../../shared/widgets/choice_sheet.dart';

String _filesLabel(int n) => n == 1 ? '1 archivo' : '$n archivos';

/// Mensaje claro para los errores de nombre de etiqueta (o `null`).
String? tagErrorMessage(Object e) {
  if (e is InvalidTagNameException) {
    return 'El nombre no puede estar vacío ni pasar de $kTagNameMax caracteres';
  }
  if (e is DuplicateTagException) {
    return 'Ya existe una etiqueta llamada "${e.existing.name}"';
  }
  return null;
}

/// Ajustes > Etiquetas: crear, renombrar y eliminar etiquetas. Eliminar una
/// etiqueta solo la quita de los archivos; los archivos no se borran.
class TagsScreen extends StatefulWidget {
  const TagsScreen({super.key, required this.repository});

  final TagRepository repository;

  @override
  State<TagsScreen> createState() => _TagsScreenState();
}

class _TagsScreenState extends State<TagsScreen> {
  List<TagModel>? _tags;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<TagModel> list;
    try {
      list = await widget.repository.list();
    } on Object {
      list = const [];
    }
    if (mounted) setState(() => _tags = list);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _create() async {
    final ok = await showBlurSheet<bool>(
      context,
      builder: (context) => _TagNameSheet(
        title: 'Nueva etiqueta',
        confirmLabel: 'Crear',
        submit: (name) => widget.repository.create(name),
      ),
    );
    if (ok == true) {
      _snack('Etiqueta creada');
      await _load();
    }
  }

  Future<void> _rename(TagModel t) async {
    final ok = await showBlurSheet<bool>(
      context,
      builder: (context) => _TagNameSheet(
        title: 'Renombrar etiqueta',
        confirmLabel: 'Guardar',
        initial: t.name,
        submit: (name) => widget.repository.rename(t.id, name),
      ),
    );
    if (ok == true) {
      _snack('Etiqueta renombrada');
      await _load();
    }
  }

  Future<void> _delete(TagModel t) async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Eliminar la etiqueta "${t.name}"?',
      message:
          'Se quitará de ${_filesLabel(t.itemCount)}; los archivos no se '
          'borran.',
      confirmLabel: 'Eliminar etiqueta',
      destructive: true,
      icon: Icons.delete_outline,
    );
    if (!ok || !mounted) return;
    try {
      await widget.repository.delete(t.id);
      _snack('Etiqueta eliminada');
    } on Object {
      _snack('No se pudo eliminar la etiqueta');
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: AppSizes.toolbar,
              child: Row(
                children: [
                  AppIconButton(
                    icon: Icons.arrow_back,
                    label: 'Volver',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: const Text('Etiquetas', style: AppTypography.title),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppSizes.contentMaxWidth,
                  ),
                  child: tags == null
                      ? const Center(child: CircularProgressIndicator())
                      : _body(tags),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(List<TagModel> tags) {
    return Padding(
      padding: AppSpacing.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Organiza tus archivos con etiquetas y filtra por ellas desde la '
            'bóveda. Eliminar una etiqueta no borra ningún archivo.',
            style: AppTypography.bodySecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: tags.isEmpty
                ? const Center(
                    child: Text(
                      'Aún no tienes etiquetas',
                      key: ValueKey('tags-empty'),
                      style: AppTypography.bodySecondary,
                    ),
                  )
                : ListView.separated(
                    itemCount: tags.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _row(tags[i]),
                  ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppFilledButton(
            key: const ValueKey('create-tag'),
            label: 'Nueva etiqueta',
            icon: Icons.add,
            onPressed: _create,
          ),
        ],
      ),
    );
  }

  Widget _row(TagModel t) {
    return Semantics(
      container: true,
      label: 'Etiqueta ${t.name}. ${_filesLabel(t.itemCount)}',
      child: DecoratedBox(
        key: ValueKey('tag-${t.id}'),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadii.mdAll,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              const Icon(Icons.label_outline, color: AppColors.accentLight),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body,
                      ),
                      Text(_filesLabel(t.itemCount), style: AppTypography.caption),
                    ],
                  ),
                ),
              ),
              AppIconButton(
                icon: Icons.edit_outlined,
                label: 'Renombrar ${t.name}',
                onPressed: () => _rename(t),
              ),
              AppIconButton(
                icon: Icons.delete_outline,
                label: 'Eliminar ${t.name}',
                onPressed: () => _delete(t),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hoja con un campo de nombre. [submit] lanza las excepciones de nombre de
/// etiqueta, que se muestran en la propia hoja sin cerrarla.
class _TagNameSheet extends StatefulWidget {
  const _TagNameSheet({
    required this.title,
    required this.confirmLabel,
    required this.submit,
    this.initial = '',
  });

  final String title;
  final String confirmLabel;
  final String initial;
  final Future<Object?> Function(String name) submit;

  @override
  State<_TagNameSheet> createState() => _TagNameSheetState();
}

class _TagNameSheetState extends State<_TagNameSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit(_name.text);
      if (mounted) Navigator.of(context).pop(true);
      return;
    } on Object catch (e) {
      if (mounted) {
        _error = tagErrorMessage(e) ?? 'No se pudo guardar la etiqueta';
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: widget.title),
        Semantics(
          textField: true,
          label: 'Nombre de la etiqueta',
          child: TextField(
            key: const ValueKey('tag-name-field'),
            controller: _name,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            style: AppTypography.body,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              hintText: 'Nombre de la etiqueta',
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
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const ValueKey('tag-name-error'),
                style: AppTypography.caption.copyWith(color: AppColors.danger),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        AppFilledButton(
          label: widget.confirmLabel,
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}
