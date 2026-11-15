import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../../core/config/google_config.dart';
import 'cloud_storage.dart';

/// Traduce cualquier error de red/Drive/plugin a un [CloudException].
CloudException mapCloudError(Object error) {
  if (error is CloudException) return error;
  if (error is drive.DetailedApiRequestError) {
    final status = error.status ?? 0;
    final reasons = [
      for (final e in error.errors)
        if (e.reason != null) e.reason!,
    ];
    if (status == 401) return const CloudNotAuthenticatedException();
    if (status == 403) {
      if (reasons.contains('storageQuotaExceeded')) {
        return const CloudQuotaExceededException();
      }
      final rate = reasons.any(
        (r) => r == 'rateLimitExceeded' || r == 'userRateLimitExceeded',
      );
      return CloudForbiddenException(
        error.message ?? 'Acceso denegado por Drive (403)',
        rateLimited: rate,
      );
    }
    if (status == 404) return const CloudNotFoundException();
    if (status == 429) {
      return CloudForbiddenException(
        error.message ?? 'Demasiadas solicitudes a Drive',
        rateLimited: true,
      );
    }
    if (status >= 500) return CloudServerException(status, error.message);
    return CloudUnknownException(
      'Drive respondió $status: ${error.message ?? ''}',
    );
  }
  if (error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException ||
      error is HandshakeException) {
    return const CloudNoNetworkException();
  }
  if (error is PlatformException) {
    final code = error.code;
    if (code == 'network_error') return const CloudNoNetworkException();
    if (code == 'sign_in_canceled') {
      return const CloudSignInCancelledException();
    }
    final text = error.message ?? code;
    // DEVELOPER_ERROR (ApiException 10): el cliente OAuth de Android no
    // coincide con package + SHA-1 de la app (o aún no se propagó).
    final digits = RegExp('[0-9]+').allMatches(text).map((m) => m.group(0));
    if (code == 'sign_in_failed' && digits.contains('10')) {
      return const CloudSignInFailedException(
        'Google rechazó la configuración OAuth (código 10): revisa que el '
        'cliente Android de Google Cloud tenga el package com.saumnty.vault '
        'y el SHA-1 de esta firma.',
        code: 'sign_in_failed',
      );
    }
    return CloudSignInFailedException(text, code: code);
  }
  return CloudUnknownException('$error');
}

/// [CloudStorage] real: google_sign_in 6.3.0 + googleapis (Drive v3), scope
/// `drive.appdata` (carpeta oculta de la app; no ve el resto de Drive).
class GoogleDriveCloudStorage implements CloudStorage {
  GoogleDriveCloudStorage({GoogleSignIn? googleSignIn})
    : _signIn =
          googleSignIn ??
          GoogleSignIn(
            scopes: const [drive.DriveApi.driveAppdataScope],
            // iOS: único caso en que se usa clientId (ver GoogleConfig).
            clientId: GoogleConfig.clientIdFor(),
            serverClientId: GoogleConfig.serverClientIdFor(),
          );

  final GoogleSignIn _signIn;

  static const String _fields = 'id,name,size,md5Checksum';
  static const String _octet = 'application/octet-stream';

  @override
  String? get currentAccountEmail => _signIn.currentUser?.email;

  CloudAccount _account(GoogleSignInAccount a) =>
      CloudAccount(email: a.email, displayName: a.displayName);

  @override
  Future<CloudAccount> signIn() async {
    try {
      final account = await _signIn.signIn();
      if (account == null) throw const CloudSignInCancelledException();
      return _account(account);
    } catch (e) {
      throw mapCloudError(e);
    }
  }

  @override
  Future<CloudAccount?> signInSilently() async {
    try {
      final account = await _signIn.signInSilently();
      return account == null ? null : _account(account);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _signIn.signOut();
    } catch (e) {
      throw mapCloudError(e);
    }
  }

  /// Ejecuta [op] con un cliente autenticado NUEVO (token fresco). Ante 401
  /// limpia la caché de tokens y reintenta una vez.
  Future<T> _withApi<T>(Future<T> Function(drive.DriveApi api) op) async {
    for (var attempt = 0; ; attempt++) {
      if (_signIn.currentUser == null) {
        final silent = await signInSilently();
        if (silent == null) throw const CloudNotAuthenticatedException();
      }
      http.Client? client;
      try {
        client = await _signIn.authenticatedClient();
        if (client == null) throw const CloudNotAuthenticatedException();
        return await op(drive.DriveApi(client));
      } catch (e) {
        final mapped = mapCloudError(e);
        if (mapped is CloudNotAuthenticatedException && attempt == 0) {
          try {
            await _signIn.currentUser?.clearAuthCache();
          } catch (_) {}
          continue;
        }
        throw mapped;
      } finally {
        client?.close();
      }
    }
  }

