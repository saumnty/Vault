import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/gallery/gallery_import_service.dart';
import '../../data/gallery/import_queue_repository.dart';
import '../../data/gallery/import_queue_service.dart';
import '../../shared/format.dart';
import '../../shared/vault_ui_mode.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';
import '../../shared/widgets/choice_sheet.dart';
import 'import_progress_sheet.dart' show stageLabel;

// --------------------------------------------------------------- aviso

/// Aviso en la cuadrícula mientras hay un lote sin cerrar (en marcha, en
/// pausa o con el resumen pendiente). Tocarlo abre la hoja de la cola.
class ImportQueueBanner extends StatelessWidget {
  const ImportQueueBanner({
    super.key,
    required this.status,
    required this.onTap,
  });

  final ValueListenable<ImportQueueStatus> status;
  final VoidCallback onTap;

  static String? textFor(ImportQueueStatus st) {
    if (!st.hasBatch) return null;
    final c = st.counts;
    return switch (st.state!) {
      ImportBatchState.running =>
        'Importando: ${c.finished} de ${c.total}',
      ImportBatchState.paused =>
        st.pauseReason == ImportPauseReason.noSpace
            ? 'Importación en pausa (sin espacio): ${c.finished} de ${c.total}'
            : 'Importación en pausa: ${c.finished} de ${c.total}',
      ImportBatchState.finished => 'Importación terminada: ver resumen',
      ImportBatchState.cancelled => 'Importación cancelada: ver resumen',
      ImportBatchState.preparing => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ImportQueueStatus>(
      valueListenable: status,
      builder: (context, st, _) {
        final text = textFor(st);
        if (text == null) return const SizedBox.shrink();
        return Semantics(
          button: true,
          liveRegion: true,
          label: '$text. Ver',
          excludeSemantics: true,
          child: Material(
            color: AppColors.surfaceHigh,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppSizes.minTouch),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.photo_library_outlined,
                        color: AppColors.accentLight,
                        size: 20,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(text, style: AppTypography.bodySecondary),
                      ),
                      Text(
                        'Ver',
                        style: AppTypography.label.copyWith(
                          color: AppColors.accentLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// --------------------------------------------------------------- destino

enum ImportDestinationKind { newFolder, existingFolder, currentFolder }

/// Dónde se guarda un álbum importado (D86).
class ImportDestination {
  const ImportDestination(this.kind, {this.folderName});
  final ImportDestinationKind kind;

  /// Nombre de la carpeta a crear ([ImportDestinationKind.newFolder]).
  final String? folderName;
}

/// Nombre libre para una carpeta nueva junto a [taken] (sin distinguir
/// mayúsculas): «Viaje», «Viaje (2)», «Viaje (3)»…
String freeFolderName(String base, Iterable<String> taken) {
  final lower = {for (final t in taken) t.toLowerCase()};
  if (!lower.contains(base.toLowerCase())) return base;
  for (var i = 2; ; i++) {
    final c = '$base ($i)';
    if (!lower.contains(c.toLowerCase())) return c;
  }
}

/// Por defecto: una carpeta con el nombre del álbum. Si ya hay una con ese
/// nombre aquí, se pregunta: usarla (lo que ya esté no se duplica), crear
/// «Nombre (2)» o la carpeta actual. `null` si se cancela.
Future<ImportDestination?> showAlbumDestinationSheet(
  BuildContext context, {
  required String albumName,
  required String currentFolderName,
  required List<String> siblingNames,
}) {
  final exists = siblingNames.any(
    (n) => n.toLowerCase() == albumName.toLowerCase(),
  );
  final fresh = freeFolderName(albumName, siblingNames);
  final options = <ChoiceOption<ImportDestination>>[
    if (exists)
      ChoiceOption(
        value: const ImportDestination(ImportDestinationKind.existingFolder),
        label: 'Usar la carpeta «$albumName» que ya existe',
        detail: 'Lo que ya esté en la bóveda no se duplica.',
      ),
    ChoiceOption(
      value: ImportDestination(
        ImportDestinationKind.newFolder,
        folderName: fresh,
      ),
      label: 'Carpeta nueva «$fresh»',
      detail: exists ? null : 'Recomendado',
    ),
    ChoiceOption(
      value: const ImportDestination(ImportDestinationKind.currentFolder),
      label: 'Carpeta actual «$currentFolderName»',
    ),
  ];
  return showChoiceSheet<ImportDestination>(
    context,
    title: '¿Dónde guardar el álbum?',
    message: exists
        ? 'Ya hay una carpeta «$albumName» aquí.'
        : 'Se creará una carpeta con el nombre del álbum.',
    options: options,
    selected: null,
  );
}

// --------------------------------------------------------------- antes

/// Resumen antes de empezar: tamaño estimado, espacio libre (con aviso si no
/// alcanza) y aviso de datos móviles para iCloud. `true` = empezar.
Future<bool> showImportPreflightSheet(
  BuildContext context, {
  required ImportPreflight preflight,
}) async {
  final r = await showBlurSheet<bool>(
    context,
    builder: (context) => ImportPreflightContent(preflight: preflight),
  );
  return r ?? false;
}

class ImportPreflightContent extends StatelessWidget {
  const ImportPreflightContent({super.key, required this.preflight});
  final ImportPreflight preflight;

  @override
  Widget build(BuildContext context) {
    final p = preflight;
    if (p.total == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(
            title: 'Nada que importar',
            message: 'No quedó ningún elemento seleccionado.',
          ),
          AppTextButton(
            label: 'Cerrar',
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      );
    }
    final n = p.total == 1 ? '1 elemento' : '${p.total} elementos';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: 'Importar $n',
          message:
              'Ocupará ≈ ${formatBytes(p.estimatedBytes)} en el teléfono'
              '${p.freeBytes == null ? '' : ' (libres: ${formatBytes(p.freeBytes!)})'}.'
              ' Se importan de uno en uno; puedes pausar, y si la app se '
              'cierra o se bloquea, sigue donde iba al volver a abrirla.',
        ),
        if (p.spaceInsufficient)
          _Warning(
            icon: Icons.sd_card_alert_outlined,
            text:
                'Puede que no haya espacio suficiente: hacen falta '
                '≈ ${formatBytes(p.neededBytes)} y hay '
                '${formatBytes(p.freeBytes!)} libres. Si se llena, la '
                'importación se pondrá en pausa.',
          ),
        if (p.cellular)
          const _Warning(
            icon: Icons.signal_cellular_alt,
            text:
                'Estás con datos móviles: las fotos que estén solo en iCloud '
                'se descargarán por datos móviles.',
          ),
        const SizedBox(height: AppSpacing.md),
        AppFilledButton(
          label: p.spaceInsufficient ? 'Importar de todos modos' : 'Empezar',
          icon: Icons.lock_outline,
          onPressed: () => Navigator.of(context).pop(true),
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

class _Warning extends StatelessWidget {
  const _Warning({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.warning, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: AppTypography.bodySecondary)),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- durante

/// Hoja de progreso de la cola: «N de M», etapa, tiempo estimado, Pausar /
/// Reanudar / Cancelar y, al terminar, el resumen. Se cierra con «Listo»
/// (borra el lote) o, en pausa, con «Cerrar» (el lote se queda).
Future<void> showImportQueueSheet(
  BuildContext context, {
  required ImportQueueService service,
  bool deleteOriginalsEnabled = false,
}) {
  return showBlurSheet<void>(
    context,
    dismissible: false,
    builder: (context) => ImportQueueContent(
      service: service,
      deleteOriginalsEnabled: deleteOriginalsEnabled,
    ),
  );
}

String _remainingText(Duration d) {
  if (d.inMinutes >= 60) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return '≈ $h h ${m.toString().padLeft(2, '0')} min restantes';
  }
  if (d.inMinutes >= 1) return '≈ ${(d.inSeconds + 59) ~/ 60} min restantes';
  return 'Menos de un minuto';
}

class ImportQueueContent extends StatefulWidget {
  const ImportQueueContent({
    super.key,
    required this.service,
    this.deleteOriginalsEnabled = false,
  });

  final ImportQueueService service;
  final bool deleteOriginalsEnabled;

  @override
  State<ImportQueueContent> createState() => _ImportQueueContentState();
}

class _ImportQueueContentState extends State<ImportQueueContent> {
  List<ImportJob>? _errors;
  bool _busy = false;

  ImportQueueService get _s => widget.service;

  Future<void> _loadErrors() async {
    try {
      final e = await _s.errors();
      if (mounted) setState(() => _errors = e);
    } on Object {
      if (mounted) setState(() => _errors = const []);
    }
  }

  Future<void> _act(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } on Object {
      // la hoja refleja el estado publicado
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ImportQueueStatus>(
      valueListenable: _s.status,
      builder: (context, st, _) {
        final finished =
            !st.running &&
            (st.state == ImportBatchState.finished ||
                st.state == ImportBatchState.cancelled);
        if (finished && _errors == null) _loadErrors();
        return PopScope(
          canPop: !st.running,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: !st.hasBatch
                ? [
                    const SheetHeader(
                      title: 'Sin importación en curso',
                      message: 'No hay nada pendiente de importar.',
                    ),
                    AppTextButton(
                      label: 'Cerrar',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ]
                : finished
                ? _summary(st)
                : st.running || st.state == ImportBatchState.running
                ? _running(st)
                : _paused(st),
          ),
        );
      },
    );
  }

  List<Widget> _progressBar(ImportQueueStatus st) {
    final c = st.counts;
    final value = c.total == 0
        ? null
        : ((c.finished + (st.fraction ?? 0)) / c.total).clamp(0.0, 1.0);
    return [
      ClipRRect(
        borderRadius: AppRadii.pillAll,
        child: LinearProgressIndicator(
          value: value,
          minHeight: AppSizes.progressBarHeight,
          backgroundColor: AppColors.surfaceHighest,
        ),
      ),
    ];
  }

  List<Widget> _running(ImportQueueStatus st) {
    final c = st.counts;
    final n = (c.finished + 1).clamp(1, c.total == 0 ? 1 : c.total);
    final detail = StringBuffer();
    final stage = st.stage;
    if (stage != null) {
      detail.write(
        stage == ImportStage.downloading && st.cellular
            ? 'Descargando de iCloud por datos móviles'
            : stageLabel(stage),
      );
      if (stage == ImportStage.downloading && st.fraction != null) {
        detail.write(' ${(st.fraction! * 100).round()} %');
      }
      if (st.originalBytes != null) {
        detail.write(' · Original ${formatBytes(st.originalBytes!)}');
        if (st.compressedBytes != null) {
          detail.write(' → ${formatBytes(st.compressedBytes!)}');
        }
      }
    } else {
      detail.write('Preparando');
    }
    final extra = <String>[
      if (c.duplicate > 0) '${c.duplicate} ya estaban',
      if (c.error > 0) '${c.error} con error',
    ];
    final remaining = st.remaining;
    final title = 'Importando $n de ${c.total}';
    return [
      Semantics(
        liveRegion: true,
        label: '$title. $detail',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.title),
              const SizedBox(height: AppSpacing.sm),
              Text(detail.toString(), style: AppTypography.bodySecondary),
              if (remaining != null)
                Text(_remainingText(remaining), style: AppTypography.caption),
              if (extra.isNotEmpty)
                Text(extra.join(' · '), style: AppTypography.caption),
              if (st.lastError != null)
                Text(
                  'Último error: ${st.lastError!.message}',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              ..._progressBar(st),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Mantén Kern abierta: la pantalla no se apagará mientras '
                'importa. Si sales o se bloquea, seguirá al volver.',
                style: AppTypography.caption,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.xl),
      AppFilledButton(
        label: 'Pausar',
        icon: Icons.pause,
        onPressed: st.running ? _s.pause : null,
      ),
      const SizedBox(height: AppSpacing.sm),
      AppTextButton(
        label: 'Cancelar',
        onPressed: _busy ? null : () => _act(_s.cancel),
      ),
    ];
  }

  List<Widget> _paused(ImportQueueStatus st) {
    final c = st.counts;
    final noSpace = st.pauseReason == ImportPauseReason.noSpace;
    return [
      SheetHeader(
        title: 'Importación en pausa',
        message:
            '${c.finished} de ${c.total} procesados. '
            '${noSpace ? 'El teléfono se quedó sin espacio: libera espacio y reanuda. ' : ''}'
            'Lo que falta se importará al reanudar, sin duplicar nada.',
      ),
      ..._progressBar(st),
      const SizedBox(height: AppSpacing.lg),
      AppFilledButton(
        label: 'Reanudar',
        icon: Icons.play_arrow,
        busy: _busy,
        onPressed: _busy ? null : () => _act(_s.resume),
      ),
      const SizedBox(height: AppSpacing.sm),
      AppTextButton(
        label: 'Cancelar importación',
        onPressed: _busy ? null : () => _act(_s.cancel),
      ),
      AppTextButton(
        label: 'Cerrar',
        onPressed: () => Navigator.of(context).pop(),
      ),
    ];
  }

  List<Widget> _summary(ImportQueueStatus st) {
    final c = st.counts;
    final cancelled = st.state == ImportBatchState.cancelled;
    final title = cancelled
        ? 'Importación cancelada'
        : c.error == 0
        ? 'Importación completa'
        : 'Importación terminada con errores';
    final parts = <String>[
      '${c.done} importado(s)',
      '${c.duplicate} ya estaban',
      '${c.error} con error',
      if (c.remaining > 0) '${c.remaining} sin procesar',
    ];
    final errors = _errors ?? const <ImportJob>[];
    return [
      SheetHeader(title: title, message: parts.join(' · ')),
      if (errors.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: errors.length,
            itemBuilder: (context, i) {
              final e = errors[i];
              final who = e.name ?? 'Elemento ${e.seq + 1}';
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(
                  '$who: ${(e.error ?? ImportErrorCode.unknown).message}',
                  style: AppTypography.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
      if (c.done > 0 || c.duplicate > 0) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          VaultUiMode.cloudless
              ? 'Los originales siguen en tu galería.'
              : widget.deleteOriginalsEnabled
              ? 'Los originales siguen en tu galería. Cuando su copia esté '
                    'verificada en la nube, te ofreceremos borrarlos, siempre '
                    'con tu confirmación.'
              : 'Los originales siguen en tu galería; cuando estén en la nube '
                    'podrás borrarlos desde Ajustes.',
          style: AppTypography.bodySecondary,
        ),
      ],
      const SizedBox(height: AppSpacing.md),
      AppFilledButton(
        label: 'Listo',
        onPressed: () async {
          await _s.acknowledge();
          if (mounted) Navigator.of(context).pop();
        },
      ),
    ];
  }
}
