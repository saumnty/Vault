/// Estado de sincronización de un item con Drive.
enum SyncStatus {
  pendiente('pendiente'),
  subiendo('subiendo'),
  enNube('en_nube'),
  enCache('en_cache'),
  sinConexion('sin_conexion'),
  error('error');

  const SyncStatus(this.dbValue);

  /// Valor guardado en la columna `syncStatus`.
  final String dbValue;

  /// Valor por defecto de un item nuevo.
  static const SyncStatus defaultValue = SyncStatus.pendiente;

  /// `null` -> [defaultValue]; valor desconocido -> [ArgumentError].
  static SyncStatus fromDb(String? value) {
    if (value == null) return defaultValue;
    for (final s in values) {
      if (s.dbValue == value) return s;
    }
    throw ArgumentError.value(value, 'value', 'SyncStatus desconocido');
  }
}
