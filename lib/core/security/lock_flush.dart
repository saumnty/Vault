// S-17: bloqueo con toma del snapshot de la BD sin alargar la vida de las
// llaves en memoria.
import 'dart:async';

/// Tiempo máximo que se espera a la copia cifrada de la BD antes de destruir
/// las llaves. La interfaz ya muestra el PIN; esto es lo que dura la ventana.
/// Si no alcanza, el estado "sucio" se conserva y el snapshot se toma al
/// siguiente desbloqueo (no se pierde nada).
const Duration kLockFlushBudget = Duration(seconds: 1);

/// Ejecuta [flush] (si hay) y luego [lock], garantizando que [lock] corra a
/// más tardar [budget] después de la llamada, incluso si [flush] se cuelga o
/// falla. [lock] se invoca exactamente una vez.
void lockWithFlush({
  required Future<void> Function()? flush,
  required void Function() lock,
  Duration budget = kLockFlushBudget,
}) {
  if (flush == null) {
    lock();
    return;
  }
  var locked = false;
  void lockOnce() {
    if (locked) return;
    locked = true;
    lock();
  }

  final timer = Timer(budget, lockOnce);
  Future<void> run() async {
    try {
      await flush();
    } on Object {
      // Sin respaldo no hay por qué retrasar el bloqueo.
    } finally {
      timer.cancel();
      lockOnce();
    }
  }

  unawaited(run());
}
