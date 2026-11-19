import '../../core/logging/vault_log.dart';

/// Un paso del trabajo que se hace al abrir la bóveda (D76).
class UnlockStep {
  const UnlockStep(this.name, this.run);

  /// Nombre fijo y corto para el diagnóstico (nunca datos del usuario).
  final String name;
  final Future<void> Function() run;
}

/// Ejecuta [steps] EN ORDEN, cada uno aislado en su try/catch: un paso que
/// falla se registra (solo su nombre y el tipo del error) y NO impide los
/// siguientes. Antes de cada paso se comprueba [stillValid] (la sesión sigue
/// siendo la misma); si no, se para sin hacer nada más.
///
/// Por qué (`docs/DISENO_MIGRACION_ATASCADA.md` §A.3.5): antes, una excepción
/// en un paso temprano impedía aplicar la guarda del cambio de cuenta y la
/// caché podía purgar con referencias de otra cuenta. El orden lo decide el
/// llamador: la guarda de la migración va PRIMERO y la purga de la caché
/// después.
Future<void> runUnlockSteps(
  List<UnlockStep> steps, {
  bool Function()? stillValid,
}) async {
  for (final step in steps) {
    if (stillValid != null && !stillValid()) return;
    try {
      await step.run();
    } on Object catch (e) {
      VaultLog.e('Al abrir: falló el paso ${step.name}', e, 'app');
    }
  }
}
