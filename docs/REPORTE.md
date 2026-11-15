# REPORTE — trabajo autónomo (rama dev-claude, sin push)

## Completado (todo con `flutter analyze` limpio y `flutter test` en verde; 148 tests al final)
- **Baseline** de tus archivos sin commit.
- **F1 Llaves** (Opus): DEK + KEK_pin + KEK_rec (Argon2id), subllaves HKDF (sqlcipher/files/thumbs), biometría atada al sistema (`biometric_storage` 5.0.1; `local_auth` eliminado), cambio de PIN por re-envoltura, retraso creciente persistido. Corregidos los 11 errores iniciales.
- **F2 Formato .vault v2** (Opus): encabezado VLT+0x02+fileId+blockSize, AAD = encabezado+índice+isFinal; pruebas de los 4 ataques y de tamaños 0 B / 1 B / 1 MiB / 1 MiB+1 / varios MB; lectura desde cualquier bloque.
- **F3 Base de datos** (Sonnet): esquema v3 (campos de sync, thumbPath, LRU, hash, sourceAssetId, durationMs, isOffline en carpetas), rutas relativas (`AppPaths`), llave SQLCipher derivada de la DEK, repositorio, snapshot cifrado para F5.
- **F3.5 Rediseño** (Sonnet): tema centralizado (`lib/core/theme`), PIN con teclado propio, cuadrícula escalonada, shimmer, íconos de estado, gestos, FAB expandible, breadcrumbs, búsqueda, estados vacíos, sheets con blur, accesibilidad. Decisiones en `docs/DISENO.md`; capturas (goldens) en `docs/screens/`.
- **F4 parcial** (Sonnet): selector de galería (`photo_manager` 3.12.0), importación por lote con hash, cifrado, miniatura cifrada, compresión opcional (`video_compress` 3.1.4, tras interfaz), borrado de originales protegido (4 condiciones, apagado por defecto), loader de miniaturas. `flutter build apk --debug` compila.

## Probado
Solo con analyze, tests unitarios/widget/golden y `build apk --debug`. **Nada se probó en emulador ni dispositivo.**

## Bloqueado
- **Emulador Pixel_7 no arranca** (qemu levanta pero adb no lo ve; probado con/sin ventana y GPU por software). Consecuencias: SQLCipher real, biometría real, permisos, selector de galería, compresión, gestos y háptica sin probar.
- **F5 en adelante** no se inició: F5 y F9 requieren tu configuración de Google Cloud/OAuth/SHA-1 para probarse. Pendiente además: iCloud (F4 iOS), F6, F7, F8, F10.
- Nota: 7 archivos quedaron con cambios solo de formato (`dart format`), incluidos en el commit; son inocuos.

## Qué debes probar, en orden
1. Arreglar el emulador (Android Studio → Device Manager, borrar/recrear AVD, o usar un teléfono real con depuración USB) y correr `flutter run`.
2. Correr `flutter test integration_test/vault_database_sqlcipher_test.dart -d <id>` (SQLCipher con la llave derivada).
3. Crear bóveda: ver código de recuperación, activar biometría, desbloquear con biometría, añadir una huella (debe pedir PIN), equivocar el PIN 5 veces (bloqueo 30 s que sobreviva al cerrar la app).
4. Importar fotos/videos desde la galería (permisos, miniaturas, compresión 1080p/720p); importar un archivo; navegar carpetas, selección, pinch, deslizar.
5. Primera compilación Android descarga JDK 17 (foojay) — confirma que te parece bien.
6. iOS (Codemagic + Sideloadly): Face ID, descarga desde iCloud, hereda pendiente F10.

## Siguiente
F5 (sincronización) necesita: proyecto en Google Cloud, Drive API, pantalla de consentimiento, cliente OAuth Android (SHA-1 debug/release) e iOS. Dime cuando quieras que te dé los pasos exactos.

---
## Actualización: emulador arreglado y Fase 1 ejecutada

