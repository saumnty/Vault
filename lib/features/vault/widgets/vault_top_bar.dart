import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_buttons.dart';
import 'breadcrumb_bar.dart';
import 'search_field.dart';
import 'selection_bar.dart';

/// Barra superior de la bóveda: título/búsqueda animados, migas de pan y, en
/// modo selección, la barra contextual. Respeta la zona segura superior.
class VaultTopBar extends StatelessWidget {
  const VaultTopBar({
    super.key,
    required this.title,
    required this.crumbs,
    required this.canGoBack,
    required this.onBack,
    required this.onCrumbTap,
    required this.searching,
    required this.searchController,
    required this.onSearchChanged,
    required this.onSearchToggle,
    required this.isListView,
    required this.onToggleView,
    required this.selectionCount,
    required this.onClearSelection,
    required this.onSelectAll,
    required this.onMove,
    required this.onOffline,
    required this.onDelete,
    this.trailing,
    this.onLock,
    this.onSettings,
    this.onFilters,
    this.filterCount = 0,
    this.onTags,
  });

  final String title;
  final List<Crumb> crumbs;
  final bool canGoBack;
  final VoidCallback onBack;
  final ValueChanged<Crumb> onCrumbTap;
  final bool searching;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchToggle;
  final bool isListView;
  final VoidCallback onToggleView;
  final int selectionCount;
  final VoidCallback onClearSelection;
  final VoidCallback onSelectAll;
  final VoidCallback onMove;
  /// `null` oculta la acción (bóveda sin nube, fase 8).
  final VoidCallback? onOffline;
  final VoidCallback onDelete;

  /// Acción extra antes de buscar (icono de sincronización).
  final Widget? trailing;

  /// "Bloquear ahora" (icono de candado); `null` lo oculta.
  final VoidCallback? onLock;

  /// Ajustes (icono de engranaje); `null` lo oculta.
  final VoidCallback? onSettings;

  /// Abre la hoja de filtros; `null` oculta el botón (sin etiquetas).
  final VoidCallback? onFilters;

  /// Filtros activos (indicador del botón).
  final int filterCount;

  /// Etiquetas de la selección; `null` oculta la acción.
  final VoidCallback? onTags;

  @override
  Widget build(BuildContext context) {
    final selecting = selectionCount > 0;
    return Material(
      color: selecting ? AppColors.surfaceHigh : AppColors.background,
      child: SafeArea(
        bottom: false,
        child: AnimatedSize(
          duration: AppMotion.medium,
          curve: AppMotion.standard,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: AppMotion.fast,
            switchInCurve: AppMotion.standard,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.25),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: selecting
                ? SelectionBar(
                    key: const ValueKey('selection'),
                    count: selectionCount,
                    onClose: onClearSelection,
                    onSelectAll: onSelectAll,
                    onMove: onMove,
                    onOffline: onOffline,
                    onDelete: onDelete,
                    onTags: onTags,
                  )
                : Column(
                    key: const ValueKey('normal'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _titleRow(),
                      if (crumbs.length > 1)
                        BreadcrumbBar(crumbs: crumbs, onTap: onCrumbTap),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _titleRow() {
    return SizedBox(
      height: AppSizes.toolbar,
      child: Row(
        children: [
          if (canGoBack)
            AppIconButton(
              icon: Icons.arrow_back,
              label: 'Volver',
              onPressed: onBack,
            )
          else
            const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: AnimatedSwitcher(
              duration: AppMotion.medium,
              switchInCurve: AppMotion.standard,
              child: searching
                  ? VaultSearchField(
                      key: const ValueKey('search'),
                      controller: searchController,
                      onChanged: onSearchChanged,
                      onClose: onSearchToggle,
                    )
                  : Align(
                      key: const ValueKey('title'),
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.title,
                        ),
                      ),
                    ),
            ),
          ),
          if (!searching) ...[
            ?trailing,
            if (onLock != null)
              AppIconButton(
                key: const ValueKey('lock-now'),
                icon: Icons.lock_outline_rounded,
                label: 'Bloquear ahora',
                onPressed: onLock,
              ),
            if (onSettings != null)
              AppIconButton(
                key: const ValueKey('open-settings'),
                icon: Icons.settings_outlined,
                label: 'Ajustes',
                onPressed: onSettings,
              ),
            if (onFilters != null)
              Badge(
                isLabelVisible: filterCount > 0,
                label: Text('$filterCount'),
                backgroundColor: AppColors.accent,
                textColor: AppColors.onAccent,
                child: AppIconButton(
                  key: const ValueKey('open-filters'),
                  icon: Icons.tune,
                  label: 'Filtros',
                  onPressed: onFilters,
                ),
              ),
            AppIconButton(
              icon: Icons.search,
              label: 'Buscar',
              onPressed: onSearchToggle,
            ),
            AppIconButton(
              icon: isListView
                  ? Icons.grid_view_rounded
                  : Icons.view_list_rounded,
              label: isListView ? 'Ver como cuadrícula' : 'Ver como lista',
              onPressed: onToggleView,
            ),
          ],
          SizedBox(width: searching ? AppSpacing.lg : AppSpacing.xs),
        ],
      ),
    );
  }
}
