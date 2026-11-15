import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/security/auto_lock.dart';
import '../../core/theme/app_motion.dart';
import '../../data/restore/restore_service.dart';
import '../../data/sync/sync_service.dart';
import '../auth/pin_screen.dart';
import '../auth/widgets/pin_prompt_screen.dart';
import 'restore_flow.dart';
import 'widgets/onboarding_page.dart';
import 'widgets/onboarding_steps.dart';
import 'widgets/recovery_code_steps.dart';

/// Pasos del onboarding obligatorio.
enum OnboardingStep {
  welcome,

  /// F9: restaurar una bóveda existente desde Google Drive.
  restore,
  createPin,

  /// Reapertura sin el código en memoria: hay que generar uno nuevo.
  regenerate,

  /// Mostrar el código y confirmarlo (dos pantallas).
  code,
  biometrics,
  drive,
}

/// Onboarding de primer arranque (F8): bienvenida -> crear PIN -> mostrar y
/// CONFIRMAR el código de recuperación -> biometría -> Google Drive -> bóveda.
///
/// * El código vive solo en memoria ([recoveryCode], que el llamador
///   conserva mientras el proceso viva); en disco solo existe la bandera
///   `onboarding_pending` ([AuthController.isOnboardingPending]).
/// * Si la app se cierra tras crear la bóveda y antes de confirmar, al
///   reabrir ([resume]) se vuelve al paso del código; sin código en memoria
///   se ofrece generar uno nuevo ([AuthController.regenerateRecoveryCode]).
/// * Tras confirmar, la bandera se borra y el código NO se vuelve a mostrar.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.auth,
    required this.onFinished,
    this.syncProvider,
    this.resume = false,
    this.recoveryCode,
    this.onVaultCreated,
    this.onRecoveryConfirmed,
    this.restoreProvider,
    this.onVaultRestored,
    this.random,
  });

  final AuthController auth;

  /// Entrar a la bóveda (último paso).
  final VoidCallback onFinished;

  /// Servicio de sincronización para el paso de Drive (se evalúa al llegar a
  /// él); si devuelve `null` el paso se omite.
  final SyncService? Function()? syncProvider;

  /// Reapertura a mitad del onboarding (la bóveda ya existe).
  final bool resume;

  /// Código aún en memoria del proceso (solo con [resume]).
  final String? recoveryCode;

  /// La bóveda se creó: el llamador conserva el código en memoria.
  final ValueChanged<String>? onVaultCreated;

  /// El usuario confirmó el código: el llamador debe olvidarlo.
  final VoidCallback? onRecoveryConfirmed;

  /// F9: servicio de restauración. `null` oculta "Ya tengo una bóveda".
  final RestoreService Function()? restoreProvider;

  /// La bóveda se restauró y quedó desbloqueada (el llamador marca que ya
  /// existe, p. ej. para que un bloqueo vuelva al PIN).
  final VoidCallback? onVaultRestored;

  /// Posiciones reproducibles de la confirmación (pruebas).
  final Random? random;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late OnboardingStep _step = widget.resume
      ? (widget.recoveryCode != null
            ? OnboardingStep.code
            : OnboardingStep.regenerate)
      : OnboardingStep.welcome;
  late String? _code = widget.recoveryCode;
  bool _confirming = false;
  bool _restored = false;
  bool _busy = false;
  String? _bioError;

  static const int _totalSteps = 6;

  int get _stepNumber => switch (_step) {
    OnboardingStep.welcome || OnboardingStep.restore => 1,
    OnboardingStep.createPin => 2,
    OnboardingStep.regenerate => 3,
    OnboardingStep.code => _confirming ? 4 : 3,
    OnboardingStep.biometrics => 5,
    OnboardingStep.drive => 6,
  };

  void _go(OnboardingStep step) {
    if (!mounted) return;
    setState(() => _step = step);
  }

  // ---------------------------------------------------------------- pasos

  void _onVaultCreated(VaultCreationResult result) {
    _code = result.recoveryCode;
    widget.onVaultCreated?.call(result.recoveryCode);
    _go(OnboardingStep.code);
  }

  Future<void> _regenerate() async {
    String? fresh;
    final ok = await showPinPrompt(
      context,
      title: 'Confirma tu PIN',
      message: 'Para generar un código nuevo, escribe tu PIN.',
      onSubmit: (pin) async {
        try {
          fresh = await widget.auth.regenerateRecoveryCode(pin);
        } on PinLockedOutException catch (e) {
          return 'Demasiados intentos. Espera ${e.remaining.inSeconds + 1} s';
        }
        return fresh == null ? 'PIN incorrecto' : null;
      },
    );
    if (!ok || fresh == null || !mounted) return;
    setState(() {
      _code = fresh;
      _confirming = false;
    });
    _go(OnboardingStep.code);
  }

  Future<void> _onCodeConfirmed() async {
    await widget.auth.completeOnboarding();
    widget.onRecoveryConfirmed?.call();
    if (!mounted) return;
    final bio = await widget.auth.biometricAvailability();
    if (!mounted) return;
    if (bio == BiometricAvailability.available) {
      _forgetCodeAnd(OnboardingStep.biometrics);
    } else if (_sync != null) {
      _forgetCodeAnd(OnboardingStep.drive);
    } else {
      widget.onFinished();
    }
  }

  /// Cambia de paso y olvida el código: nunca se vuelve a mostrar.
  void _forgetCodeAnd(OnboardingStep next) {
    setState(() {
      _code = null;
      _confirming = false;
      _step = next;
    });
  }

  Future<void> _enableBiometrics() async {
    setState(() {
      _busy = true;
      _bioError = null;
    });
    try {
      // El diálogo biométrico del sistema no cuenta como ir a segundo plano.
      await AutoLockSuspension.instance.run(widget.auth.enableBiometricUnlock);
      if (!mounted) return;
      _afterBiometrics();
    } on BiometricCancelledException {
      if (mounted) setState(() => _bioError = 'Se canceló la activación.');
    } on Object {
      if (mounted) {
        setState(
          () => _bioError =
              'No se pudo activar la biometría. Puedes hacerlo luego en '
              'Ajustes.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  SyncService? get _sync => widget.syncProvider?.call();

  void _afterBiometrics() {
    if (_restored) {
      widget.onFinished(); // Drive ya está conectado (se usó para restaurar)
    } else if (_sync != null) {
      _go(OnboardingStep.drive);
    } else {
      widget.onFinished();
    }
  }

  Future<void> _onRestored(RestoreResult result) async {
    _restored = true;
    widget.onVaultRestored?.call();
    final bio = await widget.auth.biometricAvailability();
    if (!mounted) return;
    if (bio == BiometricAvailability.available) {
      _go(OnboardingStep.biometrics);
    } else {
      widget.onFinished();
    }
  }

  void _createNewInstead() {
    unawaited(RestoreService.discardStaging());
    _go(OnboardingStep.createPin);
  }

  // ---------------------------------------------------------------- build

  Widget _content() {
    switch (_step) {
      case OnboardingStep.welcome:
        return WelcomeStep(
          key: const ValueKey('step-welcome'),
          onContinue: _createNewInstead,
          onRestore: widget.restoreProvider == null
              ? null
              : () => _go(OnboardingStep.restore),
        );
      case OnboardingStep.restore:
        return RestoreFlow(
          key: const ValueKey('step-restore'),
          service: widget.restoreProvider!(),
          onBack: () => _go(OnboardingStep.welcome),
          onCreateNew: _createNewInstead,
          onRestored: _onRestored,
        );
      case OnboardingStep.createPin:
        return MediaQuery.removePadding(
          key: const ValueKey('step-pin'),
          context: context,
          removeTop: true,
          child: PinScreen(
            authController: widget.auth,
            onAuthenticated: widget.onFinished,
            onVaultCreated: _onVaultCreated,
          ),
        );
      case OnboardingStep.regenerate:
        return RegenerateCodeStep(
          key: const ValueKey('step-regenerate'),
          onGenerate: _regenerate,
        );
      case OnboardingStep.code:
        return RecoveryCodeFlow(
          key: ValueKey('step-code-${_code ?? ''}'),
          code: _code!,
          random: widget.random,
          onConfirmingChanged: (v) => setState(() => _confirming = v),
          onConfirmed: _onCodeConfirmed,
        );
      case OnboardingStep.biometrics:
        return BiometricStep(
          key: const ValueKey('step-biometrics'),
          busy: _busy,
          error: _bioError,
          onEnable: _enableBiometrics,
          onSkip: _afterBiometrics,
        );
      case OnboardingStep.drive:
        return DriveStep(
          key: const ValueKey('step-drive'),
          sync: _sync!,
          onDone: widget.onFinished,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_step != OnboardingStep.restore && !_restored)
              OnboardingProgress(current: _stepNumber, total: _totalSteps),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppMotion.medium,
                switchInCurve: AppMotion.standard,
                child: _content(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
