# CONTEXTO – Vault

Bóveda cifrada de fotos/videos/archivos en Flutter (Android + iOS), con respaldo en Google Drive (appDataFolder).
Estado detallado de fases: ver `PLAN.md`. Esta especificación es la vigente (corrige y amplía el primer prompt).

## Reglas de trabajo
- Rama `dev-claude`; nunca push ni main sin petición del usuario.
- Pruebas locales en emulador Android (Pixel_7). iOS se compila en Codemagic + Sideloadly; lo específico de iOS va con `// iOS:` y `Platform.isIOS`.
- No inventar APIs: verificar paquetes en pub.dev y fijar versión.
- Sin datos reales aún: se pueden cambiar formatos/esquemas sin migración (confirmar antes de borrar).
- Acción manual del usuario (Google Cloud, SHA-1, Codemagic, Apple ID) → detenerse con instrucciones.

## Diseño (identidad)
Fondo OLED `#0B0B0E`, acento morado neón `#7C3AED`. Tema centralizado en `lib/core/theme/` (F3.5).

## A) Jerarquía de llaves
- DEK 256 bits aleatoria, una sola vez.
- KEK_pin = Argon2id(PIN, salt) envuelve la DEK (AES-GCM); local.
- KEK_rec = Argon2id(código ~24 chars, salt2) envuelve otra copia; ésta (+salt2) es la que se respalda en appDataFolder. El PIN nunca protege nada que salga del teléfono.
- Biometría: DEK en almacenamiento ligado a biometría del sistema (no basta local_auth).
- Subllaves HKDF(DEK): "sqlcipher", "files", "thumbs".
- Cambiar PIN = re-envolver la DEK. Retraso creciente persistido tras fallos (5 → 30 s…).

## B) Formato .vault v2
Encabezado "VLT"+0x02+fileId(16 B UUID)+tamaño de bloque. Bloques AES-GCM con AAD = encabezado + índice(uint64) + isFinal(1 B). Detecta alteración, reordenación, truncado y bloques de otro archivo. Descifrado accesible desde cualquier bloque.

## C) Base de datos
Rutas RELATIVAS al directorio de la app. vault_items: driveFileId, syncStatus (pendiente, subiendo, en_nube, en_cache, sin_conexion, error), thumbPath, lastAccessedAt, contentHash, sourceAssetId, durationMs. folders: isOffline (heredado). Respaldo periódico de la BD cifrada en appDataFolder.

## Hoja de ruta
F0 auditoría · F1 llaves · F2 .vault v2 · F3 BD · F3.5 rediseño UI · F4 importación galería · F5 sincronización · F6 visor y caché · F7 seguridad del sistema · F8 onboarding/ajustes · F9 restauración · F10 despliegue. Detalle en PLAN.md.

## Estado real del código
(Se actualiza al cerrar cada fase.)
- Baseline: login por PIN con Argon2id, cifrado por bloques v1, servicios Drive/sync/caché esqueleto, UI básica (PIN, home, visor). Con 11 errores de compilación al inicio de F1.
- F1 hecha: `lib/core/crypto/` con auth_controller (createVault/unlockWithPin/unlockWithBiometrics/changePin/restoreFromRecovery/lock), wrapped_key (AES-GCM, AAD=propósito), kdf (Argon2id m=19456,t=2,p=1), key_hierarchy (HKDF sqlcipher/files/thumbs), pin_attempt_limiter (30s,60s,2m,5m,10m,30m,1h), biometric_key_store (paquete `biometric_storage` 5.0.1; local_auth eliminado). Código de recuperación 24 chars. Android usa toolchain JDK 17 vía foojay (settings.gradle.kts).
- F2 hecha: `lib/core/crypto/vault_file_format.dart` (.vault v2: encabezado 24 B, bloques nonce(12 aleatorio)‖ct‖tag(16), AAD=encabezado‖índice u64‖isFinal; último bloque = bytes restantes, vacío solo si el archivo es vacío; VaultFileReader con decryptBlock/readRange/streamRange; encryptBytes/decryptBytes mismo formato). `CryptoService` es la fachada. Excepciones `VaultFormatException`/`VaultAuthException`. Pruebas en `test/vault_file_format_test.dart`.
- F3 hecha: BD v3 (sin migración: cambio de versión recrea tablas). `AppPaths` (rutas relativas), `VaultDatabase` (SQLCipher con hex de la subllave sqlcipher, cierra al bloquear, `exportEncryptedSnapshot`), `VaultDataRepository` (CRUD, breadcrumbs, borrado recursivo, offline heredado), `SyncStatus`. Pruebas en `test/vault_database_test.dart` (sqlite ffi, sin SQLCipher) e `integration_test/vault_database_sqlcipher_test.dart` (SQLCipher real; NO ejecutada aún: el emulador Pixel_7 se colgó).
- Pendiente de arrastre: cache_manager/sync_queue/vault_viewer con TODO(F3/F5/F6).
