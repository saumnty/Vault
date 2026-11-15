# DECISIONES

Registro de decisiones tomadas de forma autónoma (reversibles). Formato: fecha · contexto · opciones · elegida · por qué.
Fecha base de las primeras entradas: 2026-11-14/15.

## D01 — Biometría: `biometric_storage` 5.0.1
- Contexto: la DEK debe guardarse atada a biometría del sistema; `local_auth` solo devuelve booleano.
- Opciones: `local_auth`; `flutter_secure_storage` 11.x; `biometric_storage` 5.0.1; 5.2.0-dev/6.0.0-dev.
- Elegida: `biometric_storage` 5.0.1 (versión fija).
- Por qué: Keystore con autenticación biométrica fuerte por uso / Keychain `.biometryCurrentSet`; las otras eran booleano, incompatibles (win32 ^6) o prerelease/exigían SDK mayor. Requiere JDK 17 → toolchain vía foojay.

## D02 — Argon2id nativo: `sodium_libs` 3.4.6+4 (no `sodium` 4.x)
- Contexto: Dart puro era lento en el emulador; `cryptography_flutter` no implementa Argon2.
- Opciones: sodium_libs 3.x; sodium 4.x; argon2_ffi_base; dargon2_flutter; flutter_sodium.
- Elegida: sodium_libs 3.4.6+4 con fallback a Dart en isolate; parámetros m=19456 KiB, t=2, p=1 (OWASP) sin bajar.
- Por qué: binarios precompilados Android/iOS; 4.x compila libsodium (pide make/bash en Windows) y exige Dart ≥3.12. Migrar al subir el SDK (el paquete 3.x está discontinuado).

## D03 — SQLCipher con llave cruda `x'<hex>'`
- Contexto: el desbloqueo tardaba ~5 s por el PBKDF2 interno de SQLCipher (256 000 it.).
- Elegida: pasar la subllave HKDF de 256 bits en formato crudo.
- Por qué: ya es una llave de alta entropía; el KDF adicional no aporta seguridad.

## D04 — Confirmar el PIN al crear la bóveda
- Contexto: "PIN incorrecto" con el PIN correcto; causa más probable: toque perdido al crear (sin confirmación).
- Elegida: pantalla "Confirma tu PIN" + operaciones de `AuthController` serializadas + deduplicación de unlock.

## D05 — La huella no se bloquea por intentos fallidos de PIN
- Decisión del usuario (se deja como está).

## D06 — Identificador `com.saumnty.vault`
- Decisión del usuario; macOS/Linux sin renombrar (se eliminan en limpieza).

## D07 — Compresión de video: `video_compress` 3.1.4 tras interfaz
- Opciones: video_compress; light_compressor (3 años, calidades abstractas); forks de ffmpeg-kit (pesados/retirados).
- Elegida: video_compress detrás de `VideoCompressor` (reemplazable). Solo se usa el comprimido si pesa menos.

## D08 — Selector de galería propio sobre `photo_manager` 3.12.0
- Opción descartada: `wechat_assets_picker` (otra dependencia grande con su propio tema/textos).

## D09 — `contentHash` = SHA-256 del contenido realmente guardado
- Así F5 puede verificarlo; la verificación en Drive usa además MD5 + tamaño del .vault cifrado.

## D10 — Keystore de release fuera del repo
- Ubicación: `%USERPROFILE%\.vault-keys\vault-release.jks`; contraseñas en `android/key.properties` (en `.gitignore`).
- Si falta `key.properties`, el build cae a la llave debug para no romper otras máquinas/CI.
- La SHA-1 de release se registra en Google Cloud manualmente (ver REPORTE.md). El login de Google en emulador se prueba con builds debug/profile (SHA-1 debug registrada).

## D11 — `codemagic.yaml` sin correo del usuario
- No se incluye `publishing.email` (el repo podría ser público); Codemagic notifica por defecto al autor del commit.

## D12 — Solo Wi-Fi activo por defecto para sincronización
- Evita consumir datos móviles con videos grandes; configurable en ajustes (F8).

## D13 — `video_player` 2.11.1
- 2.14.1 y ≥2.12 exigen Flutter ≥3.44 / Dart ^3.12; 2.11.1 es la última compatible con Flutter 3.41.6.

## D14 — Los archivos "sin conexión" no cuentan contra el límite de caché LRU
- Contexto: si contaran, con muchos offline se purgaría todo lo demás al abrir cualquier archivo.
- Elegida: no cuentan; la caché de 500 MB aplica solo a lo purgable. (Reversible; revisar.)

## D15 — Video: descifrado completo a temporal primero, streaming después (F6b)
- El temporal en claro vive en `tmp_plain/`, se borra al cerrar el visor, al bloquear y se barre al arrancar/desbloquear.
