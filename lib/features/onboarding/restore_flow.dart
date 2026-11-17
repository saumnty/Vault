import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/cloud/cloud_storage.dart';
import '../../data/restore/restore_service.dart';
import '../../data/sync/sync_service.dart' show describeSyncError;
import '../../shared/widgets/app_buttons.dart';
import '../auth/widgets/pin_prompt_screen.dart';
import 'widgets/onboarding_page.dart';
import 'widgets/recovery_code_field.dart';

/// Pasos de la restauración.
enum RestoreStep { start, noBackup, code, working, done }

/// Texto del aviso M8 (DISENO_ROTACION.md §8): el código abre un estado
/// anterior al más reciente de la cuenta.
String restoreOlderStateMessage(RestoreCodeMatch match) => match.viaBridge
    ? 'Esto restaura el estado de antes del cambio de llave maestra que '
          'estaba en curso. Después, vuelve a rotar la llave.'
    : 'Este es un código ANTERIOR. Hay una copia más reciente que abre tu '
          'código nuevo. ¿Restaurar igualmente el estado antiguo?';

/// Restaurar una bóveda existente (F9): Google -> código de recuperación ->
/// PIN nuevo -> descarga -> listo. Ver [RestoreService] para lo que ocurre
/// por debajo (nada se instala hasta el final).
class RestoreFlow extends StatefulWidget {
  const RestoreFlow({
    super.key,
    required this.service,
    required this.onRestored,
    required this.onCreateNew,
    required this.onBack,
    this.initialStep = RestoreStep.start,
  });

  final RestoreService service;

  /// La bóveda quedó restaurada y desbloqueada.
  final ValueChanged<RestoreResult> onRestored;

  /// "Crear una bóveda nueva" (cuenta sin respaldo).
  final VoidCallback onCreateNew;

  /// Volver a la bienvenida.
  final VoidCallback onBack;

  final RestoreStep initialStep;

  @override
  State<RestoreFlow> createState() => _RestoreFlowState();
}

class _RestoreFlowState extends State<RestoreFlow> {
  late RestoreStep _step = widget.initialStep;
  bool _busy = false;
  String? _error;
  RestoreProbeResult _probe = RestoreProbeResult.noBackup;
  final TextEditingController _code = TextEditingController();
  String? _codeError;
  Timer? _lockTimer;
  Duration? _lockRemaining;
  String? _pin;
  RestoreProgress? _progress;
  CloudCancelToken? _cancel;
  RestoreResult? _result;
  bool _retryable = false;

  RestoreService get _svc => widget.service;

  @override
  void initState() {
    super.initState();
    if (_step == RestoreStep.code) unawaited(_refreshLockout());
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _code.dispose();
    _cancel?.cancel();
    super.dispose();
  }

  void _go(RestoreStep step) {
    if (!mounted) return;
    setState(() {
      _step = step;
      _error = null;
    });
  }

  // ------------------------------------------------------------ Google

