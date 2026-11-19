import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/migration/account_migration_service.dart'
    show MigrationStatus;
import '../../data/sync/cloud_verification_service.dart'
    show CloudVerificationProgress;
import '../../data/sync/sync_service.dart';
import '../../shared/vault_ui_mode.dart';
import '../../shared/widgets/app_buttons.dart';

/// D78 (parte B, §B.3): qué aviso de la nube toca mostrar en la cuadrícula.
enum CloudBannerKind {
  /// Cambio de cuenta sin terminar (abre su pantalla).
  migration,

  /// «Verificar copia en la nube» en curso.
  verifying,

  /// Archivos sin copia en ninguna parte (peligro).
  noCopy,

  /// Sin cuenta de Google y con archivos.
  noAccount,

  /// Archivos «en la nube» sin comprobar en la cuenta actual.
  unverified,

  /// Archivos solo en este teléfono (pendientes de subir).
  localOnly,

  /// Sincronización en pausa por otro motivo.
  paused,
}

@immutable
class CloudBannerState {
  const CloudBannerState(this.kind, this.title, {this.detail, this.action});
  final CloudBannerKind kind;
  final String title;
  final String? detail;

  /// Texto del botón (`null` = sin botón).
  final String? action;
}

/// Decide el aviso (uno solo) por prioridad. `null` = nada que avisar. La
/// rotación de la llave tiene su propio aviso ([rotating] ⇒ `null`, salvo un
/// cambio de cuenta, que siempre se muestra). Nunca lleva correos.
CloudBannerState? cloudBannerFor({
  required SyncSummary summary,
  MigrationStatus? migration,
  bool rotating = false,
  CloudVerificationProgress? verification,
}) {
  final c = summary.cloud;
  if (migration != null && migration.active) {
    return const CloudBannerState(
      CloudBannerKind.migration,
      'Cambio de cuenta sin terminar',
      detail:
          'La sincronización está en pausa: tus archivos no tienen copia '
          'comprobada en la nube.',
      action: 'Ver',
    );
  }
  if (rotating) return null;
  if (summary.pauseReason == SyncPauseReason.verification ||
      verification != null) {
    final p = verification;
    return CloudBannerState(
      CloudBannerKind.verifying,
      p == null || p.total == 0
          ? 'Comprobando tu copia en la nube…'
          : 'Comprobando tu copia en la nube… ${p.done}/${p.total}',
    );
  }
  if (c.noCopy > 0) {
    return CloudBannerState(
      CloudBannerKind.noCopy,
      '${c.noCopy} archivo(s) sin copia en ninguna parte',
      detail:
          'No están en tu cuenta de Google ni en este teléfono. No se '
          'borraron de la lista.',
      action: summary.accountEmail == null ? null : 'Verificar copia',
    );
  }
  if (summary.accountEmail == null) {
    if (c.total == 0) return null;
    return const CloudBannerState(
      CloudBannerKind.noAccount,
      'Sin cuenta de Google: tu bóveda no se respalda',
      action: 'Iniciar sesión',
    );
  }
  if (c.unverified > 0) {
    return CloudBannerState(
      CloudBannerKind.unverified,
      'Tus archivos no tienen copia en la nube',
      detail:
          '${c.unverified} archivo(s) sin comprobar en esta cuenta de '
          'Google.',
      action: 'Verificar copia',
    );
  }
  final pause = summary.pauseReason;
  if (c.localOnly > 0) {
    final why = pause != null
        ? 'En pausa: ${syncPauseText(pause)}.'
        : switch (summary.phase) {
            SyncPhase.offline => 'Sin conexión: se subirán al volver la red.',
            SyncPhase.waitingWifi => 'Esperando Wi-Fi para subirlos.',
            SyncPhase.quotaFull => 'Tu Google Drive no tiene espacio.',
            SyncPhase.needsSignIn => 'Inicia sesión de nuevo para subirlos.',
            _ => 'Subiéndolos a tu cuenta…',
          };
    return CloudBannerState(
      CloudBannerKind.localOnly,
      'Tus archivos no tienen copia en la nube',
      detail: '${c.localOnly} archivo(s) solo están en este teléfono. $why',
      action: 'Ver',
    );
  }
  if (pause != null) {
    return CloudBannerState(
      CloudBannerKind.paused,
      'Sincronización en pausa: ${syncPauseText(pause)}',
    );
  }
  return null;
}

/// Aviso de la nube en la cuadrícula (junto al de la rotación). Nada en la
/// bóveda adicional ([VaultUiMode.cloudless]).
class CloudStatusBanner extends StatelessWidget {
  const CloudStatusBanner({
    super.key,
    required this.sync,
    this.migration,
    this.rotationRecord,
    this.verification,
    this.onOpenMigration,
    this.onVerify,
    this.onOpenSync,
  });

  final SyncService sync;
  final ValueListenable<MigrationStatus>? migration;
  final ValueListenable<Object?>? rotationRecord;
  final ValueListenable<CloudVerificationProgress?>? verification;
  final VoidCallback? onOpenMigration;

  /// «Verificar copia» (`null` = sin botón).
  final VoidCallback? onVerify;

  /// Abre la hoja de Sincronización.
  final VoidCallback? onOpenSync;

  @override
  Widget build(BuildContext context) {
    if (VaultUiMode.cloudless) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([
        sync.summary,
        ?migration,
        ?rotationRecord,
        ?verification,
      ]),
      builder: (context, _) {
        final state = cloudBannerFor(
          summary: sync.summary.value,
          migration: migration?.value,
          rotating: rotationRecord?.value != null,
          verification: verification?.value,
        );
        if (state == null) return const SizedBox.shrink();
        final VoidCallback? onAction = switch (state.kind) {
          CloudBannerKind.migration => onOpenMigration,
          CloudBannerKind.noCopy ||
          CloudBannerKind.unverified => onVerify,
          CloudBannerKind.noAccount || CloudBannerKind.localOnly => onOpenSync,
          _ => null,
        };
        final danger =
            state.kind == CloudBannerKind.noCopy ||
            state.kind == CloudBannerKind.migration;
        return Padding(
          padding: AppSpacing.pageHorizontal,
          child: Material(
            key: ValueKey('cloud-banner-${state.kind.name}'),
            color: AppColors.surfaceHigh,
            borderRadius: AppRadii.mdAll,
            child: Padding(
              padding: AppSpacing.card,
              child: Row(
                children: [
                  Icon(
                    state.kind == CloudBannerKind.verifying
                        ? Icons.cloud_sync_outlined
                        : Icons.cloud_off_outlined,
                    color: danger ? AppColors.danger : AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(state.title, style: AppTypography.body),
                          if (state.detail != null)
                            Text(state.detail!, style: AppTypography.caption),
                        ],
                      ),
                    ),
                  ),
                  if (state.action != null && onAction != null)
                    AppTextButton(
                      key: const ValueKey('cloud-banner-action'),
                      label: state.action!,
                      onPressed: onAction,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
