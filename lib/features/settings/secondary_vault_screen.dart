import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/services/app_paths.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/choice_sheet.dart';
import '../auth/widgets/pin_prompt_screen.dart';
import 'widgets/settings_widgets.dart';

/// Ajustes > Seguridad > «Bóveda adicional» (fase 8, DISENO_SENUELO §6.12,
/// §7, §8). SOLO existe en la bóveda principal: es el único sitio de la app
/// que muestra que hay (o puede haber) una segunda bóveda.
class SecondaryVaultScreen extends StatefulWidget {
  const SecondaryVaultScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<SecondaryVaultScreen> createState() => _SecondaryVaultScreenState();
}

/// Qué protege la bóveda adicional (§7, textos para el usuario).
const List<String> secondaryVaultProtects = [
  'Si alguien te obliga a abrir Vault y le das el PIN de la bóveda '
      'adicional, verá solo lo que guardes ahí.',
  'Probar PIN después tiene el mismo límite de intentos que siempre.',
];

/// Qué NO protege (límites honestos de la variante «disimulo», §7).
const List<String> secondaryVaultDoesNotProtect = [
  'Quien examine el teléfono (archivos, espacio ocupado) o tu Google '
      'Drive puede notar que hay más datos de los que se ven.',
  'Face ID / la huella abren la bóveda principal.',
  'Midiendo el tiempo del desbloqueo se puede saber que hay una segunda '
      'bóveda (no cuál se abrió).',
  'Alguien que conozca Vault puede notar que a la bóveda adicional le '
      'faltan la nube, el código de recuperación y la biometría.',
  'Si pierdes el teléfono, lo restauras en otro u olvidas su PIN, su '
      'contenido se pierde.',
];

String _lockout(PinLockedOutException e) =>
    'Demasiados intentos. Espera ${e.remaining.inSeconds + 1} s';

class _SecondaryVaultScreenState extends State<SecondaryVaultScreen> {
  AuthController get _auth => widget.auth;

