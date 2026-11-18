import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../data/models/sync_status.dart';
import '../../../shared/vault_ui_mode.dart';

/// Texto accesible (español) de cada estado. Fase 8: en la bóveda secundaria
/// (sin nube) siempre "En este teléfono".
String syncStatusLabel(SyncStatus status) => VaultUiMode.cloudless
    ? 'En este teléfono'
    : switch (status) {
        SyncStatus.pendiente => 'Pendiente de subir',
        SyncStatus.subiendo => 'Subiendo a la nube',
        SyncStatus.enNube => 'En la nube',
        SyncStatus.enCache => 'En caché del dispositivo',
        SyncStatus.sinConexion => 'Disponible sin conexión',
        SyncStatus.error => 'Error de sincronización',
      };

IconData syncStatusIcon(SyncStatus status) => switch (status) {
  SyncStatus.pendiente => Icons.schedule,
  SyncStatus.subiendo => Icons.cloud_upload_outlined,
  SyncStatus.enNube => Icons.cloud_done_outlined,
  SyncStatus.enCache => Icons.download_done,
  SyncStatus.sinConexion => Icons.offline_pin_outlined,
  SyncStatus.error => Icons.error_outline,
};

Color syncStatusColor(SyncStatus status) => switch (status) {
  SyncStatus.pendiente => AppColors.warning,
  SyncStatus.subiendo => AppColors.accentLight,
  SyncStatus.enNube => AppColors.info,
  SyncStatus.enCache => AppColors.textPrimary,
  SyncStatus.sinConexion => AppColors.success,
  SyncStatus.error => AppColors.danger,
};

/// Insignia de estado de sincronización. `subiendo` muestra un anillo de
/// progreso (determinado si se pasa [progress] 0..1, indeterminado si no).
class SyncStatusIcon extends StatelessWidget {
  const SyncStatusIcon({
    super.key,
    required this.status,
    this.progress,
    this.downloading = false,
  });

  final SyncStatus status;
  final double? progress;

  /// Descarga "sin conexión" en curso: anillo con flecha hacia abajo.
  final bool downloading;

  @override
  Widget build(BuildContext context) {
    // Fase 8 (G7): sin nube no hay estado de subida que mostrar.
    if (VaultUiMode.cloudless) return const SizedBox.shrink();
    final color = downloading ? AppColors.success : syncStatusColor(status);
    final uploading = status == SyncStatus.subiendo || downloading;
    final base = downloading
        ? 'Descargando para uso sin conexión'
        : syncStatusLabel(status);
    final label = uploading && progress != null
        ? '$base, ${(progress! * 100).round()} por ciento'
        : base;
    return Semantics(
      label: label,
      image: true,
      child: ExcludeSemantics(
        child: Container(
          width: AppSizes.statusBadge,
          height: AppSizes.statusBadge,
          decoration: const BoxDecoration(
            color: AppColors.scrim,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (uploading)
                SizedBox.square(
                  dimension: AppSizes.statusBadge,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: AppSizes.statusStroke,
                    color: color,
                    backgroundColor: AppColors.overlayLight,
                  ),
                ),
              Icon(
                downloading ? Icons.arrow_downward : syncStatusIcon(status),
                size: uploading
                    ? AppSizes.iconSm - AppSpacing.xs
                    : AppSizes.iconSm,
                color: color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
