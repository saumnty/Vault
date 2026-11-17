import 'dart:async';

import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/data/cloud/cloud_storage.dart';
import 'package:vault/data/restore/restore_service.dart';
import 'package:vault/data/sync/sync_preferences.dart';

import 'fake_cloud.dart';
import 'fakes.dart';

/// [RestoreService] guionizado para probar la interfaz sin red ni disco.
class ScriptedRestoreService extends RestoreService {
  ScriptedRestoreService()
    : super(
        cloud: FakeCloudStorage(email: null),
        auth: AuthController(
          storage: InMemorySecureStore(),
          biometricStore: FakeBiometricKeyStore(),
          kdfParams: fastKdf,
        ),
        prefs: SyncPreferences(InMemorySecureStore()),
      );

  RestoreProbeResult probeResult = RestoreProbeResult.found;
  String email = 'persona@example.com';
  bool signedIn = false;
  Object? signInError;

  /// Código aceptado (normalizado, sin guiones).
  String accepted = 'ABCDEFGHJKMNPQRSTUVWXYZ2';
  int wrongAttempts = 0;
  Duration? lockout;
  final submitted = <String>[];

  /// Si no es null, `restore` espera a que se complete.
  Completer<void>? gate;
  Object? restoreError;
  RestoreProgress? emit;
  List<RestoreProgress> script = const [];
  RestoreResult result = const RestoreResult(
    items: 12,
    folders: 3,
    thumbnails: 12,
    lostItems: 0,
    adoptedItems: 0,
    missingThumbnails: 0,
  );
  int restoreCalls = 0;
  String? pinUsed;

  /// Lo que "abrió" el código (M8); `null` = el conjunto más reciente.
  RestoreCodeMatch? match;

  @override
  RestoreCodeMatch? get lastMatch => match;

  @override
  String? get accountEmail => signedIn ? email : null;

  @override
  Future<CloudAccount> signIn() async {
    final e = signInError;
    if (e != null) throw e;
    signedIn = true;
    return CloudAccount(email: email);
  }

  @override
  Future<void> signOut() async => signedIn = false;

  @override
  Future<RestoreProbeResult> probe() async => probeResult;

  @override
  Future<Duration?> lockoutRemaining() async => lockout;

  @override
  Future<bool> verifyCode(String code) async {
    submitted.add(code);
    final ok = code.replaceAll('-', '').toUpperCase() == accepted;
    if (!ok) wrongAttempts++;
    return ok;
  }

  @override
  Future<RestoreResult> restore({
    required String newPin,
    void Function(RestoreProgress progress)? onProgress,
    CloudCancelToken? cancel,
  }) async {
    restoreCalls++;
    pinUsed = newPin;
    for (final p in script) {
      onProgress?.call(p);
    }
    final g = gate;
    if (g != null) {
      await g.future;
      if (cancel?.isCancelled ?? false) throw const CloudCancelledException();
    }
    final e = restoreError;
    if (e != null) {
      restoreError = null;
      throw e;
    }
    return result;
  }

  @override
  void dispose() {}
}