  SecondaryVaultStatus? _status;
  bool _bioEnabled = false;
  int? _sizeBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final status = await _auth.secondaryStatus();
    final bio = await _auth.isBiometricUnlockEnabled();
    final size = status == SecondaryVaultStatus.none ? null : _dirSize();
    if (!mounted) return;
    setState(() {
      _status = status;
      _bioEnabled = bio;
      _sizeBytes = size;
    });
  }

  static int? _dirSize() {
    if (!AppPaths.isInitialized) return null;
    final root = VaultPaths.secondary.root;
    if (!root.existsSync()) return 0;
    var n = 0;
    for (final f in root.listSync(recursive: true).whereType<File>()) {
      try {
        n += f.lengthSync();
      } on FileSystemException {
        // en uso
      }
    }
    return n;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<T?> _guard<T>(Future<T> Function() op) async {
    setState(() => _busy = true);
    try {
      return await op();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  // ------------------------------------------------------------- crear

  Future<void> _create() async {
    String? primaryPin;
    String? newPin;
    var ok = await showPinPrompt(
      context,
      title: 'Tu PIN principal',
      message: 'Confirma que eres tú.',
      onSubmit: (pin) async {
        primaryPin = pin;
        return null;
      },
    );
    if (!ok || !mounted) return;
    ok = await showPinPrompt(
      context,
      title: 'PIN de la bóveda adicional',
      message: 'Elige un PIN de 6 dígitos distinto del principal.',
      minLength: AuthController.minNewPinLength,
      onSubmit: (pin) async {
        if (pin == primaryPin) return PinNotAllowedException.message;
        newPin = pin;
        return null;
      },
    );
    if (!ok || !mounted) return;
    ok = await showPinPrompt(
      context,
      title: 'Confirma el PIN',
      message: 'Escríbelo otra vez.',
      minLength: AuthController.minNewPinLength,
      onSubmit: (pin) async => pin == newPin ? null : 'Los PIN no coinciden',
    );
    if (!ok || !mounted) return;
    var disableBio = false;
    if (_bioEnabled) {
      disableBio = await showConfirmSheet(
        context,
        title: 'Face ID / huella abren la bóveda principal',
        message:
            'Si alguien te obliga a mirar el teléfono o a poner el dedo, '
            'abrirá la bóveda principal. Para que la bóveda adicional sirva '
            'de algo, desactívalos.',
        confirmLabel: 'Desactivar (recomendado)',
      );
      if (!mounted) return;
    }
    final created = await _guard(() async {
      try {
        return await _auth.createSecondaryVault(
          primaryPin: primaryPin!,
          newPin: newPin!,
          disableBiometrics: disableBio,
        );
      } on PinNotAllowedException {
        _snack(PinNotAllowedException.message);
        return null;
      } on PinLockedOutException catch (e) {
        _snack(_lockout(e));
        return null;
      } on RotationInProgressException {
        _snack('Disponible al terminar el cambio de llave maestra');
        return null;
      } on Object {
        _snack('No se pudo crear la bóveda adicional');
        return null;
      }
    });
    if (created == false) _snack('El PIN principal no era correcto');
    if (created == true) {
      _snack(
        'Listo. Bloquea Vault y entra con el PIN nuevo para llenarla con '
        'archivos creíbles.',
      );
    }
  }

  // ------------------------------------------------------- cambiar PIN

  Future<void> _changePin() async {
    String? primaryPin;
    String? currentPin;
    String? newPin;
    var ok = await showPinPrompt(
      context,
      title: 'Tu PIN principal',
      message: 'Confirma que eres tú.',
      onSubmit: (pin) async {
        primaryPin = pin;
        return null;
      },
    );
    if (!ok || !mounted) return;
    ok = await showPinPrompt(
      context,
      title: 'PIN actual de la bóveda adicional',
      onSubmit: (pin) async {
        currentPin = pin;
        return null;
      },
    );
    if (!ok || !mounted) return;
    ok = await showPinPrompt(
      context,
      title: 'PIN nuevo de la bóveda adicional',
      message: 'Elige un PIN de 6 dígitos distinto del principal.',
      minLength: AuthController.minNewPinLength,
      onSubmit: (pin) async {
        if (pin == primaryPin) return PinNotAllowedException.message;
        newPin = pin;
        return null;
      },
    );
    if (!ok || !mounted) return;
    ok = await showPinPrompt(
      context,
      title: 'Confirma el PIN nuevo',
      message: 'Escríbelo otra vez.',
      minLength: AuthController.minNewPinLength,
      onSubmit: (pin) async => pin == newPin ? null : 'Los PIN no coinciden',
    );
    if (!ok || !mounted) return;
    final r = await _guard(() async {
      try {
        return await _auth.changeSecondaryPin(
          primaryPin: primaryPin!,
          currentAltPin: currentPin!,
          newAltPin: newPin!,
        );
      } on PinNotAllowedException {
        _snack(PinNotAllowedException.message);
      } on PinLockedOutException catch (e) {
        _snack(_lockout(e));
      } on Object {
        _snack('No se pudo cambiar el PIN');
      }
      return null;
    });
    switch (r) {
      case ChangeSecondaryPinResult.changed:
        _snack('PIN de la bóveda adicional cambiado');
      case ChangeSecondaryPinResult.wrongPrimaryPin:
        _snack('El PIN principal no era correcto');
      case ChangeSecondaryPinResult.wrongSecondaryPin:
        _snack('El PIN actual de la bóveda adicional no era correcto');
      case null:
        break;
    }
  }

  // ----------------------------------------------------------- eliminar

  Future<void> _delete() async {
    final size = _sizeBytes;
    final confirmed = await showConfirmSheet(
      context,
      title: '¿Eliminar la bóveda adicional?',
      message:
          'Se borrará para siempre todo su contenido'
          '${size == null ? '' : ' (${formatBytes(size)})'}. No tiene copia '
          'en la nube ni código de recuperación: no se podrá recuperar.',
      confirmLabel: 'Eliminar',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    String? primaryPin;
    final ok = await showPinPrompt(
      context,
      title: 'Tu PIN principal',
      message: 'Confirma que eres tú.',
      onSubmit: (pin) async {
        primaryPin = pin;
        return null;
      },
    );
    if (!ok || !mounted) return;
    final done = await _guard(() async {
      try {
        return await _auth.deleteSecondaryVault(primaryPin!);
      } on PinLockedOutException catch (e) {
        _snack(_lockout(e));
      } on Object {
        _snack('No se pudo eliminar la bóveda adicional');
      }
      return null;
    });
    if (done == false) _snack('El PIN principal no era correcto');
    if (done == true) _snack('Bóveda adicional eliminada');
  }

  // ---------------------------------------------------------------- UI

  Widget _bullets(String title, List<String> items, IconData icon, Color c) =>
      Padding(
        padding: AppSpacing.page,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTypography.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            for (final t in items)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: c),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(t, style: AppTypography.bodySecondary),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final status = _status;
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
                      child: const Text(
                        'Bóveda adicional',
                        style: AppTypography.title,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: status == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      key: const ValueKey('secondary-vault-list'),
                      padding: AppSpacing.page,
                      children: [
                        const Padding(
                          padding: AppSpacing.page,
                          child: Text(
                            'Crea una segunda bóveda con otro PIN. Si alguien '
                            'te obliga a abrir Vault, puedes darle ese PIN: '
                            'verá solo lo que guardes ahí. Sirve para '
                            'disimular, no para ocultar.',
                            style: AppTypography.body,
                          ),
                        ),
                        Padding(
                          padding: AppSpacing.page,
                          child: Text(
                            'La bóveda adicional NO se copia a Google Drive '
                            'ni tiene código de recuperación. Si pierdes el '
                            'teléfono, lo restauras en otro o olvidas su PIN, '
                            'su contenido se pierde.',
                            key: const ValueKey('secondary-no-backup'),
                            style: AppTypography.bodySecondary.copyWith(
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                        _bullets(
                          'Qué protege',
                          secondaryVaultProtects,
                          Icons.check_circle_outline,
                          AppColors.success,
                        ),
                        _bullets(
                          'Qué NO protege',
                          secondaryVaultDoesNotProtect,
                          Icons.remove_circle_outline,
                          AppColors.danger,
                        ),
                        if (status != SecondaryVaultStatus.none && _bioEnabled)
                          Padding(
                            padding: AppSpacing.page,
                            child: Text(
                              'Tienes activados Face ID / la huella: abren la '
                              'bóveda principal. Desactívalos en Seguridad '
                              'para que esto sirva.',
                              key: const ValueKey('secondary-bio-warning'),
                              style: AppTypography.bodySecondary.copyWith(
                                color: AppColors.danger,
                              ),
                            ),
                          ),
                        SettingsSection(
                          title: switch (status) {
                            SecondaryVaultStatus.none => 'Desactivada',
                            SecondaryVaultStatus.active => 'Activa',
                            SecondaryVaultStatus.damaged => 'Dañada',
                          },
                          children: [
                            if (status == SecondaryVaultStatus.none)
                              SettingsTile(
                                icon: Icons.add_box_outlined,
                                title: 'Crear bóveda adicional',
                                onTap: _busy ? null : _create,
                              ),
                            if (status == SecondaryVaultStatus.active)
                              SettingsTile(
                                icon: Icons.pin_outlined,
                                title: 'Cambiar su PIN',
                                subtitle:
                                    'Hace falta tu PIN principal y el actual '
                                    'de la bóveda adicional',
                                onTap: _busy ? null : _changePin,
                              ),
                            if (status == SecondaryVaultStatus.damaged)
                              const SettingsTile(
                                icon: Icons.error_outline,
                                title: 'No se puede abrir',
                                subtitle:
                                    'Elimínala y crea otra si la necesitas',
                              ),
                            if (status != SecondaryVaultStatus.none)
                              SettingsTile(
                                icon: Icons.delete_forever_outlined,
                                title: 'Eliminar bóveda adicional',
                                subtitle: _sizeBytes == null
                                    ? null
                                    : 'Ocupa ${formatBytes(_sizeBytes!)}',
                                destructive: true,
                                onTap: _busy ? null : _delete,
                              ),
                          ],
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
