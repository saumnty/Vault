import 'package:cryptography/cryptography.dart';

import '../crypto/key_hierarchy.dart';
import 'vault_keyring.dart';

export 'vault_keyring.dart';

/// Sesión de la bóveda: mantiene en memoria las llaves ([VaultKeyring])
/// mientras la bóveda está desbloqueada. [clear] las destruye (bloquear).
///
/// D60: las llaves van por generación de DEK. Lo que ESCRIBE usa [keys] /
/// [filesKey] (generación [currentGen]); lo que LEE un item usa
/// [filesKeyFor]/[thumbsKeyFor] con la `keyGen` del item; la BD se abre con
/// [dbCandidates].
class VaultSession {
  static final VaultSession _instance = VaultSession.create();

  /// Instancia global de la app.
  factory VaultSession() => _instance;

  /// Sesión independiente (para pruebas).
  VaultSession.create();

  VaultKeyring? _ring;
  final List<void Function()> _onClear = [];

  /// Registra un callback que se invoca al bloquear ([clear]). Lo usa la BD
  /// para cerrar la conexión SQLCipher.
  void addOnClear(void Function() listener) => _onClear.add(listener);

  void removeOnClear(void Function() listener) => _onClear.remove(listener);

  bool get isUnlocked => _ring != null;

  /// Llaves de la generación actual (la que cifra lo nuevo). Lanza
  /// [StateError] si la bóveda está bloqueada.
  KeyHierarchy get keys {
    final ring = _ring;
    if (ring == null) throw StateError('La bóveda está bloqueada');
    return ring.current;
  }

  KeyHierarchy? get keysOrNull => _ring?.current;

  /// Llaves por generación, o `null` si está bloqueada.
  VaultKeyring? get keyring => _ring;

  /// Generación con la que se cifra lo nuevo (1 si está bloqueada: nunca se
  /// usa sin llave).
  int get currentGen => _ring?.currentGen ?? 1;

  /// Mayor generación con llave en esta sesión (1 si está bloqueada).
  int get maxGen {
    final ring = _ring;
    if (ring == null) return 1;
    final prev = ring.previousGen;
    return prev != null && prev > ring.currentGen ? prev : ring.currentGen;
  }

  /// Subllave para cifrar archivos NUEVOS, o `null` si está bloqueada.
  SecretKey? get filesKey => _ring?.current.files;

  /// Subllave "files" de la generación [gen] (para LEER un item de esa
  /// generación), o `null` si está bloqueada o la sesión no la tiene.
  SecretKey? filesKeyFor(int gen) => _ring?.forGenOrNull(gen)?.files;

  /// Subllave "thumbs" de la generación [gen], o `null`.
  SecretKey? thumbsKeyFor(int gen) => _ring?.forGenOrNull(gen)?.thumbs;

  /// Llaves candidatas para abrir la BD (ver [VaultKeyring.dbCandidates]);
  /// vacía si está bloqueada.
  List<(int, KeyHierarchy)> get dbCandidates => _ring?.dbCandidates ?? const [];

  /// Abre la sesión con una sola generación [gen] (la bóveda original es la
  /// 1). Ver [openKeyring].
  void open(KeyHierarchy keys, {int gen = 1}) =>
      openKeyring(VaultKeyring.single(gen, keys));

  /// Abre la sesión con [ring].
  ///
  /// Si ya está abierta con la MISMA DEK (mismo `keyCheck`) en la misma
  /// generación (p. ej. un segundo desbloqueo por doble toque o huella + PIN),
  /// se conservan las jerarquías actuales y se destruyen las nuevas
  /// duplicadas: así no se invalidan referencias que otros servicios ya
  /// tienen (`filesKey`, la llave de la BD). Las jerarquías viejas que ya no
  /// están en [ring] se destruyen.
  void openKeyring(VaultKeyring ring) {
    final old = _ring;
    if (identical(ring, old)) return;
    if (old == null || old.isDestroyed) {
      old?.destroy();
      _ring = ring;
      return;
    }
    KeyHierarchy reuse(int gen, KeyHierarchy fresh) {
      final existing = old.forGenOrNull(gen);
      if (existing != null &&
          !existing.isDestroyed &&
          !identical(existing, fresh) &&
          existing.keyCheck == fresh.keyCheck) {
        fresh.destroy();
        return existing;
      }
      return fresh;
    }

    final current = reuse(ring.currentGen, ring.current);
    final prev = ring.previous;
    final merged = prev == null
        ? VaultKeyring.single(ring.currentGen, current)
        : VaultKeyring.dual(
            currentGen: ring.currentGen,
            current: current,
            previousGen: ring.previousGen!,
            previous: reuse(ring.previousGen!, prev),
          );
    for (final k in old.all) {
      if (!merged.all.any((m) => identical(m, k))) k.destroy();
    }
    _ring = merged;
  }

  void clear() {
    _ring?.destroy();
    _ring = null;
    for (final l in List.of(_onClear)) {
      l();
    }
  }
}
