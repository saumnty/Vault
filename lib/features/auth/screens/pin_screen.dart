import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../../core/crypto/auth_controller.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/security/session_manager.dart';
import '../../vault/screens/home_vault_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

class PinScreen extends StatefulWidget {
  const PinScreen({super.key});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final AuthController _authController = AuthController();
  final CryptoService _cryptoService = CryptoService();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final TextEditingController _pinController = TextEditingController();
  
  bool _isInitializing = true;
  bool _hasPin = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _checkExistingPin();
  }

  Future<void> _checkExistingPin() async {
    final hasPin = await _authController.hasMasterPin();
    if (!mounted) return;
    setState(() {
      _hasPin = hasPin;
      _isInitializing = false;
    });
  }

  Future<void> _handleSubmit() async {
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      setState(() {
        _errorMessage = 'El PIN debe tener al menos 4 dígitos.';
      });
      return;
    }

    setState(() {
      _errorMessage = '';
    });

    if (_hasPin) {
      try {
        final saltString = await _secureStorage.read(key: 'vault_master_salt');
        if (saltString != null) {
          final salt = base64Decode(saltString);
          final key = await _cryptoService.deriveKeyFromPin(pin, salt);
          
          final isValid = await _authController.verifyMasterPin(pin);
          if (isValid) {
            SessionManager.setMasterKey(key);

            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              CupertinoPageRoute(
                // Sin 'const' para evitar errores de compilación
                builder: (context) => const HomeVaultScreen(),
              ),
            );
            return;
          }
        }
        setState(() {
          _errorMessage = 'PIN incorrecto. Inténtalo de nuevo.';
        });
      } catch (e) {
        setState(() {
          _errorMessage = 'Error al validar el acceso.';
        });
      }
    } else {
      await _authController.setupMasterPin(pin);
      if (!mounted) return;
      setState(() {
        _hasPin = true;
        _pinController.clear();
        _errorMessage = '¡PIN configurado con éxito! Ingrésalo para entrar.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return const Scaffold(
        backgroundColor: Color(0xFF0F0F13),
        body: Center(child: CircularProgressIndicator(color: Colors.deepPurple)),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F13),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.shield_rounded,
                  size: 80,
                  color: Colors.deepPurpleAccent,
                ),
                const SizedBox(height: 24),
                Text(
                  _hasPin ? 'Desbloquear Vault' : 'Crea tu PIN Maestro',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _hasPin
                      ? 'Ingresa tu PIN para acceder a tus datos'
                      : 'Esta contraseña cifrará toda tu información localmente',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[400], fontSize: 14),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 8),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '••••',
                    hintStyle: TextStyle(color: Colors.grey[600]),
                    filled: true,
                    fillColor: const Color(0xFF1E1E24),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.deepPurpleAccent, width: 2),
                    ),
                  ),
                ),
                if (_errorMessage.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _handleSubmit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _hasPin ? 'Entrar' : 'Configurar PIN',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}