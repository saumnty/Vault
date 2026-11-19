import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/app_paths.dart';
import 'security_preferences.dart';

/// Canal `vault/security` hacia código nativo.
///
/// TRES mecanismos distintos (ver D26 en DECISIONES.md):
/// * Android: `setSecure` -> FLAG_SECURE (capturas, grabación, miniatura en
///   recientes);
/// * iOS: cobertura del selector de apps (SceneDelegate, nativo) + el
///   `PrivacyCover` de Flutter;
/// * iOS: `excludeFromBackup` -> NSURLIsExcludedFromBackupKey (iCloud).
class PlatformSecurity {
  PlatformSecurity({MethodChannel? channel, bool? isAndroid, bool? isIOS})
    : _channel = channel ?? const MethodChannel(channelName),
      _isAndroid = isAndroid ?? Platform.isAndroid,
      _isIOS = isIOS ?? Platform.isIOS;

  static const String channelName = 'vault/security';
  static final PlatformSecurity instance = PlatformSecurity();

  final MethodChannel _channel;
  final bool _isAndroid;
  final bool _isIOS;

  /// Android: activa/desactiva FLAG_SECURE. No hace nada en otras plataformas.
  Future<void> setSecure(bool secure) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } on PlatformException catch (e) {
      debugPrint('setSecure falló: ${e.code}');
    } on MissingPluginException {
      debugPrint('setSecure: canal no disponible');
    }
  }

  /// iOS: excluye [paths] (absolutas) del respaldo de iCloud/iTunes. No hace
  /// nada en otras plataformas. // iOS: sin probar en dispositivo.
  Future<void> excludeFromBackup(List<String> paths) async {
    if (!_isIOS || paths.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('excludeFromBackup', {'paths': paths});
    } on PlatformException catch (e) {
      debugPrint('excludeFromBackup falló: ${e.code}');
    } on MissingPluginException {
      debugPrint('excludeFromBackup: canal no disponible');
    }
  }

  /// Rutas absolutas de todo lo que cuelga de [AppPaths] (vault/, thumbs/,
  /// db/ y la caché).
  static List<String> vaultPaths() => [
    AppPaths.vaultDir.path,
    AppPaths.thumbsDir.path,
    AppPaths.dbDir.path,
    AppPaths.cacheDir.path,
  ];

  /// Marca las carpetas del vault como excluidas del respaldo (se repite en
  /// cada arranque por si el sistema limpió el atributo). Las carpetas de la
  /// bóveda principal se crean antes si faltan.
  ///
  /// Fase 8 (M2): la raíz de la bóveda secundaria (`alt/`) se excluye SOLO si
  /// ya existe y nunca se crea aquí (un arranque sin secundaria no escribe
  /// nada nuevo en disco). // iOS: sin probar en dispositivo.
  Future<void> excludeVaultFromBackup() async {
    for (final d in [
      AppPaths.vaultDir,
      AppPaths.thumbsDir,
      AppPaths.dbDir,
      AppPaths.cacheDir,
    ]) {
      if (!d.existsSync()) d.createSync(recursive: true);
    }
    final secondary = VaultPaths.secondary.root;
    await excludeFromBackup([
      ...vaultPaths(),
      if (secondary.existsSync()) secondary.path,
    ]);
  }
}

/// "Proteger pantalla": decide y aplica FLAG_SECURE.
class ScreenProtection {
  ScreenProtection({
    required ScreenProtectionPreferences preferences,
    PlatformSecurity? platform,
    bool? allowScreenshotsDefine,
    bool? releaseMode,
  }) : _prefs = preferences,
       _platform = platform ?? PlatformSecurity.instance,
       _allowDefine = allowScreenshotsDefine ?? _allowScreenshotsDefine,
       _release = releaseMode ?? kReleaseMode;

  static const bool _allowScreenshotsDefine = bool.fromEnvironment(
    'VAULT_ALLOW_SCREENSHOTS',
  );

  final ScreenProtectionPreferences _prefs;
  final PlatformSecurity _platform;
  final bool _allowDefine;
  final bool _release;

  /// `true` si el define de depuración fuerza la protección apagada. SOLO en
  /// builds que no son release: en release el define se ignora.
  bool get overriddenOff => !_release && _allowDefine;

  /// Lo que el usuario eligió en Ajustes (ignora el define de depuración).
  Future<bool> isPreferenceEnabled() => _prefs.getProtect();

  Future<bool> isEnabled() async {
    if (overriddenOff) return false;
    return _prefs.getProtect();
  }

  /// Aplica el estado actual (arranque).
  Future<void> apply() async => _platform.setSecure(await isEnabled());

  /// Cambia la preferencia (ajustes, F8) y la aplica.
  Future<void> setEnabled(bool value) async {
    await _prefs.setProtect(value);
    await apply();
  }
}
