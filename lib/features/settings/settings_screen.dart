import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/crypto/auth_controller.dart';
import '../../core/security/security_preferences.dart';
import '../../core/services/cache_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/cloud/cloud_storage.dart';
import '../../data/gallery/video_compressor.dart';
import '../../data/migration/account_migration_service.dart';
import '../../data/rotation/key_rotation_service.dart';
import '../onboarding/widgets/recovery_code_field.dart';
import 'key_rotation_screen.dart';
import '../../data/sync/cloud_verification_service.dart';
import '../../data/sync/storage_service.dart';
import '../../data/sync/sync_service.dart';
import '../../shared/format.dart';
import '../../shared/widgets/app_buttons.dart';
import '../../shared/widgets/choice_sheet.dart';
import '../../shared/widgets/cloud_privacy_note.dart';
import '../gallery/delete_originals_sheet.dart';
import '../sync/quota_bar.dart';
import '../vault/vault_services.dart';
import 'account_migration_screen.dart';
import 'cloud_verification_screen.dart';
import 'diagnostics_screen.dart';
import 'pin_flows.dart';
import 'secondary_vault_screen.dart';
import 'tags_screen.dart';
import 'trash_screen.dart';
import 'settings_environment.dart';
import 'widgets/settings_widgets.dart';

/// Presets del límite de caché (500 MB es el valor por defecto).
const List<int> cacheLimitPresets = [
  250 * 1024 * 1024,
  500 * 1024 * 1024,
  1024 * 1024 * 1024,
  2 * 1024 * 1024 * 1024,
  5 * 1024 * 1024 * 1024,
];

String _limitLabel(int bytes) {
  for (final p in cacheLimitPresets) {
    if (p == bytes) {
      return p >= 1024 * 1024 * 1024
          ? '${p ~/ (1024 * 1024 * 1024)} GB'
          : '${p ~/ (1024 * 1024)} MB';
    }
  }
  return formatBytes(bytes);
}

