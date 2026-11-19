import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/cloud/cloud_storage.dart';
import '../../data/migration/account_migration_service.dart'
    show MigrationStatus;
import '../../data/sync/sync_queue_repository.dart';
import '../../data/sync/sync_service.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/blur_sheet.dart';
import '../../shared/widgets/cloud_privacy_note.dart';
import 'quota_bar.dart';
import 'sync_actions.dart';

/// Hoja "Sincronización" (mínimo de F5; el ajuste definitivo irá en F8).
///
/// D78: con [migrating] (cambio de cuenta sin terminar) «Iniciar sesión» y
/// «Cerrar sesión» llevan a su pantalla ([onOpenMigration]) en lugar de
/// cambiar la sesión por fuera; mismas guardas que Ajustes
/// (`sync_actions.dart`).
Future<void> showSyncSheet(
  BuildContext context,
  SyncService sync, {
  ValueListenable<MigrationStatus>? migration,
  ValueListenable<Object?>? rotationRecord,
  VoidCallback? onOpenMigration,
}) {
  return showBlurSheet<void>(
    context,
    builder: (context) => SyncSheetContent(
      sync: sync,
      migration: migration,
      rotationRecord: rotationRecord,
      onOpenMigration: onOpenMigration,
    ),
  );
}

/// D78: «Todo está al día» SOLO si de verdad lo está (sin pausa, sin cola y
/// sin archivos pendientes o sin comprobar en `vault_items`).
String syncPhaseText(SyncSummary s) {
  final pause = s.pauseReason;
  if (pause != null && s.phase != SyncPhase.running) {
    return 'En pausa: ${syncPauseText(pause)}.';
  }
  return switch (s.phase) {
    SyncPhase.running => 'Sincronizando…',
    SyncPhase.offline => 'Sin conexión. Se reanudará al volver la red.',
    SyncPhase.waitingWifi => 'Esperando Wi-Fi (solo Wi-Fi activado).',
    SyncPhase.needsSignIn => 'Inicia sesión con Google para sincronizar.',
    SyncPhase.quotaFull => 'Tu Google Drive no tiene espacio.',
    SyncPhase.idle =>
      s.accountEmail == null
          ? 'Conecta tu cuenta de Google para respaldar tu bóveda cifrada.'
          : s.upToDate
          ? 'Todo está al día.'
          : s.cloud.unverified > 0
          ? '${s.cloud.unverified} archivo(s) sin comprobar en esta cuenta.'
          : s.cloud.noCopy > 0
          ? '${s.cloud.noCopy} archivo(s) sin copia en ninguna parte.'
          : 'En cola.',
  };
}

String _kindLabel(SyncJobKind k) => switch (k) {
  SyncJobKind.file => 'Archivo',
  SyncJobKind.thumb => 'Miniatura',
  SyncJobKind.dbSnapshot => 'Respaldo de la base de datos',
  SyncJobKind.recoveryBackup => 'Respaldo de recuperación',
  SyncJobKind.deleteRemote => 'Eliminar de la nube',
};

class SyncSheetContent extends StatefulWidget {
  const SyncSheetContent({
    super.key,
    required this.sync,
    this.migration,
    this.rotationRecord,
    this.onOpenMigration,
  });

  final SyncService sync;

  /// D78: estado del cambio de cuenta (`null` = no disponible).
  final ValueListenable<MigrationStatus>? migration;

  /// D78: registro de la rotación de la llave (`null` = sin rotación).
  final ValueListenable<Object?>? rotationRecord;

  /// D78: abre la pantalla del cambio de cuenta (la hoja se cierra antes).
  final VoidCallback? onOpenMigration;

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

  /// D78: mensaje del último toque (resultado o motivo del bloqueo), visible
  /// en la propia hoja (una SnackBar quedaría debajo).
  String? _notice;
  bool _syncing = false;

  bool get _migrating => widget.migration?.value.active ?? false;
  bool get _rotating => widget.rotationRecord?.value != null;

  /// D78: durante un cambio de cuenta, la sesión se cambia SOLO desde su
  /// pantalla: se cierra la hoja y se abre.
  bool _redirectToMigration() {
    if (!accountBlockedByMigration(_sync, migrating: _migrating)) return false;
    final open = widget.onOpenMigration;
    if (open == null) {
      setState(
        () => _notice = accountActionBlockReason(_sync, migrating: true),
      );
      return true;
    }
    Navigator.of(context).maybePop();
    open();
    return true;
  }

  Future<void> _signIn() async {
    if (_redirectToMigration()) return;
    final reason = accountActionBlockReason(_sync, rotating: _rotating);
    if (reason != null) {
      setState(() => _notice = reason);
      return;
    }
    setState(() {
      _signingIn = true;
      _notice = null;
    });
    try {
      await _sync.signIn();
    } on SyncAccountActionBlockedException catch (e) {
      if (mounted) setState(() => _notice = e.message);
    } on CloudException {
      // El mensaje queda en summary.lastMessage y se muestra abajo.
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Future<void> _signOut() async {
    if (_redirectToMigration()) return;
    final reason = accountActionBlockReason(_sync, rotating: _rotating);
    if (reason != null) {
      setState(() => _notice = reason);
      return;
    }
    try {
      await _sync.signOut();
      if (mounted) setState(() => _notice = 'Sesión cerrada.');
    } on SyncAccountActionBlockedException catch (e) {
      if (mounted) setState(() => _notice = e.message);
    } on Object {
      if (mounted) setState(() => _notice = 'No se pudo cerrar la sesión.');
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _notice = null;
    });
    try {
      final (_, text) = await runManualSync(_sync);
      if (mounted) setState(() => _notice = text);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _sync.summary,
        _sync.quota,
        ?widget.migration,
        ?widget.rotationRecord,
      ]),
      builder: (context, _) {
        final s = _sync.summary.value;
        final signedIn = s.accountEmail != null;
        final running = s.phase == SyncPhase.running;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: 'Sincronización', message: syncPhaseText(s)),
            _account(s),
            if (_notice != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  _notice!,
                  key: const ValueKey('sync-sheet-notice'),
                  style: AppTypography.bodySecondary,
                ),
              ),
            ],
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
              QuotaBar(quota: _sync.quota.value),
              const SizedBox(height: AppSpacing.lg),
              _counts(s),
            ],
            const SizedBox(height: AppSpacing.lg),
            const CloudPrivacyNote(),
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
            // D78: siempre se puede tocar; el resultado se dice arriba. Con
            // una pasada en curso, «Detener» es la salida si se cuelga.
            if (running)
              AppTextButton(
                key: const ValueKey('sync-sheet-stop'),
                label: 'Detener la sincronización',
                onPressed: () {
                  _sync.stop();
                  setState(() => _notice = 'Sincronización detenida.');
                },
              )
            else
              AppFilledButton(
                key: const ValueKey('sync-sheet-sync-now'),
                label: 'Sincronizar ahora',
                icon: Icons.sync,
                busy: _syncing,
                onPressed: _syncNow,
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
        AppTextButton(
          key: const ValueKey('sync-sheet-sign-out'),
          label: 'Cerrar sesión',
          onPressed: _signOut,
        ),
      ],
    );
  }

  /// D78: pendientes y errores = cola ∪ archivos de `vault_items`.
  Widget _counts(SyncSummary s) {
    final c = SyncCounts(
      pending: s.pendingTotal,
      uploading: s.counts.uploading,
      errors: s.errorTotal,
    );
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
