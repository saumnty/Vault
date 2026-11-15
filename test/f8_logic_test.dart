import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/crypto/key_recovery_service.dart';
import 'package:vault/core/crypto/pin_attempt_limiter.dart';
import 'package:vault/core/crypto/recovery_challenge.dart';
import 'package:vault/core/security/auto_lock.dart';
import 'package:vault/core/security/platform_security.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/services/cache_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/gallery/import_preferences.dart';
import 'package:vault/data/gallery/video_compressor.dart';
import 'package:vault/data/models/sync_status.dart';
import 'package:vault/data/sync/network_monitor.dart';
import 'package:vault/data/sync/storage_service.dart';
import 'package:vault/data/sync/sync_service.dart';

import 'support/f6_env.dart';
import 'support/fakes.dart';

const pin = '123456';
const kb = 1024;

void main() {
  group('Código de recuperación: regenerateRecoveryCode', () {
    late InMemorySecureStore storage;
    late FakeBiometricKeyStore bio;
    late FakeClock clock;

    AuthController controller({InMemorySecureStore? on}) => AuthController(
      storage: on ?? storage,
      biometricStore: bio,
      kdfParams: fastKdf,
      clock: clock.call,
      session: VaultSession.create(),
    );

    setUp(() {
      storage = InMemorySecureStore();
      bio = FakeBiometricKeyStore();
      clock = FakeClock();
    });

    /// Simula un teléfono nuevo que recibe [backupJson] (p. ej. de Drive) y
    /// escribe [code].
    Future<bool> restores(String code, String backupJson) async {
      final fresh = controller(on: InMemorySecureStore());
      return fresh.restoreFromRecovery(
        recoveryCode: code,
        recoveryBackupJson: backupJson,
        newPin: '654321',
      );
    }

    test(
      'el código viejo deja de abrir el respaldo local; el nuevo sí',
      () async {
        final c = controller();
        final created = await c.createVault(pin);
        final oldBackup = (await c.exportRecoveryBackup())!;
        expect(await restores(created.recoveryCode, oldBackup), isTrue);

        final fresh = await c.regenerateRecoveryCode(pin);
        expect(fresh, isNotNull);
        expect(fresh, isNot(created.recoveryCode));
        expect(RecoveryCode.normalize(fresh!), isNotNull);
        expect(fresh.split('-'), hasLength(6)); // grupos de 4

        final newBackup = (await c.exportRecoveryBackup())!;
        expect(newBackup, isNot(oldBackup));
        expect(await restores(created.recoveryCode, newBackup), isFalse);
        expect(await restores(fresh, newBackup), isTrue);
      },
    );

    test(
      'la DEK no cambia: mismas subllaves y la envoltura del PIN intacta',
      () async {
        final c = controller();
        await c.createVault(pin);
        final dek = c.session.keys.dekBytes();
        final keyCheck = c.session.keys.keyCheck;
        final envelopeBefore = storage.data[AuthController.pinEnvelopeKey];

        await c.regenerateRecoveryCode(pin);

        expect(storage.data[AuthController.pinEnvelopeKey], envelopeBefore);
        c.lock();
        final reopened = controller();
        expect(await reopened.unlockWithPin(pin), isTrue);
        expect(reopened.session.keys.dekBytes(), dek);
        expect(reopened.session.keys.keyCheck, keyCheck);
      },
    );

    test('el respaldo nuevo usa sal y KEK distintas (salt2 cambia)', () async {
      final c = controller();
      await c.createVault(pin);
      final before = jsonDecode((await c.exportRecoveryBackup())!) as Map;
      await c.regenerateRecoveryCode(pin);
      final after = jsonDecode((await c.exportRecoveryBackup())!) as Map;
      expect(after['salt'], isNot(before['salt']));
      expect(after['ct'], isNot(before['ct']));
      expect(after['purpose'], 'recovery');
    });

    test(
      'PIN incorrecto: devuelve null, cuenta el intento y no toca nada',
      () async {
        final c = controller();
        await c.createVault(pin);
        final backupBefore = await c.exportRecoveryBackup();
        expect(await c.regenerateRecoveryCode('000000'), isNull);
        expect(await c.exportRecoveryBackup(), backupBefore);
        expect(storage.data[PinAttemptLimiter.storageKey], isNotNull);
      },
    );

    test('con retraso por PIN fallidos lanza PinLockedOutException', () async {
      final c = controller();
      await c.createVault(pin);
      var locked = false;
      for (var i = 0; i < 8 && !locked; i++) {
        try {
          await c.regenerateRecoveryCode('000000');
        } on PinLockedOutException {
          locked = true;
        }
      }
      expect(locked, isTrue);
    });

    test('nada protegido solo por el PIN sale del teléfono', () async {
      final c = controller();
      await c.createVault(pin);
      await c.regenerateRecoveryCode(pin);
      final backup = (await c.exportRecoveryBackup())!;
      // Es un respaldo válido, de propósito "recovery" y sin campos extra.
      assertRecoveryBackupSafe(backup);
      // No contiene la envoltura del PIN ni su sal.
      final pinEnv =
          jsonDecode(storage.data[AuthController.pinEnvelopeKey]!) as Map;
      expect(backup.contains(pinEnv['salt'] as String), isFalse);
      expect(backup.contains(pinEnv['ct'] as String), isFalse);
      expect(backup.contains(pin), isFalse);
      // Y el respaldo NO abre con el PIN.
      expect(await restores(pin, backup), isFalse);
    });

    test('la bandera onboarding_pending no cambia al regenerar', () async {
      final c = controller();
      await c.createVault(pin, onboardingPending: true);
      await c.regenerateRecoveryCode(pin);
      expect(await c.isOnboardingPending(), isTrue);
    });

    test(
      'Drive: tras regenerar, el siguiente sync sube el respaldo nuevo',
      () async {
        final env = F6Env();
        await env.setUp();
        addTearDown(env.tearDown);
        final c = controller();
        final created = await c.createVault(pin);
        final sync = SyncService(
          cloud: env.cloud,
          queue: env.queue,
          items: env.items,
          network: env.net,
          prefs: env.syncPrefs,
          isUnlocked: () => true,
          resolvePath: (rel) => File(rel),
          recoveryBackupProvider: c.exportRecoveryBackup,
          snapshotProvider: () async => throw UnimplementedError(),
          scheduleWakeups: false,
        );
        addTearDown(sync.dispose);

        await sync.run(manual: true);
        final first = utf8.decode(
          env.cloud.bytesOf(CloudNames.recoveryBackup)!,
        );
        expect(first, await c.exportRecoveryBackup());

        final fresh = (await c.regenerateRecoveryCode(pin))!;
        await sync.run(manual: true);
        final second = utf8.decode(
          env.cloud.bytesOf(CloudNames.recoveryBackup)!,
        );
        expect(second, isNot(first));
        expect(second, await c.exportRecoveryBackup());
        // Lo que está en Drive ya solo abre con el código nuevo.
        expect(await restores(created.recoveryCode, second), isFalse);
        expect(await restores(fresh, second), isTrue);
      },
    );
  });

  group('Bandera onboarding_pending', () {
    late InMemorySecureStore storage;
    late FakeBiometricKeyStore bio;

    AuthController controller([SecureOrSpy? spy]) => AuthController(
      storage: spy ?? storage,
      biometricStore: bio,
      kdfParams: fastKdf,
      session: VaultSession.create(),
    );

    setUp(() {
      storage = InMemorySecureStore();
      bio = FakeBiometricKeyStore();
    });

    test('por defecto no hay bandera', () async {
      final c = controller();
      await c.createVault(pin);
      expect(await c.isOnboardingPending(), isFalse);
    });

    test('con onboarding: persiste hasta completeOnboarding y sobrevive a '
        'reabrir la app', () async {
      final c = controller();
      await c.createVault(pin, onboardingPending: true);
      c.lock();
      final reopened = controller();
      expect(await reopened.hasVault(), isTrue);
      expect(await reopened.isOnboardingPending(), isTrue);
      await reopened.completeOnboarding();
      expect(await controller().isOnboardingPending(), isFalse);
    });

    test('la bandera se escribe ANTES de la envoltura del PIN', () async {
      final order = <String>[];
      final c = controller(_SpyStore(storage, order));
      await c.createVault(pin, onboardingPending: true);
      expect(
        order.indexOf(AuthController.onboardingPendingKey),
        lessThan(order.indexOf(AuthController.pinEnvelopeKey)),
      );
    });

    test('restaurar con el código de recuperación borra la bandera', () async {
      final c = controller();
      final created = await c.createVault(pin, onboardingPending: true);
      final backup = (await c.exportRecoveryBackup())!;
      expect(
        await c.restoreFromRecovery(
          recoveryCode: created.recoveryCode,
          recoveryBackupJson: backup,
          newPin: '654321',
        ),
        isTrue,
      );
      expect(await c.isOnboardingPending(), isFalse);
    });
  });

  group('RecoveryCodeChallenge', () {
    const code = 'ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2';

    test('posiciones distintas, ordenadas y dentro de 1..24', () {
      for (var seed = 0; seed < 50; seed++) {
        final ch = RecoveryCodeChallenge.generate(code, random: Random(seed));
        expect(ch.positions, hasLength(4));
        expect(ch.positions.toSet(), hasLength(4));
        expect([...ch.positions]..sort(), ch.positions);
        expect(ch.positions.first, greaterThanOrEqualTo(1));
        expect(ch.positions.last, lessThanOrEqualTo(24));
      }
    });

    test('Random inyectable: misma semilla, mismas posiciones', () {
      final a = RecoveryCodeChallenge.generate(code, random: Random(42));
      final b = RecoveryCodeChallenge.generate(code, random: Random(42));
      final c = RecoveryCodeChallenge.generate(code, random: Random(43));
      expect(a.positions, b.positions);
      expect(a.positions, isNot(c.positions));
    });

    test('distintas semillas cubren posiciones variadas', () {
      final seen = <int>{};
      for (var seed = 0; seed < 100; seed++) {
        seen.addAll(
          RecoveryCodeChallenge.generate(code, random: Random(seed)).positions,
        );
      }
      expect(seen.length, greaterThan(20));
    });

    String expectedFor(RecoveryCodeChallenge ch) {
      final n = RecoveryCode.normalize(code)!;
      return [for (final p in ch.positions) n[p - 1]].join();
    }

    test(
      'acepta los caracteres correctos (mayúsculas/minúsculas/espacios)',
      () {
        final ch = RecoveryCodeChallenge.generate(code, random: Random(7));
        final ok = expectedFor(ch);
        expect(ch.verify(ok), isTrue);
        expect(ch.verify(ok.toLowerCase()), isTrue);
        expect(ch.verify(ok.split('').join(' ')), isTrue);
        expect(ch.verify(' ${ok.split('').join('-')} '), isTrue);
      },
    );

    test('rechaza errores: otro carácter, orden, largo, vacío', () {
      final ch = RecoveryCodeChallenge.generate(code, random: Random(7));
      final ok = expectedFor(ch);
      expect(ch.verify(''), isFalse);
      expect(ch.verify(ok.substring(0, 3)), isFalse);
      expect(ch.verify('${ok}A'), isFalse);
      final swapped = ok.split('').reversed.join();
      if (swapped != ok) expect(ch.verify(swapped), isFalse);
      final wrongChar = ok[0] == 'A' ? 'B' : 'A';
      expect(ch.verify('$wrongChar${ok.substring(1)}'), isFalse);
    });

    test('positionsLabel en español', () {
      final ch = RecoveryCodeChallenge.generate(code, random: Random(7));
      final labels = ch.positions.map((p) => '$p.º').toList();
      expect(
        ch.positionsLabel,
        '${labels.sublist(0, 3).join(', ')} y ${labels.last}',
      );
    });

    test('código con formato inválido lanza ArgumentError', () {
      expect(() => RecoveryCodeChallenge.generate('ABC'), throwsArgumentError);
    });

    test('constantTimeEquals', () {
      expect(RecoveryCodeChallenge.constantTimeEquals('AB', 'AB'), isTrue);
      expect(RecoveryCodeChallenge.constantTimeEquals('AB', 'AC'), isFalse);
      expect(RecoveryCodeChallenge.constantTimeEquals('AB', 'ABC'), isFalse);
      expect(RecoveryCodeChallenge.constantTimeEquals('', ''), isTrue);
    });
  });

  group('Almacenamiento (StorageService) con BD y archivos reales', () {
    late F6Env env;
    late StorageService storage;

    setUp(() async {
      env = F6Env();
      await env.setUp();
      storage = StorageService(
        cache: env.cache,
        items: env.items,
        offline: env.offline,
      );
    });
    tearDown(() => env.tearDown());

    test('cambiar el límite dispara la purga LRU en caliente', () async {
      await env.addCloudItem('a', size: 100 * kb, lastAccessedAt: 1);
      await env.addCloudItem('b', size: 100 * kb, lastAccessedAt: 2);
      await env.addCloudItem('c', size: 100 * kb, lastAccessedAt: 3);
      final freed = await storage.setLimitBytes(150 * kb);
      expect(freed.files, 2);
      expect(freed.bytes, 200 * kb);
      expect(env.localFile('a').existsSync(), isFalse);
      expect(env.localFile('b').existsSync(), isFalse);
      expect(env.localFile('c').existsSync(), isTrue);
      expect(await env.cachePrefs.getLimitBytes(), 150 * kb);
      // Los purgados siguen en la nube: en_nube, no borrados.
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
    });

    test('subir el límite no purga nada', () async {
      await env.addCloudItem('a', size: 100 * kb);
      final freed = await storage.setLimitBytes(10 * 1024 * kb);
      expect(freed.files, 0);
      expect(env.localFile('a').existsSync(), isTrue);
    });

    test(
      'vaciar caché: conserva sin conexión, pendientes, subiendo y error',
      () async {
        await env.addCloudItem('cached', size: 50 * kb);
        await env.addCloudItem(
          'offline',
          size: 50 * kb,
          offline: true,
          status: SyncStatus.sinConexion,
        );
        for (final (id, st) in [
          ('pend', SyncStatus.pendiente),
          ('up', SyncStatus.subiendo),
          ('err', SyncStatus.error),
        ]) {
          await env.addCloudItem(
            id,
            size: 50 * kb,
            status: st,
            verified: false,
          );
        }
        final freed = await storage.clearCache();
        expect(freed.files, 1);
        expect(freed.bytes, 50 * kb);
        expect(env.localFile('cached').existsSync(), isFalse);
        for (final id in ['offline', 'pend', 'up', 'err']) {
          expect(env.localFile(id).existsSync(), isTrue, reason: id);
        }
      },
    );

    test('liberar sin conexión: quita marcas verificadas y purga; NUNCA toca '
        'pendiente/subiendo/error', () async {
      await env.addFolder('f', offline: true);
      await env.addCloudItem(
        'o1',
        size: 40 * kb,
        offline: true,
        status: SyncStatus.sinConexion,
      );
      await env.addCloudItem(
        'inFolder',
        size: 40 * kb,
        folderId: 'f',
        status: SyncStatus.sinConexion,
      );
      await env.addCloudItem('plain', size: 40 * kb);
      final unverified = <String, SyncStatus>{
        'pend': SyncStatus.pendiente,
        'up': SyncStatus.subiendo,
        'err': SyncStatus.error,
      };
      for (final e in unverified.entries) {
        await env.addCloudItem(
          e.key,
          size: 40 * kb,
          status: e.value,
          verified: false,
          offline: true, // marca propia: no debe tocarse
        );
      }

      final before = await storage.stats();
      expect(before.offlineCount, 2);
      final freed = await storage.freeOfflineSpace();

      expect(freed.files, 3); // o1 + inFolder + plain
      expect(freed.bytes, 120 * kb);
      for (final id in ['o1', 'inFolder', 'plain']) {
        expect(env.localFile(id).existsSync(), isFalse, reason: id);
        final item = (await env.items.getItem(id))!;
        expect(item.syncStatus, SyncStatus.enNube, reason: id);
        expect(item.isOffline, isFalse, reason: id);
        expect(item.driveFileId, isNotNull, reason: id); // sigue en la nube
      }
      expect((await env.items.getFolder('f'))!.isOffline, isFalse);
      for (final e in unverified.entries) {
        final item = (await env.items.getItem(e.key))!;
        expect(item.syncStatus, e.value, reason: e.key);
        expect(item.isOffline, isTrue, reason: e.key);
        expect(env.localFile(e.key).existsSync(), isTrue, reason: e.key);
      }
      final after = await storage.stats();
      expect(after.offlineCount, 0);
      expect(after.cachedCount, 0);
    });

    test('liberar: un item abierto ahora mismo conserva su copia', () async {
      await env.addCloudItem(
        'open',
        size: 40 * kb,
        offline: true,
        status: SyncStatus.sinConexion,
      );
      env.cache.markInUse('open');
      final freed = await storage.freeOfflineSpace();
      expect(freed.files, 0);
      expect(env.localFile('open').existsSync(), isTrue);
      env.cache.releaseInUse('open');
    });

    test('stats informa caché y sin conexión por separado', () async {
      await env.addCloudItem('a', size: 30 * kb);
      await env.addCloudItem(
        'b',
        size: 70 * kb,
        offline: true,
        status: SyncStatus.sinConexion,
      );
      final s = await storage.stats();
      expect(s.cachedBytes, 30 * kb);
      expect(s.offlineBytes, 70 * kb);
      expect(s.limitBytes, CachePreferences.defaultLimitBytes);
    });
  });

  group('Cuenta y sincronización', () {
    late F6Env env;
    setUp(() async {
      env = F6Env();
      await env.setUp();
    });
    tearDown(() => env.tearDown());

    test('cerrar sesión: deja de sincronizar, conserva lo local y se puede '
        'volver a iniciar', () async {
      await env.addCloudItem(
        'a',
        size: 10 * kb,
        status: SyncStatus.pendiente,
        verified: false,
      );
      await env.sync.start();
      expect(env.sync.summary.value.accountEmail, isNotNull);

      await env.sync.signOut();
      expect(env.cloud.currentAccountEmail, isNull);
      expect(env.sync.summary.value.accountEmail, isNull);
      expect(env.sync.summary.value.phase, SyncPhase.needsSignIn);
      expect(env.sync.quota.value, isNull);

      // Sin sesión no sube nada y no pierde lo local.
      final uploadsBefore = env.cloud.uploadedNames.length;
      await env.sync.run(manual: true);
      expect(env.sync.summary.value.phase, SyncPhase.needsSignIn);
      expect(env.cloud.uploadedNames.length, uploadsBefore);
      expect(env.localFile('a').existsSync(), isTrue);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.pendiente);

      // Volver a iniciar sesión reanuda la subida.
      await env.sync.signIn();
      await _idle(env.sync); // signIn lanza un run por su cuenta
      await env.sync.run(manual: true);
      expect(env.sync.summary.value.accountEmail, isNotNull);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
    });

    test('cerrar sesión olvida el "respaldo ya subido" para el próximo '
        'inicio', () async {
      await env.syncPrefs.setRecoveryUploadedSha('abc');
      await env.sync.signOut();
      expect(await env.syncPrefs.getRecoveryUploadedSha(), isNot('abc'));
    });

    test('Solo Wi-Fi: persiste y aplica en caliente', () async {
      await env.addCloudItem(
        'a',
        size: 10 * kb,
        status: SyncStatus.pendiente,
        verified: false,
      );
      env.net.kind = NetworkKind.mobile;
      await env.sync.setWifiOnly(true);
      expect(await env.syncPrefs.getWifiOnly(), isTrue);
      await env.sync.run(manual: true);
      expect(env.sync.summary.value.phase, SyncPhase.waitingWifi);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.pendiente);

      await env.sync.setWifiOnly(false); // dispara un run por su cuenta
      expect(await env.syncPrefs.getWifiOnly(), isFalse);
      await _idle(env.sync);
      await env.sync.run(manual: true);
      expect((await env.items.getItem('a'))!.syncStatus, SyncStatus.enNube);
    });
  });

  group('Preferencias que cablea Ajustes', () {
    test('calidad de video por defecto: original, y persiste', () async {
      final store = InMemorySecureStore();
      final prefs = GalleryImportPreferences(store);
      expect(await prefs.getVideoQuality(), VideoQualityOption.original);
      await prefs.setVideoQuality(VideoQualityOption.p720);
      expect(
        await GalleryImportPreferences(store).getVideoQuality(),
        VideoQualityOption.p720,
      );
      store.data['pref.gallery.videoQuality'] = 'basura';
      expect(await prefs.getVideoQuality(), VideoQualityOption.original);
    });

    test('borrar originales: apagado por defecto', () async {
      final prefs = GalleryImportPreferences(InMemorySecureStore());
      expect(await prefs.getDeleteOriginalsWhenInCloud(), isFalse);
      await prefs.setDeleteOriginalsWhenInCloud(true);
      expect(await prefs.getDeleteOriginalsWhenInCloud(), isTrue);
    });

    test('límite de caché: 500 MB por defecto; persiste', () async {
      final store = InMemorySecureStore();
      final prefs = CachePreferences(store);
      expect(await prefs.getLimitBytes(), 500 * 1024 * 1024);
      await prefs.setLimitBytes(2 * 1024 * 1024 * 1024);
      expect(
        await CachePreferences(store).getLimitBytes(),
        2 * 1024 * 1024 * 1024,
      );
    });

    test('autobloqueo: setDelay aplica en caliente y persiste', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final store = InMemorySecureStore();
      var locks = 0;
      final c = AutoLockController(
        onLock: () => locks++,
        preferences: AutoLockPreferences(store),
      );
      expect(c.delay, AutoLockDelay.defaultValue);
      await c.setDelay(AutoLockDelay.seconds15);
      expect(c.delay, AutoLockDelay.seconds15);
      expect(
        await AutoLockPreferences(store).getDelay(),
        AutoLockDelay.seconds15,
      );
      expect(locks, 0);
    });

    test(
      'proteger pantalla: setEnabled persiste y aplica FLAG_SECURE',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('vault/security-f8-test');
        final calls = <bool>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'setSecure') {
                calls.add((call.arguments as Map)['secure'] as bool);
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final store = InMemorySecureStore();
        final protection = ScreenProtection(
          preferences: ScreenProtectionPreferences(store),
          platform: PlatformSecurity(channel: channel, isAndroid: true),
          allowScreenshotsDefine: false,
          releaseMode: true,
        );
        expect(await protection.isPreferenceEnabled(), isTrue); // por defecto
        await protection.setEnabled(false);
        expect(await protection.isPreferenceEnabled(), isFalse);
        expect(calls.last, isFalse);
        await protection.setEnabled(true);
        expect(calls.last, isTrue);
        expect(await ScreenProtectionPreferences(store).getProtect(), isTrue);
      },
    );
  });
}

/// Espera a que termine el run que lanzan por su cuenta signIn/setWifiOnly.
Future<void> _idle(SyncService sync) async {
  for (var i = 0; i < 200 && sync.isRunning; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

typedef SecureOrSpy = _SpyStore;

class _SpyStore extends InMemorySecureStore {
  _SpyStore(this._inner, this.order);
  final InMemorySecureStore _inner;
  final List<String> order;

  @override
  Map<String, String> get data => _inner.data;

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) {
    order.add(key);
    return _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
