import 'package:flutter/foundation.dart';

/// D78 (parte B, §B.3): cuántos archivos (`.vault`, Papelera incluida) NO
/// tienen una copia real comprobada en la cuenta de Google actual, según
/// `vault_items` (no la cola). Solo conteos.
@immutable
class CloudCopyCounts {
  const CloudCopyCounts({
    this.total = 0,
    this.localOnly = 0,
    this.unverified = 0,
    this.noCopy = 0,
  });

  /// Todos los archivos.
  final int total;

  /// Solo en este teléfono: `pendiente`/`subiendo`, o `error` sin copia
  /// remota registrada (subida fallida).
  final int localOnly;

  /// «En la nube» según la BD pero sin el tag de la cuenta actual (sin
  /// comprobar en esta cuenta; sin sesión, todos los que tienen referencias).
  final int unverified;

  /// `error` con referencias remotas: la verificación no los encontró en la
  /// cuenta ni en el teléfono («sin copia en ninguna parte»).
  final int noCopy;

  /// Archivos sin copia real comprobada en la nube.
  int get withoutCloudCopy => localOnly + unverified + noCopy;

  @override
  bool operator ==(Object other) =>
      other is CloudCopyCounts &&
      other.total == total &&
      other.localOnly == localOnly &&
      other.unverified == unverified &&
      other.noCopy == noCopy;

  @override
  int get hashCode => Object.hash(total, localOnly, unverified, noCopy);
}
