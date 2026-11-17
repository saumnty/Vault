import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/tags/tag_repository.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/blur_sheet.dart';

/// Nombre legible de un tipo de archivo (plural, para chips).
String kindFilterLabel(KindFilter k) => switch (k) {
  KindFilter.photo => 'Fotos',
  KindFilter.video => 'Videos',
  KindFilter.file => 'Archivos',
};

/// Fecha como "dd/mm/aaaa".
String formatFilterDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year.toString().padLeft(4, '0')}';
}

/// Cuántos filtros (sin contar el texto) hay activos: tipo, fechas y etiquetas.
int activeFilterCount(ItemFilter f) =>
    (f.kind != null ? 1 : 0) +
    (f.from != null ? 1 : 0) +
    (f.to != null ? 1 : 0) +
    f.tagIds.length;

/// Estilo común de los chips de filtro.
Widget filterChip({
  Key? key,
  required String label,
  required bool selected,
  required ValueChanged<bool> onSelected,
}) {
  return FilterChip(
    key: key,
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    onSelected: onSelected,
    backgroundColor: AppColors.surfaceHigh,
    selectedColor: AppColors.accentContainer,
    side: BorderSide(color: selected ? AppColors.accentLight : AppColors.border),
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.pillAll),
    labelStyle: AppTypography.label.copyWith(
      color: selected ? AppColors.accentLight : AppColors.textPrimary,
    ),
  );
}

/// Hoja "Filtros". Devuelve el filtro nuevo (conserva el texto de
/// [current]) o `null` si se cierra sin aplicar.
Future<ItemFilter?> showFilterSheet(
  BuildContext context, {
  required TagRepository tags,
  required ItemFilter current,
}) {
  return showBlurSheet<ItemFilter>(
    context,
    builder: (context) => FilterSheetContent(tags: tags, current: current),
  );
}

class FilterSheetContent extends StatefulWidget {
  const FilterSheetContent({
    super.key,
    required this.tags,
    required this.current,
  });

  final TagRepository tags;
  final ItemFilter current;

  @override
  State<FilterSheetContent> createState() => _FilterSheetContentState();
}

class _FilterSheetContentState extends State<FilterSheetContent> {
  late KindFilter? _kind = widget.current.kind;
  late final Set<String> _tagIds ={...widget.current.tagIds};
  late DateTime? _from = widget.current.from;
  late DateTime? _to = widget.current.to;
  List<TagModel>? _tags;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    List<TagModel> list;
    try {
      list = await widget.tags.list();
    } on Object {
      list = const [];
    }
    if (mounted) setState(() => _tags = list);
  }

  Future<void> _pick({required bool from}) async {
    final now = DateTime.now();
    final initial = (from ? _from : _to) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: from ? 'Desde' : 'Hasta',
      cancelText: 'Cancelar',
      confirmText: 'Aceptar',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (from) {
        _from = picked;
        if (_to != null && _to!.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
        if (_from != null && _from!.isAfter(picked)) _from = picked;
      }
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      widget.current.copyWith(
        kind: () => _kind,
        tagIds: _tagIds,
        from: () => _from,
        to: () => _to,
      ),
    );
  }

  void _clear() {
    Navigator.of(context).pop(
      widget.current.copyWith(
        kind: () => null,
        tagIds: <String>{},
        from: () => null,
        to: () => null,
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Semantics(
      header: true,
      child: Text(
        title,
        style: AppTypography.label.copyWith(color: AppColors.accentLight),
      ),
    ),
  );

  Widget _dateField({
    required Key key,
    required String label,
    required DateTime? value,
    required VoidCallback onPick,
    required VoidCallback onRemove,
  }) {
    return Expanded(
      child: Semantics(
        button: true,
        label: value == null
            ? '$label: sin definir'
            : '$label: ${formatFilterDate(value)}',
        excludeSemantics: true,
        onTap: onPick,
        child: InkWell(
          key: key,
          borderRadius: AppRadii.mdAll,
          onTap: onPick,
          child: Container(
            constraints: const BoxConstraints(minHeight: AppSizes.minTouch),
            padding: const EdgeInsets.only(left: AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: AppRadii.mdAll,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.event_outlined,
                  size: AppSizes.iconMd,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: AppTypography.caption),
                      Text(
                        value == null ? 'Sin definir' : formatFilterDate(value),
                        style: AppTypography.body,
                      ),
                    ],
                  ),
                ),
                if (value != null)
                  AppIconButton(
                    icon: Icons.close,
                    label: 'Quitar fecha $label',
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader(
          title: 'Filtros',
          message: 'Los resultados incluyen toda la bóveda, no solo esta carpeta.',
        ),
        _section('Tipo'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            filterChip(
              key: const ValueKey('kind-all'),
              label: 'Todo',
              selected: _kind == null,
              onSelected: (_) => setState(() => _kind = null),
            ),
            for (final k in KindFilter.values)
              filterChip(
                key: ValueKey('kind-${k.name}'),
                label: kindFilterLabel(k),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _section('Etiquetas'),
        if (tags == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (tags.isEmpty)
          const Text(
            'Aún no tienes etiquetas',
            key: ValueKey('filter-no-tags'),
            style: AppTypography.bodySecondary,
          )
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final t in tags)
                filterChip(
                  key: ValueKey('tag-${t.id}'),
                  label: t.name,
                  selected: _tagIds.contains(t.id),
                  onSelected: (on) => setState(() {
                    on ? _tagIds.add(t.id) : _tagIds.remove(t.id);
                  }),
                ),
            ],
          ),
        const SizedBox(height: AppSpacing.lg),
        _section('Fecha de importación'),
        Row(
          children: [
            _dateField(
              key: const ValueKey('date-from'),
              label: 'Desde',
              value: _from,
              onPick: () => _pick(from: true),
              onRemove: () => setState(() => _from = null),
            ),
            const SizedBox(width: AppSpacing.sm),
            _dateField(
              key: const ValueKey('date-to'),
              label: 'Hasta',
              value: _to,
              onPick: () => _pick(from: false),
              onRemove: () => setState(() => _to = null),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        AppFilledButton(
          label: 'Aplicar',
          icon: Icons.check,
          onPressed: _apply,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(label: 'Limpiar', onPressed: _clear),
      ],
    );
  }
}
