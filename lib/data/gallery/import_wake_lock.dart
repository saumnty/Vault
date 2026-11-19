import 'package:keep_screen_on/keep_screen_on.dart';

/// Mantener la pantalla encendida mientras corre un lote de importación
/// (D88). Inyectable; nunca lanza.
abstract interface class ImportWakeLock {
  Future<void> enable();
  Future<void> disable();
}

/// `keep_screen_on` 6.0.0: Android `FLAG_KEEP_SCREEN_ON` en la ventana de la
/// actividad; iOS `UIApplication.isIdleTimerDisabled` (// iOS: sin probar).
/// Solo afecta a la pantalla de Kern mientras está en primer plano: no
/// impide que el sistema suspenda la app en segundo plano.
class KeepScreenOnWakeLock implements ImportWakeLock {
  const KeepScreenOnWakeLock();

  @override
  Future<void> enable() async {
    try {
      await KeepScreenOn.turnOn();
    } on Object {
      // Sin plugin (pruebas/escritorio) o sin actividad: se importa igual.
    }
  }

  @override
  Future<void> disable() async {
    try {
      await KeepScreenOn.turnOff();
    } on Object {
      // best-effort
    }
  }
}

/// Sin efecto (pruebas, bóvedas sin UI).
class NoopWakeLock implements ImportWakeLock {
  const NoopWakeLock();
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}
