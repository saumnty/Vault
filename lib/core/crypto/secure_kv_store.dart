import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Almacén clave/valor seguro y local (nunca sale del teléfono).
///
/// Se abstrae para poder inyectar un fake en memoria en las pruebas.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Implementación real sobre `flutter_secure_storage`
/// (Android: EncryptedSharedPreferences con llave en Keystore;
/// iOS: Keychain).
class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // iOS: `unlocked_this_device` = kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
  // El elemento solo es legible con el dispositivo desbloqueado y NO viaja en
  // copias de iCloud/iTunes ni a otro dispositivo. (Antes se usaba `passcode`,
  // que hace fallar la escritura si el usuario no tiene código de desbloqueo.)
  static const IOSOptions _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  );

  static const AndroidOptions _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  @override
  Future<String?> read(String key) =>
      _storage.read(key: key, iOptions: _iosOptions, aOptions: _androidOptions);

  @override
  Future<void> write(String key, String value) => _storage.write(
    key: key,
    value: value,
    iOptions: _iosOptions,
    aOptions: _androidOptions,
  );

  @override
  Future<void> delete(String key) => _storage.delete(
    key: key,
    iOptions: _iosOptions,
    aOptions: _androidOptions,
  );
}