### Diagnóstico del emulador
- `emulator -accel-check`: **WHPX instalado y usable**; virtualización activa en firmware (`VirtualizationFirmwareEnabled=True`, `HypervisorPresent=True`). **No falta aceleración**, no hay que tocar la BIOS (en una HP Victus la opción se llamaría "Virtualization Technology (VTx)" en Configuración avanzada del sistema, pero ya está activa).
- Causa real: arranque lento/colgado con GPU `auto` y snapshot. Con `-no-snapshot -gpu swiftshader_indirect` arranca (boot ≈ 95 s). Avisos: `opengl32sw` no carga (cae a OpenGL del sistema), y el AVD tiene 2 GB de RAM con imagen Android 17 (API 37) → "System UI isn't responding" al inicio (pulsar "Wait"). RAM del PC: 15.7 GB (el emulador sugiere 16).
- Comando que funciona:
  `emulator -avd Pixel_7 -no-snapshot -gpu swiftshader_indirect`
  (adb está en `%LOCALAPPDATA%\Android\Sdk\platform-tools`, no está en el PATH).
- Recomendación: en Android Studio → Device Manager, editar Pixel_7: Graphics = Software, RAM 3-4 GB; o crear un AVD con imagen API 34/35 (más ligera).

### Fase 1 en el emulador (capturas en docs/screens/emu/)
- ✅ Crear bóveda con PIN 123456: pantalla "Creando bóveda…" (≈40 s en emulador por Argon2id en Dart + CPU emulada), luego **código de recuperación** (24 chars, `QSB5-PNMD-6RR3-QTGV-R7JT-FDPJ`) y "Ya lo guardé".
- ✅ Bóveda abre con estado vacío → **la BD SQLCipher abrió con la llave derivada** (sin errores en el log de `flutter run`).
- ✅ Cerrar la app (force-stop) y reabrir → pantalla de PIN; PIN correcto → bóveda desbloqueada (tras ≈40 s).
- No ejecutado: PIN incorrecto ×5 (bloqueo 30 s), biometría (el emulador no tiene huella enrolada), cambio de huella.
- Observaciones: (1) el desbloqueo/creación tarda ~40 s en el emulador (Argon2id m=19456 en Dart puro sobre CPU emulada); en teléfono real debería ser mucho menor, pero hay que medirlo — si pasa de ~2 s, reducir parámetros o usar `cryptography_flutter`. (2) El código de recuperación se parte en 2 líneas ("FDPJ" huérfano): ajuste cosmético pendiente. (3) Sin indicador de progreso claro durante la derivación aparte del spinner del botón.

---
## Actualización: Argon2id nativo (libsodium)

- `lib/core/crypto/argon2_backend.dart`: interfaz `Argon2Backend` inyectable (`Argon2Backend.current`). Android/iOS: `FallbackArgon2Backend(SodiumArgon2Backend → IsolateDartArgon2Backend)`; escritorio: Dart puro en isolate; `flutter test`: Dart en el mismo isolate (FakeAsync). `Argon2Params.deriveKey` delega en él; API y JSON sin cambios.
- Paquete: `sodium_libs` 3.4.6+4 + `sodium` 3.4.6 (libsodium 1.0.20 precompilado, `crypto_pwhash` ALG_ARGON2ID13, corre en otro isolate con `runIsolated`). `cryptography_flutter` NO implementa Argon2 (solo AES/ChaCha/HMAC/PBKDF2/Ed25519/X25519/ECDSA/RSA). `sodium_libs` está marcado como discontinuado en favor de `sodium` 4.x, que compila libsodium con build hooks (exige `make`+bash en Windows y Dart ≥3.12 en sus versiones nuevas): migrar cuando se suba el SDK.
- Parámetros SIN cambios: m=19456 KiB, t=2, p=1. Resultado idéntico: vector phc-winner-argon2 (test/argon2_backend_test.dart) y libsodium == Dart en el emulador (integration_test/argon2_native_test.dart).
- Tiempos en emulador (Pixel_7, x86_64), por derivación: Dart en hilo UI (antes) release 0,5–1,2 s / debug 1,5–3,4 s (primera hasta 6–7 s en debug); libsodium (ahora) release 70–140 ms / debug 0,3–1,1 s. El flujo completo crear/desbloquear sigue en ~4,5–6 s release: el resto se va fuera de Argon2id (probablemente SQLCipher: la llave se pasa como texto hex → PBKDF2-SHA512 256 000 iteraciones al abrir; usar llave cruda `x'…'` lo evitaría — pendiente, fuera de este cambio).
- Android descarga el zip de libsodium (verificado por SHA-512) en la primera compilación; iOS lo hace en `pod install` (prepare_command). iOS sin probar.

