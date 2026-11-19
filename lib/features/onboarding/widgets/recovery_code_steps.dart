import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/crypto/recovery_challenge.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/app_buttons.dart';
import 'onboarding_page.dart';

/// Parte el código (`XXXX-XXXX-...`) en filas de 3 grupos.
List<List<String>> _groupRows(String code) {
  final groups = code.split('-').where((g) => g.isNotEmpty).toList();
  return [
    for (var i = 0; i < groups.length; i += 3)
      groups.sublist(i, i + 3 > groups.length ? groups.length : i + 3),
  ];
}

/// Muestra el código de recuperación en grupos de 4. Sin botón de copiar y
/// con texto NO seleccionable: el portapapeles es legible por otras apps y
/// por la sincronización de portapapeles del sistema.
class RecoveryCodeShowStep extends StatelessWidget {
  const RecoveryCodeShowStep({
    super.key,
    required this.code,
    required this.onContinue,
    this.title = 'Tu código de recuperación',
  });

  final String code;
  final VoidCallback onContinue;
  final String title;

  @override
  Widget build(BuildContext context) {
    return OnboardingPage(
      title: title,
      message:
          'Anótalo en papel y guárdalo fuera del teléfono. Es la única forma '
          'de recuperar tu bóveda si olvidas el PIN o cambias de teléfono. '
          'No se puede copiar y no se volverá a mostrar cuando termines.',
      body: [
        Container(
          key: const ValueKey('recovery-code-box'),
          padding: AppSpacing.page,
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: AppRadii.mdAll,
            border: Border.all(color: AppColors.accent),
          ),
          child: Semantics(
            label: 'Código de recuperación: $code',
            // Cada grupo de 4 caracteres es indivisible: 3 grupos por fila.
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final row in _groupRows(code))
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final group in row)
                          Padding(
                            padding: AppSpacing.recoveryGroup,
                            child: Text(
                              group,
                              maxLines: 1,
                              style: AppTypography.code,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
      footer: [AppFilledButton(label: 'Ya lo anoté', onPressed: onContinue)],
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}

/// "Confirma tu código": pide los caracteres de [challenge]. No se puede
/// continuar sin acertar; "Ver código otra vez" vuelve a mostrarlo.
class RecoveryCodeConfirmStep extends StatefulWidget {
  const RecoveryCodeConfirmStep({
    super.key,
    required this.challenge,
    required this.onConfirmed,
    required this.onShowAgain,
  });

  final RecoveryCodeChallenge challenge;
  final VoidCallback onConfirmed;
  final VoidCallback onShowAgain;

  @override
  State<RecoveryCodeConfirmStep> createState() =>
      _RecoveryCodeConfirmStepState();
}

class _RecoveryCodeConfirmStepState extends State<RecoveryCodeConfirmStep> {
  final TextEditingController _input = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _complete =>
      RecoveryCodeChallenge.normalizeInput(_input.text).length ==
      widget.challenge.count;

  void _submit() {
    if (!_complete) return;
    if (widget.challenge.verify(_input.text)) {
      AppHaptics.success();
      widget.onConfirmed();
      return;
    }
    AppHaptics.error();
    setState(() {
      _error =
          'Esos caracteres no coinciden con tu código. Revísalos o '
          'vuelve a ver el código.';
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.challenge;
    return OnboardingPage(
      title: 'Confirma tu código',
      message:
          'Escribe los caracteres ${c.positionsLabel} de tu código de '
          'recuperación, en ese orden. Así sabemos que lo anotaste bien.',
      body: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppSizes.pinMaxWidth),
            child: Semantics(
              textField: true,
              label:
                  'Caracteres ${c.positionsLabel} del código de recuperación',
              child: TextField(
                key: const ValueKey('confirm-code-field'),
                controller: _input,
                autofocus: true,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                keyboardType: TextInputType.visiblePassword,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                style: AppTypography.code,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                  const _UpperCaseFormatter(),
                  LengthLimitingTextInputFormatter(c.count),
                ],
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.surfaceHigh,
                  hintText: '${c.count} caracteres',
                  hintStyle: AppTypography.bodySecondary,
                  border: OutlineInputBorder(
                    borderRadius: AppRadii.mdAll,
                    borderSide: BorderSide(
                      color: _error == null
                          ? AppColors.border
                          : AppColors.danger,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: AppRadii.mdAll,
                    borderSide: BorderSide(
                      color: _error == null
                          ? AppColors.accentLight
                          : AppColors.danger,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
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
      ],
      footer: [
        AppFilledButton(
          label: 'Confirmar',
          onPressed: _complete ? _submit : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Ver código otra vez',
          onPressed: widget.onShowAgain,
        ),
      ],
    );
  }
}

/// Mostrar -> confirmar. Cada vez que se entra a confirmar se sortean
/// posiciones nuevas. NO ofrece salida: hay que acertar.
class RecoveryCodeFlow extends StatefulWidget {
  const RecoveryCodeFlow({
    super.key,
    required this.code,
    required this.onConfirmed,
    this.random,
    this.onConfirmingChanged,
    this.showTitle = 'Tu código de recuperación',
  });

  final String code;
  final VoidCallback onConfirmed;

  /// Inyectable para posiciones reproducibles en pruebas.
  final Random? random;
  final ValueChanged<bool>? onConfirmingChanged;
  final String showTitle;

  @override
  State<RecoveryCodeFlow> createState() => _RecoveryCodeFlowState();
}

class _RecoveryCodeFlowState extends State<RecoveryCodeFlow> {
  RecoveryCodeChallenge? _challenge;

  void _setConfirming(bool confirming) {
    setState(() {
      _challenge = confirming
          ? RecoveryCodeChallenge.generate(widget.code, random: widget.random)
          : null;
    });
    widget.onConfirmingChanged?.call(confirming);
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    return AnimatedSwitcher(
      duration: AppMotion.medium,
      switchInCurve: AppMotion.standard,
      child: challenge == null
          ? RecoveryCodeShowStep(
              key: const ValueKey('code-show'),
              code: widget.code,
              title: widget.showTitle,
              onContinue: () => _setConfirming(true),
            )
          : RecoveryCodeConfirmStep(
              key: ValueKey('code-confirm-${challenge.positions.join('-')}'),
              challenge: challenge,
              onConfirmed: widget.onConfirmed,
              onShowAgain: () => _setConfirming(false),
            ),
    );
  }
}
