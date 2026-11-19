import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/rotation/key_rotation_service.dart';
import '../../data/rotation/rotation_repository.dart' show RotationProgress;
import '../../shared/format.dart';
import '../../shared/navigation/app_page_route.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/choice_sheet.dart';
import '../auth/widgets/pin_prompt_screen.dart';
import '../onboarding/widgets/recovery_code_steps.dart';

/// Texto legible de cada fase (`docs/DISENO_ROTACION.md` §8).
String rotationPhaseLabel(RotationPhase p) => switch (p) {
  RotationPhase.prepared => 'Esperando que confirmes tu código nuevo',
  RotationPhase.confirmed => 'Preparando el cambio de llave',
  RotationPhase.freezing => 'Guardando la copia actual de Drive',
  RotationPhase.reencrypting => 'Re-cifrando tus archivos',
  RotationPhase.uploading => 'Subiendo la copia nueva a Drive',
  RotationPhase.rekeyingDb => 'Re-cifrando el índice',
  RotationPhase.switchingLocal => 'Pasando tu PIN a la llave nueva',
  RotationPhase.uploadingSnapshot => 'Subiendo el índice nuevo',
  RotationPhase.uploadingBackup => 'Subiendo el respaldo del código nuevo',
  RotationPhase.deletingOldCloud => 'Borrando la copia anterior de Drive',
  RotationPhase.finalizingLocal => 'Terminando',
  RotationPhase.blockedQuota => 'En pausa: tu Google Drive está lleno',
  RotationPhase.blockedLocalSpace => 'En pausa: falta espacio en el teléfono',
  RotationPhase.blockedSignIn => 'En pausa: inicia sesión con tu cuenta',
  RotationPhase.blockedCorrupt => 'En pausa: hay un problema',
  RotationPhase.blockedForeign =>
    'Hay restos de un cambio de llave que no es de esta bóveda',
};

/// Contador `37/120 archivos` (D72) a partir del avance persistido: durante
/// el re-cifrado cuenta los ya re-cifrados; durante la subida, los ya subidos.
/// `null` en las demás fases o sin cifras.
({int done, int total, String text})? rotationCounter(
  RotationPhase phase,
  RotationProgress? p,
) {
  if (p == null || p.total <= 0) return null;
  final (done, verb) = switch (phase) {
    RotationPhase.reencrypting => (p.done, 'Re-cifrando'),
    RotationPhase.uploading => (p.uploaded, 'Subiendo'),
    _ => (-1, ''),
  };
  if (done < 0) return null;
  return (done: done, total: p.total, text: '$verb: $done/${p.total} archivos');
}

/// Qué código sirve en este momento (tabla del §8).
String rotationCodeAdvice(RotationRecord rec) {
  final p = rec.effectivePhase;
  if (p == RotationPhase.prepared) return 'Anota tu código nuevo.';
  if (p == RotationPhase.confirmed) {
    return 'Aún no empezó. Mientras tanto sigue valiendo tu código anterior.';
  }
  if (p.index >= RotationPhase.deletingOldCloud.index) {
    return 'Tu código NUEVO ya es el único que vale.';
  }
  return 'Ya basta con tu código NUEVO. El anterior dejará de servir al '
      'terminar.';
}

/// "Rotar llave maestra" / "Generar código nuevo" (S-11): hoja previa,
/// código nuevo con confirmación, progreso, bloqueos y final. El estado vive
/// en el almacén seguro y la BD (sobrevive a cerrar la app); aquí solo se
/// muestra y se dirige.
class KeyRotationScreen extends StatefulWidget {
  const KeyRotationScreen({
    super.key,
    required this.service,
    this.reason = RotationReason.rotateKey,
    this.random,
  });

  final KeyRotationService service;
  final RotationReason reason;

  /// Posiciones de la confirmación (pruebas).
  final Random? random;

  @override
  State<KeyRotationScreen> createState() => _KeyRotationScreenState();
}

class _KeyRotationScreenState extends State<KeyRotationScreen> {
  KeyRotationService get _s => widget.service;
  AuthController get _auth => _s.auth;

