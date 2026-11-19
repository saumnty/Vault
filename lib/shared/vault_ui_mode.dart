/// Modo de la interfaz según la bóveda abierta (fase 8, D70,
/// DISENO_SENUELO §6.11 y G7).
///
/// Con la bóveda secundaria abierta ([cloudless] = `true`) la interfaz no
/// muestra nada que nombre la nube, Drive o Google: ni el estado de subida
/// de cada archivo, ni "sin conexión", ni el borrado de originales, ni
/// mensajes de error de descarga. Lo fija la raíz de la app al abrir/bloquear
/// la bóveda (las rutas del visor y las hojas viven fuera del árbol de la
/// pantalla de la bóveda, por eso no es un InheritedWidget).
abstract final class VaultUiMode {
  /// `true` con la bóveda secundaria abierta.
  static bool cloudless = false;
}
