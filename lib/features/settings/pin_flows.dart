import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/theme/app_spacing.dart';
import '../../shared/navigation/app_page_route.dart';
import '../auth/widgets/pin_prompt_screen.dart';
import '../onboarding/widgets/recovery_code_steps.dart';

String _lockoutText(PinLockedOutException e) =>
    'Demasiados intentos. Espera ${e.remaining.inSeconds + 1} s';

/// Cambiar PIN: PIN actual -> PIN nuevo -> confirmación. Vuelve a envolver la
/// misma DEK ([AuthController.changePin]); no recifra archivos. Si el PIN
/// actual era incorrecto, vuelve a pedirlo con un aviso. Devuelve `true` si
/// se cambió.
Future<bool> runChangePinFlow(BuildContext context, AuthController auth) async {
  var wrongCurrent = false;
  while (true) {
    if (!context.mounted) return false;
    String? oldPin;
    String? newPin;
    var ok = await showPinPrompt(
      context,
      title: 'PIN actual',
      message: wrongCurrent
          ? 'El PIN actual no era correcto. Inténtalo de nuevo.'
          : 'Escribe tu PIN actual.',
      onSubmit: (pin) async {
        oldPin = pin;
        return null;
      },
    );
    if (!ok || !context.mounted) return false;
    ok = await showPinPrompt(
      context,
      title: 'PIN nuevo',
      message: 'Elige un PIN de 6 dígitos.',
      minLength: AuthController.minNewPinLength,
      onSubmit: (pin) async {
        if (pin == oldPin) return 'El PIN nuevo debe ser distinto del actual';
        newPin = pin;
        return null;
      },
    );
    if (!ok || !context.mounted) return false;
    ok = await showPinPrompt(
      context,
      title: 'Confirma el PIN nuevo',
      minLength: AuthController.minNewPinLength,
      message: 'Escríbelo otra vez.',
      onSubmit: (pin) async => pin == newPin ? null : 'Los PIN no coinciden',
    );
    if (!ok || !context.mounted) return false;
    try {
      if (await auth.changePin(oldPin: oldPin!, newPin: newPin!)) return true;
    } on PinLockedOutException catch (e) {
      if (context.mounted) _snack(context, _lockoutText(e));
      return false;
    } on RotationInProgressException {
      // M2 (D63): no se cambia el PIN durante un cambio de llave maestra.
      if (context.mounted) {
        _snack(context, 'Disponible al terminar el cambio de llave maestra');
      }
      return false;
    }
    wrongCurrent = true;
  }
}

/// Generar un código de recuperación nuevo: pide el PIN, genera el código,
/// lo muestra y EXIGE confirmarlo. El código viejo deja de servir para el
/// respaldo local (y para el de Drive en cuanto se sincronice). Devuelve
/// `true` si se generó y confirmó.
Future<bool> runRegenerateCodeFlow(
  BuildContext context,
  AuthController auth, {
  Random? random,
}) async {
  String? code;
  final ok = await showPinPrompt(
    context,
    title: 'Confirma tu PIN',
    message: 'El código de recuperación anterior dejará de servir.',
    onSubmit: (pin) async {
      try {
        code = await auth.regenerateRecoveryCode(pin);
      } on PinLockedOutException catch (e) {
        return _lockoutText(e);
      } on RotationInProgressException {
        return 'Disponible al terminar el cambio de llave maestra';
      }
      return code == null ? 'PIN incorrecto' : null;
    },
  );
  if (!ok || code == null || !context.mounted) return false;
  final confirmed = await Navigator.of(context).push<bool>(
    AppPageRoute<bool>(
      builder: (_) => _NewCodeScreen(code: code!, random: random),
    ),
  );
  return confirmed ?? false;
}

/// Pantalla de código nuevo: sin salida hasta confirmarlo.
class _NewCodeScreen extends StatelessWidget {
  const _NewCodeScreen({required this.code, this.random});

  final String code;
  final Random? random;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.lg),
            child: RecoveryCodeFlow(
              code: code,
              random: random,
              showTitle: 'Tu nuevo código',
              onConfirmed: () => Navigator.of(context).pop(true),
            ),
          ),
        ),
      ),
    );
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