---
## Ronda 2 (autónoma)

### 1. Argon2id: ver sección del subagente más arriba (sodium_libs/libsodium, isolate, m=19456 KiB t=2 p=1 sin bajar). Derivación en emulador release 0,5–1,2 s → 70–140 ms (debug 1,5–3,4 s → 0,3–1,1 s). La espera total de crear/desbloquear bajó a ~4,5–6 s (release); el resto era SQLCipher: pasarle la llave en formato crudo `x'<hex>'` evita su PBKDF2 de 256 000 iteraciones (commit aparte). Test de integración SQLCipher **verde en emulador** (abre con la llave derivada, rechaza otra, cierra al bloquear).

### 2. Fase 1 completada en emulador (capturas en docs/screens/emu/10-15)
- ✅ Crear bóveda (release) y código de recuperación en grupos de 4 sin partirse.
- ✅ Huella registrada con `adb emu finger touch 1` (tras `locksettings set-pin 1234` + BIOMETRIC_ENROLL). Oferta "Activar" → activada.
- ✅ Arranque en frío + huella → bóveda desbloqueada sin PIN.
- ✅ 5 PIN incorrectos → "Demasiados intentos. Espera N s" (30 s). Un fallo más → nivel 60 s. Cerrar y reabrir la app → el bloqueo **persiste** ("Espera 25 s").
- Observación de diseño: el bloqueo por PIN no impide el prompt biométrico (la biometría sigue disponible durante el bloqueo). Es habitual, pero confírmalo si quieres que el bloqueo aplique también a la huella.
- Pendiente: cambio de huella (invalidación de llave) no probado.

### 3. ✅ Código de recuperación: grupos de 4 indivisibles, 3 por fila (golden y emulador).

### 4. F4 en emulador (capturas 20-27)
- ✅ FAB expandible, permiso de fotos (Android 13+ "Allow all"), selector real con `photo_manager` (video con duración 0:05), selección múltiple, hoja de calidad (Original / 1080p ≈2,98 MB / 720p ≈1,49 MB con estimaciones), progreso "Comprimiendo video · Original 66,8 KB", "Importación completa – 3 importados".
- ✅ Cuadrícula con 3 archivos con **miniaturas descifradas** desde `thumbs/*.thumb` (cifradas con la subllave "thumbs") y estado "pendiente".
- Limitaciones: (a) el video de prueba (screenrecord de 6 s, 68 KB) es demasiado pequeño para mostrar reducción real; el servicio solo usa el comprimido si pesa menos. Prueba con un video real de varios MB. (b) No pude listar `vault/` y `thumbs/` en disco (APK release no depurable → `run-as` falla); el cifrado de archivos/miniaturas está cubierto por tests unitarios. (c) iCloud (iOS) sin probar. (d) El visor de video/foto (F6) aún no existe.
- Media de prueba: `/sdcard/DCIM/Camera/prueba_*.png|mp4` en el emulador. En Git Bash usa `MSYS_NO_PATHCONV=1` con adb.

### Comando del emulador que funciona
`emulator -avd Pixel_7 -no-snapshot -gpu swiftshader_indirect` (PATH: `%LOCALAPPDATA%\Android\Sdk\platform-tools` y `\emulator`). Si aparece "System UI isn't responding", pulsa Wait.

