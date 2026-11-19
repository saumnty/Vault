import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/migration/account_migration_service.dart';
import '../../data/migration/migration_repository.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/choice_sheet.dart';
import 'account_migration_screen.dart';

/// D76 (`docs/DISENO_MIGRACION_ATASCADA.md` §B.1): «Cambio de cuenta sin
/// terminar». La raíz la muestra UNA vez por desbloqueo si hay un cambio de
/// cuenta guardado y no está corriendo. Nada se reanuda ni se purga antes de
/// que el usuario elija:
///
/// * **Continuar** → la pantalla del cambio de cuenta y `resume()`.
/// * **Cancelar y quedarme en «cuenta actual»** → `abandonStayOnCurrent()`
///   (y después la verificación de la copia en esa cuenta). Sin sesión, el
///   botón pide iniciar sesión primero.
/// * «Volver a la cuenta anterior» (`cancelAndRestore`), secundaria.
///
/// Los correos solo se muestran aquí; nunca se registran.
class UnfinishedMigrationScreen extends StatefulWidget {
  const UnfinishedMigrationScreen({
    super.key,
    required this.service,
    this.unverifiedCount,
  });

  final AccountMigrationService service;

  /// Cuántos archivos no tienen copia comprobada en la cuenta actual (`null`
  /// = no se sabe).
  final Future<int> Function()? unverifiedCount;

  @override
  State<UnfinishedMigrationScreen> createState() =>
      _UnfinishedMigrationScreenState();
}

class _UnfinishedMigrationScreenState extends State<UnfinishedMigrationScreen> {
  AccountMigrationService get _s => widget.service;
  bool _busy = false;
  int? _unverified;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _s.refresh();
    } on Object {
      // bloqueada: la pantalla se cierra con el bloqueo
    }
    final count = widget.unverifiedCount;
    if (count == null) return;
    try {
      final n = await count();
      if (mounted) setState(() => _unverified = n);
    } on Object {
      // sin cifra
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
    } on MigrationException catch (e) {
      _snack(e.message);
    } on Object {
      _snack('No se pudo completar. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    final nav = Navigator.of(context);
    unawaited(_s.resume());
    await nav.pushReplacement<void, void>(
      MaterialPageRoute<void>(
        builder: (_) => AccountMigrationScreen(service: _s),
      ),
    );
  }

  Future<void> _signInFirst() => _guard(() async {
    await _s.signInCurrent();
    if (mounted) setState(() {});
  });

  Future<void> _stay(String email) async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Quedarte en esta cuenta?',
      message:
          'El cambio de cuenta se da por terminado y te quedas en $email. '
          'No se borra nada (ni en el teléfono ni en ninguna cuenta). Después '
          'se comprueba qué archivos tiene de verdad esta cuenta y se suben '
          'los que falten desde el teléfono.',
      confirmLabel: 'Quedarme en esta cuenta',
      cancelLabel: 'Volver',
    );
    if (!ok || !mounted) return;
    await _guard(() async {
      await _s.abandonStayOnCurrent();
      if (!mounted) return;
      _snack('Listo. Comprobando tu copia en la nube…');
      Navigator.of(context).maybePop();
    });
  }

  Future<void> _backToOld() async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Volver a la cuenta anterior?',
      message:
          'Se restauran las referencias de la cuenta anterior y se te pide '
          'iniciar sesión con ella. Si esa cuenta ya no tiene tus archivos, '
          'es mejor «Cancelar y quedarme» en la cuenta actual.',
      confirmLabel: 'Volver a la anterior',
      cancelLabel: 'Seguir aquí',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(() async {
      await _s.cancelAndRestore();
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ValueListenableBuilder<MigrationStatus>(
          valueListenable: _s.status,
          builder: (context, st, _) {
            final phase = st.phase;
            final current = _s.currentAccountEmail;
            return ListView(
              padding: AppSpacing.page,
              children: [
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  header: true,
                  liveRegion: true,
                  child: const Text(
                    'Cambio de cuenta sin terminar',
                    key: ValueKey('unfinished-migration-title'),
                    style: AppTypography.title,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (phase != null)
                  Text(
                    'Se quedó en: ${migrationPhaseLabel(phase)}',
                    style: AppTypography.body,
                  ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  [
                    'Cuenta anterior: ${st.oldEmail ?? 'desconocida'}',
                    'Cuenta actual: ${current ?? 'sin sesión'}',
                  ].join('\n'),
                  style: AppTypography.bodySecondary,
                ),
                const SizedBox(height: AppSpacing.md),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _unverified == null
                        ? 'La sincronización está en pausa.'
                        : 'La sincronización está en pausa. $_unverified '
                              'archivo(s) no tienen copia comprobada en la '
                              'cuenta actual.',
                    key: const ValueKey('unfinished-migration-paused'),
                    style: AppTypography.body.copyWith(color: AppColors.danger),
                  ),
                ),
                if (st.message != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(st.message!, style: AppTypography.bodySecondary),
                ],
                const SizedBox(height: AppSpacing.xl),
                if (phase != null && phase != MigrationPhase.unknown) ...[
                  AppFilledButton(
                    key: const ValueKey('unfinished-continue'),
                    label: 'Continuar',
                    icon: Icons.play_arrow,
                    busy: _busy,
                    onPressed: _busy ? null : _continue,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (current == null)
                  AppFilledButton(
                    key: const ValueKey('unfinished-sign-in'),
                    label: 'Inicia sesión primero',
                    icon: Icons.login,
                    busy: _busy,
                    onPressed: _busy ? null : _signInFirst,
                  )
                else
                  AppFilledButton(
                    key: const ValueKey('unfinished-stay'),
                    label: 'Cancelar y quedarme en $current',
                    icon: Icons.check,
                    busy: _busy,
                    onPressed: _busy ? null : () => _stay(current),
                  ),
                const SizedBox(height: AppSpacing.xl),
                if (phase != null &&
                    phase != MigrationPhase.askDeleteOld &&
                    phase != MigrationPhase.unknown)
                  AppTextButton(
                    key: const ValueKey('unfinished-back-to-old'),
                    label: 'Volver a la cuenta anterior',
                    onPressed: _busy ? null : _backToOld,
                  ),
                AppTextButton(
                  key: const ValueKey('unfinished-later'),
                  label: 'Ahora no (sigue en pausa)',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'Mientras no elijas, la sincronización sigue en pausa y la '
                  'caché no libera espacio. Lo encontrarás en Ajustes > '
                  'Sincronización y cuenta.',
                  style: AppTypography.caption,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