  RotationPlan? _plan;
  bool _busy = false;

  /// Carga de la lista de archivos con problema (tras reiniciar la app).
  bool _loadingProblems = false;
  String? _problemsError;
  bool _problemsNeedPin = false;

  void _ensureProblems() {
    if (_loadingProblems || _problemsError != null) return;
    _loadingProblems = true;
    unawaited(
      Future<void>(() async {
        String? error;
        var needPin = false;
        try {
          await _s.loadProblems();
        } on RotationException catch (e) {
          error = e.message;
          needPin = _s.session.keyring?.isDual != true;
        } on Object {
          error =
              'No se pudo comprobar qué archivos fallan (¿sin conexión?). '
              'Pulsa Reintentar.';
        }
        _loadingProblems = false;
        if (mounted) {
          setState(() {
            _problemsError = error;
            _problemsNeedPin = needPin;
          });
        }
      }),
    );
  }

  Future<void> _dropMissing() async {
    final n = _s.problems.value?.missing.length ?? 0;
    final ok = await showConfirmSheet(
      context,
      title: '¿Continuar sin estos archivos?',
      message:
          '$n archivo(s) no tienen ninguna copia, ni en este teléfono ni en tu '
          'Google Drive. Se quitarán de la bóveda (también de la Papelera y '
          'de sus etiquetas) y NO se podrán recuperar. Si la copia puede '
          'aparecer (por ejemplo, estabas sin conexión), pulsa "Reintentar" '
          'en su lugar.',
      confirmLabel: 'Quitar y continuar',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(() async {
      await _s.dropMissingItems();
      unawaited(_s.resume());
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final rec = await _auth.rotationRecord();
    unawaited(_s.refreshProgress());
    if (rec == null) {
      try {
        final plan = await _s.plan();
        if (mounted) setState(() => _plan = plan);
      } on Object {
        // sin plan: se muestra la hoja sin cifras
      }
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on RotationException catch (e) {
      _snack(e.message);
    } on RotationInProgressException catch (e) {
      _snack(e.message);
    } on Object {
      _snack('No se pudo completar. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _lockout(PinLockedOutException e) =>
      'Demasiados intentos. Espera ${e.remaining.inSeconds + 1} s';

  // ------------------------------------------------------------- acciones

  Future<void> _begin() async {
    String? code;
    final ok = await showPinPrompt(
      context,
      title: 'Confirma tu PIN',
      message: 'Se creará tu llave nueva y tu código de recuperación nuevo.',
      onSubmit: (pin) async {
        try {
          code = await _s.start(pin, reason: widget.reason);
        } on PinLockedOutException catch (e) {
          return _lockout(e);
        } on RotationException catch (e) {
          return e.message;
        } on RotationInProgressException catch (e) {
          return e.message;
        }
        return code == null ? 'PIN incorrecto' : null;
      },
    );
    if (!ok || code == null || !mounted) return;
    await _showAndConfirm(code!);
  }

  Future<void> _newCodeAgain() async {
    String? code;
    final ok = await showPinPrompt(
      context,
      title: 'Confirma tu PIN',
      message: 'Se mostrará otro código nuevo (el anterior no llegó a usarse).',
      onSubmit: (pin) async {
        try {
          code = await _auth.regenerateNextRecoveryCode(pin);
        } on PinLockedOutException catch (e) {
          return _lockout(e);
        } on RotationInProgressException catch (e) {
          return e.message;
        }
        return code == null ? 'PIN incorrecto' : null;
      },
    );
    if (!ok || code == null || !mounted) return;
    await _showAndConfirm(code!);
  }

  Future<void> _showAndConfirm(String code) async {
    final confirmed = await Navigator.of(context).push<bool>(
      AppPageRoute<bool>(
        builder: (_) => _NewCodeScreen(code: code, random: widget.random),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _guard(() async {
      if (!await _s.confirm(code)) {
        _snack('El código no coincide. Vuelve a intentarlo.');
        return;
      }
      unawaited(_s.resume());
    });
  }

  Future<void> _cancel() async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Cancelar el cambio de llave?',
      message:
          'Todavía no se ha re-cifrado nada: todo queda como estaba y sigue '
          'valiendo tu código ANTERIOR. Puedes destruir el código nuevo.',
      confirmLabel: 'Cancelar el cambio',
      cancelLabel: 'Seguir',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(_s.cancel);
  }

  Future<void> _skipCorrupt() async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Omitir los archivos dañados?',
      message:
          'Esos archivos ya no se podían abrir (ni la copia del teléfono ni la '
          'de Drive). Quedarán marcados como perdidos y su copia en Drive se '
          'conserva aparte, sin borrarse, por si quieres revisarla.',
      confirmLabel: 'Omitir y continuar',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(() async {
      await _s.skipCorruptItems();
      unawaited(_s.resume());
    });
  }

  Future<void> _discardForeign() async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Descartar los restos?',
      message:
          'Se olvida en este teléfono un cambio de llave que no corresponde a '
          'esta bóveda. No se borra nada de tu Google Drive.',
      confirmLabel: 'Descartar restos',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(_s.discardForeign);
  }

  Future<void> _enterPin() async {
    final ok = await showPinPrompt(
      context,
      title: 'Introduce tu PIN',
      message: 'Hace falta para continuar el cambio de llave.',
      onSubmit: (pin) async {
        try {
          // A2 (fase 8): reautenticación en la sesión principal; nunca
          // cambia de bóveda (el PIN de la secundaria aquí es "incorrecto").
          return await _auth.reauthPrimary(pin) ? null : 'PIN incorrecto';
        } on PinLockedOutException catch (e) {
          return _lockout(e);
        }
      },
    );
    if (!ok || !mounted) return;
    if (_problemsNeedPin) {
      // Lista de problemas pendiente de la llave: se vuelve a cargar.
      setState(() {
        _problemsError = null;
        _problemsNeedPin = false;
      });
      return;
    }
    unawaited(_s.resume());
  }

  /// M7 (D72): borra lo que conserva la cuenta de Google anterior.
  Future<void> _deleteOldAccount() async {
    final old = _plan?.oldAccountKept;
    if (old == null) return;
    final ok = await showConfirmSheet(
      context,
      title: '¿Borrar los datos de la cuenta anterior?',
      message:
          'Se borrarán PARA SIEMPRE (sin papelera ni versiones) todos los '
          'archivos de Vault que guarda $old. Primero elige esa cuenta de '
          'Google; al terminar volverás a la cuenta actual, que no se toca. '
          'Después, esa cuenta ya no podrá restaurar tu bóveda.',
      confirmLabel: 'Elegir cuenta y borrar',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(() async {
      final n = await _s.deleteOldAccountData();
      _snack('Datos de la cuenta anterior borrados ($n archivos)');
      final plan = await _s.plan();
      if (mounted) setState(() => _plan = plan);
    });
  }

  /// M11 (D73): limpieza manual de generaciones que no son la vigente.
  Future<void> _cleanLeftovers() async {
    await _guard(() async {
      final scan = await _s.scanLeftovers();
      if (scan.isEmpty) {
        _snack('No hay restos que limpiar');
        return;
      }
      if (!mounted) return;
      final ok = await showConfirmSheet(
        context,
        title: '¿Limpiar restos de cambios de llave?',
        message:
            'Se borrarán PARA SIEMPRE ${scan.cloudFiles} archivo(s) de tu '
            'Google Drive (${formatBytes(scan.cloudBytes)}) y '
            '${scan.localFiles} del teléfono que pertenecen a una llave que '
            'ya no se usa (restos de un cambio de llave interrumpido). No se '
            'toca nada de la llave vigente. No lo hagas si estás cambiando la '
            'llave desde otro teléfono.',
        confirmLabel: 'Limpiar',
        destructive: true,
      );
      if (!ok || !mounted) return;
      final r = await _s.cleanLeftovers();
      _snack(
        r.staleSkipped
            ? 'Limpieza parcial: la copia vigente aún no está completa en '
                  'Drive, no se borró lo anterior.'
            : 'Limpieza hecha: ${r.cloudFiles} en Drive y ${r.localFiles} en '
                  'el teléfono.',
      );
    });
  }

  Future<void> _reactivateBiometric() async {
    await _guard(() async {
      await _auth.enableBiometricUnlock();
      _snack('Desbloqueo biométrico activado');
    });
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final title = widget.reason == RotationReason.newCode
        ? 'Generar código nuevo'
        : 'Rotar llave maestra';
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: AppSizes.toolbar,
              child: Row(
                children: [
                  AppIconButton(
                    icon: Icons.arrow_back,
                    label: 'Volver',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: AppTypography.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppSizes.contentMaxWidth,
                  ),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      _s.status,
                      _s.problems,
                      _s.progress,
                      _auth.rotationStore.record,
                    ]),
                    builder: (context, _) {
                      final st = _s.status.value;
                      final rec = _auth.rotationStore.record.value;
                      return ListView(
                        padding: AppSpacing.page,
                        children: rec != null
                            ? _active(rec, st)
                            : st.finished
                            ? _finished(st)
                            : _intro(),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _intro() {
    final plan = _plan;
    final canStart =
        plan == null ||
        (plan.signedIn && plan.pendingUploads == 0 && plan.enoughDriveSpace);
    return [
      _Block(
        title: 'Qué va a pasar',
        lines: [
          widget.reason == RotationReason.newCode
              ? 'Para que tu código anterior deje de servir del todo, Vault '
                    'cambia la llave con la que está cifrado todo y vuelve a '
                    'subirlo a Google Drive.'
              : 'Vault cambiará la llave que cifra todos tus archivos y '
                    'volverá a subirlos.',
          'Recibirás un código de recuperación NUEVO. Al terminar, el '
              'anterior ya no abrirá nada.',
          'Las copias que alguien haya descargado antes con tu código '
              'anterior no se pueden revocar: esto protege lo de ahora en '
              'adelante.',
        ],
      ),
      const SizedBox(height: AppSpacing.lg),
      const _Block(
        title: 'Antes de empezar',
        lines: [
          'Puede tardar: hay que volver a subir toda tu bóveda.',
          'Usa Wi-Fi y conecta el cargador.',
          'Mantén Vault abierta (en primer plano). Puedes seguir usándola; si '
              'se cierra o se bloquea, continúa donde se quedó.',
          'Durante el cambio tu Google Drive guarda las dos copias: necesitas '
              'aproximadamente el doble de espacio.',
          'Mientras dure no podrás cambiar el PIN, cerrar sesión de Google ni '
              'borrar originales de la galería. La huella o Face ID se apagan '
              'y podrás reactivarlas al final.',
        ],
      ),
      if (plan != null) ...[
        const SizedBox(height: AppSpacing.lg),
        _PlanBlock(plan: plan),
      ],
      const SizedBox(height: AppSpacing.xl),
      AppFilledButton(
        label: 'Empezar',
        icon: Icons.key_outlined,
        busy: _busy,
        onPressed: canStart && !_busy ? _begin : null,
      ),
      const SizedBox(height: AppSpacing.sm),
      AppTextButton(
        label: 'Ahora no',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      const SizedBox(height: AppSpacing.lg),
      _Block(
        title: 'Mantenimiento',
        lines: [
          'Si un cambio de llave se interrumpió, pueden quedar archivos de '
              'una llave que ya no se usa.',
        ],
      ),
      const SizedBox(height: AppSpacing.sm),
      if (plan?.oldAccountKept != null)
        AppTextButton(
          label: 'Borrar datos de la cuenta anterior',
          onPressed: _busy ? null : _deleteOldAccount,
        ),
      AppTextButton(
        label: 'Limpiar restos de cambios de llave',
        onPressed: _busy ? null : _cleanLeftovers,
      ),
    ];
  }

  List<Widget> _active(RotationRecord rec, RotationStatus st) {
    final phase = rec.phase;
    final effective = rec.effectivePhase;
    final blocked = phase.isBlocked;
    // D72: el contador sale de lo persistido (sobrevive a reiniciar la app);
    // la cifra en memoria del re-cifrado en curso es el respaldo.
    final counter = rotationCounter(effective, _s.progress.value);
    final total = counter?.total ?? st.itemsTotal;
    final doneCount = counter?.done ?? st.itemsDone;
    return [
      Semantics(
        header: true,
        liveRegion: true,
        child: Text(
          rotationPhaseLabel(phase),
          key: const ValueKey('rotation-phase'),
          style: AppTypography.titleSmall,
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      if (!blocked && phase != RotationPhase.prepared)
        ClipRRect(
          borderRadius: AppRadii.pillAll,
          child: LinearProgressIndicator(
            key: const ValueKey('rotation-progress'),
            value: total > 0 ? doneCount / total : null,
            minHeight: AppSizes.progressBarHeight,
            color: AppColors.accent,
            backgroundColor: AppColors.surfaceHighest,
          ),
        ),
      if (total > 0) ...[
        const SizedBox(height: AppSpacing.xs),
        Text(
          counter?.text ?? '$doneCount de $total',
          key: const ValueKey('rotation-counter'),
          style: AppTypography.caption,
        ),
      ],
      if ((rec.lastError ?? st.message) != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          liveRegion: true,
          child: Text(
            (rec.lastError ?? st.message)!,
            key: const ValueKey('rotation-message'),
            style: AppTypography.bodySecondary.copyWith(
              color: blocked ? AppColors.danger : null,
            ),
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
      Text(
        rotationCodeAdvice(rec),
        key: const ValueKey('rotation-advice'),
        style: AppTypography.body,
      ),
      const SizedBox(height: AppSpacing.lg),
      ..._actions(rec, st, effective),
    ];
  }

  List<Widget> _actions(
    RotationRecord rec,
    RotationStatus st,
    RotationPhase effective,
  ) {
    final phase = rec.phase;
    final out = <Widget>[];
    void primary(String label, IconData icon, VoidCallback? onPressed) =>
        out.addAll([
          AppFilledButton(
            label: label,
            icon: icon,
            busy: _busy,
            onPressed: _busy ? null : onPressed,
          ),
          const SizedBox(height: AppSpacing.sm),
        ]);

    if (phase == RotationPhase.prepared) {
      primary('Ver otro código nuevo', Icons.key_outlined, _newCodeAgain);
    } else if (phase == RotationPhase.blockedCorrupt &&
        rec.resumePhase == RotationPhase.reencrypting) {
      final probs = _s.problems.value;
      if (probs == null) {
        _ensureProblems();
        out.addAll([
          Text(
            _problemsError ?? 'Comprobando qué archivos fallan…',
            key: const ValueKey('rotation-problems-loading'),
            style: AppTypography.bodySecondary,
          ),
          const SizedBox(height: AppSpacing.md),
        ]);
        if (_problemsNeedPin) {
          primary('Introducir PIN', Icons.pin_outlined, _enterPin);
        }
      } else {
        if (probs.missing.isNotEmpty) {
          out.addAll([
            _ProblemList(
              key: const ValueKey('rotation-missing'),
              title: 'Sin ninguna copia (${probs.missing.length})',
              text:
                  'No están ni en este teléfono ni en tu Google Drive: no se '
                  'pueden recuperar.',
              items: probs.missing,
            ),
            const SizedBox(height: AppSpacing.md),
          ]);
          primary('Continuar sin ellos', Icons.playlist_remove, _dropMissing);
        }
        if (probs.damaged.isNotEmpty) {
          out.addAll([
            _ProblemList(
              key: const ValueKey('rotation-damaged'),
              title: 'Dañados (${probs.damaged.length})',
              text:
                  'Tienen copia pero no se puede abrir. Al omitirlos, su copia '
                  'de Drive se conserva aparte.',
              items: probs.damaged,
            ),
            const SizedBox(height: AppSpacing.md),
          ]);
          primary('Omitir los dañados', Icons.report_outlined, _skipCorrupt);
        }
      }
      out.add(
        AppTextButton(
          label: 'Reintentar',
          onPressed: _busy
              ? null
              : () {
                  setState(() {
                    _problemsError = null;
                    _problemsNeedPin = false;
                  });
                  unawaited(_s.retry());
                },
        ),
      );
    } else if (phase == RotationPhase.blockedForeign) {
      primary('Descartar restos', Icons.delete_outline, _discardForeign);
    } else if (phase.isBlocked) {
      primary(
        phase == RotationPhase.blockedSignIn
            ? 'Reintentar tras iniciar sesión'
            : 'Reintentar',
        Icons.refresh,
        () => unawaited(_s.retry()),
      );
    } else if (st.needsPin) {
      primary('Introducir PIN', Icons.pin_outlined, _enterPin);
    } else if (st.running) {
      out.add(AppTextButton(label: 'Pausar', onPressed: _s.pause));
    } else {
      primary('Continuar', Icons.play_arrow, () => unawaited(_s.resume()));
    }
    if (rec.isCancellable && !phase.isBlocked) {
      out.add(AppTextButton(label: 'Cancelar el cambio', onPressed: _cancel));
    }
    return out;
  }

  List<Widget> _finished(RotationStatus st) => [
    const Icon(
      Icons.verified_user_outlined,
      color: AppColors.success,
      size: AppSizes.iconXl,
    ),
    const SizedBox(height: AppSpacing.md),
    Semantics(
      header: true,
      liveRegion: true,
      child: const Text('Rotación terminada', style: AppTypography.titleSmall),
    ),
    const SizedBox(height: AppSpacing.sm),
    const Text(
      'Tu código anterior ya no abre nada: destrúyelo. Guarda SOLO el código '
      'nuevo, en papel y fuera del teléfono.',
      style: AppTypography.body,
    ),
    const SizedBox(height: AppSpacing.xl),
    if (st.offerBiometric) ...[
      AppFilledButton(
        label: 'Reactivar huella o Face ID',
        icon: Icons.fingerprint,
        busy: _busy,
        onPressed: _busy ? null : _reactivateBiometric,
      ),
      const SizedBox(height: AppSpacing.sm),
    ],
    AppTextButton(
      label: 'Listo',
      onPressed: () => Navigator.of(context).maybePop(),
    ),
  ];
}

/// Código nuevo: sin salida hasta confirmarlo (mismo flujo que el onboarding).
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
              showTitle: 'Tu código NUEVO',
              onConfirmed: () => Navigator.of(context).pop(true),
            ),
          ),
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.lines});
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: AppTypography.titleSmall),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final l in lines) ...[
          Text(l, style: AppTypography.bodySecondary),
          const SizedBox(height: AppSpacing.xs),
        ],
      ],
    );
  }
}

/// Lista de archivos con problema (solo nombres visibles al usuario; nunca
/// van a logs ni al Diagnóstico).
class _ProblemList extends StatelessWidget {
  const _ProblemList({
    super.key,
    required this.title,
    required this.text,
    required this.items,
  });

  /// Nombres que se muestran antes de "y N más".
  static const int maxShown = 8;

  final String title;
  final String text;
  final List<RotationProblemItem> items;

  @override
  Widget build(BuildContext context) {
    final shown = items.take(maxShown).toList();
    final rest = items.length - shown.length;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.mdAll,
      ),
      child: Padding(
        padding: AppSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(title, style: AppTypography.titleSmall),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(text, style: AppTypography.bodySecondary),
            const SizedBox(height: AppSpacing.sm),
            for (final i in shown)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                child: Text(
                  i.name,
                  style: AppTypography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (rest > 0)
              Text('y $rest más', style: AppTypography.bodySecondary),
          ],
        ),
      ),
    );
  }
}

class _PlanBlock extends StatelessWidget {
  const _PlanBlock({required this.plan});
  final RotationPlan plan;

  @override
  Widget build(BuildContext context) {
    final q = plan.quota;
    final free = q?.limitBytes == null ? null : q!.limitBytes! - q.usedBytes;
    final warnings = <String>[
      if (!plan.signedIn)
        'Inicia sesión con Google (Ajustes > Sincronización) para empezar.',
      if (plan.pendingUploads > 0)
        'Hay ${plan.pendingUploads} archivo(s) sin subir: espera a que '
            'terminen (o reintenta los que fallaron) antes de empezar.',
      if (!plan.enoughDriveSpace)
        'Tu Google Drive no tiene espacio para la copia nueva. Libera espacio '
            'antes de empezar.',
      if (plan.noCopyItems > 0)
        '${plan.noCopyItems} archivo(s) no tienen ninguna copia (ni en el '
            'teléfono ni en Drive). Durante el cambio podrás continuar sin '
            'ellos.',
      if (plan.lostThumbnails > 0)
        '${plan.lostThumbnails} miniatura(s) no se pueden recuperar: esos '
            'archivos quedarán con su ícono.',
      if (plan.oldAccountKept != null)
        'Tu cuenta anterior (${plan.oldAccountKept}) todavía guarda una copia '
            'que abre tu código anterior. Bórrala desde esa cuenta si ya no la '
            'necesitas.',
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.mdAll,
      ),
      child: Padding(
        padding: AppSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: const Text('Tu bóveda', style: AppTypography.titleSmall),
            ),
            const SizedBox(height: AppSpacing.sm),
            _row('Archivos', '${plan.items}'),
            _row('A subir de nuevo', formatBytes(plan.uploadBytes)),
            _row(
              'A descargar (solo en la nube)',
              plan.cloudOnlyBytes == 0
                  ? 'nada'
                  : formatBytes(plan.cloudOnlyBytes),
            ),
            _row(
              'Libre en Google Drive',
              free == null ? 'no se pudo comprobar' : formatBytes(free),
            ),
            for (final w in warnings) ...[
              const SizedBox(height: AppSpacing.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  w,
                  style: AppTypography.bodySecondary.copyWith(
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: AppTypography.bodySecondary)),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppTypography.body,
          ),
        ),
      ],
    ),
  );
}