/// Pantalla de Ajustes (F8): Seguridad, Importación, Almacenamiento,
/// Sincronización y cuenta, Acerca de. Cada control aplica EN CALIENTE y se
/// persiste en las preferencias que ya existen (no hay claves nuevas aparte
/// de la calidad de video por defecto).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.env, required this.services});

  final SettingsEnvironment env;
  final VaultServices services;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsEnvironment get _env => widget.env;
  AuthController get _auth => _env.auth;
  SyncService? get _sync => widget.services.sync;
  StorageService? get _storage => widget.services.storage;

  bool _loaded = false;
  BiometricAvailability _bioAvailability = BiometricAvailability.unavailable;
  bool _bioEnabled = false;
  bool _protectScreen = true;
  VideoQualityOption _quality = VideoQualityOption.original;
  bool _deleteOriginals = false;
  CacheStats? _stats;
  bool _wifiOnly = true;
  String _version = '';
  bool _busyStorage = false;
  int? _missingThumbs;
  bool _regenBusy = false;
  bool _signingIn = false;

  KeyRotationService? get _rotation => widget.services.rotation;

  /// Fase 8: dentro de la bóveda secundaria, Ajustes reducido (§6.11).
  bool get _secondary => _env.isSecondary;

  /// Estado de la bóveda adicional (solo en la principal).
  SecondaryVaultStatus? _altStatus;

  /// Hay un cambio de llave maestra registrado (S-11).
  bool get _rotating => _rotation?.auth.rotationStore.record.value != null;

  void _onRotationChanged() {
    if (mounted) setState(() {});
  }

  /// Campo de "Comprobar mi código" (vive con la pantalla: el diálogo lo
  /// sigue usando mientras se cierra).
  final TextEditingController _checkCodeController = TextEditingController();

  @override
  void dispose() {
    _rotation?.auth.rotationStore.record.removeListener(_onRotationChanged);
    _checkCodeController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _rotation?.auth.rotationStore.record.addListener(_onRotationChanged);
    unawaited(_load());
    final sync = _sync;
    if (sync != null && sync.summary.value.accountEmail != null) {
      unawaited(sync.refreshQuota());
    }
  }

  Future<void> _load() async {
    final bioAvailability = await _auth.biometricAvailability();
    final bioEnabled = await _auth.isBiometricUnlockEnabled();
    final protect = await _env.screenProtection.isPreferenceEnabled();
    final quality = await _env.importPreferences.getVideoQuality();
    final delete = await _env.importPreferences.getDeleteOriginalsWhenInCloud();
    final wifi = await _sync?.getWifiOnly() ?? true;
    final stats = await _safeStats();
    final missing = await _safeMissingThumbs();
    SecondaryVaultStatus? alt;
    if (!_secondary) {
      try {
        alt = await _auth.secondaryStatus();
      } on Object {
        alt = null;
      }
    }
    String version = '';
    try {
      version = (await _env.versionLoader()).toString();
    } on Object {
      version = 'desconocida';
    }
    if (!mounted) return;
    setState(() {
      _bioAvailability = bioAvailability;
      _bioEnabled = bioEnabled;
      _protectScreen = protect;
      _quality = quality;
      _deleteOriginals = delete;
      _wifiOnly = wifi;
      _stats = stats;
      _missingThumbs = missing;
      _altStatus = alt;
      _version = version;
      _loaded = true;
    });
  }

  Future<CacheStats?> _safeStats() async {
    try {
      return await _storage?.stats();
    } on Object {
      return null; // bóveda bloqueada
    }
  }

  Future<int?> _safeMissingThumbs() async {
    try {
      return await widget.services.gallery?.regeneration?.countMissing();
    } on Object {
      return null; // bóveda bloqueada
    }
  }

  /// Regenera las miniaturas que faltan (videos importados sin miniatura,
  /// miniaturas perdidas al restaurar...). Manual: sin topes y reintenta lo
  /// que falló.
  Future<void> _regenerateThumbs() async {
    final regen = widget.services.gallery?.regeneration;
    if (regen == null || _regenBusy) return;
    setState(() => _regenBusy = true);
    try {
      final r = await regen.run(manual: true);
      final left = await _safeMissingThumbs();
      if (!mounted) return;
      setState(() => _missingThumbs = left);
      _snack(
        r.candidates == 0
            ? 'No falta ninguna miniatura'
            : '${r.regenerated} miniatura(s) regenerada(s)'
                  '${r.failed > 0 ? ', ${r.failed} sin resolver' : ''}',
      );
    } finally {
      if (mounted) setState(() => _regenBusy = false);
    }
  }

  /// D75: aviso de los archivos que la caché no toca por no estar comprobados
  /// en la cuenta actual ('' si no hay).
  static String _unverifiedNote(CacheStats? s) {
    final n = s?.unverifiedCount ?? 0;
    if (n == 0) return '';
    return '. $n archivo(s) pendientes de comprobar en tu cuenta no se tocan.';
  }

  Future<void> _refreshStats() async {
    final stats = await _safeStats();
    if (mounted) setState(() => _stats = stats);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------- seguridad

  Future<void> _changePin() async {
    final changed = await runChangePinFlow(context, _auth);
    if (changed) _snack('PIN cambiado');
  }

  Future<void> _toggleBiometric(bool value) async {
    try {
      if (value) {
        await _auth.enableBiometricUnlock();
      } else {
        await _auth.disableBiometricUnlock();
      }
    } on BiometricCancelledException {
      _snack('Se canceló la activación de la biometría');
    } on Object {
      _snack('No se pudo cambiar el desbloqueo biométrico');
    }
    final enabled = await _auth.isBiometricUnlockEnabled();
    if (mounted) setState(() => _bioEnabled = enabled);
  }

  Future<void> _pickAutoLock() async {
    final picked = await showChoiceSheet<AutoLockDelay>(
      context,
      title: 'Autobloqueo',
      message: 'Tiempo en segundo plano tras el cual se pide el PIN.',
      options: [
        for (final d in AutoLockDelay.values)
          ChoiceOption(value: d, label: d.label),
      ],
      selected: _env.autoLock.delay,
    );
    if (picked == null) return;
    await _env.autoLock.setDelay(picked);
    if (mounted) setState(() {});
  }

  Future<void> _toggleProtectScreen(bool value) async {
    if (!value) {
      final ok = await showConfirmSheet(
        context,
        title: '¿Permitir capturas de pantalla?',
        message:
            'Sin esta protección, otras apps o el propio sistema podrán '
            'capturar y grabar tu bóveda, y el contenido se verá en la lista '
            'de apps recientes.',
        confirmLabel: 'Desactivar protección',
        destructive: true,
      );
      if (!ok) return;
    }
    await _env.screenProtection.setEnabled(value);
    final now = await _env.screenProtection.isPreferenceEnabled();
    if (mounted) setState(() => _protectScreen = now);
  }

  Future<void> _openRotation(RotationReason reason) async {
    final rotation = _rotation;
    if (rotation == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => KeyRotationScreen(service: rotation, reason: reason),
      ),
    );
    if (mounted) setState(() {});
  }

  /// M1: "Comprobar mi código" contra el respaldo local (sin red).
  Future<void> _checkCode() async {
    final controller = _checkCodeController..clear();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Comprobar mi código'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Escribe tu código de recuperación para comprobar que es el '
              'vigente. No se guarda ni sale del teléfono.',
              style: AppTypography.bodySecondary,
            ),
            const SizedBox(height: AppSpacing.md),
            RecoveryCodeField(controller: controller, onChanged: (_) {}),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Comprobar'),
          ),
        ],
      ),
    );
    if (code == null || !mounted) return;
    try {
      final ok = await _auth.verifyLocalRecoveryCode(code);
      _snack(ok ? 'Este código es el vigente' : 'No coincide');
    } on PinLockedOutException catch (e) {
      _snack('Demasiados intentos. Espera ${e.remaining.inSeconds + 1} s');
    }
  }

  Future<void> _regenerateCode() async {
    // Con el servicio de rotación, "Generar código nuevo" es la rotación
    // completa (el código viejo deja de abrir NADA, S-11).
    if (_rotation != null) return _openRotation(RotationReason.newCode);
    final done = await runRegenerateCodeFlow(context, _auth);
    if (!done) return;
    // El SyncService detecta el respaldo nuevo (SHA-256) y lo sube.
    unawaited(_sync?.run(manual: true));
    _snack(
      _sync?.summary.value.accountEmail == null
          ? 'Código nuevo confirmado. Se actualizará en la nube cuando '
                'conectes Google Drive.'
          : 'Código nuevo confirmado. Se está actualizando el respaldo en '
                'tu Drive.',
    );
  }

  // ------------------------------------------------------------ importación

  Future<void> _pickQuality() async {
    final picked = await showChoiceSheet<VideoQualityOption>(
      context,
      title: 'Calidad de video por defecto',
      message:
          'Se usará al importar desde la galería (puedes cambiarla en '
          'cada importación).',
      options: [
        for (final q in VideoQualityOption.values)
          ChoiceOption(value: q, label: q.label),
      ],
      selected: _quality,
    );
    if (picked == null) return;
    await _env.importPreferences.setVideoQuality(picked);
    if (mounted) setState(() => _quality = picked);
  }

  Future<void> _toggleDeleteOriginals(bool value) async {
    if (value) {
      final ok = await showConfirmSheet(
        context,
        title: '¿Borrar originales de la galería?',
        message:
            'Solo se borrará un original cuando su copia cifrada esté '
            'verificada en tu Google Drive, y siempre te pediremos '
            'confirmación antes de borrar. Esta acción no se puede deshacer.',
        confirmLabel: 'Activar',
      );
      if (!ok) return;
    }
    await _env.importPreferences.setDeleteOriginalsWhenInCloud(value);
    final now = await _env.importPreferences.getDeleteOriginalsWhenInCloud();
    if (mounted) setState(() => _deleteOriginals = now);
  }

  Future<void> _deleteOriginalsNow() async {
    final gallery = widget.services.gallery;
    if (gallery == null) return;
    final n = await showDeleteOriginalsSheet(context, service: gallery.service);
    if (n > 0) {
      _snack(
        n == 1
            ? 'Se borró 1 original del dispositivo'
            : 'Se borraron $n originales del dispositivo',
      );
    }
  }

  // ----------------------------------------------------------- almacenamiento

  Future<void> _pickCacheLimit() async {
    final storage = _storage;
    if (storage == null) return;
    final current = _stats?.limitBytes ?? CachePreferences.defaultLimitBytes;
    final picked = await showChoiceSheet<int>(
      context,
      title: 'Límite de caché',
      message:
          'Espacio máximo para archivos ya respaldados en la nube. Al '
          'superarlo se liberan los menos usados (siguen en la nube).',
      options: [
        for (final p in cacheLimitPresets)
          ChoiceOption(
            value: p,
            label: _limitLabel(p),
            detail: p == CachePreferences.defaultLimitBytes
                ? 'Predeterminado'
                : null,
          ),
      ],
      selected: current,
    );
    if (picked == null) return;
    setState(() => _busyStorage = true);
    try {
      final freed = await storage.setLimitBytes(picked);
      if (freed.files > 0) {
        _snack(
          'Límite ${_limitLabel(picked)}: se liberaron '
          '${formatBytes(freed.bytes)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busyStorage = false);
    }
    await _refreshStats();
  }

  Future<void> _clearCache() async {
    final storage = _storage;
    if (storage == null) return;
    final ok = await showConfirmSheet(
      context,
      title: '¿Vaciar la caché?',
      message:
          'Se borrarán las copias locales de lo que ya está en tu Google '
          'Drive y no está marcado "sin conexión". Se volverán a descargar '
          'al abrirlas.',
      confirmLabel: 'Vaciar caché',
      icon: Icons.cleaning_services_outlined,
    );
    if (!ok || !mounted) return;
    setState(() => _busyStorage = true);
    try {
      final freed = await storage.clearCache();
      final kept = _unverifiedNote(await _safeStats());
      _snack(
        (freed.files == 0
                ? 'No había nada que liberar'
                : 'Caché vaciada: ${freed.files} archivo(s), '
                      '${formatBytes(freed.bytes)} liberados') +
            kept,
      );
    } on Object {
      _snack('No se pudo vaciar la caché');
    } finally {
      if (mounted) setState(() => _busyStorage = false);
    }
    await _refreshStats();
  }

  Future<void> _freeOffline() async {
    final storage = _storage;
    if (storage == null) return;
    final stats = _stats;
    final detail = stats == null
        ? ''
        : ' (${stats.offlineCount} archivo(s), '
              '${formatBytes(stats.offlineBytes)})';
    final ok = await showConfirmSheet(
      context,
      title: '¿Liberar espacio sin conexión?',
      message:
          'Se quitará la marca "sin conexión" de todo lo que ya está en tu '
          'Google Drive$detail y se borrará su copia local. Nada se '
          'elimina de la nube y lo pendiente de subir no se toca.',
      confirmLabel: 'Liberar espacio',
      icon: Icons.offline_pin_outlined,
    );
    if (!ok || !mounted) return;
    setState(() => _busyStorage = true);
    try {
      final freed = await storage.freeOfflineSpace();
      final kept = _unverifiedNote(await _safeStats());
      _snack(
        (freed.files == 0
                ? 'No había nada que liberar'
                : 'Se liberaron ${formatBytes(freed.bytes)} '
                      '(${freed.files} archivo(s))') +
            kept,
      );
    } on Object {
      _snack('No se pudo liberar el espacio');
    } finally {
      if (mounted) setState(() => _busyStorage = false);
    }
    await _refreshStats();
  }

  // ---------------------------------------------------------- sincronización

  Future<void> _toggleWifi(bool value) async {
    setState(() => _wifiOnly = value);
    await _sync?.setWifiOnly(value);
  }

  Future<void> _signIn() async {
    final sync = _sync;
    if (sync == null) return;
    setState(() => _signingIn = true);
    try {
      await sync.signIn();
    } on CloudException {
      // El mensaje queda en summary.lastMessage (se muestra abajo).
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Future<void> _openMigration(AccountMigrationService migration) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AccountMigrationScreen(service: migration),
      ),
    );
    if (mounted) setState(() {});
  }

  /// D75: «Verificar copia en la nube» (muestra la cuenta y el resultado).
  Future<void> _openVerification(CloudVerificationService service) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CloudVerificationScreen(
          service: service,
          accountEmail: () => _sync?.cloud.currentAccountEmail,
        ),
      ),
    );
    if (!mounted) return;
    await _refreshStats();
  }

  Future<void> _signOut() async {
    final sync = _sync;
    if (sync == null) return;
    final ok = await showConfirmSheet(
      context,
      title: '¿Cerrar sesión de Google?',
      message:
          'Vault dejará de sincronizar con tu Drive. Tus archivos en el '
          'teléfono se conservan y lo que ya está en tu Drive no se borra. '
          'Si luego inicias sesión con OTRA cuenta, tus archivos NO se '
          'moverán solos: lo que está en el Drive de ahora no pasa a la '
          'cuenta nueva y los archivos que ya no estén en este teléfono '
          'dejarán de estar disponibles. Para cambiar de cuenta sin perder '
          'nada usa «Cambiar de cuenta de Google». Puedes volver a iniciar '
          'sesión cuando quieras.',
      confirmLabel: 'Cerrar sesión',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await sync.signOut();
      _snack('Sesión cerrada');
    } on Object {
      _snack('No se pudo cerrar la sesión');
    }
  }

  // -------------------------------------------------------------------- UI

  List<Widget> _security() {
    final bioAvailable = _bioAvailability == BiometricAvailability.available;
    final bioSubtitle = switch (_bioAvailability) {
      BiometricAvailability.available => 'Huella o rostro en lugar del PIN',
      BiometricAvailability.notEnrolled =>
        'No disponible: registra una huella o rostro en los ajustes del '
            'teléfono',
      BiometricAvailability.unavailable => 'No disponible en este dispositivo',
    };
    final rotating = _rotating;
    if (_secondary) {
      // Fase 8 (§6.11): en la secundaria no hay Cambiar PIN (C2), biometría,
      // Proteger pantalla, código de recuperación ni rotación.
      return [
        SettingsTile(
          icon: Icons.timer_outlined,
          title: 'Autobloqueo',
          trailing: _env.autoLock.delay.label,
          onTap: _pickAutoLock,
        ),
        SettingsTile(
          icon: Icons.lock_outline_rounded,
          title: 'Bloquear ahora',
          onTap: _env.onLock,
        ),
      ];
    }
    return [
      SettingsTile(
        icon: Icons.pin_outlined,
        title: 'Cambiar PIN',
        subtitle: rotating
            ? 'Disponible al terminar el cambio de llave maestra'
            : 'Tus archivos no se vuelven a cifrar',
        onTap: rotating ? null : _changePin,
      ),
      SettingsSwitchTile(
        icon: Icons.fingerprint,
        title: 'Desbloqueo biométrico',
        subtitle: bioSubtitle,
        value: _bioEnabled && bioAvailable,
        onChanged: bioAvailable || _bioEnabled ? _toggleBiometric : null,
      ),
      SettingsTile(
        icon: Icons.timer_outlined,
        title: 'Autobloqueo',
        trailing: _env.autoLock.delay.label,
        onTap: _pickAutoLock,
      ),
      SettingsSwitchTile(
        icon: Icons.screen_lock_portrait_outlined,
        title: 'Proteger pantalla',
        subtitle: _env.screenProtection.overriddenOff
            ? 'Compilación de depuración: capturas permitidas'
            : 'Bloquea capturas, grabación y vista previa en apps recientes',
        value: _protectScreen,
        onChanged: _toggleProtectScreen,
      ),
      SettingsTile(
        icon: Icons.key_outlined,
        title: 'Generar nuevo código de recuperación',
        subtitle: _rotation == null
            ? 'El código actual dejará de servir'
            : 'Cambia también la llave: el código actual no abrirá nada',
        onTap: rotating
            ? () => _openRotation(RotationReason.newCode)
            : _regenerateCode,
      ),
      if (_rotation != null)
        SettingsTile(
          icon: Icons.enhanced_encryption_outlined,
          title: rotating ? 'Cambio de llave en curso' : 'Rotar llave maestra',
          subtitle: rotating
              ? 'Toca para ver el progreso o continuar'
              : 'Vuelve a cifrar todo con una llave y un código nuevos',
          onTap: () => _openRotation(RotationReason.rotateKey),
        ),
      SettingsTile(
        icon: Icons.fact_check_outlined,
        title: 'Comprobar mi código',
        subtitle: 'Confirma que tu código anotado es el vigente',
        onTap: _checkCode,
      ),
      SettingsTile(
        key: const ValueKey('secondary-vault-tile'),
        icon: Icons.layers_outlined,
        title: 'Bóveda adicional',
        subtitle: switch (_altStatus) {
          SecondaryVaultStatus.active => 'Activa',
          SecondaryVaultStatus.damaged => 'Dañada',
          _ => 'Desactivada',
        },
        onTap: _openSecondaryVault,
      ),
      SettingsTile(
        icon: Icons.lock_outline_rounded,
        title: 'Bloquear ahora',
        onTap: _env.onLock,
      ),
    ];
  }

  Future<void> _openSecondaryVault() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SecondaryVaultScreen(auth: _auth),
      ),
    );
    if (!mounted) return;
    SecondaryVaultStatus? alt;
    try {
      alt = await _auth.secondaryStatus();
    } on Object {
      alt = null;
    }
    final bio = await _auth.isBiometricUnlockEnabled();
    if (mounted) {
      setState(() {
        _altStatus = alt;
        _bioEnabled = bio;
      });
    }
  }

  List<Widget> _import() => [
    SettingsTile(
      icon: Icons.videocam_outlined,
      title: 'Calidad de video por defecto',
      trailing: _quality.label,
      onTap: _pickQuality,
    ),
    // Sin nube no hay verificación: en la secundaria no se borran originales.
    if (!_secondary)
      SettingsSwitchTile(
        icon: Icons.delete_sweep_outlined,
        title: 'Borrar originales cuando estén en la nube',
        subtitle: deleteOriginalsExplanation,
        value: _deleteOriginals,
        onChanged: _toggleDeleteOriginals,
      ),
    if (!_secondary && _deleteOriginals && widget.services.gallery != null)
      SettingsTile(
        icon: Icons.cleaning_services_outlined,
        title: 'Borrar ahora los originales verificados',
        subtitle:
            'Muestra la lista y pide confirmación. Solo archivos con su '
            'copia verificada en Drive.',
        onTap: _deleteOriginalsNow,
      ),
  ];

  List<Widget> _storageTiles() {
    final s = _stats;
    final usage = s == null
        ? 'Calculando…'
        : 'Caché: ${formatBytes(s.cachedBytes)} (${s.cachedCount} archivos)'
              ' · Sin conexión: ${formatBytes(s.offlineBytes)} '
              '(${s.offlineCount} archivos)'
              '${s.unverifiedCount > 0 ? ' · ${s.unverifiedCount} pendientes de comprobar (no se tocan)' : ''}';
    return [
      SettingsTile(
        icon: Icons.storage_outlined,
        title: 'Límite de caché',
        trailing: _limitLabel(
          s?.limitBytes ?? CachePreferences.defaultLimitBytes,
        ),
        subtitle: usage,
        onTap: _busyStorage ? null : _pickCacheLimit,
      ),
      SettingsTile(
        icon: Icons.offline_pin_outlined,
        title: 'Liberar espacio sin conexión',
        subtitle: 'Quita la marca de lo que ya está en la nube',
        onTap: _busyStorage ? null : _freeOffline,
      ),
      SettingsTile(
        icon: Icons.cleaning_services_outlined,
        title: 'Vaciar caché ahora',
        onTap: _busyStorage ? null : _clearCache,
      ),
      if (widget.services.gallery?.regeneration != null)
        SettingsTile(
          icon: Icons.image_search_outlined,
          title: 'Regenerar miniaturas que faltan',
          subtitle: _regenBusy
              ? 'Regenerando…'
              : (_missingThumbs == null
                    ? null
                    : (_missingThumbs == 0
                          ? 'No falta ninguna'
                          : 'Faltan $_missingThumbs')),
          onTap: _regenBusy ? null : _regenerateThumbs,
        ),
    ];
  }

  Widget _syncSection(SyncService sync) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        sync.summary,
        sync.quota,
        ?widget.services.migration?.status,
      ]),
      builder: (context, _) {
        final s = sync.summary.value;
        final email = s.accountEmail;
        final signedIn = email != null;
        final migration = widget.services.migration;
        final migrating = migration?.status.value.active ?? false;
        return SettingsSection(
          title: 'Sincronización y cuenta',
          children: [
            if (migration != null && migrating)
              SettingsTile(
                key: const ValueKey('migration-in-progress-tile'),
                icon: Icons.swap_horiz,
                title: 'Cambio de cuenta en curso',
                // D76: la fase a la vista (distingue las variantes del atasco).
                subtitle:
                    'Fase: ${migrationPhaseLabel(migration.status.value.phase!)}. '
                    'La sincronización está en pausa. Toca para ver o continuar.',
                onTap: () => _openMigration(migration),
              ),
            const Padding(padding: AppSpacing.page, child: CloudPrivacyNote()),
            SettingsSwitchTile(
              icon: Icons.wifi,
              title: 'Solo Wi-Fi',
              subtitle: 'No usar datos móviles para subir ni descargar',
              value: _wifiOnly,
              onChanged: _toggleWifi,
            ),
            if (signedIn) ...[
              SettingsTile(
                icon: Icons.account_circle_outlined,
                title: 'Cuenta de Google',
                subtitle: email,
              ),
              Padding(
                padding: AppSpacing.page,
                child: QuotaBar(quota: sync.quota.value),
              ),
              SettingsTile(
                icon: Icons.sync,
                title: 'Sincronizar ahora',
                subtitle: s.phase == SyncPhase.running
                    ? 'Sincronizando…'
                    : null,
                onTap: s.phase == SyncPhase.running
                    ? null
                    : () => unawaited(sync.run(manual: true)),
              ),
              if (widget.services.verification != null)
                SettingsTile(
                  key: const ValueKey('verify-cloud-tile'),
                  icon: Icons.fact_check_outlined,
                  title: 'Verificar copia en la nube',
                  subtitle: migrating || _rotating
                      ? 'No disponible: termina primero el cambio en curso'
                      : 'Comprueba que esta cuenta tiene cada archivo',
                  onTap: () => _openVerification(widget.services.verification!),
                ),
              if (migration != null && !migrating)
                SettingsTile(
                  icon: Icons.swap_horiz,
                  title: 'Cambiar de cuenta de Google',
                  subtitle: 'Mueve tu bóveda a otra cuenta sin perder nada',
                  onTap: () => _openMigration(migration),
                ),
              SettingsTile(
                icon: Icons.logout,
                title: 'Cerrar sesión de Google',
                destructive: true,
                // Con un cambio de cuenta o de llave en curso no se cierra
                // sesión (los dos necesitan la misma cuenta hasta terminar).
                onTap: migrating || _rotating ? null : _signOut,
              ),
            ] else
              Padding(
                padding: AppSpacing.page,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Sin cuenta conectada. Tu bóveda no se está '
                      'respaldando en la nube.',
                      style: AppTypography.bodySecondary,
                    ),
                    if (s.lastMessage != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          s.lastMessage!,
                          style: AppTypography.bodySecondary.copyWith(
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    AppFilledButton(
                      label: 'Iniciar sesión con Google',
                      icon: Icons.login,
                      busy: _signingIn,
                      onPressed: _signIn,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
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
                      child: const Text('Ajustes', style: AppTypography.title),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: AppSizes.contentMaxWidth,
                        ),
                        child: ListView(
                          padding: AppSpacing.page,
                          children: [
                            if (_rotation != null)
                              RotationBanner(
                                record: _rotation!.auth.rotationStore.record,
                                progress: _rotation!.progress,
                                onTap: () =>
                                    _openRotation(RotationReason.rotateKey),
                              ),
                            SettingsSection(
                              title: 'Seguridad',
                              children: _security(),
                            ),
                            SettingsSection(
                              title: 'Importación',
                              children: _import(),
                            ),
                            if (_storage != null)
                              SettingsSection(
                                title: 'Almacenamiento',
                                children: _storageTiles(),
                              )
                            else if (_secondary &&
                                widget.services.gallery?.regeneration != null)
                              SettingsSection(
                                title: 'Almacenamiento',
                                children: _storageTiles()
                                    .where(
                                      (w) =>
                                          w is SettingsTile &&
                                          w.icon == Icons.image_search_outlined,
                                    )
                                    .toList(),
                              ),
                            if (widget.services.tags != null)
                              SettingsSection(
                                title: 'Etiquetas',
                                children: [
                                  SettingsTile(
                                    icon: Icons.label_outline,
                                    title: 'Etiquetas',
                                    subtitle:
                                        'Crea, renombra o elimina etiquetas '
                                        'para organizar tus archivos',
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => TagsScreen(
                                          repository: widget.services.tags!,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            if (widget.services.trash != null)
                              SettingsSection(
                                title: 'Papelera',
                                children: [
                                  SettingsTile(
                                    icon: Icons.delete_outline,
                                    title: 'Papelera',
                                    subtitle:
                                        'Restaura o elimina lo que borraste '
                                        '(se vacía sola a los 30 días)',
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => TrashScreen(
                                          service: widget.services.trash!,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            if (_sync != null) _syncSection(_sync!),
                            SettingsSection(
                              title: 'Acerca de',
                              children: [
                                SettingsTile(
                                  icon: Icons.info_outline,
                                  title: 'Versión',
                                  trailing: _version,
                                ),
                                if (_secondary)
                                  // Fase 8 (§6.11): texto neutro.
                                  const SettingsTile(
                                    icon: Icons.privacy_tip_outlined,
                                    title: 'Privacidad',
                                    subtitle:
                                        'Tus archivos se cifran en este '
                                        'teléfono antes de guardarse. El PIN '
                                        'y las llaves nunca salen del '
                                        'dispositivo. Vault no tiene '
                                        'servidores, ni analíticas, ni '
                                        'comparte datos con terceros.',
                                  )
                                else
                                  const SettingsTile(
                                    icon: Icons.privacy_tip_outlined,
                                    title: 'Privacidad',
                                    subtitle:
                                        'Tus archivos se cifran en este '
                                        'teléfono antes de guardarse o de '
                                        'subirse a un espacio privado de tu '
                                        'Google Drive. El PIN y las llaves '
                                        'nunca salen del dispositivo: solo '
                                        'viaja un respaldo cifrado con tu '
                                        'código de recuperación. Vault no '
                                        'tiene servidores, ni analíticas, ni '
                                        'comparte datos con terceros.',
                                  ),
                                if (!_secondary)
                                  SettingsTile(
                                    icon: Icons.bug_report_outlined,
                                    title: 'Diagnóstico',
                                    subtitle: 'Registro local sin datos tuyos',
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => DiagnosticsScreen(
                                          headerLoader: () =>
                                              loadDiagnosticsHeader(
                                                versionLoader:
                                                    _env.versionLoader,
                                              ),
                                        ),
                                      ),
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
        ),
      ),
    );
  }
}
