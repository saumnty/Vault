import '../security/auto_lock.dart';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:biometric_storage/biometric_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Estado de la biometría del sistema.
enum BiometricAvailability {
  available,

  /// Hay hardware pero no hay huellas/rostro registrados (o no hay código de
  /// desbloqueo en iOS).
  notEnrolled,
  unavailable,
}

/// El usuario canceló (o el sistema interrumpió) el diálogo biométrico.
class BiometricCancelledException implements Exception {
  const BiometricCancelledException();
  @override
  String toString() => 'BiometricCancelledException';
}

/// Almacén de UNA llave ligado a la biometría del sistema operativo.
///
/// No es un "sí/no" como `local_auth`: el secreto solo se puede leer después
/// de que el SO verifica la biometría, porque la llave que lo protege vive en
/// hardware y exige autenticación de usuario para cada uso.
///
/// Se abstrae tras esta interfaz para poder usar un fake en las pruebas.
abstract interface class BiometricKeyStore {
  Future<BiometricAvailability> availability();

  /// Guarda [key] (sobrescribe). Puede mostrar el diálogo biométrico.
  Future<void> writeKey(Uint8List key);

  /// Muestra el diálogo biométrico y devuelve la llave, o `null` si no hay
  /// ninguna guardada (o el SO la invalidó al cambiar las huellas/rostros).
  /// Lanza [BiometricCancelledException] si el usuario cancela.
  Future<Uint8List?> readKey();

  Future<void> deleteKey();
}

/// Implementación con `biometric_storage` (pub.dev, publisher codeux.design).
///
/// Por qué este paquete (evaluado en nov-2026):
/// * Hace exactamente lo que pedimos: cada "archivo" se cifra con una llave
///   AES-256-GCM del Android Keystore creada con
///   `setUserAuthenticationRequired(true)` y, en Android 11+,
///   `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`; se descifra
///   vía `BiometricPrompt` con `CryptoObject` (autenticación POR USO, usa
///   StrongBox si existe). En iOS guarda en el Keychain con
///   `SecAccessControl(.biometryCurrentSet)` y
///   `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
///   Verificado leyendo la fuente 5.0.1 (BiometricStorageFile.kt,
///   BiometricStorageImpl.swift).
/// * Si el usuario añade/quita huellas o rostros, el SO invalida la llave y
///   el paquete borra el archivo → [readKey] devuelve `null` y se vuelve a
///   pedir el PIN. No se pierde nada: la DEK sigue envuelta por el PIN.
/// * Alternativas descartadas:
///   - `local_auth`: solo devuelve un booleano; no protege ningún secreto.
///   - `flutter_secure_storage` 10/11 (tiene `AndroidOptions.biometric` y
///     `accessControlFlags`): exige `win32 ^6`, incompatible con
///     `file_picker ^8` del proyecto, y en Android degrada en silencio si no
///     hay biometría (`enforceBiometrics: false`).
///   - `biometric_storage` 6.0.0-dev.*: muy activo, pero exige Flutter
///     >= 3.44 (el proyecto usa 3.41.6) y es prerelease.
/// * Versión fijada: 5.0.1 (última estable; el autor sigue publicando la
///   rama 6.x en nov-2026, así que el proyecto está mantenido).
///   Requisitos: minSdk 23, `MainActivity` = `FlutterFragmentActivity`, tema
///   AppCompat, permiso USE_BIOMETRIC, `NSFaceIDUsageDescription` en iOS y un
///   JDK 17 para compilar (Gradle lo descarga vía foojay; ver
///   android/settings.gradle.kts).
class SystemBiometricKeyStore implements BiometricKeyStore {
  SystemBiometricKeyStore({BiometricStorage? plugin})
    : _plugin = plugin ?? BiometricStorage();

  static const String _storageName = 'vault_dek_biometric';

  final BiometricStorage _plugin;

  static final PromptInfo _prompt = PromptInfo(
    androidPromptInfo: const AndroidPromptInfo(
      title: 'Desbloquear Vault',
      subtitle: 'Usa tu huella o rostro',
      negativeButton: 'Usar PIN',
      confirmationRequired: false,
    ),
    // iOS: textos del diálogo de Face ID / Touch ID.
    iosPromptInfo: const IosPromptInfo(
      saveTitle: 'Activar desbloqueo biométrico de Vault',
      accessTitle: 'Desbloquear Vault',
    ),
  );

  bool get _platformSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<BiometricStorageFile> _file() => _plugin.getStorage(
    _storageName,
    options: StorageFileInitOptions(
      // -1 = autenticación por cada uso (CryptoObject), sin ventana de
      // validez reutilizable.
      authenticationValidityDurationSeconds: -1,
      authenticationRequired: true,
      // Solo biometría fuerte; el PIN/patrón del sistema NO desbloquea.
      androidBiometricOnly: true,
      // iOS: .biometryCurrentSet (no acepta el código del dispositivo).
      darwinBiometricOnly: true,
    ),
    promptInfo: _prompt,
  );

  @override
  Future<BiometricAvailability> availability() async {
    if (!_platformSupported) return BiometricAvailability.unavailable;
    try {
      final response = await _plugin.canAuthenticate();
      switch (response) {
        case CanAuthenticateResponse.success:
          return BiometricAvailability.available;
        case CanAuthenticateResponse.errorNoBiometricEnrolled:
        case CanAuthenticateResponse.errorPasscodeNotSet:
          return BiometricAvailability.notEnrolled;
        default:
          return BiometricAvailability.unavailable;
      }
    } catch (_) {
      return BiometricAvailability.unavailable;
    }
  }

  @override
  Future<void> writeKey(Uint8List key) async {
    final file = await _file();
    try {
      // El prompt biométrico pasa la app a inactive: no debe contar para el autobloqueo.
      await AutoLockSuspension.instance.run(
        () => file.write(base64Encode(key)),
      );
    } on AuthException catch (e) {
      throw _mapAuth(e);
    }
  }

  @override
  Future<Uint8List?> readKey() async {
    final file = await _file();
    final String? content;
    try {
      content = await AutoLockSuspension.instance.run(() => file.read());
    } on AuthException catch (e) {
      throw _mapAuth(e);
    }
    if (content == null) return null;
    try {
      return base64Decode(content);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> deleteKey() async {
    if (!_platformSupported) return;
    final file = await _file();
    await file.delete();
  }

  Exception _mapAuth(AuthException e) {
    switch (e.code) {
      case AuthExceptionCode.userCanceled:
      case AuthExceptionCode.canceled:
      case AuthExceptionCode.timeout:
        return const BiometricCancelledException();
      default:
        return e;
    }
  }
}