/// Aviso en la cuadrícula y en Ajustes mientras hay un cambio de llave.
class RotationBanner extends StatelessWidget {
  const RotationBanner({
    super.key,
    required this.record,
    required this.onTap,
    this.progress,
  });

  final ValueListenable<RotationRecord?> record;
  final VoidCallback onTap;

  /// Avance persistido (D72) para el contador «37/120 archivos».
  final ValueListenable<RotationProgress?>? progress;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([record, ?progress]),
      builder: (context, _) {
        final rec = record.value;
        if (rec == null) return const SizedBox.shrink();
        final counter = rotationCounter(rec.effectivePhase, progress?.value);
        final text = rec.phase.isBlocked
            ? 'Cambio de llave maestra en pausa. Toca para ver qué hacer.'
            : rec.phase == RotationPhase.prepared
            ? 'Cambio de llave maestra: falta confirmar tu código nuevo.'
            : counter != null
            ? 'Cambiando la llave maestra · ${counter.text} · Mantén Vault '
                  'abierta.'
            : 'Cambiando la llave maestra · Mantén Vault abierta.';
        return Padding(
          padding: AppSpacing.pageHorizontal,
          child: Material(
            color: AppColors.surfaceHigh,
            borderRadius: AppRadii.mdAll,
            child: InkWell(
              key: const ValueKey('rotation-banner'),
              borderRadius: AppRadii.mdAll,
              onTap: onTap,
              child: Padding(
                padding: AppSpacing.card,
                child: Row(
                  children: [
                    const Icon(
                      Icons.key_outlined,
                      color: AppColors.accentLight,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        button: true,
                        child: Text(text, style: AppTypography.caption),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