  Future<void> _signInAndProbe({bool otherAccount = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (otherAccount) await _svc.signOut();
      await _svc.signIn();
      final result = await _svc.probe();
      if (!mounted) return;
      _probe = result;
      if (result == RestoreProbeResult.found) {
        await _refreshLockout();
        _go(RestoreStep.code);
      } else {
        _go(RestoreStep.noBackup);
      }
    } on CloudSignInCancelledException {
      // El usuario cerró el selector de cuentas: no es un error.
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = describeSyncError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ código

  Future<void> _refreshLockout() async {
    final remaining = await _svc.lockoutRemaining();
    if (!mounted) return;
    _lockTimer?.cancel();
    setState(() => _lockRemaining = remaining);
    if (remaining != null) {
      _lockTimer = Timer(
        Duration(seconds: remaining.inSeconds + 1),
        () => unawaited(_refreshLockout()),
      );
    }
  }

  bool get _codeValid =>
      evaluateRecoveryInput(_code.text) == CodeFieldState.valid;

  Future<void> _submitCode() async {
    if (!_codeValid || _busy || _lockRemaining != null) return;
    setState(() {
      _busy = true;
      _codeError = null;
    });
    try {
      final ok = await _svc.verifyCode(_code.text);
      if (!mounted) return;
      if (!ok) {
        setState(() => _codeError = 'Código incorrecto');
        await _refreshLockout();
        return;
      }
      setState(() => _busy = false);
      // M8 (D61): el código abre un estado ANTERIOR al más reciente.
      final match = _svc.lastMatch;
      if (match != null && match.olderThanLatest) {
        if (!await _confirmOlderState(match)) return;
        if (!mounted) return;
      }
      await _askPin();
    } on PinLockedOutException catch (e) {
      if (mounted) {
        setState(() => _codeError = null);
        await _refreshLockout();
        if (_lockRemaining == null) {
          setState(() => _error = 'Espera ${e.remaining.inSeconds + 1} s');
        }
      }
    } on FormatException {
      if (mounted) {
        setState(() {
          _probe = RestoreProbeResult.invalid;
          _step = RestoreStep.noBackup;
        });
      }
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = describeSyncError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmOlderState(RestoreCodeMatch match) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Estado anterior'),
        content: Text(restoreOlderStateMessage(match)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restaurar igualmente'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // --------------------------------------------------------------- PIN

  Future<void> _askPin() async {
    String? first;
    var ok = await showPinPrompt(
      context,
      title: 'Elige un PIN nuevo',
      minLength: AuthController.minNewPinLength,
      message:
          'De 6 dígitos. Solo sirve en este teléfono: no se guarda en '
          'Drive.',
      onSubmit: (pin) async {
        first = pin;
        return null;
      },
    );
    if (!ok || !mounted) return;
    ok = await showPinPrompt(
      context,
      title: 'Confirma tu PIN',
      minLength: AuthController.minNewPinLength,
      message: 'Escríbelo otra vez.',
      onSubmit: (pin) async => pin == first ? null : 'Los PIN no coinciden',
    );
    if (!ok || !mounted) return;
    _pin = first;
    unawaited(_run());
  }

  // ----------------------------------------------------------- descarga

  Future<void> _run() async {
    final pin = _pin;
    if (pin == null) return;
    final cancel = _cancel = CloudCancelToken();
    setState(() {
      _step = RestoreStep.working;
      _error = null;
      _retryable = false;
      _progress = const RestoreProgress(RestoreStage.downloadingDb);
    });
    try {
      final result = await _svc.restore(
        newPin: pin,
        cancel: cancel,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      _pin = null;
      if (!mounted) return;
      setState(() {
        _result = result;
        _step = RestoreStep.done;
      });
    } on CloudCancelledException {
      if (mounted) _go(RestoreStep.code);
    } on RestoreCorruptException catch (e) {
      _fail(e.message, retryable: false);
    } on RestoreIncompatibleException catch (e) {
      _fail(e.message, retryable: false);
    } on RestoreException catch (e) {
      _fail(e.message, retryable: true);
    } on CloudException catch (e) {
      _fail(describeSyncError(e), retryable: true);
    } on Object {
      _fail(
        'No se pudo restaurar. No se cambió nada en este teléfono.',
        retryable: true,
      );
    }
  }

  void _fail(String message, {required bool retryable}) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _retryable = retryable;
    });
  }

  Future<void> _abandon() async {
    _cancel?.cancel();
    await RestoreService.discardStaging();
    _pin = null;
    if (mounted) _go(RestoreStep.start);
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.medium,
      switchInCurve: AppMotion.standard,
      child: switch (_step) {
        RestoreStep.start => _start(),
        RestoreStep.noBackup => _noBackup(),
        RestoreStep.code => _codeStep(),
        RestoreStep.working => _working(),
        RestoreStep.done => _done(),
      },
    );
  }

  Widget _errorText(String text) => Semantics(
    liveRegion: true,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: AppTypography.bodySecondary.copyWith(color: AppColors.danger),
    ),
  );

  Widget _start() {
    return OnboardingPage(
      key: const ValueKey('restore-start'),
      title: 'Restaurar tu bóveda',
      message:
          'Inicia sesión con la cuenta de Google donde respaldaste tu '
          'bóveda. Después te pediremos tu código de recuperación.',
      body: [
        const InfoCard(
          icon: Icons.cloud_download_outlined,
          title: 'Tus archivos siguen cifrados',
          text:
              'Descargamos tu índice y las miniaturas. Cada archivo completo '
              'se baja cuando lo abres.',
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          _errorText(_error!),
        ],
      ],
      footer: [
        AppFilledButton(
          label: 'Iniciar sesión con Google',
          icon: Icons.login,
          busy: _busy,
          onPressed: _signInAndProbe,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(label: 'Volver', onPressed: _busy ? null : widget.onBack),
      ],
    );
  }

  Widget _noBackup() {
    final (title, message) = switch (_probe) {
      RestoreProbeResult.incomplete => (
        'El respaldo está incompleto',
        'Esta cuenta tiene tus llaves pero no el índice de tus archivos, así '
            'que no hay nada que mostrar todavía.',
      ),
      RestoreProbeResult.invalid => (
        'El respaldo no es válido',
        'Encontramos un respaldo en esta cuenta, pero no se puede leer.',
      ),
      _ => (
        'No hay respaldo en esta cuenta de Google',
        'No encontramos una bóveda de Vault respaldada en esta cuenta. '
            'Prueba con otra cuenta o crea una bóveda nueva.',
      ),
    };
    return OnboardingPage(
      key: const ValueKey('restore-nobackup'),
      title: title,
      message: message,
      body: [if (_error != null) _errorText(_error!)],
      footer: [
        AppFilledButton(
          label: 'Usar otra cuenta',
          icon: Icons.switch_account_outlined,
          busy: _busy,
          onPressed: () => _signInAndProbe(otherAccount: true),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Crear una bóveda nueva',
          onPressed: _busy ? null : widget.onCreateNew,
        ),
      ],
    );
  }

  Widget _codeStep() {
    final hint = recoveryInputHint(_code.text);
    final locked = _lockRemaining;
    final email = _svc.accountEmail;
    return OnboardingPage(
      key: const ValueKey('restore-code'),
      title: 'Tu código de recuperación',
      message:
          'Escribe el código de 24 caracteres que anotaste al crear la '
          'bóveda. Puedes usar minúsculas; los guiones se ponen solos.',
      body: [
        if (email != null)
          Semantics(
            container: true,
            label: 'Cuenta de Google: $email',
            child: ExcludeSemantics(
              child: Container(
                padding: AppSpacing.card,
                margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadii.mdAll,
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        RecoveryCodeField(
          controller: _code,
          enabled: !_busy && locked == null,
          error: _codeError,
          onChanged: (_) => setState(() => _codeError = null),
          onSubmitted: _submitCode,
        ),
        if (_codeError != null) ...[
          const SizedBox(height: AppSpacing.md),
          _errorText(_codeError!),
        ] else if (locked != null) ...[
          const SizedBox(height: AppSpacing.md),
          _errorText(
            'Demasiados intentos. Espera ${locked.inSeconds + 1} s para '
            'volver a probar.',
          ),
        ] else if (hint != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: AppTypography.bodySecondary,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          _errorText(_error!),
        ],
      ],
      footer: [
        AppFilledButton(
          label: 'Continuar',
          busy: _busy,
          onPressed: _codeValid && locked == null ? _submitCode : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Usar otra cuenta',
          onPressed: _busy
              ? null
              : () {
                  _code.clear();
                  unawaited(_signInAndProbe(otherAccount: true));
                },
        ),
      ],
    );
  }

  String _stageLabel(RestoreProgress p) => switch (p.stage) {
    RestoreStage.downloadingDb => 'Descargando el índice de tu bóveda…',
    RestoreStage.opening => 'Abriendo tu bóveda…',
    RestoreStage.thumbnails =>
      'Descargando miniaturas ${p.done} de ${p.total}…',
    RestoreStage.installing => 'Terminando…',
  };

  Widget _working() {
    final p = _progress ?? const RestoreProgress(RestoreStage.downloadingDb);
    final fraction = p.stage == RestoreStage.thumbnails && p.total > 0
        ? p.done / p.total
        : null;
    final failed = _error != null;
    return OnboardingPage(
      key: const ValueKey('restore-working'),
      title: failed ? 'No se pudo restaurar' : 'Restaurando tu bóveda',
      message: failed
          ? _error
          : 'No cierres la app. Si se corta la conexión podrás reintentar.',
      body: [
        if (!failed)
          Semantics(
            liveRegion: true,
            label: _stageLabel(p),
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _stageLabel(p),
                    key: const ValueKey('restore-stage'),
                    style: AppTypography.bodySecondary,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ClipRRect(
                    borderRadius: AppRadii.pillAll,
                    child: LinearProgressIndicator(
                      key: const ValueKey('restore-progress'),
                      value: fraction,
                      minHeight: AppSizes.progressBarHeight,
                      color: AppColors.accent,
                      backgroundColor: AppColors.surfaceHighest,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
      footer: failed
          ? [
              if (_retryable)
                AppFilledButton(label: 'Reintentar', onPressed: _run),
              if (_retryable) const SizedBox(height: AppSpacing.sm),
              AppTextButton(label: 'Empezar de nuevo', onPressed: _abandon),
            ]
          : [
              AppTextButton(
                label: 'Cancelar',
                onPressed: () => _cancel?.cancel(),
              ),
            ],
    );
  }

  Widget _done() {
    final r = _result!;
    return OnboardingPage(
      key: const ValueKey('restore-done'),
      title: 'Bóveda restaurada',
      message:
          '${r.items} ${r.items == 1 ? 'archivo' : 'archivos'} y '
          '${r.folders} ${r.folders == 1 ? 'carpeta' : 'carpetas'} '
          'recuperados. Cada archivo se descargará cuando lo abras.',
      body: [
        if (r.lostItems > 0)
          InfoCard(
            key: const ValueKey('restore-lost'),
            icon: Icons.warning_amber_rounded,
            title: '${r.lostItems} no se pudieron recuperar',
            text:
                'Su copia nunca llegó a Drive (se perdieron con el teléfono '
                'anterior). Aparecen con un aviso de error.',
            color: AppColors.warning,
            border: AppColors.warning,
          ),
        if (r.lostItems > 0) const SizedBox(height: AppSpacing.md),
        const InfoCard(
          icon: Icons.fingerprint,
          title: 'La biometría no se traslada',
          text:
              'Tu PIN nuevo ya funciona. Si quieres usar huella o rostro en '
              'este teléfono, podrás activarla ahora.',
        ),
      ],
      footer: [
        AppFilledButton(
          label: 'Continuar',
          onPressed: () => widget.onRestored(r),
        ),
      ],
    );
  }
}
