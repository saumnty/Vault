import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/crypto/aes_gcm_backend.dart';
import '../../core/crypto/argon2_backend.dart';
import '../../core/crypto/key_rotation_store.dart';
import '../../core/logging/diagnostics_buffer.dart';
import '../../core/logging/diagnostics_store.dart';
import '../../data/sync/sync_service.dart' show SyncSummary;
import '../../shared/widgets/choice_sheet.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_buttons.dart';
import 'settings_environment.dart';

/// Nombre legible (y estable también en release, sin depender de
/// `runtimeType`) del backend AES en uso.
String aesBackendLabel(AesGcmBackend b) => switch (b) {
  NativeAesGcmBackend() => 'Nativo',
  DartAesGcmBackend() => 'Dart',
  FallbackAesGcmBackend() => 'Nativo con respaldo Dart',
  _ => 'Otro',
};

/// Nombre legible del backend Argon2 en uso.
String argon2BackendLabel(Argon2Backend b) => switch (b) {
  SodiumArgon2Backend() => 'libsodium',
  IsolateDartArgon2Backend() => 'Dart (isolate)',
  DartArgon2Backend() => 'Dart',
  FallbackArgon2Backend() => 'libsodium con respaldo Dart',
  _ => 'Otro',
};

/// Datos no sensibles del encabezado.
class DiagnosticsHeader {
  const DiagnosticsHeader({
    required this.version,
    required this.platform,
    required this.aes,
    required this.argon2,
    required this.mode,
    this.rotation = 'ninguno',
  });

  final String version;
  final String platform;
  final String aes;
  final String argon2;
  final String mode;

  /// Estado del cambio de llave maestra (fase y generaciones; nada más).
  final String rotation;

  String toText() =>
      'Versión: $version\nPlataforma: $platform\nAES: $aes\n'
      'Argon2: $argon2\nModo: $mode\nCambio de llave: $rotation';
}

/// Fase del cambio de llave para el diagnóstico (sin datos personales: ni
/// correo, ni ids, ni mensajes con nombres).
String rotationDiagnosticsLabel(RotationRecord? rec) {
  if (rec == null) return 'ninguno';
  final resume = rec.resumePhase == null ? '' : ' → ${rec.resumePhase!.name}';
  return '${rec.phase.name}$resume (gen ${rec.fromGen} → ${rec.toGen})';
}

/// D78 (§B.5): estado de la nube para el Diagnóstico (solo lectura). Solo
/// nombres de fase/motivo y conteos: ni correos, ni ids, ni nombres.
String cloudDiagnosticsText({
  required SyncSummary summary,
  String? migrationPhase,
  String? verificationLine,
}) {
  final c = summary.cloud;
  final q = summary.counts;
  return [
    'Cambio de cuenta: ${migrationPhase ?? 'ninguno'}',
    'Sesión de Google: ${summary.accountEmail == null ? 'no' : 'sí'}',
    'Pausa: ${summary.pauseReason?.name ?? 'ninguna'}',
    'Archivos: ${c.total}; solo en el teléfono=${c.localOnly}, '
        'sin comprobar=${c.unverified}, sin copia=${c.noCopy}',
    'Cola: pendientes=${q.pending}, subiendo=${q.uploading}, '
        'con error=${q.errors}',
    'Última verificación: ${verificationLine ?? 'ninguna en esta sesión'}',
  ].join('\n');
}

/// Reúne el encabezado real (versión, SO, backends, modo).
Future<DiagnosticsHeader> loadDiagnosticsHeader({
  AppVersionLoader versionLoader = loadAppVersion,
}) async {
  String version;
  try {
    version = (await versionLoader()).toString();
  } catch (_) {
    version = 'desconocida';
  }
  String platform;
  try {
    platform = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  } catch (_) {
    platform = 'desconocida';
  }
  return DiagnosticsHeader(
    version: version,
    platform: DiagnosticsBuffer.sanitize(platform, max: 120),
    aes: _safe(() => aesBackendLabel(AesGcmBackend.current)),
    argon2: _safe(() => argon2BackendLabel(Argon2Backend.current)),
    mode: kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
    rotation: rotationDiagnosticsLabel(RotationKeyStore.shared.record.value),
  );
}

String _safe(String Function() f) {
  try {
    return f();
  } catch (_) {
    return 'no disponible';
  }
}

