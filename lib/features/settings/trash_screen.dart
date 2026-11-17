import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/trash/trash_repository.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/choice_sheet.dart';
import '../vault/services/trash_service.dart';

/// Ajustes > Papelera: lo que se borró de la bóveda, restaurable durante
/// [kTrashRetentionDays] días. Pasado ese plazo se elimina solo (al
/// desbloquear), también de Google Drive.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.service});

  final TrashService service;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashEntry>? _entries;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<TrashEntry>? list;
    try {
      list = await widget.service.list();
    } on Object {
      list = const [];
    }
    if (mounted) setState(() => _entries = list);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _restore(TrashEntry e) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await widget.service.restore(e.id);
      _snack(ok ? 'Restaurado: ${e.name}' : 'Ya no estaba en la Papelera');
    } on Object {
      _snack('No se pudo restaurar');
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _deleteForever(TrashEntry e) async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Eliminar definitivamente?',
      message:
          '"${e.name}" se eliminará de este teléfono y de tu Google Drive. '
          'Esta acción NO se puede deshacer.',
      confirmLabel: 'Eliminar definitivamente',
      destructive: true,
      icon: Icons.delete_forever_outlined,
    );
    if (!ok || !mounted) return;
    await _run(() => widget.service.deleteForever([e.id]), 'Eliminado');
  }

  Future<void> _empty() async {
    final entries = _entries ?? const [];
    if (entries.isEmpty) return;
    final ok = await showConfirmSheet(
      context,
      title: '¿Vaciar la Papelera?',
      message:
          'Se eliminarán definitivamente ${entries.length} elemento(s) de '
          'este teléfono y de tu Google Drive. Esta acción NO se puede '
          'deshacer.',
      confirmLabel: 'Vaciar Papelera',
      destructive: true,
      icon: Icons.delete_forever_outlined,
    );
    if (!ok || !mounted) return;
    await _run(widget.service.emptyAll, 'Papelera vaciada');
  }

  Future<void> _run(Future<int> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      _snack(done);
    } on Object {
      _snack('No se pudo completar');
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  String _subtitle(TrashEntry e) {
    final left = widget.service.daysLeft(e);
    final what = e.isFolder
        ? '${e.itemCount} archivo(s) · ${formatBytes(e.bytes)}'
        : formatBytes(e.bytes);
    final when = left <= 0
        ? 'Se eliminará en breve'
        : (left == 1 ? 'Queda 1 día' : 'Quedan $left días');
    return '$what · $when';
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
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
                      child: const Text('Papelera', style: AppTypography.title),
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
                  child: entries == null
                      ? const Center(child: CircularProgressIndicator())
                      : _body(entries),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(List<TrashEntry> entries) {
    return Padding(
      padding: AppSpacing.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Lo que borras queda aquí $kTrashRetentionDays días y puedes '
            'restaurarlo. Después se elimina solo, también de tu Google Drive.',
            style: AppTypography.bodySecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'La Papelera está vacía',
                      key: ValueKey('trash-empty'),
                      style: AppTypography.bodySecondary,
                    ),
                  )
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _row(entries[i]),
                  ),
          ),
          if (entries.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            AppFilledButton(
              label: 'Vaciar Papelera',
              icon: Icons.delete_forever_outlined,
              destructive: true,
              onPressed: _busy ? null : _empty,
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(TrashEntry e) {
    return Semantics(
      container: true,
      label: '${e.isFolder ? 'Carpeta' : 'Archivo'} ${e.name}. ${_subtitle(e)}',
      child: DecoratedBox(
        key: ValueKey('trash-${e.id}'),
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
              Icon(
                e.isFolder
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
                color: AppColors.accentLight,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body,
                      ),
                      Text(_subtitle(e), style: AppTypography.caption),
                    ],
                  ),
                ),
              ),
              AppIconButton(
                icon: Icons.restore_from_trash_outlined,
                label: 'Restaurar ${e.name}',
                onPressed: _busy ? null : () => _restore(e),
              ),
              AppIconButton(
                icon: Icons.delete_forever_outlined,
                label: 'Eliminar definitivamente ${e.name}',
                onPressed: _busy ? null : () => _deleteForever(e),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
