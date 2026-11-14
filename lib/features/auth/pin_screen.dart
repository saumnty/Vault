import 'package:flutter/material.dart';
import '../../core/crypto/auth_controller.dart';

class PinScreen extends StatefulWidget {
  final VoidCallback onAuthenticated;
  final AuthController? authController;

  const PinScreen({
    super.key,
    required this.onAuthenticated,
    this.authController,
  });

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  late final AuthController _authController =
      widget.authController ?? AuthController();
  final TextEditingController _pinController = TextEditingController();
  bool _hasVault = false;
  bool _isLoading = true;
  bool _isBusy = false;
  bool _biometricEnabled = false;
  String _statusMessage = 'Ingresa tu PIN maestro';

  @override
  void initState() {
    super.initState();
    _checkVaultStatus();
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _checkVaultStatus() async {
    final vaultExists = await _authController.hasVault();
    final biometricEnabled =
        vaultExists && await _authController.isBiometricUnlockEnabled();
    final lockout = vaultExists
        ? await _authController.pinLockoutRemaining()
        : null;
    if (!mounted) return;
    setState(() {
      _hasVault = vaultExists;
      _biometricEnabled = biometricEnabled;
      _isLoading = false;
      _statusMessage = !vaultExists
          ? 'Crea un nuevo PIN'
          : lockout != null
          ? _lockoutMessage(lockout)
          : 'Ingresa tu PIN maestro';
    });
    if (biometricEnabled && lockout == null) {
      await _unlockWithBiometrics();
    }
  }

  String _lockoutMessage(Duration remaining) {
    final seconds = remaining.inSeconds + 1;
    return 'Demasiados intentos. Espera $seconds s';
  }

  Future<void> _verifyPin() async {
    final pin = _pinController.text;
    if (pin.length < AuthController.minPinLength || _isBusy) return;

    setState(() {
      _isBusy = true;
      _statusMessage = _hasVault ? 'Verificando…' : 'Creando bóveda…';
    });
    try {
      if (_hasVault) {
        final isValid = await _authController.unlockWithPin(pin);
        if (isValid) {
          widget.onAuthenticated();
          return;
        }
        final lockout = await _authController.pinLockoutRemaining();
        _pinController.clear();
        if (mounted) {
          setState(
            () => _statusMessage = lockout != null
                ? _lockoutMessage(lockout)
                : 'PIN Incorrecto',
          );
        }
      } else {
        final result = await _authController.createVault(pin);
        if (!mounted) return;
        await _showRecoveryCode(result.recoveryCode);
        if (!mounted) return;
        await _offerBiometrics();
        widget.onAuthenticated();
        return;
      }
    } on PinLockedOutException catch (e) {
      _pinController.clear();
      if (mounted) {
        setState(() => _statusMessage = _lockoutMessage(e.remaining));
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _unlockWithBiometrics() async {
    try {
      final ok = await _authController.unlockWithBiometrics();
      if (ok) {
        widget.onAuthenticated();
        return;
      }
      // Llave invalidada (cambio de huellas/rostro) o desactivada.
      if (mounted) {
        setState(() {
          _biometricEnabled = false;
          _statusMessage = 'Biometría desactivada. Ingresa tu PIN maestro';
        });
      }
    } on BiometricCancelledException {
      // El usuario prefirió el PIN.
    } catch (_) {
      if (mounted) {
        setState(() => _statusMessage = 'No se pudo usar la biometría');
      }
    }
  }

  /// Muestra el código de recuperación UNA sola vez (no se guarda en claro).
  Future<void> _showRecoveryCode(String code) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF18181C),
        title: const Text(
          'Código de recuperación',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Anótalo y guárdalo fuera del teléfono. Es la única forma de '
              'recuperar tu bóveda si olvidas el PIN o cambias de teléfono. '
              'No se volverá a mostrar.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            SelectableText(
              code,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontFamily: 'monospace',
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        actions: [
          // Sin botón "Copiar" a propósito: el portapapeles es legible por
          // otras apps y por la sincronización de portapapeles del sistema.
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Ya lo guardé'),
          ),
        ],
      ),
    );
  }

  Future<void> _offerBiometrics() async {
    if (await _authController.biometricAvailability() !=
        BiometricAvailability.available) {
      return;
    }
    if (!mounted) return;
    final accept = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF18181C),
        title: const Text(
          'Desbloqueo biométrico',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '¿Quieres desbloquear Vault con tu huella o rostro?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Ahora no'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Activar'),
          ),
        ],
      ),
    );
    if (accept != true) return;
    try {
      await _authController.enableBiometricUnlock();
    } catch (_) {
      // Cancelado o fallido: se puede activar más tarde (F8, ajustes).
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B0B0E),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0E),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                enabled: !_isBusy,
                style: const TextStyle(color: Colors.white, fontSize: 24),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF18181C),
                ),
                onSubmitted: (_) => _verifyPin(),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isBusy ? null : _verifyPin,
                child: _isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Continuar'),
              ),
              if (_hasVault && _biometricEnabled) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _isBusy ? null : _unlockWithBiometrics,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Usar biometría'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
