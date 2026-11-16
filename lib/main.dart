import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/crypto/aes_gcm_backend.dart';
import 'core/crypto/auth_controller.dart';
import 'core/crypto/secure_kv_store.dart';
import 'core/logging/vault_log.dart';
import 'core/security/auto_lock.dart';
import 'core/security/platform_security.dart';
import 'core/security/security_preferences.dart';
import 'core/services/app_paths.dart';
import 'core/services/plain_residue.dart';
import 'core/services/plain_temp_manager.dart';
import 'core/theme/app_motion.dart';
import 'core/theme/app_theme.dart';
import 'data/cloud/cloud_provider.dart';
import 'data/gallery/import_preferences.dart';
import 'data/gallery/photo_manager_gallery_source.dart';
import 'data/gallery/video_compress_plugin.dart';
import 'data/gallery/video_compressor.dart';
import 'data/repositories/vault_database.dart';
import 'data/restore/restore_service.dart';
import 'data/sync/sync_preferences.dart';
import 'features/auth/pin_screen.dart';
import 'features/onboarding/onboarding_flow.dart';
import 'features/settings/settings_environment.dart';
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
    // S-02: copias en claro del selector de archivos (Android) y temporales
    // de la importación de la galería que quedaron de un cierre abrupto.
    await PlainResidue.sweepAtStartup();
    // S-03: miniaturas en claro de Glide / copias pm_* de photo_manager.
    await PhotoManagerGallerySource.clearPhotoManagerCaches();
  } on Object catch (e) {
    VaultLog.e('No se pudo barrer temporales en claro', e);
  }
  // S-16: caché de compresión de video (en claro) al arrancar; best-effort.
  await sweepVideoCompressorCacheAtStartup(VideoCompressPlugin());

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
    VaultLog.e('No se pudo aplicar la seguridad del sistema', e);
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
    this.restoreService,
  });

  /// Inyectables para pruebas; por defecto usan almacenamiento, biometría y
  /// base de datos reales.
  final AuthController? authController;
  final VaultServices? services;
  final AutoLockClock? autoLockClock;
  final AutoLockSuspension? autoLockSuspension;
  final AutoLockDelay? autoLockDelay;

  /// Pruebas: servicio de restauración (F9).
  final RestoreService? restoreService;

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
        restoreService: restoreService,
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
    this.restoreService,
  });

  final AuthController? authController;
  final VaultServices? services;

  /// Pruebas: reloj, suspensión y tiempo del autobloqueo. Con
  /// [autoLockDelay] nulo se carga la preferencia persistida.
  final AutoLockClock? autoLockClock;
  final AutoLockSuspension? autoLockSuspension;
  final AutoLockDelay? autoLockDelay;
  final RestoreService? restoreService;

  @override
  State<VaultRootNavigator> createState() => _VaultRootNavigatorState();
}

enum _Phase { loading, onboarding, pin, vault }

class _VaultRootNavigatorState extends State<VaultRootNavigator> {
  late final AuthController _authController =
      widget.authController ?? AuthController();
  _Phase _phase = _Phase.loading;

  /// Reapertura a mitad del onboarding: la bóveda existe pero falta confirmar
  /// el código de recuperación.
  bool _resumeOnboarding = false;

  /// La bóveda ya existe (creada en este proceso o antes): un bloqueo en el
  /// onboarding vuelve a la pantalla de PIN.
  bool _vaultExists = false;

  /// Código de recuperación recién creado, SOLO en memoria y solo hasta que
  /// el usuario lo confirma. Si el proceso muere se pierde (y se ofrece
  /// generar uno nuevo).
  String? _pendingCode;

  VaultServices? _realServices;
  RestoreService? _restoreService;

  RestoreService get _restore =>
      widget.restoreService ??
      (_restoreService ??= RestoreService(
        cloud: CloudProvider.instance,
        auth: _authController,
        prefs: SyncPreferences(FlutterSecureKeyValueStore()),
      ));

  VaultServices get _services =>
      widget.services ?? (_realServices ??= VaultServices.real());

  late final AutoLockController _autoLock = AutoLockController(
    onLock: _lock,
    preferences: widget.autoLockDelay == null
        ? AutoLockPreferences(FlutterSecureKeyValueStore())
        : null,
    clock: widget.autoLockClock,
    suspension: widget.autoLockSuspension,
    initialDelay: widget.autoLockDelay ?? AutoLockDelay.defaultValue,
  );

