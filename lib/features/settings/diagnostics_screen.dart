import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/crypto/aes_gcm_backend.dart';
import '../../core/crypto/argon2_backend.dart';
import '../../core/crypto/key_rotation_store.dart';
import '../../core/logging/diagnostics_buffer.dart';
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
    this.headerLoader = loadDiagnosticsHeader,
  });

  /// Por defecto [DiagnosticsBuffer.instance].
  final DiagnosticsBuffer? buffer;
  final Future<DiagnosticsHeader> Function() headerLoader;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late final DiagnosticsBuffer _buffer =
      widget.buffer ?? DiagnosticsBuffer.instance;
  DiagnosticsHeader? _header;

  @override
  void initState() {
    super.initState();
    widget.headerLoader().then((h) {
      if (mounted) setState(() => _header = h);
    });
  }

  String _fullText() {
    final h = _header?.toText() ?? '';
    return '$h\n\n${_buffer.export()}'.trim();
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
                  child: ValueListenableBuilder<int>(
                    valueListenable: _buffer.revision,
                    builder: (context, _, _) => _body(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final entries = _buffer.entries;
    return Padding(
      padding: AppSpacing.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_header != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Text(_header!.toText(), style: AppTypography.log),
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
          const Text(
            'No contiene nombres de archivo, rutas, correos ni claves.',
            style: AppTypography.caption,
          ),
          const SizedBox(height: AppSpacing.md),
          AppFilledButton(label: 'Copiar', icon: Icons.copy, onPressed: _copy),
        ],
      ),
    );
  }
}
