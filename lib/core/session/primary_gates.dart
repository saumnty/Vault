import 'vault_session.dart';

/// Compuertas de los servicios que son SOLO de la bóveda principal
/// (sincronización, sin conexión, migración de cuenta, rotación, snapshot):
/// D67, `docs/DISENO_SENUELO.md` §4.3. Con la bóveda secundaria abierta no
/// corre nada de ellos.
abstract final class PrimaryGates {
  /// `isUnlocked` de `SyncService` / `OfflineService`: solo con la principal.
  static bool Function() unlocked(VaultSession s) =>
      () => s.isUnlockedAs(VaultSlot.primary);

  /// `VaultDataRepository.onDataChanged`: solo los cambios de la principal
  /// marcan sucio el snapshot de Drive.
  static void Function() dataChanged(VaultSession s, void Function() notify) =>
      () {
        if (s.isUnlockedAs(VaultSlot.primary)) notify();
      };

  /// Ticket de la sesión principal abierta, o `null` si no lo está.
  static SessionTicket? Function() ticket(VaultSession s) =>
      () => s.isUnlockedAs(VaultSlot.primary) ? s.ticket() : null;
}
