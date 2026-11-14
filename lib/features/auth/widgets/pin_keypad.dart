import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/haptics.dart';

/// Teclado numérico propio: 1-9, [biometría | vacío], 0, borrar.
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.onBiometric,
    this.enabled = true,
  });

  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;

  /// Si no es null aparece el botón de biometría.
  final VoidCallback? onBiometric;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget row(List<Widget> keys) =>
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: keys);
    Widget digit(int d) => _KeyButton(
      label: 'Dígito $d',
      onTap: () => onDigit(d),
      child: Text('$d', style: AppTypography.pinDigit),
    );

    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.4,
      duration: AppMotion.fast,
      child: IgnorePointer(
        ignoring: !enabled,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSizes.pinMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row([digit(1), digit(2), digit(3)]),
              const SizedBox(height: AppSizes.keypadGap),
              row([digit(4), digit(5), digit(6)]),
              const SizedBox(height: AppSizes.keypadGap),
              row([digit(7), digit(8), digit(9)]),
              const SizedBox(height: AppSizes.keypadGap),
              row([
                onBiometric == null
                    ? const SizedBox.square(dimension: AppSizes.keypadKey)
                    : _KeyButton(
                        label: 'Usar biometría',
                        onTap: onBiometric!,
                        child: const Icon(
                          Icons.fingerprint,
                          size: AppSizes.iconXl,
                          color: AppColors.accentLight,
                        ),
                      ),
                digit(0),
                _KeyButton(
                  label: 'Borrar',
                  onTap: onBackspace,
                  child: const Icon(
                    Icons.backspace_outlined,
                    size: AppSizes.iconLg,
                    color: AppColors.textSecondary,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyButton extends StatefulWidget {
  const _KeyButton({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _pressed = false;

  void _set(bool v) => setState(() => _pressed = v);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapCancel: () => _set(false),
        onTapUp: (_) => _set(false),
        onTap: () {
          AppHaptics.selection();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.88 : 1,
          duration: AppMotion.instant,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            width: AppSizes.keypadKey,
            height: AppSizes.keypadKey,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _pressed ? AppColors.accentContainer : AppColors.surface,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
