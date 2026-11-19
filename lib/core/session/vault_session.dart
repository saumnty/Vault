import 'package:cryptography/cryptography.dart';

import '../crypto/key_hierarchy.dart';
import 'session_ticket.dart';
import 'vault_keyring.dart';
import 'vault_slot.dart';

export 'session_ticket.dart';
export 'vault_keyring.dart';
export 'vault_slot.dart';

/// Sesión de la bóveda: mantiene en memoria las llaves ([VaultKeyring])
/// mientras la bóveda está desbloqueada. [clear] las destruye (bloquear).
///
/// D60: las llaves van por generación de DEK. Lo que ESCRIBE usa [keys] /
/// [filesKey] (generación [currentGen]); lo que LEE un item usa
/// [filesKeyFor]/[thumbsKeyFor] con la `keyGen` del item; la BD se abre con
/// [dbCandidates].
///
/// D67 (fase 8, `docs/DISENO_SENUELO.md` §4.1): la sesión es de UNA bóveda
/// ([slot]) y tiene una [epoch] que cambia al bloquear y al abrir desde el
/// estado bloqueado. Las llaves de lectura se piden indicando la bóveda: con
/// la otra bóveda abierta devuelven `null`. Abrir otra bóveda sin bloquear
/// antes es un error ([StateError]).
class VaultSession {
  static final VaultSession _instance = VaultSession.create();

  /// Instancia global de la app.
  factory VaultSession() => _instance;

  /// Sesión independiente (para pruebas).
  VaultSession.create();

  VaultKeyring? _ring;
  VaultSlot? _slot;
  int _epoch = 0;
  final List<void Function()> _onClear = [];

  /// Registra un callback que se invoca al bloquear ([clear]). Lo usa la BD
  /// para cerrar la conexión SQLCipher.
  void addOnClear(void Function() listener) => _onClear.add(listener);

  void removeOnClear(void Function() listener) => _onClear.remove(listener);

  bool get isUnlocked => _ring != null;

  /// Bóveda abierta, o `null` si está bloqueada.
  VaultSlot? get slot => _ring == null ? null : _slot;

  /// `true` si está desbloqueada y la bóveda abierta es [s].
  bool isUnlockedAs(VaultSlot s) => _ring != null && _slot == s;

  /// Época de la sesión: cambia en cada [clear] y en cada apertura desde el
  /// estado bloqueado (no al cambiar el anillo de la MISMA sesión, p. ej.
  /// durante una rotación).
  int get epoch => _epoch;

  /// Captura bóveda y época para una operación larga. Lanza [StateError] si
  /// está bloqueada.
  SessionTicket ticket() {
    final s = slot;
    if (s == null) throw StateError('La bóveda está bloqueada');
    return _Ticket(this, s, _epoch);
  }

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

  /// Subllave "files" de la generación [gen] de la bóveda [slot] (para LEER
  /// un item de esa generación), o `null` si está bloqueada, si la bóveda
  /// abierta es otra o si la sesión no tiene esa generación.
  ///
  /// [slot] es posicional opcional con la principal por defecto: los
  /// servicios existentes (todos de la principal) siguen igual y, con la
  /// secundaria abierta, reciben `null` (falla cerrado).
  SecretKey? filesKeyFor(int gen, [VaultSlot slot = VaultSlot.primary]) =>
      _ringFor(slot)?.forGenOrNull(gen)?.files;

  /// Subllave "thumbs" de la generación [gen] de la bóveda [slot], o `null`.
  SecretKey? thumbsKeyFor(int gen, [VaultSlot slot = VaultSlot.primary]) =>
      _ringFor(slot)?.forGenOrNull(gen)?.thumbs;

  VaultKeyring? _ringFor(VaultSlot s) => _slot == s ? _ring : null;

  /// Llaves candidatas para abrir la BD (ver [VaultKeyring.dbCandidates]);
  /// vacía si está bloqueada.
  List<(int, KeyHierarchy)> get dbCandidates => _ring?.dbCandidates ?? const [];

  /// Como [dbCandidates] pero vacía si la bóveda abierta no es [s].
  List<(int, KeyHierarchy)> dbCandidatesFor(VaultSlot s) =>
      _ringFor(s)?.dbCandidates ?? const [];

  /// Abre la sesión con una sola generación [gen] (la bóveda original es la
  /// 1). Ver [openKeyring].
  void open(
    KeyHierarchy keys, {
    int gen = 1,
    VaultSlot slot = VaultSlot.primary,
  }) => openKeyring(VaultKeyring.single(gen, keys), slot: slot);

  /// Abre la sesión con [ring] en la bóveda [slot].
  ///
  /// Si ya está abierta con la MISMA DEK (mismo `keyCheck`) en la misma
  /// generación (p. ej. un segundo desbloqueo por doble toque o huella + PIN),
  /// se conservan las jerarquías actuales y se destruyen las nuevas
  /// duplicadas: así no se invalidan referencias que otros servicios ya
  /// tienen (`filesKey`, la llave de la BD). Las jerarquías viejas que ya no
  /// están en [ring] se destruyen.
  ///
  /// D67: con la sesión abierta en OTRA bóveda lanza [StateError] (y destruye
  /// [ring]): para cambiar de bóveda hay que bloquear antes ([clear]).
  void openKeyring(VaultKeyring ring, {VaultSlot slot = VaultSlot.primary}) {
    final old = _ring;
    if (identical(ring, old)) return;
    final live = old != null && !old.isDestroyed;
    if (live && _slot != slot) {
      ring.destroy();
      throw StateError(
        'La sesión está abierta en otra bóveda: hay que bloquear antes',
      );
    }
    if (!live) {
      old?.destroy();
      // Abrir desde el estado bloqueado (o desde llaves ya destruidas) es una
      // sesión nueva: otra época.
      _epoch++;
      _slot = slot;
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
    _slot = null;
    _epoch++;
    for (final l in List.of(_onClear)) {
      l();
    }
  }
}

class _Ticket implements SessionTicket {
  _Ticket(this._session, this.slot, this.epoch);

  final VaultSession _session;
  @override
  final VaultSlot slot;
  @override
  final int epoch;

  @override
  bool get isValid => _session.isUnlockedAs(slot) && _session.epoch == epoch;

  @override
  void check() {
    if (!isValid) throw SessionChangedException();
  }
}
