import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/tags/tag_repository.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/blur_sheet.dart';
import '../models/browser_entry.dart';
import '../vault_browser_controller.dart';

/// Hoja "Etiquetas" de la selección múltiple: marca o desmarca etiquetas de
/// los ARCHIVOS seleccionados (las carpetas se ignoran) y permite crear una.
Future<void> showTagsSheet(
  BuildContext context, {
  required VaultBrowserController controller,
  required List<BrowserEntry> targets,
}) {
  return showBlurSheet<void>(
    context,
    builder: (context) =>
        TagsSheetContent(controller: controller, targets: targets),
  );
}

class TagsSheetContent extends StatefulWidget {
  const TagsSheetContent({
    super.key,
    required this.controller,
    required this.targets,
  });

  final VaultBrowserController controller;
  final List<BrowserEntry> targets;

  @override
  State<TagsSheetContent> createState() => _TagsSheetContentState();
}

class _TagsSheetContentState extends State<TagsSheetContent> {
  final TextEditingController _name = TextEditingController();
  List<TagModel>? _tags;

  /// Etiquetas que tienen TODOS los archivos seleccionados.
  final Set<String> _checked = {};
  String? _error;
  bool _busy = false;

  TagRepository? get _repo => widget.controller.services.tags;

  List<FileEntry> get _files => widget.targets.whereType<FileEntry>().toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<TagModel> list = const [];
    final checked = <String>{};
    try {
      list = await _repo?.list() ?? const [];
      final byItem = await widget.controller.tagsOf(_files);
      for (final t in list) {
        if (_files.isNotEmpty &&
            _files.every(
              (f) => (byItem[f.item.id] ?? const []).any((x) => x.id == t.id),
            )) {
          checked.add(t.id);
        }
      }
    } on Object {
      // sin etiquetas
    }
    if (!mounted) return;
    setState(() {
      _tags = list;
      _checked
        ..clear()
        ..addAll(checked);
    });
  }

  Future<void> _toggle(TagModel t) async {
    if (_busy) return;
    final on = !_checked.contains(t.id);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.setTag(_files, t.id, on: on);
      if (mounted) {
        setState(() => on ? _checked.add(t.id) : _checked.remove(t.id));
      }
    } on Object {
      if (mounted) setState(() => _error = 'No se pudo cambiar la etiqueta');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _create() async {
    final repo = _repo;
    if (repo == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      TagModel tag;
      try {
        tag = await repo.create(_name.text);
      } on DuplicateTagException catch (e) {
        // Ya existe: se asigna la existente.
        tag = e.existing;
      }
      await widget.controller.setTag(_files, tag.id, on: true);
      _name.clear();
      await _load();
    } on InvalidTagNameException {
      if (mounted) {
        setState(
          () => _error = _name.text.trim().isEmpty
              ? 'Escribe un nombre para la etiqueta'
              : 'El nombre es demasiado largo (máximo $kTagNameMax caracteres)',
        );
      }
    } on Object {
      if (mounted) setState(() => _error = 'No se pudo crear la etiqueta');
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _row(TagModel t) {
    final checked = _checked.contains(t.id);
    return Semantics(
      container: true,
      checked: checked,
      label: 'Etiqueta ${t.name}',
      excludeSemantics: true,
      onTap: () => _toggle(t),
      child: InkWell(
        key: ValueKey('tag-row-${t.id}'),
        borderRadius: AppRadii.mdAll,
        onTap: () => _toggle(t),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.minTouch),
          child: Row(
            children: [
              IgnorePointer(
                child: Checkbox(
                  value: checked,
                  onChanged: (_) {},
                  activeColor: AppColors.accent,
                  checkColor: AppColors.onAccent,
                  side: const BorderSide(color: AppColors.textSecondary),
                ),
              ),
              Expanded(
                child: Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    final n = _files.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: 'Etiquetas',
          message: n == 1
              ? 'Se aplican a 1 archivo.'
              : 'Se aplican a $n archivos. Una casilla marcada significa que '
                    'todos la tienen.',
        ),
        if (tags == null)
          const Padding(
            padding: AppSpacing.page,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (tags.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              'Aún no tienes etiquetas. Crea la primera abajo.',
              key: ValueKey('tags-sheet-empty'),
              style: AppTypography.bodySecondary,
            ),
          )
        else
          for (final t in tags) _row(t),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Semantics(
                textField: true,
                label: 'Nueva etiqueta',
                child: TextField(
                  key: const ValueKey('new-tag-field'),
                  controller: _name,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  maxLength: kTagNameMax + 10,
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                  style: AppTypography.body,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _create(),
                  decoration: const InputDecoration(
                    hintText: 'Nueva etiqueta',
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
            ),
            const SizedBox(width: AppSpacing.sm),
            AppFilledButton(
              label: 'Crear',
              icon: Icons.add,
              onPressed: _busy ? null : _create,
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const ValueKey('tags-sheet-error'),
                style: AppTypography.caption.copyWith(color: AppColors.danger),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        AppTextButton(
          label: 'Listo',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
