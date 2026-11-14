import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

class GoogleDriveService {
  // Solicitamos acceso exclusivo a la carpeta de datos de la app en Drive
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [drive.DriveApi.driveAppdataScope],
  );

  GoogleSignInAccount? _currentUser;

  /// Inicia sesión con la cuenta de Google del usuario
  Future<bool> signIn() async {
    try {
      _currentUser = await _googleSignIn.signIn();
      return _currentUser != null;
    } catch (e) {
      debugPrint('Error al iniciar sesión en Google: $e');
      return false;
    }
  }

  /// Cierra sesión de Google Drive
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _currentUser = null;
  }

  /// Obtiene la API de Drive autenticada para realizar operaciones
  Future<drive.DriveApi?> _getDriveApi() async {
    try {
      if (_currentUser == null) {
        _currentUser = await _googleSignIn.signInSilently();
        if (_currentUser == null) return null;
      }

      final httpClient = await _googleSignIn.authenticatedClient();
      if (httpClient == null) return null;

      return drive.DriveApi(httpClient);
    } catch (e) {
      debugPrint('Error al conectar con la API de Drive: $e');
      return null;
    }
  }

  /// Sube un archivo cifrado (.vault) al appDataFolder de Google Drive
  Future<bool> uploadEncryptedFile(
    File localFile,
    String remoteFileName,
  ) async {
    try {
      final driveApi = await _getDriveApi();
      if (driveApi == null) return false;

      // Configuramos los metadatos indicando que va en la carpeta oculta appDataFolder
      var driveFile = drive.File();
      driveFile.name = remoteFileName;
      driveFile.parents = ['appDataFolder'];

      final media = drive.Media(localFile.openRead(), localFile.lengthSync());

      await driveApi.files.create(driveFile, uploadMedia: media);

      return true;
    } catch (e) {
      debugPrint('Error al subir archivo a Drive: $e');
      return false;
    }
  }

  /// Descarga un archivo cifrado desde Google Drive al almacenamiento local
  Future<bool> downloadEncryptedFile(
    String fileId,
    File localDestination,
  ) async {
    try {
      final driveApi = await _getDriveApi();
      if (driveApi == null) return false;

      drive.Media media =
          await driveApi.files.get(
                fileId,
                downloadOptions: drive.DownloadOptions.fullMedia,
              )
              as drive.Media;

      final IOSink sink = localDestination.openWrite();
      await media.stream.pipe(sink);
      await sink.close();

      return true;
    } catch (e) {
      debugPrint('Error al descargar archivo de Drive: $e');
      return false;
    }
  }
}
