import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/crypto/aes_gcm_backend.dart';
import 'core/crypto/auth_controller.dart';
import 'core/crypto/secure_kv_store.dart';
import 'core/security/auto_lock.dart';
import 'core/security/platform_security.dart';
import 'core/security/security_preferences.dart';
import 'core/services/app_paths.dart';
import 'core/services/plain_temp_manager.dart';
import 'core/theme/app_motion.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/pin_screen.dart';
import 'features/vault/home_vault_screen.dart';
import 'features/vault/vault_services.dart';
import 'shared/widgets/privacy_cover.dart';

void main() async {
  // Asegurar la inicialización de los bindings de Flutter
  WidgetsFlutterBinding.ensureInitialized();

  // D22: AES-GCM nativo (cryptography_flutter) con respaldo Dart; el resto de
  // primitivas siguen en Dart. Antes de cualquier operación criptográfica.
  configureCryptography();

  // F6a: por si la app se cerró de forma abrupta con un video descifrado en
  // disco, se barre la carpeta de temporales en claro al arrancar.
  try {
    await AppPaths.init();
    await PlainTempManager.instance.sweep();
  } on Object catch (e) {
    debugPrint('No se pudo barrer tmp_plain: $e');
  }

  // F7: seguridad del sistema, ANTES de dibujar la primera pantalla.
  // Android: FLAG_SECURE según la preferencia "Proteger pantalla" (activa por
  // defecto; el nativo ya lo activa en onCreate y aquí se apaga si procede).
  // iOS: excluir vault/, thumbs/, db/ y la caché del respaldo de iCloud (se
  // repite en cada arranque). iOS: sin probar en dispositivo.
  try {
    await ScreenProtection(
      preferences: ScreenProtectionPreferences(FlutterSecureKeyValueStore()),
    ).apply();
    if (Platform.isIOS && AppPaths.isInitialized) {
      await PlatformSecurity.instance.excludeVaultFromBackup();
    }
  } on Object catch (e) {
    debugPrint('No se pudo aplicar la seguridad del sistema: $e');
  }

  // Forzar orientación vertical para mantener la estética y seguridad de la app
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Barra de estado transparente con iconos claros (estética OLED)
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);

  runApp(const VaultApp());
}

class VaultApp extends StatelessWidget {
  const VaultApp({
    super.key,
    this.authController,
    this.services,
    this.autoLockClock,
    this.autoLockSuspension,
    this.autoLockDelay,
  });

  /// Inyectables para pruebas; por defecto usan almacenamiento, biometría y
  /// base de datos reales.
  final AuthController? authController;
  final VaultServices? services;
  final AutoLockClock? autoLockClock;
  final AutoLockSuspension? autoLockSuspension;
  final AutoLockDelay? autoLockDelay;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // F7: capa de privacidad multiplataforma sobre TODA la app (rutas,
      // diálogos y hojas incluidos) cuando no está activa.
      builder: (context, child) =>
          PrivacyCover(child: child ?? const SizedBox.shrink()),
      // El punto de entrada inicial arranca en la pantalla de PIN / Autenticación
      home: VaultRootNavigator(
        authController: authController,
        services: services,
        autoLockClock: autoLockClock,
        autoLockSuspension: autoLockSuspension,
        autoLockDelay: autoLockDelay,
      ),
    );
  }
}

/// Administrador de rutas raíz que decide entre el muro de seguridad y la bóveda
class VaultRootNavigator extends StatefulWidget {
  const VaultRootNavigator({
    super.key,
    this.authController,
    this.services,
    this.autoLockClock,
    this.autoLockSuspension,
    this.autoLockDelay,
  });

  final AuthController? authController;
  final VaultServices? services;

  /// Pruebas: reloj, suspensión y tiempo del autobloqueo. Con
  /// [autoLockDelay] nulo se carga la preferencia persistida.
  final AutoLockClock? autoLockClock;
  final AutoLockSuspension? autoLockSuspension;
  final AutoLockDelay? autoLockDelay;

  @override
  State<VaultRootNavigator> createState() => _VaultRootNavigatorState();
}

class _VaultRootNavigatorState extends State<VaultRootNavigator> {
  late final AuthController _authController =
      widget.authController ?? AuthController();
  bool _isAuthenticated = false;

  late final AutoLockController _autoLock = AutoLockController(
    onLock: _lock,
    preferences: widget.autoLockDelay == null
        ? AutoLockPreferences(FlutterSecureKeyValueStore())
        : null,
    clock: widget.autoLockClock,
    suspension: widget.autoLockSuspension,
    initialDelay: widget.autoLockDelay ?? AutoLockDelay.defaultValue,
  );

  @override
  void initState() {
    super.initState();
    _autoLock.attach();
    if (widget.autoLockDelay == null) {
      _autoLock.load().then((_) {
        // Depuración: `--dart-define=VAULT_AUTOLOCK_MS=15000` fija el tiempo
        // (solo fuera de release; sirve para probar en emulador).
        const dbg = String.fromEnvironment('VAULT_AUTOLOCK_MS');
        final ms = int.tryParse(dbg);
        if (!kReleaseMode && ms != null) {
          _autoLock.setDelay(AutoLockDelay.fromMillis(ms));
        }
      });
    }
  }

  @override
  void dispose() {
    _autoLock.detach();
    super.dispose();
  }

  /// Bloqueo (manual o automático): cierra la sesión (BD, temporales en
  /// claro, visor, servidor de streaming, subidas), CANCELA cualquier
  /// desbloqueo en curso y vuelve a la pantalla de PIN con la pila de
  /// navegación vacía (visor, hojas y diálogos incluidos).
  void _lock() {
    _authController.lock();
    if (!_isAuthenticated || !mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() => _isAuthenticated = false);
  }

  void _handleAuthenticationSuccess() {
    // Si se bloqueó durante la animación de desbloqueo, no se abre la bóveda.
    if (!_authController.isUnlocked) return;
    setState(() {
      _isAuthenticated = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Transición suave entre el muro de seguridad y la bóveda.
    return AnimatedSwitcher(
      duration: AppMotion.medium,
      switchInCurve: AppMotion.standard,
      child: _isAuthenticated
          // null indica la raíz de la bóveda
          ? HomeVaultScreen(
              key: const ValueKey('vault'),
              currentFolderId: null,
              currentFolderName: 'Mi Bóveda',
              services: widget.services,
              onLock: _autoLock.lockNow,
            )
          : PinScreen(
              key: const ValueKey('pin'),
              authController: _authController,
              onAuthenticated: _handleAuthenticationSuccess,
            ),
    );
  }
}
