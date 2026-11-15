import 'package:flutter/material.dart';

import '../../../core/crypto/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/haptics.dart';
import '../../../shared/navigation/app_page_route.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/shake_widget.dart';
import '../pin_screen.dart';
import 'pin_dots.dart';
import 'pin_keypad.dart';

/// Valida/usa el PIN tecleado. Devuelve el texto de error (en español) o
/// `null` si se aceptó (entonces la pantalla se cierra con `true`).
typedef PinSubmit = Future<String?> Function(String pin);

/// Abre [PinPromptScreen] y devuelve `true` si el PIN fue aceptado, `false`
/// si el usuario volvió atrás.
Future<bool> showPinPrompt(
  BuildContext context, {
  required String title,
  String? message,
  required PinSubmit onSubmit,
  int minLength = AuthController.minPinLength,
}) async {
  final result = await Navigator.of(context).push<bool>(
    AppPageRoute<bool>(
      builder: (_) => PinPromptScreen(
        title: title,
        message: message,
        onSubmit: onSubmit,
        minLength: minLength,
      ),
    ),
  );
  return result ?? false;
}

/// Pantalla completa para pedir un PIN (cambiar PIN, generar un código de
/// recuperación nuevo...). Misma entrada que la pantalla de PIN: puntos +
/// teclado propio, 4 a 6 dígitos, envío automático al llegar a 6.
class PinPromptScreen extends StatefulWidget {
  const PinPromptScreen({
    super.key,
    required this.title,
    required this.onSubmit,
    this.message,
    this.minLength = AuthController.minPinLength,
  });

  final String title;
  final String? message;
  final PinSubmit onSubmit;
  final int minLength;

  @override
  State<PinPromptScreen> createState() => _PinPromptScreenState();
}

class _PinPromptScreenState extends State<PinPromptScreen> {
  String _pin = '';
  String? _error;
  bool _busy = false;
  int _shakes = 0;

  bool get _enabled => !_busy;

  void _onDigit(int digit) {
    if (!_enabled || _pin.length >= PinScreen.maxPinLength) return;
    setState(() {
      _pin += '$digit';
      _error = null;
    });
    if (_pin.length == PinScreen.maxPinLength) _submit();
  }

  void _onBackspace() {
    if (!_enabled || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    final pin = _pin;
    if (pin.length < widget.minLength || !_enabled) return;
    setState(() => _busy = true);
    String? error;
    try {
      error = await widget.onSubmit(pin);
    } on Object catch (e) {
      error = 'Error: $e';
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    AppHaptics.error();
    setState(() {
      _busy = false;
      _error = error;
      _shakes++;
    });
    await Future<void>.delayed(AppMotion.shake);
    if (mounted) setState(() => _pin = '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: AppIconButton(
                icon: Icons.arrow_back,
                label: 'Volver',
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).pop(false),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: AppSpacing.page,
                child: Column(
                  children: [
                    Semantics(
                      header: true,
                      liveRegion: true,
                      child: Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: AppTypography.titleSmall,
                      ),
                    ),
                    if (widget.message != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        widget.message!,
                        textAlign: TextAlign.center,
                        style: AppTypography.bodySecondary,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: AppTypography.bodySecondary.copyWith(
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    ShakeWidget(
                      shakeCount: _shakes,
                      child: PinDots(
                        key: const ValueKey('pin-dots'),
                        length: PinScreen.maxPinLength,
                        filled: _pin.length,
                        hasError: _error != null,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    PinKeypad(
                      enabled: _enabled,
                      onDigit: _onDigit,
                      onBackspace: _onBackspace,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppSizes.pinMaxWidth,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: AppFilledButton(
                          label: 'Continuar',
                          busy: _busy,
                          onPressed: _enabled && _pin.length >= widget.minLength
                              ? _submit
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
