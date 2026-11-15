import 'package:package_info_plus/package_info_plus.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/security/auto_lock.dart';
import '../../core/security/platform_security.dart';
import '../../data/gallery/import_preferences.dart';

/// Versión de la app para "Acerca de".
class AppVersion {
  const AppVersion({required this.version, required this.build});

  final String version;
  final String build;

  @override
  String toString() => build.isEmpty ? version : '$version ($build)';
}

typedef AppVersionLoader = Future<AppVersion> Function();

/// Lee la versión del paquete (pubspec `version: x.y.z+build`) con
/// `package_info_plus`.
Future<AppVersion> loadAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return AppVersion(version: info.version, build: info.buildNumber);
}

/// Dependencias de Ajustes que viven en la raíz de la app (inyectables en
/// pruebas). Los servicios de datos (sincronización, almacenamiento) llegan
/// por `VaultServices`.
class SettingsEnvironment {
  const SettingsEnvironment({
    required this.auth,
    required this.autoLock,
    required this.screenProtection,
    required this.importPreferences,
    required this.onLock,
    this.versionLoader = loadAppVersion,
  });

  final AuthController auth;

  /// El MISMO controlador que escucha el ciclo de vida: cambiar su tiempo
  /// aplica en caliente.
  final AutoLockController autoLock;
  final ScreenProtection screenProtection;
  final GalleryImportPreferences importPreferences;

  /// "Bloquear ahora".
  final void Function() onLock;
  final AppVersionLoader versionLoader;
}
