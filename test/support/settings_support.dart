import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/security/auto_lock.dart';
import 'package:vault/core/security/platform_security.dart';
import 'package:vault/core/security/security_preferences.dart';
import 'package:vault/core/services/cache_manager.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/data/gallery/import_preferences.dart';
import 'package:vault/data/repositories/vault_data_repository.dart';
import 'package:vault/data/sync/offline_service.dart';
import 'package:vault/data/sync/storage_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';
import 'package:vault/data/sync/sync_queue_repository.dart';
import 'package:vault/data/sync/sync_service.dart';
import 'package:vault/features/settings/settings_environment.dart';
import 'package:vault/features/settings/settings_screen.dart';

import 'fake_cloud.dart';
import 'fakes.dart';
import 'ui_helpers.dart';

const settingsTestPin = '123456';
const settingsMb = 1024 * 1024;

/// Almacenamiento falso: registra llamadas y devuelve datos fijos.
class FakeStorage implements StorageService {
  FakeStorage({this.limit = 500 * settingsMb});

  int limit;
  final calls = <String>[];
  FreedSpace next = const FreedSpace(files: 3, bytes: 12 * settingsMb);

  @override
  CacheManager get cache => throw UnimplementedError();

  @override
  OfflineService? get offline => null;

  @override
  Future<CacheStats> stats() async => CacheStats(
    cachedBytes: 20 * settingsMb,
    cachedCount: 4,
    offlineBytes: 30 * settingsMb,
    offlineCount: 5,
    limitBytes: limit,
  );

  @override
  Future<FreedSpace> setLimitBytes(int bytes) async {
    calls.add('limit:$bytes');
    limit = bytes;
    return const FreedSpace(files: 0, bytes: 0);
  }

  @override
  Future<FreedSpace> clearCache() async {
    calls.add('clear');
    return next;
  }

  @override
  Future<FreedSpace> freeOfflineSpace() async {
    calls.add('free');
    return next;
  }
}

class SettingsTestEnv {
  final store = InMemorySecureStore();
  final bio = FakeBiometricKeyStore();
  final cloud = FakeCloudStorage(email: 'santy@example.com');
  final storage = FakeStorage();
  final secureCalls = <bool>[];
  int locks = 0;
  late final AuthController auth;
  late final AutoLockController autoLock;
  late final ScreenProtection protection;
  late final SyncService sync;
  late final SettingsEnvironment env;
  late final MethodChannel channel;

  Future<void> init({bool withVault = true}) async {
    auth = AuthController(
      storage: store,
      biometricStore: bio,
      kdfParams: fastKdf,
      session: VaultSession.create(),
    );
    if (withVault) await auth.createVault(settingsTestPin);
    autoLock = AutoLockController(
      onLock: () => locks++,
      preferences: AutoLockPreferences(store),
    );
    channel = const MethodChannel('vault/security-settings-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setSecure') {
            secureCalls.add((call.arguments as Map)['secure'] as bool);
          }
          return null;
        });
    protection = ScreenProtection(
      preferences: ScreenProtectionPreferences(store),
      platform: PlatformSecurity(channel: channel, isAndroid: true),
      allowScreenshotsDefine: false,
      releaseMode: true,
    );
    sync = SyncService(
      cloud: cloud,
      queue: SyncQueueRepository(),
      items: VaultDataRepository(),
      network: FakeNetworkMonitor(),
      prefs: SyncPreferences(store),
      isUnlocked: () => false, // sin BD: solo cuenta/preferencias
      resolvePath: (rel) => throw UnimplementedError(),
      recoveryBackupProvider: () async => null,
      snapshotProvider: () async => throw UnimplementedError(),
      scheduleWakeups: false,
    );
    await sync.start(); // restaura la sesión de Google (sin UI)
    env = SettingsEnvironment(
      auth: auth,
      autoLock: autoLock,
      screenProtection: protection,
      importPreferences: GalleryImportPreferences(store),
      onLock: () => locks++,
      versionLoader: () async =>
          const AppVersion(version: '1.2.3', build: '45'),
    );
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    sync.dispose();
  }

  Widget screen({bool withSync = true, bool withStorage = true}) => testApp(
    SettingsScreen(
      env: env,
      services: fakeServices(
        FakeVaultRepository(),
        sync: withSync ? sync : null,
        storage: withStorage ? storage : null,
      ),
    ),
  );
}
