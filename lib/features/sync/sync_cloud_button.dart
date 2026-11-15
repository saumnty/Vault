import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/sync/sync_service.dart';
import '../../shared/widgets/app_buttons.dart';

/// Texto accesible del estado de sincronización.
String syncSummaryLabel(SyncSummary s) {
  if (s.accountEmail == null) return 'Sincronización: sin cuenta de Google';
  if (s.phase == SyncPhase.running || s.counts.uploading > 0) {
    return 'Sincronización: subiendo';
  }
  if (s.counts.errors > 0) {
    return 'Sincronización: ${s.counts.errors} con error';
  }
  if (s.counts.pending > 0) {
    return 'Sincronización: ${s.counts.pending} pendientes';
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
        } else if (s.counts.errors > 0) {
          icon = Icons.cloud_off_outlined;
          color = AppColors.danger;
        } else if (s.counts.pending > 0) {
          icon = Icons.cloud_upload_outlined;
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
