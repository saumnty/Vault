import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/tags/tag_repository.dart';
import 'filter_sheet.dart';

/// Fila de chips de los filtros activos (cada uno con X para quitarlo) y un
/// chip "Limpiar" cuando hay dos o más.
class ActiveFiltersBar extends StatelessWidget {
  const ActiveFiltersBar({
    super.key,
    required this.filter,
    required this.tagNames,
    required this.onChanged,
    required this.onClear,
  });

  final ItemFilter filter;

  /// id de etiqueta -> nombre.
  final Map<String, String> tagNames;
  final ValueChanged<ItemFilter> onChanged;
  final VoidCallback onClear;

  Widget _chip(String label, VoidCallback onRemove, {Key? key}) {
    return InputChip(
      key: key,
      label: Text(label),
      onDeleted: onRemove,
      deleteIcon: const Icon(Icons.close, size: AppSizes.iconMd),
      deleteButtonTooltipMessage: 'Quitar filtro $label',
      backgroundColor: AppColors.accentContainer,
      deleteIconColor: AppColors.accentLight,
      side: const BorderSide(color: AppColors.accentLight),
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.pillAll),
      labelStyle: AppTypography.label.copyWith(color: AppColors.accentLight),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = filter;
    final chips = <Widget>[
      if (f.kind != null)
        _chip(
          kindFilterLabel(f.kind!),
          () => onChanged(f.copyWith(kind: () => null)),
          key: const ValueKey('chip-kind'),
        ),
      for (final id in f.tagIds)
        _chip(
          tagNames[id] ?? 'Etiqueta',
          () => onChanged(f.copyWith(tagIds: {...f.tagIds}..remove(id))),
          key: ValueKey('chip-tag-$id'),
        ),
      if (f.from != null)
        _chip(
          'Desde ${formatFilterDate(f.from!)}',
          () => onChanged(f.copyWith(from: () => null)),
          key: const ValueKey('chip-from'),
        ),
      if (f.to != null)
        _chip(
          'Hasta ${formatFilterDate(f.to!)}',
          () => onChanged(f.copyWith(to: () => null)),
          key: const ValueKey('chip-to'),
        ),
    ];
    return Material(
      color: AppColors.background,
      child: SizedBox(
        height: AppSizes.minTouch + AppSpacing.sm,
        child: ListView(
          key: const ValueKey('active-filters'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          children: [
            for (final c in chips)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Center(child: c),
              ),
            if (activeFilterCount(f) >= 2)
              Center(
                child: ActionChip(
                  key: const ValueKey('chip-clear'),
                  label: const Text('Limpiar'),
                  avatar: const Icon(Icons.filter_alt_off_outlined),
                  onPressed: onClear,
                  backgroundColor: AppColors.surfaceHigh,
                  side: const BorderSide(color: AppColors.border),
                  shape: const RoundedRectangleBorder(
                    borderRadius: AppRadii.pillAll,
                  ),
                  labelStyle: AppTypography.label,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
