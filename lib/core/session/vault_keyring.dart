import '../crypto/key_hierarchy.dart';

/// Llaves de una sesión desbloqueada, por generación de DEK (D60).
///
/// Normalmente hay UNA generación ([VaultKeyring.single]). Solo durante una
/// rotación de la DEK (fases `reencrypting`..`rekeyingDb`) conviven dos
/// ([VaultKeyring.dual]): [current] (la nueva, con la que se CIFRA todo lo
/// nuevo) y [previous] (la vieja, solo para leer lo aún no re-cifrado).
class VaultKeyring {
  VaultKeyring.single(this.currentGen, this.current)
    : previousGen = null,
      previous = null {
    _checkGen(currentGen);
  }

  VaultKeyring.dual({
    required this.currentGen,
    required this.current,
    required int this.previousGen,
    required KeyHierarchy this.previous,
  }) {
    _checkGen(currentGen);
    _checkGen(previousGen!);
    if (previousGen == currentGen) {
      throw ArgumentError('Las dos generaciones deben ser distintas');
    }
    if (previous!.keyCheck == current.keyCheck) {
      throw ArgumentError('Las dos generaciones tienen la misma DEK');
    }
  }

  static void _checkGen(int gen) {
    if (gen < 1) throw ArgumentError.value(gen, 'gen', 'Generación inválida');
  }

  /// Generación con la que se cifra lo nuevo.
  final int currentGen;
  final KeyHierarchy current;

  /// Generación anterior (solo durante una rotación), o `null`.
  final int? previousGen;
  final KeyHierarchy? previous;

  bool get isDual => previous != null;

  /// Todas las jerarquías, la actual primero.
  List<KeyHierarchy> get all => [current, ?previous];

  /// `true` si alguna jerarquía ya se destruyó (la sesión no es utilizable).
  bool get isDestroyed =>
      current.isDestroyed || (previous?.isDestroyed ?? false);

  /// Llaves de la generación [gen], o `null` si esta sesión no la tiene.
  KeyHierarchy? forGenOrNull(int gen) {
    if (gen == currentGen) return current;
    if (gen == previousGen) return previous;
    return null;
  }

  /// Llaves de la generación [gen]. Lanza [StateError] si no está.
  KeyHierarchy forGen(int gen) {
    final k = forGenOrNull(gen);
    if (k == null) {
      throw StateError('Esta sesión no tiene la llave de la generación $gen');
    }
    return k;
  }

  /// Candidatas para abrir la BD, en orden: la anterior primero (la BD se
  /// re-cifra al final de la rotación) y luego la actual.
  List<(int, KeyHierarchy)> get dbCandidates => [
    if (previous != null) (previousGen!, previous!),
    (currentGen, current),
  ];

  void destroy() {
    for (final k in all) {
      k.destroy();
    }
  }
}