---
## F5 — Sincronización con Google Drive (🧪 probada en emulador)
- **Resultado:** analyze limpio, 207 tests verdes, build debug OK.
- **Arquitectura:** `lib/core/config/google_config.dart` (IDs OAuth en un solo lugar, sobreescribibles con `--dart-define`); `lib/data/cloud/` (`CloudStorage` con errores tipados + `GoogleDriveCloudStorage`, subida resumible 2 MiB, idempotente); `lib/data/sync/` (`SyncService` con un solo worker, backoff exponencial+jitter 10 s–15 min, 5 intentos; cola persistente `sync_queue` en la BD cifrada, esquema v4 sin migración; solo Wi-Fi activo por defecto; `connectivity_plus`); hoja "Sincronización" (cuenta, cuota, conteos, solo Wi-Fi, sincronizar ahora, errores).
- **Verificación:** tamaño + MD5 local (en streaming) vs Drive antes de `en_nube`; `cloudVerifier` conectado al borrado de originales (la bandera sigue apagada; no se borra nada solo).
- **Respaldos en appDataFolder:** `recovery_backup.json` (DEK envuelta con KEK_rec, validado: nunca la envoltura del PIN) y `vault_db.snapshot` (≥20 subidas o ≥6 h).
- **Probado en emulador:** inicio de sesión Google real (con serverClientId Web, sin DEVELOPER_ERROR; el primer intento falló con ApiException 10 antes de aplicar los IDs, luego OK), subida real con tamaño+MD5 verificados, cuota visible ("25,98 MB de 15,00 GB", crece al subir), reanudación tras `force-stop` (7 → 4 pendientes), corte de wifi/datos ("Sin conexión. Se reanudará al volver la red.") y reanudación automática al restaurar → "Todo está al día".
- **No probado:** listar archivos de appDataFolder directamente (la subida se respalda con MD5 y cuota); videos grandes; iOS (Info.plist con GIDClientID y URL scheme puestos pero sin compilar).
- **Pendiente/limitaciones:** al borrar un item no se borra su copia en Drive (`TODO(F6)`); un desbloqueo falló una vez con "PIN incorrecto" (atribuido a taps del emulador/bóveda previa; vigilar).
- **Privacidad:** el subagente borró las capturas del emulador que mostraban el correo del usuario.
- **Acciones tuyas:** mantener tu correo como tester; la 1.ª vez aparece "Google hasn't verified this app" → Continue y marcar el permiso de Drive. Para release con llave propia, registrar su SHA-1 en el cliente Android. Antes de F10, comprobar login iOS en Codemagic.

---
## Investigación "PIN incorrecto" (resuelta)
Causa más probable: **crear la bóveda no pedía confirmar el PIN**; un toque perdido (emulador lento) dejaba la bóveda con otro PIN (p. ej. 12346) y "123456" fallaba siempre. Arreglado con pantalla "Confirma tu PIN". Además: operaciones de AuthController serializadas (contador de intentos con actualizaciones perdidas), unlock duplicado con el mismo PIN deduplicado (el 2.º `session.open` destruía las llaves en uso), envoltura ausente ya no cuenta como PIN incorrecto, y copia propia del secreto para el backend nativo (fallback a Dart). Descartado con evidencia: isolate de Argon2id, puesta a cero del secreto, teclado, SQLCipher; 50 desbloqueos seguidos con DEK idéntica; salt/DEK envuelta nunca se regeneran salvo `changePin`/`restore`. Logs de diagnóstico `[vault-auth]` solo en debug, sin PIN/llaves. Pendiente para F7: `lock()` debe cancelar un unlock en curso.

## F10 (preparación sin acciones tuyas)
- **Keystore de release** (fuera del repo): `%USERPROFILE%\.vault-keys\vault-release.jks`, alias `vault-release`. Las contraseñas están en `android/key.properties` (en .gitignore; **haz copia de seguridad del .jks y de key.properties**: sin ellos no podrás actualizar la app).
- **SHA-1 de release: `98:41:90:61:8B:DA:8C:ED:11:FA:FA:1B:D5:08:65:89:E9:0D:AD:A6`**
- SHA-256 de release: `9E:C5:D7:7D:48:3F:8C:73:4D:2E:64:3B:03:BE:44:C3:6F:68:AD:FA:6F:0D:D2:B5:B1:56:60:91:3B:57:B2:EA`
- `flutter build apk --release` firmado con esa llave verificado con apksigner (SHA-1 coincide). Si falta `key.properties` el build cae a la llave debug.
- `codemagic.yaml` con workflow `ios-unsigned` (.ipa sin firmar para Sideloadly) y `android-release` opcional.
- Info.plist iOS revisado: GIDClientID + URL scheme (reversed client ID), NSPhotoLibrary*, NSFaceIDUsageDescription presentes. No hay `ios/Podfile` en el repo (lo genera Flutter en la compilación en Codemagic).
