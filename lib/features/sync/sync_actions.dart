import 'package:flutter/material.dart';

import '../../core/logging/vault_log.dart';
import '../../data/sync/sync_service.dart';

/// D78 (parte B, §B.4): guardas y mensajes COMPARTIDOS por Ajustes y la hoja
/// de Sincronización de la cuadrícula. Ningún botón vuelve en silencio ni se
/// desactiva sin decir por qué.

/// Motivo por el que «Iniciar/Cerrar sesión de Google» no está disponible, o
/// `null` si lo está. [migrating]/[rotating] los da la UI (estado visible);
/// el resto lo decide [SyncService.accountActionBlock].
String? accountActionBlockReason(
  SyncService sync, {
  bool migrating = false,
  bool rotating = false,
}) {
  if (migrating) {
    return 'No disponible: termina o cancela el cambio de cuenta.';
  }
  final block = sync.accountActionBlock();
  if (block != null) return block.message;
  if (rotating) {
    return 'No disponible: termina primero el cambio de llave maestra.';
  }
  return null;
}

/// `true` si el bloqueo de la sesión es por un cambio de cuenta (la acción
/// lleva a su pantalla en lugar de cambiar la sesión por fuera).
bool accountBlockedByMigration(SyncService sync, {bool migrating = false}) =>
    migrating || sync.pausedForMigration;

/// Subtítulo de «Sincronizar ahora» (`null` = nada que decir).
String? syncNowSubtitle(SyncSummary s) {
  final pause = s.pauseReason;
  if (pause != null) return 'En pausa: ${syncPauseText(pause)}.';
  if (s.phase == SyncPhase.running) {
    return 'Sincronizando… Toca para ver o detener.';
  }
  if (s.accountEmail == null) return 'Inicia sesión con Google para sincronizar.';
  return null;
}

/// Lanza una sincronización manual y devuelve el texto a mostrar. Las
/// acciones de la SnackBar: «Ver» (cambio de cuenta) y «Detener» (pasada en
/// curso, salida si se cuelga).
Future<(SyncRunOutcome, String)> runManualSync(SyncService sync) async {
  final outcome = await sync.run(manual: true);
  final text = syncRunMessage(outcome, counts: sync.summary.value.counts);
  if (outcome.blocked) {
    VaultLog.d(
      'Sincronizar ahora: ${outcome.kind.name}',
      category: 'ui',
    );
  }
  return (outcome, text);
}

/// SnackBar con el resultado de [runManualSync].
SnackBar syncOutcomeSnackBar(
  SyncService sync,
  SyncRunOutcome outcome,
  String text, {
  VoidCallback? onOpenMigration,
}) {
  SnackBarAction? action;
  if (outcome.kind == SyncRunKind.paused &&
      outcome.pauseReason == SyncPauseReason.migration &&
      onOpenMigration != null) {
    action = SnackBarAction(label: 'Ver', onPressed: onOpenMigration);
  } else if (outcome.kind == SyncRunKind.alreadyRunning) {
    action = SnackBarAction(label: 'Detener', onPressed: sync.stop);
  }
  return SnackBar(content: Text(text), action: action);
}
