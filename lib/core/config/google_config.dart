import 'dart:io' show Platform;

/// Configuración de Google Sign-In / Drive. ÚNICO lugar donde viven los IDs
/// de cliente OAuth.
///
/// Los IDs de cliente OAuth son PÚBLICOS (no son secretos: van dentro de la
/// app y en las URL de consentimiento); aun así no se incrustan en el código
/// fuente: se pasan en compilación con `--dart-define`.
///
/// Qué necesita cada plataforma (google_sign_in 6.3.0, verificado en el
/// código de `google_sign_in_android` 6.2.1 y `google_sign_in_ios` 5.9.0):
/// * Android: NINGÚN ID en código. El cliente OAuth "Android" de Google Cloud
///   se resuelve por `package name + SHA-1` del certificado de firma
///   (com.saumnty.vault + SHA-1 debug/release). `clientId` se ignora en
///   Android. `serverClientId` solo hace falta si se quiere `idToken`/código
///   de servidor (no es el caso: solo se usa el scope `drive.appdata`).
/// * iOS: `clientId` = ID del cliente OAuth "iOS" (termina en
///   `.apps.googleusercontent.com`). Además el esquema de URL (REVERSED
///   client id) en Info.plist (ya añadido: GIDClientID + CFBundleURLTypes).
/// * serverClientId (Web): opcional; se pasa solo si no está vacío.
///
/// Los valores por defecto son los IDs reales del proyecto (públicos);
/// se pueden sobreescribir así:
/// ```
/// flutter run \
///   --dart-define=GOOGLE_IOS_CLIENT_ID=1234-abc.apps.googleusercontent.com \
///   --dart-define=GOOGLE_WEB_CLIENT_ID=1234-xyz.apps.googleusercontent.com
/// ```
/// (en Codemagic: variables de entorno del flujo de trabajo pasadas igual).
abstract final class GoogleConfig {
  /// ID de cliente OAuth de iOS. Vacío = no configurado (placeholder).
  static const String iosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
    defaultValue:
        '1084069117024-8fbi173vdos9ocupmg93rap3o0g5kafm.apps.googleusercontent.com',
  );

  /// ID de cliente OAuth Web (`serverClientId`). Vacío = no se envía.
  static const String webClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue:
        '1084069117024-fdiqero13ccqjr7ftfk3q0l7mpuk97uv.apps.googleusercontent.com',
  );

  /// Cliente OAuth Android (solo documentación, NO va en código): se resuelve
  /// por package com.saumnty.vault + SHA-1 de la firma.
  /// 1084069117024-616ukqcch2sjncuunln8lsikla5abele.apps.googleusercontent.com

  /// `clientId` para `GoogleSignIn(...)`: solo iOS y solo si está configurado.
  static String? clientIdFor({bool? isIOS, String ios = iosClientId}) {
    final onIOS = isIOS ?? Platform.isIOS;
    // iOS: único caso en que google_sign_in usa clientId.
    if (!onIOS || ios.isEmpty) return null;
    return ios;
  }

  /// `serverClientId` para `GoogleSignIn(...)`: solo si no está vacío.
  static String? serverClientIdFor({String web = webClientId}) =>
      web.isEmpty ? null : web;
}