  late final SettingsEnvironment _settings = SettingsEnvironment(
    auth: _authController,
    autoLock: _autoLock,
    screenProtection: ScreenProtection(
      preferences: ScreenProtectionPreferences(FlutterSecureKeyValueStore()),
    ),
    importPreferences: GalleryImportPreferences(FlutterSecureKeyValueStore()),
    onLock: _autoLock.lockNow,
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
    _bootstrap();
  }

  /// Sin bóveda -> onboarding; con bóveda -> PIN (y, si el onboarding quedó a
  /// medias, tras el PIN se vuelve al paso del código).
  Future<void> _bootstrap() async {
    var hasVault = await _authController.hasVault();
    // F9 (iOS): llaves en el Keychain de una instalación anterior, sin BD.
    if (Platform.isIOS &&
        hasVault &&
        AppPaths.isInitialized &&
        !await _authController.isOnboardingPending() &&
        !File(VaultDatabase.defaultDbPath).existsSync()) {
      await _authController.discardLocalKeys();
      hasVault = false;
    }
    // F9: sin bóveda no puede haber BD ni miniaturas válidas (restos de una
    // restauración interrumpida durante la instalación).
    if (!hasVault && widget.restoreService == null) {
      await RestoreService.sweepOrphans();
    }
    if (!mounted) return;
    setState(() {
      _vaultExists = hasVault;
      _phase = hasVault ? _Phase.pin : _Phase.onboarding;
    });
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
    // F9: con cambios sin respaldar, la copia cifrada de la BD se toma ANTES
    // de destruir las llaves (la interfaz ya vuelve al PIN de inmediato).
    final flush = _phase == _Phase.vault && _authController.isUnlocked
        ? _services.beforeLock
        : null;
    if (flush == null) {
      _authController.lock();
    } else {
      unawaited(
        flush()
            .timeout(const Duration(seconds: 3))
            .catchError((Object _) {})
            .whenComplete(_authController.lock),
      );
    }
    if (!mounted) return;
    final inVault = _phase == _Phase.vault;
    // En el onboarding SIN bóveda todavía no hay nada que bloquear.
    final inOnboardingWithVault = _phase == _Phase.onboarding && _vaultExists;
    if (!inVault && !inOnboardingWithVault) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() {
      _resumeOnboarding = inOnboardingWithVault;
      _phase = _Phase.pin;
    });
  }

  Future<void> _handleAuthenticationSuccess() async {
    // Si se bloqueó durante la animación de desbloqueo, no se abre la bóveda.
    if (!_authController.isUnlocked) return;
    final pending = await _authController.isOnboardingPending();
    if (!mounted || !_authController.isUnlocked) return;
    setState(() {
      _resumeOnboarding = pending;
      _phase = pending ? _Phase.onboarding : _Phase.vault;
    });
  }

  void _finishOnboarding() {
    if (!mounted) return;
    setState(() {
      _pendingCode = null;
      _resumeOnboarding = false;
      _phase = _authController.isUnlocked ? _Phase.vault : _Phase.pin;
    });
  }

  Widget _body() {
    switch (_phase) {
      case _Phase.loading:
        return const Scaffold(
          key: ValueKey('loading'),
          body: Center(child: CircularProgressIndicator()),
        );
      case _Phase.onboarding:
        return OnboardingFlow(
          key: ValueKey('onboarding-$_resumeOnboarding'),
          auth: _authController,
          resume: _resumeOnboarding,
          recoveryCode: _pendingCode,
          syncProvider: () => _services.sync,
          onVaultCreated: (code) {
            _vaultExists = true;
            _pendingCode = code;
          },
          onRecoveryConfirmed: () => _pendingCode = null,
          restoreProvider: () => _restore,
          onVaultRestored: () => _vaultExists = true,
          onFinished: _finishOnboarding,
        );
      case _Phase.pin:
        return PinScreen(
          key: const ValueKey('pin'),
          authController: _authController,
          onAuthenticated: _handleAuthenticationSuccess,
        );
      case _Phase.vault:
        // null indica la raíz de la bóveda
        return HomeVaultScreen(
          key: const ValueKey('vault'),
          currentFolderId: null,
          currentFolderName: 'Mi Bóveda',
          services: _services,
          onLock: _autoLock.lockNow,
          settings: _settings,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Transición suave entre el muro de seguridad y la bóveda.
    return AnimatedSwitcher(
      duration: AppMotion.medium,
      switchInCurve: AppMotion.standard,
      child: _body(),
    );
  }
}
