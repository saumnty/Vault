import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/sync/sync_service.dart';
import '../../shared/widgets/app_buttons.dart';

/// Texto accesible del estado de sincronización.
///
/// D78: nunca dice «al día» con la sincronización en pausa, con archivos
/// sin comprobar en la cuenta actual o con archivos pendientes en
/// `vault_items` (no solo en la cola).
String syncSummaryLabel(SyncSummary s) {
  if (s.accountEmail == null) return 'Sincronización: sin cuenta de Google';
  if (s.phase == SyncPhase.running || s.counts.uploading > 0) {
    return 'Sincronización: subiendo';
  }
  final pause = s.pauseReason;
  if (pause != null) return 'Sincronización: en pausa (${syncPauseText(pause)})';
  if (s.errorTotal > 0) {
    return 'Sincronización: ${s.errorTotal} con error';
  }
  if (s.pendingTotal > 0) {
    return 'Sincronización: ${s.pendingTotal} pendientes';
  }
  if (s.cloud.unverified > 0) {
    return 'Sincronización: ${s.cloud.unverified} sin comprobar';
  }
  return 'Sincronización: al día';
}

/// Icono de nube de la barra superior: refleja el estado y abre la hoja.
class SyncCloudButton extends StatelessWidget {
  const SyncCloudButton({super.key, required this.sync, required this.onTap});

  final SyncService sync;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncSummary>(
      valueListenable: sync.summary,
      builder: (context, s, _) {
        final IconData icon;
        Color color = AppColors.textPrimary;
        if (s.accountEmail == null) {
          icon = Icons.cloud_off_outlined;
        } else if (s.phase == SyncPhase.running || s.counts.uploading > 0) {
          icon = Icons.cloud_sync_outlined;
          color = AppColors.accentLight;
        } else if (s.pauseReason != null) {
          icon = Icons.cloud_off_outlined;
          color = AppColors.warning;
        } else if (s.errorTotal > 0) {
          icon = Icons.cloud_off_outlined;
          color = AppColors.danger;
        } else if (s.pendingTotal > 0) {
          icon = Icons.cloud_upload_outlined;
          color = AppColors.warning;
        } else if (s.cloud.unverified > 0) {
          icon = Icons.cloud_queue_outlined;
          color = AppColors.warning;
        } else {
          icon = Icons.cloud_done_outlined;
        }
        return AppIconButton(
          icon: icon,
          color: color,
          label: syncSummaryLabel(s),
          onPressed: onTap,
        );
      },
    );
  }
}
