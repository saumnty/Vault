import 'vault_slot.dart';

/// La sesión cambió de bóveda o de época (se bloqueó, o se abrió otra
/// bóveda) desde que la operación capturó su [SessionTicket]: la operación
/// debe abandonar SIN escribir nada (D67, `docs/DISENO_SENUELO.md` §4.1).
///
/// Es un [StateError] para que los llamadores que ya tratan "bóveda
/// bloqueada" como `StateError` lo manejen igual.
class SessionChangedException extends StateError {
  SessionChangedException([
    super.message = 'La sesión cambió durante la operación',
  ]);
}

/// Se pidió un recurso (p. ej. la BD) de una bóveda con OTRA bóveda abierta
/// (D67). Es un error de programa o una operación tardía: nunca se lee ni se
/// escribe la otra bóveda.
class WrongVaultSlotError extends StateError {
  WrongVaultSlotError(this.expected, this.actual)
    : super(
        'Recurso de la bóveda ${expected.name} con la sesión en '
        '${actual?.name ?? 'bloqueo'}',
      );

  final VaultSlot expected;
  final VaultSlot? actual;
}

/// Lo que una operación larga captura AL EMPEZAR: de qué bóveda es y en qué
/// época de la sesión empezó. Antes de cada escritura o borrado llama a
/// [check]; si la sesión se bloqueó o cambió de bóveda, lanza.
abstract interface class SessionTicket {
  VaultSlot get slot;
  int get epoch;

  /// `true` si la sesión sigue abierta en la MISMA bóveda y época.
  bool get isValid;

  /// Lanza [SessionChangedException] si ya no es válida.
  void check();
}
