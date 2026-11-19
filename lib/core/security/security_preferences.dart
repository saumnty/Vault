import '../crypto/secure_kv_store.dart';

/// Tiempo en segundo plano tras el cual la bóveda se bloquea sola.
enum AutoLockDelay {
  immediate(Duration.zero, 'Inmediato'),
  seconds15(Duration(seconds: 15), '15 segundos'),
  seconds30(Duration(seconds: 30), '30 segundos'),
  minute1(Duration(minutes: 1), '1 minuto'),
  minutes5(Duration(minutes: 5), '5 minutos'),
  minutes15(Duration(minutes: 15), '15 minutos');

  const AutoLockDelay(this.duration, this.label);

  final Duration duration;
  final String label;

  /// Valor por defecto: 1 minuto.
  static const AutoLockDelay defaultValue = AutoLockDelay.minute1;

  static AutoLockDelay fromMillis(int? ms) {
    for (final d in values) {
      if (d.duration.inMilliseconds == ms) return d;
    }
    return defaultValue;
  }
}

/// Preferencia persistida del autobloqueo (la usará la pantalla de ajustes, F8).
class AutoLockPreferences {
  AutoLockPreferences(this._store);

  final SecureKeyValueStore _store;

  static const String delayKey = 'security.v1.autolock_ms';

  Future<AutoLockDelay> getDelay() async =>
      AutoLockDelay.fromMillis(int.tryParse(await _store.read(delayKey) ?? ''));

  Future<void> setDelay(AutoLockDelay delay) =>
      _store.write(delayKey, '${delay.duration.inMilliseconds}');
}

/// Preferencia "Proteger pantalla" (FLAG_SECURE en Android). ACTIVA por defecto.
class ScreenProtectionPreferences {
  ScreenProtectionPreferences(this._store);

  final SecureKeyValueStore _store;

  static const String protectKey = 'security.v1.protect_screen';

  Future<bool> getProtect() async => (await _store.read(protectKey)) != 'false';

  Future<void> setProtect(bool value) =>
      _store.write(protectKey, value ? 'true' : 'false');
}
