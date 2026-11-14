import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/haptics.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/shake_widget.dart';
import 'widgets/auth_sheets.dart';
import 'widgets/pin_dots.dart';
import 'widgets/pin_keypad.dart';

/// Pantalla de PIN: crea la bóveda (primera vez) o la desbloquea.
class PinScreen extends StatefulWidget {
  final VoidCallback onAuthenticated;
  final AuthController? authController;

  /// Longitud máxima del PIN (se envía solo al completarla).
  static const int maxPinLength = 6;

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
  Timer? _lockTimer;

  String _pin = '';
  bool _hasVault = false;
  bool _isLoading = true;
  bool _isBusy = false;
  bool _biometricEnabled = false;
  bool _hasError = false;
  bool _unlocked = false;
  int _shakes = 0;

  /// Segundos de espera restantes por bloqueo (0 = sin bloqueo).
  int _lockSeconds = 0;
  String _statusMessage = _enterPin;

  static const String _enterPin = 'Ingresa tu PIN maestro';
  static const String _createPin = 'Crea un nuevo PIN';

  @override
  void initState() {
    super.initState();
    _checkVaultStatus();
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    super.dispose();
  }

  bool get _locked => _lockSeconds > 0;
  bool get _inputEnabled => !_isBusy && !_locked && !_unlocked;

  String get _title => _locked ? _lockoutMessage(_lockSeconds) : _statusMessage;

