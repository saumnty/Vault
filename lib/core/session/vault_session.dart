import 'package:cryptography/cryptography.dart';

import '../crypto/key_hierarchy.dart';

/// Sesión de la bóveda: mantiene en memoria la [KeyHierarchy] mientras la
/// bóveda está desbloqueada. [clear] la destruye (bloquear).
class VaultSession {
  static final VaultSession _instance = VaultSession.create();

  /// Instancia global de la app.
  factory VaultSession() => _instance;

  /// Sesión independiente (para pruebas).
  VaultSession.create();

  KeyHierarchy? _keys;
  final List<void Function()> _onClear = [];

  /// Registra un callback que se invoca al bloquear ([clear]). Lo usa la BD
  /// para cerrar la conexión SQLCipher.
  void addOnClear(void Function() listener) => _onClear.add(listener);

  void removeOnClear(void Function() listener) => _onClear.remove(listener);

  bool get isUnlocked => _keys != null;

  /// Llaves de la sesión. Lanza [StateError] si la bóveda está bloqueada.
  KeyHierarchy get keys {
    final keys = _keys;
    if (keys == null) throw StateError('La bóveda está bloqueada');
    return keys;
  }

  KeyHierarchy? get keysOrNull => _keys;

  /// Subllave para cifrar archivos, o `null` si está bloqueada.
  SecretKey? get filesKey => _keys?.files;

  /// Abre la sesión con [keys].
  ///
  /// Si ya está abierta con la MISMA DEK (mismo `keyCheck`; p. ej. un segundo
  /// desbloqueo por doble toque o huella + PIN), se conservan las llaves
  /// actuales y se destruyen las nuevas: así no se invalidan referencias que
  /// otros servicios ya tienen (`filesKey`, la llave de la BD). Si es otra DEK,
  /// las anteriores se destruyen.
  void open(KeyHierarchy keys) {
    final current = _keys;
    if (identical(keys, current)) return;
    if (current != null &&
        !current.isDestroyed &&
        current.keyCheck == keys.keyCheck) {
      keys.destroy();
      return;
    }
    current?.destroy();
    _keys = keys;
  }

  void clear() {
    _keys?.destroy();
    _keys = null;
    for (final l in List.of(_onClear)) {
      l();
    }
  }
}
