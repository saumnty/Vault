import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/cloud/cloud_storage.dart';
import '../../../data/sync/sync_service.dart';
import '../../../shared/widgets/app_buttons.dart';
import 'onboarding_page.dart';

/// Paso 1: bienvenida en tres tarjetas.
class WelcomeStep extends StatelessWidget {
  const WelcomeStep({super.key, required this.onContinue, this.onRestore});

  final VoidCallback onContinue;

  /// F9: "Ya tengo una bóveda (restaurar)"; `null` oculta el botón.
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    return OnboardingPage(
      title: 'Bienvenido a Vault',
      message: 'Tus fotos, videos y archivos, protegidos solo para ti.',
      body: const [
        InfoCard(
          icon: Icons.lock_outline_rounded,
          title: 'Cifrado en tu teléfono',
          text:
              'Todo se cifra en tu dispositivo antes de guardarse. Sin tu PIN '
              'nadie puede abrirlo, ni siquiera nosotros.',
        ),
        SizedBox(height: AppSpacing.md),
        InfoCard(
          icon: Icons.cloud_done_outlined,
          title: 'Respaldo en tu Google Drive',
          text:
              'Opcional: una copia cifrada en un espacio privado de tu propio '
              'Drive, para no perder nada si pierdes el teléfono.',
        ),
        SizedBox(height: AppSpacing.md),
        InfoCard(
          icon: Icons.key_outlined,
          title: 'Código de recuperación',
          text:
              'Recibirás un código único. Si olvidas el PIN o cambias de '
              'teléfono, es la única forma de recuperar tu bóveda.',
        ),
      ],
      footer: [
        AppFilledButton(label: 'Empezar', onPressed: onContinue),
        if (onRestore != null) ...[
          const SizedBox(height: AppSpacing.sm),
          AppTextButton(
            label: 'Ya tengo una bóveda (restaurar)',
            onPressed: onRestore,
          ),
        ],
      ],
    );
  }
}

/// Reapertura a mitad del onboarding sin el código en memoria (el proceso
/// murió): hay que generar uno nuevo para poder confirmarlo.
class RegenerateCodeStep extends StatelessWidget {
  const RegenerateCodeStep({
    super.key,
    required this.onGenerate,
    this.busy = false,
  });

  final VoidCallback onGenerate;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return OnboardingPage(
      title: 'Falta tu código de recuperación',
      message:
          'Cerraste la app antes de confirmar tu código y, por seguridad, no '
          'se guarda en el teléfono. Genera uno nuevo para continuar: el '
          'anterior dejará de servir.',
      body: const [
        InfoCard(
          icon: Icons.key_outlined,
          title: 'Se te pedirá tu PIN',
          text:
              'Después verás el código nuevo y tendrás que confirmarlo antes '
              'de entrar a tu bóveda.',
        ),
      ],
      footer: [
        AppFilledButton(
          label: 'Generar nuevo código',
          icon: Icons.key_outlined,
          busy: busy,
          onPressed: onGenerate,
        ),
      ],
    );
  }
}

/// Paso 5: ofrecer biometría.
class BiometricStep extends StatelessWidget {
  const BiometricStep({
    super.key,
    required this.onEnable,
    required this.onSkip,
    this.busy = false,
    this.error,
  });

  final VoidCallback onEnable;
  final VoidCallback onSkip;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return OnboardingPage(
      title: 'Desbloqueo biométrico',
      message:
          '¿Quieres desbloquear Vault con tu huella o rostro? Seguirás '
          'pudiendo usar el PIN y puedes cambiarlo luego en Ajustes.',
      body: [
        const InfoCard(
          icon: Icons.fingerprint,
          title: 'Más rápido, igual de seguro',
          text:
              'La llave se guarda en el almacén seguro del teléfono y solo se '
              'libera tras verificar tu biometría.',
        ),
        if (error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Semantics(
            liveRegion: true,
            child: Text(
              error!,
              style: AppTypography.bodySecondary.copyWith(
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ],
      footer: [
        AppFilledButton(
          label: 'Activar',
          icon: Icons.fingerprint,
          busy: busy,
          onPressed: onEnable,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(label: 'Ahora no', onPressed: busy ? null : onSkip),
      ],
    );
  }
}

/// Paso 6: conectar Google Drive (opcional).
class DriveStep extends StatefulWidget {
  const DriveStep({super.key, required this.sync, required this.onDone});

  final SyncService sync;
  final VoidCallback onDone;

  @override
  State<DriveStep> createState() => _DriveStepState();
}

class _DriveStepState extends State<DriveStep> {
  bool _busy = false;
  String? _error;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sync.signIn();
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = describeSyncError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncSummary>(
      valueListenable: widget.sync.summary,
      builder: (context, summary, _) {
        final email = summary.accountEmail;
        final connected = email != null;
        return OnboardingPage(
          title: 'Respaldo en Google Drive',
          message: connected
              ? 'Listo: tu bóveda se respaldará cifrada en tu Drive.'
              : 'Conecta tu cuenta para guardar una copia cifrada en un '
                    'espacio privado de tu Drive (solo esta app puede verlo).',
          body: [
            if (connected)
              Semantics(
                container: true,
                label: 'Cuenta de Google conectada: $email',
                child: ExcludeSemantics(
                  child: Container(
                    key: const ValueKey('drive-connected'),
                    padding: AppSpacing.page,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: AppRadii.lgAll,
                      border: Border.all(color: AppColors.success),
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
              )
            else
              const InfoCard(
                icon: Icons.warning_amber_rounded,
                title: 'Sin respaldo, sin red de seguridad',
                text:
                    'Si no conectas Drive y pierdes el teléfono, perderás tus '
                    'archivos: el código de recuperación solo sirve para '
                    'recuperar lo que esté respaldado en la nube. Puedes '
                    'conectarlo después desde Ajustes.',
                color: AppColors.warning,
                border: AppColors.warning,
              ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: AppTypography.bodySecondary.copyWith(
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
          ],
          footer: connected
              ? [
                  AppFilledButton(
                    label: 'Entrar a mi bóveda',
                    onPressed: widget.onDone,
                  ),
                ]
              : [
                  AppFilledButton(
                    label: 'Conectar Google Drive',
                    icon: Icons.login,
                    busy: _busy,
                    onPressed: _connect,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextButton(
                    label: 'Más tarde',
                    onPressed: _busy ? null : widget.onDone,
                  ),
                ],
        );
      },
    );
  }
}