/// Ajustes > Acerca de > Diagnóstico: registro en memoria (sin datos del
/// usuario) para soporte. Copiar al portapapeles; no hay "Compartir" porque
/// la app no incluye share_plus.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    this.buffer,
    this.store,
    this.headerLoader = loadDiagnosticsHeader,
    this.cloudStateLoader,
  });

  /// Por defecto [DiagnosticsBuffer.instance].
  final DiagnosticsBuffer? buffer;

  /// D78: diagnóstico persistente. Por defecto [DiagnosticsStore.instance]
  /// (solo si no se inyecta [buffer]); `null` = solo la memoria.
  final DiagnosticsStore? store;
  final Future<DiagnosticsHeader> Function() headerLoader;

  /// D78: estado de la nube (solo conteos y nombres de fase; sin datos).
  final Future<String> Function()? cloudStateLoader;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late final DiagnosticsBuffer _buffer =
      widget.buffer ?? DiagnosticsBuffer.instance;
  late final DiagnosticsStore? _store =
      widget.store ??
      (widget.buffer == null ? DiagnosticsStore.instance : null);
  DiagnosticsHeader? _header;
  String? _cloudState;
  List<DiagEntry> _entries = const [];
  bool _reloading = false;
  bool _reloadAgain = false;

  @override
  void initState() {
    super.initState();
    widget.headerLoader().then((h) {
      if (mounted) setState(() => _header = h);
    });
    final cloud = widget.cloudStateLoader;
    if (cloud != null) {
      cloud().then(
        (t) {
          if (mounted) setState(() => _cloudState = t);
        },
        onError: (Object _) {
          // sin estado de la nube
        },
      );
    }
    _entries = _buffer.entries;
    _buffer.revision.addListener(_reload);
    _store?.health.addListener(_onHealth);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _buffer.revision.removeListener(_reload);
    _store?.health.removeListener(_onHealth);
    super.dispose();
  }

  /// D83: «el diagnóstico no pudo guardar N eventos» (solo conteos y tipo).
  void _onHealth() {
    if (!mounted) return;
    final h = _store?.health.value;
    final recovered = h != null && h.failures == 0 && _lastFailures > 0;
    _lastFailures = h?.failures ?? 0;
    setState(() {});
    // Volvió a poder guardar: se relee la tabla (solo en esa transición, sin
    // bucles mientras siga fallando).
    if (recovered) unawaited(_reload());
  }

  int _lastFailures = 0;

  String? get _healthText {
    final h = _store?.health.value;
    if (h == null || h.healthy) return null;
    return h.describe();
  }

  Future<void> _reload() async {
    final store = _store;
    if (store == null) {
      if (mounted) setState(() => _entries = _buffer.entries);
      return;
    }
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        List<DiagEntry> list;
        try {
          list = await store.entries();
        } on Object {
          // D83: nunca se queda sin refrescar: al menos la memoria.
          list = _buffer.entries;
        }
        if (mounted) setState(() => _entries = list);
      } while (_reloadAgain && mounted);
    } finally {
      _reloading = false;
    }
  }

  String _fullText() {
    final h = _header?.toText() ?? '';
    final c = _cloudState == null ? '' : '\n$_cloudState';
    final hs = _healthText;
    final s = hs == null ? '' : '\n$hs';
    final lines = _entries.map((e) => e.format()).join('\n');
    return '$h$c$s\n\n$lines'.trim();
  }

  /// D78: «Borrar diagnóstico» (con confirmación): tabla y memoria.
  Future<void> _clear() async {
    final ok = await showConfirmSheet(
      context,
      title: '¿Borrar el diagnóstico?',
      message:
          'Se borran todos los eventos guardados en este teléfono. No afecta '
          'a tus archivos ni a la nube.',
      confirmLabel: 'Borrar diagnóstico',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final store = _store;
    if (store != null) {
      await store.clearAll();
    } else {
      _buffer.clear();
    }
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnóstico borrado')));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _fullText()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnóstico copiado')));
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
                        'Diagnóstico',
                        style: AppTypography.title,
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
                  child: _body(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final entries = _entries;
    return Padding(
      padding: AppSpacing.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_header != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(_header!.toText(), style: AppTypography.log),
            ),
          if (_cloudState != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Text(
                _cloudState!,
                key: const ValueKey('diagnostics-cloud-state'),
                style: AppTypography.log,
              ),
            ),
          if (_healthText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Text(
                _healthText!,
                key: const ValueKey('diagnostics-store-health'),
                style: AppTypography.log.copyWith(color: AppColors.danger),
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'Sin eventos registrados',
                      style: AppTypography.bodySecondary,
                    ),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (_, i) => Text(
                      entries[i].format(),
                      style: AppTypography.log.copyWith(
                        color: entries[i].level == DiagLevel.error
                            ? AppColors.danger
                            : null,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            _store == null
                ? 'No contiene nombres de archivo, rutas, correos ni claves.'
                : 'No contiene nombres de archivo, rutas, correos ni claves. '
                      'Se guardan los últimos 500 eventos, cifrados, solo en '
                      'este teléfono.',
            style: AppTypography.caption,
          ),
          const SizedBox(height: AppSpacing.md),
          AppFilledButton(label: 'Copiar', icon: Icons.copy, onPressed: _copy),
          const SizedBox(height: AppSpacing.sm),
          AppTextButton(
            key: const ValueKey('diagnostics-clear'),
            label: 'Borrar diagnóstico',
            onPressed: _clear,
          ),
        ],
      ),
    );
  }
}
