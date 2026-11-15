import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/cloud/cloud_storage.dart';
import '../../data/sync/sync_queue_repository.dart';
import '../../data/sync/sync_service.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';

/// Hoja "Sincronización" (mínimo de F5; el ajuste definitivo irá en F8).
Future<void> showSyncSheet(BuildContext context, SyncService sync) {
  return showBlurSheet<void>(
    context,
    builder: (context) => SyncSheetContent(sync: sync),
  );
}

String _phaseText(SyncSummary s) => switch (s.phase) {
  SyncPhase.running => 'Sincronizando…',
  SyncPhase.offline => 'Sin conexión. Se reanudará al volver la red.',
  SyncPhase.waitingWifi => 'Esperando Wi-Fi (solo Wi-Fi activado).',
  SyncPhase.needsSignIn => 'Inicia sesión con Google para sincronizar.',
  SyncPhase.quotaFull => 'Tu Google Drive no tiene espacio.',
  SyncPhase.idle =>
    s.accountEmail == null
        ? 'Conecta tu cuenta de Google para respaldar tu bóveda cifrada.'
        : (s.counts.total == 0 ? 'Todo está al día.' : 'En cola.'),
};

String _kindLabel(SyncJobKind k) => switch (k) {
  SyncJobKind.file => 'Archivo',
  SyncJobKind.thumb => 'Miniatura',
  SyncJobKind.dbSnapshot => 'Respaldo de la base de datos',
  SyncJobKind.recoveryBackup => 'Respaldo de recuperación',
};

class SyncSheetContent extends StatefulWidget {
  const SyncSheetContent({super.key, required this.sync});

  final SyncService sync;

  @override
  State<SyncSheetContent> createState() => _SyncSheetContentState();
}

class _SyncSheetContentState extends State<SyncSheetContent> {
  bool _wifiOnly = true;
  bool _signingIn = false;
  List<SyncJob> _errors = const [];
  int _lastErrorCount = -1;

  SyncService get _sync => widget.sync;

  @override
  void initState() {
    super.initState();
    _sync.getWifiOnly().then((v) {
      if (mounted) setState(() => _wifiOnly = v);
    });
    _sync.refreshCounts();
    if (_sync.summary.value.accountEmail != null) _sync.refreshQuota();
    _sync.summary.addListener(_onSummary);
    _onSummary();
  }

  @override
  void dispose() {
    _sync.summary.removeListener(_onSummary);
    super.dispose();
  }

  Future<void> _onSummary() async {
    final n = _sync.summary.value.counts.errors;
    if (n == _lastErrorCount) return;
    _lastErrorCount = n;
    final errors = await _sync.recentErrors();
    if (mounted) setState(() => _errors = errors);
  }

  Future<void> _signIn() async {
    setState(() => _signingIn = true);
    try {
      await _sync.signIn();
    } on CloudException {
      // El mensaje queda en summary.lastMessage y se muestra abajo.
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_sync.summary, _sync.quota]),
      builder: (context, _) {
        final s = _sync.summary.value;
        final signedIn = s.accountEmail != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: 'Sincronización', message: _phaseText(s)),
            _account(s),
            if (s.lastMessage != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  s.lastMessage!,
                  style: AppTypography.bodySecondary.copyWith(
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
            if (signedIn) ...[
              const SizedBox(height: AppSpacing.lg),
              _quota(),
              const SizedBox(height: AppSpacing.lg),
              _counts(s.counts),
            ],
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _wifiOnly,
              activeThumbColor: AppColors.accentLight,
              activeTrackColor: AppColors.accentContainer,
              title: const Text('Solo Wi-Fi', style: AppTypography.body),
              subtitle: const Text(
                'No usar datos móviles para subir',
                style: AppTypography.caption,
              ),
              onChanged: (v) {
                setState(() => _wifiOnly = v);
                _sync.setWifiOnly(v);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            AppFilledButton(
              label: 'Sincronizar ahora',
              icon: Icons.sync,
              busy: s.phase == SyncPhase.running,
              onPressed: signedIn ? () => _sync.run(manual: true) : null,
            ),
            if (_errors.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Semantics(
                header: true,
                child: const Text('Con error', style: AppTypography.label),
              ),
              for (final job in _errors) _errorRow(job),
            ],
          ],
        );
      },
    );
  }

  Widget _account(SyncSummary s) {
    if (s.accountEmail == null) {
      return AppFilledButton(
        label: 'Iniciar sesión con Google',
        icon: Icons.login,
        busy: _signingIn,
        onPressed: _signIn,
      );
    }
    return Row(
      children: [
        const Icon(Icons.account_circle_outlined, color: AppColors.accentLight),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Semantics(
            label: 'Cuenta de Google: ${s.accountEmail}',
            excludeSemantics: true,
            child: Text(
              s.accountEmail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.body,
            ),
          ),
        ),
        AppTextButton(label: 'Cerrar sesión', onPressed: () => _sync.signOut()),
      ],
    );
  }

  Widget _quota() {
    final q = _sync.quota.value;
    if (q == null) {
      return const Text(
        'Espacio de Drive: consultando…',
        style: AppTypography.bodySecondary,
      );
    }
    final text = q.limitBytes == null
        ? '${formatBytes(q.usedBytes)} usados en Drive'
        : '${formatBytes(q.usedBytes)} de ${formatBytes(q.limitBytes!)} usados';
    return Semantics(
      label: 'Espacio de Drive: $text',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: AppTypography.bodySecondary),
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: AppRadii.pillAll,
              child: LinearProgressIndicator(
                value: q.fraction ?? 0,
                minHeight: AppSizes.progressBarHeight,
                color: (q.fraction ?? 0) > 0.9
                    ? AppColors.danger
                    : AppColors.accent,
                backgroundColor: AppColors.surfaceHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _counts(SyncCounts c) {
    Widget cell(String label, int n, Color color) => Expanded(
      child: Semantics(
        label: '$label: $n',
        excludeSemantics: true,
        child: Column(
          children: [
            Text('$n', style: AppTypography.titleSmall.copyWith(color: color)),
            Text(label, style: AppTypography.caption),
          ],
        ),
      ),
    );
    return Row(
      children: [
        cell('Pendientes', c.pending, AppColors.warning),
        cell('Subiendo', c.uploading, AppColors.accentLight),
        cell(
          'Con error',
          c.errors,
          c.errors > 0 ? AppColors.danger : AppColors.textPrimary,
        ),
      ],
    );
  }

  Widget _errorRow(SyncJob job) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_kindLabel(job.kind), style: AppTypography.body),
                Text(
                  job.lastError ?? 'Error desconocido',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          AppTextButton(
            label: 'Reintentar',
            onPressed: () => _sync.retryErrors(jobId: job.id),
          ),
        ],
      ),
    );
  }
}