  String _lockoutMessage(int seconds) =>
      'Demasiados intentos. Espera $seconds s';

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
      _statusMessage = vaultExists ? _enterPin : _createPin;
    });
    if (lockout != null) _startLockout(lockout);
    if (biometricEnabled && lockout == null) {
      await _unlockWithBiometrics();
    }
  }

  /// Cuenta atrás visible del bloqueo; al llegar a 0 vuelve a consultar al
  /// limitador por si aún queda tiempo.
  void _startLockout(Duration remaining) {
    _lockTimer?.cancel();
    setState(() => _lockSeconds = remaining.inSeconds + 1);
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_lockSeconds > 1) {
        setState(() => _lockSeconds--);
        return;
      }
      timer.cancel();
      final still = await _authController.pinLockoutRemaining();
      if (!mounted) return;
      if (still != null) {
        _startLockout(still);
      } else {
        setState(() {
          _lockSeconds = 0;
          _statusMessage = _enterPin;
        });
      }
    });
  }

  // ---------------------------------------------------------------- entrada

  void _onDigit(int digit) {
    if (!_inputEnabled || _pin.length >= PinScreen.maxPinLength) return;
    setState(() {
      _pin += '$digit';
      if (_hasError) {
        _hasError = false;
        _statusMessage = _hasVault ? _enterPin : _createPin;
      }
    });
    if (_pin.length == PinScreen.maxPinLength) _submit();
  }

  void _onBackspace() {
    if (!_inputEnabled || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ch = event.character;
    if (ch != null && ch.length == 1 && '0123456789'.contains(ch)) {
      _onDigit(int.parse(ch));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _onBackspace();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ----------------------------------------------------------------- acciones

  Future<void> _fail(String message) async {
    AppHaptics.error();
    setState(() {
      _hasError = true;
      _shakes++;
      _statusMessage = message;
    });
    // Deja ver los puntos rojos durante la sacudida y luego limpia.
    await Future<void>.delayed(AppMotion.shake);
    if (mounted) setState(() => _pin = '');
  }

  Future<void> _submit() async {
    final pin = _pin;
    if (pin.length < AuthController.minPinLength || !_inputEnabled) return;

    setState(() {
      _isBusy = true;
      _statusMessage = _hasVault ? 'Verificando…' : 'Creando bóveda…';
    });
    try {
      if (_hasVault) {
        final isValid = await _authController.unlockWithPin(pin);
        if (isValid) {
          await _finishUnlock();
          return;
        }
        final lockout = await _authController.pinLockoutRemaining();
        await _fail('PIN incorrecto');
        if (lockout != null && mounted) _startLockout(lockout);
      } else {
        final result = await _authController.createVault(pin);
        if (!mounted) return;
        await showRecoveryCodeSheet(context, result.recoveryCode);
        if (!mounted) return;
        await _offerBiometrics();
        await _finishUnlock();
        return;
      }
    } on PinLockedOutException catch (e) {
      if (mounted) {
        setState(() => _pin = '');
        _startLockout(e.remaining);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pin = '';
          _statusMessage = 'Error: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Transición de desbloqueo: puntos en acento, háptica y fundido.
  Future<void> _finishUnlock() async {
    if (!mounted) return;
    AppHaptics.success();
    setState(() => _unlocked = true);
    await Future<void>.delayed(AppMotion.unlock);
    if (mounted) widget.onAuthenticated();
  }

  Future<void> _unlockWithBiometrics() async {
    try {
      final ok = await _authController.unlockWithBiometrics();
      if (ok) {
        await _finishUnlock();
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

  Future<void> _offerBiometrics() async {
    if (await _authController.biometricAvailability() !=
        BiometricAvailability.available) {
      return;
    }
    if (!mounted) return;
    if (!await showBiometricOfferSheet(context)) return;
    try {
      await _authController.enableBiometricUnlock();
    } catch (_) {
      // Cancelado o fallido: se puede activar más tarde (F8, ajustes).
    }
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: SafeArea(
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: AppSpacing.page,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - AppSpacing.page.vertical,
                ),
                child: Center(child: _content()),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    return AnimatedOpacity(
      opacity: _unlocked ? 0 : 1,
      duration: AppMotion.unlock,
      curve: AppMotion.emphasized,
      child: AnimatedScale(
        scale: _unlocked ? 1.06 : 1,
        duration: AppMotion.unlock,
        curve: AppMotion.emphasized,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LockBadge(open: _unlocked),
            const SizedBox(height: AppSpacing.xl),
            Semantics(
              liveRegion: true,
              child: Text(
                _title,
                textAlign: TextAlign.center,
                style: _hasError
                    ? AppTypography.titleSmall.copyWith(color: AppColors.danger)
                    : AppTypography.titleSmall,
              ),
            ),
            if (!_hasVault) ...[
              const SizedBox(height: AppSpacing.xs),
              const Text(
                'Elige de 4 a 6 dígitos',
                style: AppTypography.bodySecondary,
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            ShakeWidget(
              shakeCount: _shakes,
              child: PinDots(
                key: const ValueKey('pin-dots'),
                length: PinScreen.maxPinLength,
                filled: _pin.length,
                hasError: _hasError,
                success: _unlocked,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            PinKeypad(
              enabled: _inputEnabled,
              onDigit: _onDigit,
              onBackspace: _onBackspace,
              onBiometric: _hasVault && _biometricEnabled
                  ? _unlockWithBiometrics
                  : null,
            ),
            const SizedBox(height: AppSpacing.xl),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSizes.pinMaxWidth),
              child: SizedBox(
                width: double.infinity,
                child: AppFilledButton(
                  label: 'Continuar',
                  busy: _isBusy,
                  onPressed:
                      _inputEnabled &&
                          _pin.length >= AuthController.minPinLength
                      ? _submit
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockBadge extends StatelessWidget {
  const _LockBadge({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: AppSizes.keypadKey,
        height: AppSizes.keypadKey,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.accentContainer,
          boxShadow: AppShadows.glow,
        ),
        child: AnimatedSwitcher(
          duration: AppMotion.fast,
          child: Icon(
            open ? Icons.lock_open_rounded : Icons.lock_rounded,
            key: ValueKey(open),
            size: AppSizes.iconXl,
            color: AppColors.accentLight,
          ),
        ),
      ),
    );
  }
}