  CloudFile _toCloud(drive.File f) => CloudFile(
    id: f.id!,
    name: f.name ?? '',
    size: int.tryParse(f.size ?? '') ?? 0,
    md5Checksum: f.md5Checksum,
  );

  @override
  Future<CloudQuota> getQuota() => _withApi((api) async {
    final about = await api.about.get($fields: 'storageQuota');
    final q = about.storageQuota;
    return CloudQuota(
      usedBytes: int.tryParse(q?.usage ?? '') ?? 0,
      limitBytes: int.tryParse(q?.limit ?? ''),
    );
  });

  @override
  Future<CloudFile> uploadFile({
    required File file,
    required String name,
    String? replaceFileId,
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) => _withApi((api) async {
    final total = await file.length();
    var sent = 0;
    // Cada chunk que el cargador reanudable consume pasa por aquí: sirve de
    // progreso y de punto de cancelación (el error aborta la subida).
    final stream = file.openRead().map((chunk) {
      if (cancel?.isCancelled ?? false) throw const CloudCancelledException();
      sent += chunk.length;
      onProgress?.call(sent, total);
      return chunk;
    });
    final media = drive.Media(stream, total, contentType: _octet);
    final options = drive.ResumableUploadOptions(chunkSize: 2 * 1024 * 1024);
    try {
      final result = replaceFileId == null
          ? await api.files.create(
              drive.File(name: name, parents: ['appDataFolder']),
              uploadMedia: media,
              uploadOptions: options,
              $fields: _fields,
            )
          : await api.files.update(
              drive.File(),
              replaceFileId,
              uploadMedia: media,
              uploadOptions: options,
              $fields: _fields,
            );
      return _toCloud(result);
    } catch (e) {
      if (cancel?.isCancelled ?? false) {
        throw const CloudCancelledException();
      }
      rethrow;
    }
  });

  @override
  Future<CloudFile> uploadBytes({
    required Uint8List bytes,
    required String name,
    String? replaceFileId,
  }) => _withApi((api) async {
    final media = drive.Media(
      Stream.value(bytes),
      bytes.length,
      contentType: _octet,
    );
    final result = replaceFileId == null
        ? await api.files.create(
            drive.File(name: name, parents: ['appDataFolder']),
            uploadMedia: media,
            $fields: _fields,
          )
        : await api.files.update(
            drive.File(),
            replaceFileId,
            uploadMedia: media,
            $fields: _fields,
          );
    return _toCloud(result);
  });

  @override
  Future<CloudFile> getMetadata(String fileId) => _withApi((api) async {
    final f = await api.files.get(fileId, $fields: _fields) as drive.File;
    return _toCloud(f);
  });

  Future<drive.Media> _media(drive.DriveApi api, String fileId) async =>
      await api.files.get(
            fileId,
            downloadOptions: drive.DownloadOptions.fullMedia,
          )
          as drive.Media;

  @override
  Future<void> download(
    String fileId,
    File destination, {
    CloudProgress? onProgress,
    CloudCancelToken? cancel,
  }) => _withApi((api) async {
    final media = await _media(api, fileId);
    final total = media.length ?? 0;
    var got = 0;
    final sink = destination.openWrite();
    try {
      await for (final chunk in media.stream) {
        if (cancel?.isCancelled ?? false) {
          throw const CloudCancelledException();
        }
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  });

  @override
  Future<Uint8List> downloadBytes(String fileId) => _withApi((api) async {
    final media = await _media(api, fileId);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in media.stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  });

  @override
  Future<void> delete(String fileId) =>
      _withApi((api) => api.files.delete(fileId));

  @override
  Future<CloudFile?> findByName(String name) => _withApi((api) async {
    final escaped = name.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final res = await api.files.list(
      spaces: 'appDataFolder',
      q: "name = '$escaped' and trashed = false",
      orderBy: 'createdTime desc',
      pageSize: 1,
      $fields: 'files($_fields)',
    );
    final files = res.files;
    if (files == null || files.isEmpty) return null;
    return _toCloud(files.first);
  });

  @override
  Future<List<CloudFile>> list() => _withApi((api) async {
    final out = <CloudFile>[];
    String? token;
    do {
      final res = await api.files.list(
        spaces: 'appDataFolder',
        pageSize: 200,
        pageToken: token,
        $fields: 'nextPageToken,files($_fields)',
      );
      out.addAll((res.files ?? const []).map(_toCloud));
      token = res.nextPageToken;
    } while (token != null);
    return out;
  });
}
