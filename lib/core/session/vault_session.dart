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

  void open(KeyHierarchy keys) {
    if (identical(keys, _keys)) return;
    _keys?.destroy();
    _keys = keys;
  }

  void clear() {
    _keys?.destroy();
    _keys = null;
  }
}
