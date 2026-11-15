import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/crypto/aes_gcm_backend.dart';
import 'core/crypto/auth_controller.dart';
import 'core/services/app_paths.dart';
import 'core/services/plain_temp_manager.dart';
import 'core/theme/app_motion.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/pin_screen.dart';
import 'features/vault/home_vault_screen.dart';
import 'features/vault/vault_services.dart';

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
  const VaultApp({super.key, this.authController, this.services});

  /// Inyectables para pruebas; por defecto usan almacenamiento, biometría y
  /// base de datos reales.
  final AuthController? authController;
  final VaultServices? services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // El punto de entrada inicial arranca en la pantalla de PIN / Autenticación
      home: VaultRootNavigator(
        authController: authController,
        services: services,
      ),
    );
  }
}

/// Administrador de rutas raíz que decide entre el muro de seguridad y la bóveda
class VaultRootNavigator extends StatefulWidget {
  const VaultRootNavigator({super.key, this.authController, this.services});

  final AuthController? authController;
  final VaultServices? services;

  @override
  State<VaultRootNavigator> createState() => _VaultRootNavigatorState();
}

class _VaultRootNavigatorState extends State<VaultRootNavigator> {
  late final AuthController _authController =
      widget.authController ?? AuthController();
  bool _isAuthenticated = false;

  void _handleAuthenticationSuccess() {
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
            )
          : PinScreen(
              key: const ValueKey('pin'),
              authController: _authController,
              onAuthenticated: _handleAuthenticationSuccess,
            ),
    );
  }
}
