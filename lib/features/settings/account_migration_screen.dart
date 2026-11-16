import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/migration/account_migration_service.dart';
import '../../data/migration/migration_repository.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/choice_sheet.dart';

/// "Cambiar de cuenta de Google" CON migración: hoja explicativa, progreso,
/// pausa/reanudación y las decisiones finales. El estado vive en la BD
/// (sobrevive a matar la app); aquí solo se muestra y se dirige.
class AccountMigrationScreen extends StatefulWidget {
  const AccountMigrationScreen({super.key, required this.service});

  final AccountMigrationService service;

  @override
  State<AccountMigrationScreen> createState() => _AccountMigrationScreenState();
}

class _AccountMigrationScreenState extends State<AccountMigrationScreen> {
  AccountMigrationService get _s => widget.service;

  MigrationPlan? _plan;
  bool _loadingPlan = false;
  bool _wasActive = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    await _s.refresh();
    if (!mounted) return;
    _wasActive = _s.status.value.active;
    if (!_wasActive) await _loadPlan();
  }

  Future<void> _loadPlan() async {
    setState(() => _loadingPlan = true);
    try {
      final plan = await _s.plan();
      if (mounted) setState(() => _plan = plan);
    } finally {
      if (mounted) setState(() => _loadingPlan = false);
    }
  }

  void _snack(String message) {
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
      if (mounted) _snack(e.message);
    } on Object {
      if (mounted) _snack('No se pudo completar. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    final plan = _plan;
    if (plan == null) return;
    // No se espera: el flujo corre y se sigue por [status].
    unawaited(
      _guard(() async {
        await _s.start(plan);
      }),
    );
  }

  Future<void> _cancelAndRestore() async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Cancelar el cambio de cuenta?',
      message:
          'Vuelves a tu cuenta anterior y todo queda como estaba. Lo que ya se '
          'haya subido a la cuenta nueva no se borra. Se te pedirá elegir la '
          'cuenta anterior al iniciar sesión.',
      confirmLabel: 'Cancelar el cambio',
      cancelLabel: 'Seguir',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(_s.cancelAndRestore);
  }

  Future<void> _deleteOld(String? oldEmail) async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Borrar los datos de la cuenta anterior?',
      message:
          'Se borrarán de forma PERMANENTE todos los archivos de Vault de '
          '${oldEmail ?? 'la cuenta anterior'} (sin papelera ni versiones '
          'anteriores). Tus archivos ya están en la cuenta nueva y en este '
          'teléfono. Para borrar tendrás que iniciar sesión un momento con la '
          'cuenta anterior.',
      confirmLabel: 'Borrar permanentemente',
      cancelLabel: 'Ahora no',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(_s.deleteOldAccountData);
    if (mounted && !_s.status.value.active) {
      _snack('Datos de la cuenta anterior borrados');
    }
  }

  @override
  Widget build(BuildContext context) {
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
                        'Cambiar de cuenta de Google',
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
                  child: ValueListenableBuilder<MigrationStatus>(
                    valueListenable: _s.status,
                    builder: (context, st, _) {
                      if (_wasActive && !st.active) {
                        return _Finished(
                          onClose: () => Navigator.of(context).maybePop(),
                        );
                      }
                      if (st.active) _wasActive = true;
                      return ListView(
                        padding: AppSpacing.page,
                        children: st.active ? _active(st) : _intro(),
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

  // ----------------------------------------------------------- hoja previa

  List<Widget> _intro() {
    final plan = _plan;
    return [
      const _Block(
        title: 'Qué va a pasar',
        lines: [
          '1. Se descargan de tu cuenta actual los archivos que no están en '
              'este teléfono (verificando que no se corrompan).',
          '2. Inicias sesión con la cuenta NUEVA. Si ya tiene el respaldo de '
              'OTRA bóveda de Vault, el cambio se detiene sin tocar nada.',
          '3. Se suben todos tus archivos, cifrados, a la cuenta nueva y se '
              'verifica cada uno. También el respaldo de recuperación y el '
              'índice.',
          '4. Al final eliges si borrar o conservar los datos de la cuenta '
              'anterior.',
        ],
      ),
      const SizedBox(height: AppSpacing.lg),
      if (_loadingPlan || plan == null)
        const Center(child: CircularProgressIndicator())
      else
        _PlanBlock(plan: plan),
      const SizedBox(height: AppSpacing.lg),
      const _Block(
        title: 'Antes de empezar',
        lines: [
          'Usa Wi-Fi: puede mover muchos archivos.',
          'Mientras dura, la sincronización normal queda en pausa y la caché '
              'no libera espacio.',
          'Puedes pausar o cancelar cuando quieras sin perder nada: cancelar '
              'te devuelve a tu cuenta anterior.',
          'Si se interrumpe (cierras la app, se va la red o se bloquea), '
              'continúa donde se quedó cuando vuelvas a abrir la bóveda.',
        ],
      ),
      const SizedBox(height: AppSpacing.xl),
      AppFilledButton(
        label: 'Empezar',
        icon: Icons.swap_horiz,
        busy: _busy,
        onPressed: plan != null && plan.enoughLocalSpace && !_busy
            ? _start
            : null,
      ),
      const SizedBox(height: AppSpacing.sm),
      AppTextButton(
        label: 'Ahora no',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    ];
  }

  // ---------------------------------------------------------- en curso

  String _phaseTitle(MigrationPhase p) => switch (p) {
    MigrationPhase.downloading => 'Descargando de la cuenta anterior',
    MigrationPhase.signInNew => 'Elegir la cuenta nueva',
    MigrationPhase.checkingNew => 'Comprobando la cuenta nueva',
    MigrationPhase.uploading => 'Subiendo a la cuenta nueva',
    MigrationPhase.finalizing => 'Guardando el respaldo y el índice',
    MigrationPhase.askDeleteOld =>
      'Listo: tus archivos están en la cuenta nueva',
    MigrationPhase.blockedOtherVault => 'La cuenta nueva ya tiene otra bóveda',
    MigrationPhase.blockedQuota => 'La cuenta nueva no tiene espacio',
  };

  List<Widget> _active(MigrationStatus st) {
    final phase = st.phase!;
    final canResume =
        !st.running &&
        (phase == MigrationPhase.downloading ||
            phase == MigrationPhase.checkingNew ||
            phase == MigrationPhase.uploading ||
            phase == MigrationPhase.finalizing);
    final progressPhases =
        phase == MigrationPhase.downloading ||
        phase == MigrationPhase.uploading;
    return [
      Semantics(
        header: true,
        liveRegion: true,
        child: Text(_phaseTitle(phase), style: AppTypography.titleSmall),
      ),
      if (st.oldEmail != null || st.newEmail != null) ...[
        const SizedBox(height: AppSpacing.xs),
        Text(
          [
            if (st.oldEmail != null) 'Cuenta anterior: ${st.oldEmail}',
            if (st.newEmail != null) 'Cuenta nueva: ${st.newEmail}',
          ].join('\n'),
          style: AppTypography.bodySecondary,
        ),
      ],
      const SizedBox(height: AppSpacing.md),
      if (progressPhases || st.running)
        ClipRRect(
          borderRadius: AppRadii.pillAll,
          child: LinearProgressIndicator(
            key: const ValueKey('migration-progress'),
            value: st.running && !progressPhases ? null : st.fraction,
            minHeight: AppSizes.progressBarHeight,
            color: AppColors.accent,
            backgroundColor: AppColors.surfaceHighest,
          ),
        ),
      if (st.itemsTotal > 0) ...[
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${st.itemsDone} de ${st.itemsTotal}',
          style: AppTypography.caption,
        ),
      ],
      if (st.message != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          liveRegion: true,
          child: Text(
            st.message!,
            key: const ValueKey('migration-message'),
            style: AppTypography.bodySecondary.copyWith(
              color: st.needsAttention ? AppColors.danger : null,
            ),
          ),
        ),
      ],
      ..._explain(phase),
      const SizedBox(height: AppSpacing.lg),
      if (st.running)
        AppTextButton(label: 'Pausar', onPressed: _s.pause)
      else ...[
        if (canResume)
          AppFilledButton(
            label: 'Reanudar',
            icon: Icons.play_arrow,
            busy: _busy,
            onPressed: _busy ? null : () => _guard(_s.resume),
          ),
        if (phase == MigrationPhase.signInNew)
          AppFilledButton(
            label: 'Elegir cuenta nueva',
            icon: Icons.account_circle_outlined,
            busy: _busy,
            onPressed: _busy ? null : () => _guard(_s.resume),
          ),
        if (phase == MigrationPhase.blockedOtherVault ||
            phase == MigrationPhase.blockedQuota)
          AppFilledButton(
            label: 'Elegir otra cuenta',
            icon: Icons.swap_horiz,
            busy: _busy,
            onPressed: _busy ? null : () => _guard(_s.chooseAnotherAccount),
          ),
        if (phase == MigrationPhase.askDeleteOld) ...[
          AppFilledButton(
            label: 'Borrar datos de la cuenta anterior',
            icon: Icons.delete_outline,
            destructive: true,
            busy: _busy,
            onPressed: _busy ? null : () => _deleteOld(st.oldEmail),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppFilledButton(
            label: 'Conservarlos',
            onPressed: _busy ? null : () => _guard(_s.keepOldAccountData),
          ),
        ],
      ],
      if (phase != MigrationPhase.askDeleteOld && !st.running) ...[
        const SizedBox(height: AppSpacing.sm),
        AppTextButton(
          label: 'Cancelar y volver a la cuenta anterior',
          onPressed: _busy ? null : _cancelAndRestore,
        ),
      ],
    ];
  }

  List<Widget> _explain(MigrationPhase phase) {
    final text = switch (phase) {
      MigrationPhase.blockedOtherVault =>
        'Esa cuenta ya guarda el respaldo de OTRA bóveda de Vault. No se '
            'subió ni se borró nada. Elige otra cuenta o cancela.',
      MigrationPhase.blockedQuota =>
        'Esa cuenta no tiene espacio libre suficiente en Google Drive / '
            'Google One para tus archivos. No se subió nada. Libera espacio, '
            'elige otra cuenta o cancela.',
      MigrationPhase.askDeleteOld =>
        'Los archivos, el respaldo de recuperación y el índice ya están en '
            'la cuenta nueva y verificados. Los datos de la cuenta anterior '
            'siguen ahí: bórralos para liberar espacio o consérvalos como '
            'copia extra.',
      _ => null,
    };
    if (text == null) return const [];
    return [
      const SizedBox(height: AppSpacing.md),
      Text(text, style: AppTypography.body),
    ];
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

class _PlanBlock extends StatelessWidget {
  const _PlanBlock({required this.plan});
  final MigrationPlan plan;

  @override
  Widget build(BuildContext context) {
    final free = plan.freeBytes;
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
            _row('Cuenta actual', plan.oldEmail ?? 'sin sesión'),
            _row('Archivos', '${plan.itemCount}'),
            _row(
              'A descargar ahora',
              plan.bytesToDownload == 0
                  ? 'nada (todo está en el teléfono)'
                  : formatBytes(plan.bytesToDownload),
            ),
            _row('Ocupará en la cuenta nueva', formatBytes(plan.uploadBytes)),
            _row(
              'Espacio libre en el teléfono',
              free == null ? 'no se pudo comprobar' : formatBytes(free),
            ),
            if (!plan.enoughLocalSpace) ...[
              const SizedBox(height: AppSpacing.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  'No hay espacio suficiente en el teléfono para bajar tus '
                  'archivos. Libera espacio e inténtalo de nuevo.',
                  style: AppTypography.bodySecondary.copyWith(
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
            if (plan.lostCount > 0) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${plan.lostCount} archivo(s) ya no existen ni en el teléfono '
                'ni en la nube: no se pueden migrar.',
                style: AppTypography.bodySecondary,
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'La cuenta nueva necesita ese espacio libre en su Google Drive '
              '(Google One). Se comprueba al iniciar sesión con ella, antes '
              'de subir nada.',
              style: AppTypography.caption,
            ),
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

class _Finished extends StatelessWidget {
  const _Finished({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppSpacing.page,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: AppSizes.iconXl,
            color: AppColors.accentLight,
          ),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            liveRegion: true,
            child: const Text(
              'Listo',
              textAlign: TextAlign.center,
              style: AppTypography.title,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'El cambio de cuenta terminó. La sincronización normal se '
            'reanuda con la cuenta actual.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySecondary,
          ),
          const SizedBox(height: AppSpacing.xl),
          AppFilledButton(label: 'Cerrar', onPressed: onClose),
        ],
      ),
    );
  }
}
