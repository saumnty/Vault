import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';

/// Una migaja de pan. [id] `null` = raíz de la bóveda.
class Crumb {
  const Crumb({required this.id, required this.label});

  final String? id;
  final String label;
}

/// Ruta de carpetas: `Mi Bóveda > Viajes > 2025`. La última es la carpeta
/// actual (no pulsable). Se desplaza hasta mostrar siempre el final.
class BreadcrumbBar extends StatefulWidget {
  const BreadcrumbBar({super.key, required this.crumbs, required this.onTap});

  final List<Crumb> crumbs;
  final ValueChanged<Crumb> onTap;

  @override
  State<BreadcrumbBar> createState() => _BreadcrumbBarState();
}

class _BreadcrumbBarState extends State<BreadcrumbBar> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(BreadcrumbBar old) {
    super.didUpdateWidget(old);
    _scrollToEnd();
  }

  @override
  void initState() {
    super.initState();
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = widget.crumbs;
    return Semantics(
      container: true,
      label: 'Ruta: ${crumbs.map((c) => c.label).join(', ')}',
      child: SizedBox(
        height: AppSizes.minTouch,
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: AppSpacing.pageHorizontal,
          itemCount: crumbs.length,
          separatorBuilder: (context, i) => const ExcludeSemantics(
            child: Icon(
              Icons.chevron_right,
              size: AppSizes.iconMd,
              color: AppColors.textSecondary,
            ),
          ),
          itemBuilder: (context, i) {
            final crumb = crumbs[i];
            final isLast = i == crumbs.length - 1;
            return _CrumbChip(
              crumb: crumb,
              isCurrent: isLast,
              onTap: () => widget.onTap(crumb),
            );
          },
        ),
      ),
    );
  }
}

class _CrumbChip extends StatelessWidget {
  const _CrumbChip({
    required this.crumb,
    required this.isCurrent,
    required this.onTap,
  });

  final Crumb crumb;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      crumb.label,
      maxLines: 1,
      style: isCurrent
          ? AppTypography.label
          : AppTypography.bodySecondary.copyWith(color: AppColors.accentLight),
    );
    if (isCurrent) {
      return Semantics(
        label: 'Carpeta actual: ${crumb.label}',
        excludeSemantics: true,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: text,
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Ir a ${crumb.label}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: AppRadii.smAll,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: AppSizes.minTouch),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: text,
            ),
          ),
        ),
      ),
    );
  }
}
