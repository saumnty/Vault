import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../data/gallery/photo_saver.dart' show albumNameFor;
import '../../../data/models/vault_item_model.dart';
import '../viewer/folder_album_export.dart';

/// «Guardar en Fotos como álbum» (v2.2): confirmación con el aviso de copias
/// SIN cifrar, progreso «N de M» con pausar/cancelar y resumen final.
Future<void> showAlbumExportDialog(
  BuildContext context, {
  required FolderAlbumService service,
  required String folderId,
  required String folderName,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => AlbumExportDialog(
    service: service,
    folderId: folderId,
    folderName: folderName,
  ),
);

enum _Phase { loading, confirm, running, summary }

class AlbumExportDialog extends StatefulWidget {
  const AlbumExportDialog({
    super.key,
    required this.service,
    required this.folderId,
    required this.folderName,
  });

  final FolderAlbumService service;
  final String folderId;
  final String folderName;

  @override
  State<AlbumExportDialog> createState() => _AlbumExportDialogState();
}

class _AlbumExportDialogState extends State<AlbumExportDialog> {
  _Phase _phase = _Phase.loading;
  bool _includeSub = false;
  List<VaultItemModel> _items = const [];
  int _already = 0;
  FolderAlbumJob? _job;
  AlbumJobEnd? _end;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Cerrar el diálogo (p. ej. por bloqueo) cancela el lote: el archivo en
    // vuelo borra su temporal en `finally`.
    _job?.removeListener(_onJob);
    _job?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() => _phase = _Phase.loading);
    List<VaultItemModel> items;
    try {
      items = await widget.service.collect(
        widget.folderId,
        includeSubfolders: _includeSub,
      );
    } on Object {
      items = const [];
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _items = items;
      _already = widget.service.alreadySaved(widget.folderId, items);
      _phase = _Phase.confirm;
    });
  }

  Future<void> _start({required bool skipSaved}) async {
    final job = widget.service.createJob(
      folderId: widget.folderId,
      folderName: widget.folderName,
      items: _items,
      skipSaved: skipSaved,
    );
    job.addListener(_onJob);
    setState(() {
      _job = job;
      _phase = _Phase.running;
    });
    await _runJob(job);
  }

  Future<void> _runJob(FolderAlbumJob job) async {
    final end = await job.start();
    if (!mounted) return;
    if (end == AlbumJobEnd.locked) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _end = end;
      _phase = _Phase.summary;
    });
  }

  void _onJob() {
    if (mounted) setState(() {});
  }

  Future<void> _retry() async {
    final job = _job;
    if (job == null) return;
    setState(() {
      _end = null;
      _phase = _Phase.running;
    });
    await _runJob(job);
  }

  Future<void> _openSettings() => widget.service.exporter.openSettings();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase != _Phase.running,
      child: AlertDialog(
        title: Text(switch (_phase) {
          _Phase.running => 'Guardando en Fotos',
          _Phase.summary => 'Resumen',
          _ => 'Guardar en Fotos como álbum',
        }),
        content: SingleChildScrollView(child: _content()),
        actions: _actions(),
      ),
    );
  }

  Widget _content() {
    final album = albumNameFor(widget.folderName);
    switch (_phase) {
      case _Phase.loading:
        return const Center(
          heightFactor: 2,
          child: CircularProgressIndicator(key: ValueKey('album-loading')),
        );
      case _Phase.confirm:
        final remaining = _items.length - _already;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Se creará (o se usará, si ya existe) el álbum «$album» en '
              'Fotos con ${_items.length} foto(s) y video(s).\n\n'
              'Las copias quedarán SIN cifrar en tu galería: cualquier app '
              'con acceso a Fotos podrá verlas, y seguirán ahí aunque borres '
              'los archivos de Vault.',
            ),
            CheckboxListTile(
              key: const ValueKey('album-include-sub'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _includeSub,
              onChanged: (v) {
                _includeSub = v ?? false;
                _load();
              },
              title: const Text('Incluir subcarpetas'),
            ),
            if (_items.isEmpty)
              const Text(
                'Esta carpeta no tiene fotos ni videos.',
                key: ValueKey('album-empty'),
              )
            else if (_already > 0)
              Text(
                'Ya guardaste $_already de ${_items.length} en esta sesión. '
                'Si repites todo, esas copias se duplicarán en el álbum. '
                '(Si cerraste la app desde entonces, Kern ya no sabe qué '
                'guardaste: revisa el álbum antes de repetir.)',
                key: const ValueKey('album-already'),
              )
            else
              const Text(
                'Si cierras la app a mitad, lo ya guardado se queda en Fotos; '
                'al repetir, Kern no sabe cuáles eran.',
              ),
            if (_already > 0 && remaining == 0)
              const Text(
                'No falta ninguno.',
                key: ValueKey('album-none-left'),
              ),
          ],
        );
      case _Phase.running:
        final j = _job!;
        final total = j.runTotal;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                j.isPaused
                    ? 'En pausa: ${j.runDone} de $total'
                    : '${j.runDone} de $total',
                key: const ValueKey('album-progress'),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            LinearProgressIndicator(
              value: total == 0 ? null : j.runDone / total,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text('No cierres la app mientras se guarda.'),
          ],
        );
      case _Phase.summary:
        final j = _job!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_endText(_end!), key: const ValueKey('album-end')),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Guardados: ${j.savedCount} de ${j.total}\n'
              'Con error: ${j.failedCount}'
              '${j.pendingCount - j.failedCount > 0 ? '\nSin intentar: ${j.pendingCount - j.failedCount}' : ''}',
              key: const ValueKey('album-summary'),
            ),
          ],
        );
    }
  }

  String _endText(AlbumJobEnd end) => switch (end) {
    AlbumJobEnd.completed => 'Listo. Las copias están sin cifrar en Fotos.',
    AlbumJobEnd.cancelled =>
      'Cancelado. Lo ya guardado se queda en Fotos (sin cifrar).',
    AlbumJobEnd.permissionDenied =>
      'Sin permiso para guardar en Fotos. Puedes darlo en Ajustes del '
          'sistema.',
    AlbumJobEnd.noSpace =>
      'No hay espacio libre suficiente en el teléfono. Libera espacio y '
          'reintenta: solo se guardarán los que faltan.',
    AlbumJobEnd.albumUnsupported =>
      'iOS no permitió añadir al álbum ya creado con el permiso de solo '
          'agregar. Se detuvo para no crear álbumes repetidos. Da acceso '
          'completo a Fotos a Kern en Ajustes y reintenta.',
    AlbumJobEnd.locked => '',
  };

  List<Widget> _actions() {
    switch (_phase) {
      case _Phase.loading:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
        ];
      case _Phase.confirm:
        final remaining = _items.length - _already;
        return [
          TextButton(
            key: const ValueKey('album-cancel-confirm'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          if (_already > 0)
            TextButton(
              key: const ValueKey('album-repeat-all'),
              onPressed: () => _start(skipSaved: false),
              child: const Text('Repetir todo'),
            ),
          if (_items.isNotEmpty && remaining > 0)
            TextButton(
              key: const ValueKey('export-confirm'),
              onPressed: () => _start(skipSaved: true),
              child: Text(
                _already > 0
                    ? 'Guardar los $remaining que faltan'
                    : 'Guardar sin cifrar',
              ),
            ),
        ];
      case _Phase.running:
        final j = _job!;
        return [
          TextButton(
            key: const ValueKey('album-pause'),
            onPressed: j.isPaused ? j.resume : j.pause,
            child: Text(j.isPaused ? 'Reanudar' : 'Pausar'),
          ),
          TextButton(
            key: const ValueKey('album-cancel'),
            onPressed: j.cancel,
            child: const Text('Cancelar'),
          ),
        ];
      case _Phase.summary:
        final j = _job!;
        final denied = _end == AlbumJobEnd.permissionDenied;
        final canRetry =
            j.pendingCount > 0 &&
            _end != AlbumJobEnd.albumUnsupported &&
            _end != AlbumJobEnd.permissionDenied;
        return [
          if (denied)
            TextButton(
              key: const ValueKey('album-settings'),
              onPressed: _openSettings,
              child: const Text('Abrir ajustes'),
            ),
          if (denied)
            TextButton(
              key: const ValueKey('album-retry'),
              onPressed: _retry,
              child: const Text('Reintentar'),
            ),
          if (canRetry)
            TextButton(
              key: const ValueKey('album-retry'),
              onPressed: _retry,
              child: Text('Reintentar los ${j.pendingCount} que faltan'),
            ),
          TextButton(
            key: const ValueKey('album-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ];
    }
  }
}
