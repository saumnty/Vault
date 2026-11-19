import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/sync/cloud_verification_service.dart';
import '../../shared/widgets/app_buttons.dart';

/// Ajustes > Sincronización y cuenta > «Verificar copia en la nube» (D75).
/// Muestra la cuenta que se comprueba (el correo SOLO en pantalla) y el
/// resultado. Nunca borra nada: solo comprueba y re-sube lo que falta.
class CloudVerificationScreen extends StatefulWidget {
  const CloudVerificationScreen({
    super.key,
    required this.service,
    required this.accountEmail,
    this.autoStart = true,
  });

  final CloudVerificationService service;

  /// Correo de la sesión actual (para mostrar).
  final String? Function() accountEmail;
  final bool autoStart;

  @override
  State<CloudVerificationScreen> createState() =>
      _CloudVerificationScreenState();
}

class _CloudVerificationScreenState extends State<CloudVerificationScreen> {
  CloudVerificationService get _s => widget.service;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart && !_s.isRunning) unawaited(_run());
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _s.verify();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.accountEmail();
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
                        'Verificar copia en la nube',
                        style: AppTypography.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: AppSpacing.page,
                children: [
                  Text(
                    'Cuenta: ${email ?? 'sin sesión'}',
                    key: const ValueKey('verify-account'),
                    style: AppTypography.body,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Comprueba que esta cuenta de Google tiene de verdad cada '
                    'archivo (tamaño y huella MD5), el respaldo de tus llaves '
                    'y el índice. Lo que falte y esté en el teléfono se vuelve '
                    'a subir. No se borra nada.',
                    style: AppTypography.bodySecondary,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  ValueListenableBuilder<CloudVerificationProgress?>(
                    valueListenable: _s.progress,
                    builder: (context, p, _) {
                      if (!_busy && p == null) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: AppRadii.pillAll,
                            child: LinearProgressIndicator(
                              value: p == null || p.total == 0
                                  ? null
                                  : p.done / p.total,
                              minHeight: AppSizes.progressBarHeight,
                              color: AppColors.accent,
                              backgroundColor: AppColors.surfaceHighest,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              p == null
                                  ? 'Comprobando…'
                                  : 'Comprobando… ${p.done}/${p.total}',
                              style: AppTypography.caption,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                        ],
                      );
                    },
                  ),
                  ValueListenableBuilder<CloudVerificationResult?>(
                    valueListenable: _s.last,
                    builder: (context, r, _) {
                      if (r == null || _busy) return const SizedBox.shrink();
                      final danger =
                          r.noCopy > 0 ||
                          r.outcome ==
                              CloudVerificationOutcome.blockedOtherVault;
                      return Semantics(
                        liveRegion: true,
                        child: Text(
                          r.summary,
                          key: const ValueKey('verify-result'),
                          style: AppTypography.body.copyWith(
                            color: danger ? AppColors.danger : null,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  AppFilledButton(
                    key: const ValueKey('verify-run'),
                    label: 'Comprobar ahora',
                    icon: Icons.fact_check_outlined,
                    busy: _busy,
                    onPressed: _busy ? null : _run,
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
