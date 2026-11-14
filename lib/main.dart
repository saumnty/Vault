import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/crypto/auth_controller.dart';
import 'features/auth/pin_screen.dart';
import 'features/vault/home_vault_screen.dart';

void main() async {
  // Asegurar la inicialización de los bindings de Flutter
  WidgetsFlutterBinding.ensureInitialized();

  // Forzar orientación vertical para mantener la estética y seguridad de la app
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Configurar la barra de estado transparente con iconos claros (estética OLED)
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0B0B0E),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const VaultApp());
}

class VaultApp extends StatelessWidget {
  const VaultApp({super.key, this.authController});

  /// Inyectable para pruebas; por defecto usa almacenamiento y biometría reales.
  final AuthController? authController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      // Definir tema oscuro global basado en la paleta OLED y morado neón
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0B0E),
        primaryColor: const Color(0xFF7C3AED),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF7C3AED),
          secondary: Color(0xFF3B82F6),
          surface: Color(0xFF18181C),
        ),
        fontFamily: 'Inter', // O tu tipografía predeterminada
      ),
      // El punto de entrada inicial arranca en la pantalla de PIN / Autenticación
      home: VaultRootNavigator(authController: authController),
    );
  }
}

/// Administrador de rutas raíz que decide entre el muro de seguridad y la bóveda
class VaultRootNavigator extends StatefulWidget {
  const VaultRootNavigator({super.key, this.authController});

  final AuthController? authController;

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
    if (!_isAuthenticated) {
      // Si no está autenticado, mostramos obligatoriamente el PinScreen
      return PinScreen(
        authController: _authController,
        onAuthenticated: _handleAuthenticationSuccess,
      );
    } else {
      // Una vez superado el PIN o la biometría, entramos a la raíz de la Bóveda
      return const HomeVaultScreen(
        currentFolderId: null, // null indica la raíz de la bóveda
        currentFolderName: 'Mi Bóveda',
      );
    }
  }
}
