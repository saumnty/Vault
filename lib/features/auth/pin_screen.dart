import 'package:flutter/material.dart';
import '../../core/crypto/auth_controller.dart'; 

class PinScreen extends StatefulWidget {
  final VoidCallback onAuthenticated;

  const PinScreen({Key? key, required this.onAuthenticated}) : super(key: key);

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final AuthController _authController = AuthController(); 
  final TextEditingController _pinController = TextEditingController();
  bool _hasVault = false;
  bool _isLoading = true;
  String _statusMessage = 'Ingresa tu PIN maestro';

  @override
  void initState() {
    super.initState();
    _checkVaultStatus();
  }

  Future<void> _checkVaultStatus() async {
    final vaultExists = await _authController.hasVault();
    setState(() {
      _hasVault = vaultExists;
      _isLoading = false;
      _statusMessage = vaultExists ? 'Ingresa tu PIN maestro' : 'Crea un nuevo PIN';
    });
  }

  Future<void> _verifyPin() async {
    final pin = _pinController.text;
    if (pin.length < 4) return;

    if (_hasVault) {
      final isValid = await _authController.verifyPin(pin);
      if (isValid) {
        widget.onAuthenticated();
      } else {
        setState(() => _statusMessage = 'PIN Incorrecto');
      }
    } else {
      await _authController.createVault(pin);
      widget.onAuthenticated();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(backgroundColor: Color(0xFF0B0B0E), body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0E),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_statusMessage, style: const TextStyle(color: Colors.white, fontSize: 18)),
              const SizedBox(height: 20),
              TextField(
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: Colors.white, fontSize: 24),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(filled: true, fillColor: Color(0xFF18181C)),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _verifyPin,
                child: const Text('Continuar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}