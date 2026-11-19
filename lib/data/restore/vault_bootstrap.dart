import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/crypto/auth_controller.dart';
import '../../core/logging/vault_log.dart';
import '../../core/services/app_paths.dart';
import '../repositories/vault_database.dart';
import 'restore_service.dart';

/// Decisión de arranque (¿hay bóveda en este dispositivo?), separada de
/// `main.dart` para poder probarla con iOS simulado.
///
/// * iOS (F9): el Keychain sobrevive a desinstalar la app, los archivos no. Si
///   hay envoltura del PIN pero no existe la BD ni ningún resto de una
///   rotación de llave (`vault_secure.db.kN` / `vault_secure.db.kN.tmp`), es
///   una instalación limpia con llaves viejas: se descartan.
/// * C1 (D62): con restos de la rotación NO se descarta nada (la reparación
///   necesita el PIN): se va a la pantalla del PIN.
/// * Sin bóveda se barren BD y miniaturas huérfanas (restauración
///   interrumpida durante la instalación).
abstract final class VaultBootstrap {
  /// `vault_secure.db.kN` (copia de seguridad de la rotación) o
  /// `vault_secure.db.kN.tmp` (exportación en curso).
  static final RegExp _rotationLeftover = RegExp(
    '^${RegExp.escape(VaultSchema.dbFileName)}\\.k[0-9]+(\\.tmp)?\$',
  );

  /// Devuelve `true` si hay bóveda (ir al PIN) o `false` (onboarding).
  static Future<bool> decide({
    required AuthController auth,
    required bool isIOS,
    bool sweepOrphans = true,
    String? dbPath,
  }) async {
    var hasVault = await auth.hasVault();
    if (isIOS && hasVault && AppPaths.isInitialized) {
      final path = dbPath ?? VaultDatabase.defaultDbPath;
      if (!await auth.isOnboardingPending() &&
          !File(path).existsSync() &&
          !hasRotationLeftovers(path)) {
        await auth.discardLocalKeys();
        hasVault = false;
      }
    }
    if (!hasVault && sweepOrphans) {
      await RestoreService.sweepOrphans(dbPath: dbPath);
    }
    // Fase 8 (§9): la bóveda secundaria se reconcilia DESPUÉS y nunca cambia
    // la decisión sobre la principal. Un error del almacén no borra nada
    // (M4) ni impide arrancar.
    try {
      await auth.reconcileSecondaryAtStartup(primaryExists: hasVault);
    } on Object catch (e) {
      VaultLog.e('Reconciliación de la bóveda secundaria omitida', e);
    }
    return hasVault;
  }

  /// `true` si junto a [dbPath] hay restos de una rotación de la DEK.
  static bool hasRotationLeftovers(String dbPath) {
    final dir = Directory(p.dirname(dbPath));
    if (!dir.existsSync()) return false;
    final base = p.basename(dbPath);
    final pattern = base == VaultSchema.dbFileName
        ? _rotationLeftover
        : RegExp('^${RegExp.escape(base)}\\.k[0-9]+(\\.tmp)?\$');
    for (final e in dir.listSync()) {
      if (e is File && pattern.hasMatch(p.basename(e.path))) return true;
    }
    return false;
  }
}
