# REPORTE FINAL (rama `dev-claude`, sin push, main intacta)

> Debajo de este bloque están los reportes detallados por fase/ronda (en el orden en que se escribieron).
> Estado a la fecha: `flutter analyze` sin issues · `flutter test` 563 verdes · APK release firmado y verificado · regresión final en emulador OK.

## 1. Resumen de lo completado y probado

| Fase | Contenido | Estado |
|---|---|---|
| F0 | Auditoría | 🧪 |
| F1 | DEK + KEK_pin + KEK_rec (Argon2id nativo m=19 MiB, t=2, p=1), HKDF, biometría atada al sistema, retraso persistido, confirmar PIN | 🧪 emulador (huella, invalidación por huella nueva, bloqueo persistente) |
| F2 | Formato `.vault` v2 (AAD con encabezado+índice+final) | 🧪 tests de los 4 ataques y tamaños 0 B…varios MB |
| F3 | BD SQLCipher v5, rutas relativas, llave cruda | 🧪 emulador |
| F3.5 | Rediseño UI con sistema de tokens | 🧪 emulador (gestos, pellizco, háptica) |
| F4 | Importación de galería, miniaturas cifradas, compresión de video, borrado de originales **verificado + confirmado** | 🧪 emulador (video 24,9 MB: 720p → 11,8 MB; 1080p conserva el original) |
| F5 | Sincronización con Drive (cola persistente, reintentos, solo Wi-Fi, MD5+tamaño, cuota, respaldos) | 🧪 emulador con Google real |
| F6 | Visor foto/video, caché LRU, sin conexión, borrado remoto, **streaming por bloques** sin texto plano en disco, AES-GCM nativo | 🧪 emulador |
| F7 | Autobloqueo, FLAG_SECURE, sin respaldo Android; 📝 cobertura multitarea iOS y exclusión de iCloud | 🧪 Android · 📝 iOS |
| F8 | Onboarding con confirmación del código por posiciones, regenerar código, Ajustes completos | 🧪 emulador |
| F9 | Restauración completa (Google → código → PIN nuevo → BD + miniaturas), snapshot siempre fresco | 🧪 emulador (incluye código incorrecto) |
| F10 | APK release ofuscado y firmado (SHA-1 verificada), `codemagic.yaml`, Info.plist | 🧪 APK · 📝 Codemagic/iOS sin probar |
| Seguridad | Revisión independiente (Opus): 4 altos corregidos con test | ✅ ver §4 |

- **Regresión final con el APK release** (`build/vault-release-signed.apk`, 74 127 300 B, SHA-256 `8aeaed98…45145`): crear bóveda → importar → sincronizar → foto con zoom y video con streaming/seek → sin conexión + corte de red → bloquear/desbloquear (PIN y huella) + autobloqueo → restaurar en instalación limpia: **todo OK**. Tabla en la sección "Regresión final".
- Capturas útiles en `docs/screens/` y `docs/screens/emu/` (correo y códigos difuminados).
- **Nada se ha probado en iPhone**: todo lo iOS está escrito y revisado por lectura.

## 2. Bloqueos 🚫

Ninguno abierto. Notas:
- Emulador que no arrancaba: resuelto (`emulator -avd Pixel_7 -no-snapshot -gpu swiftshader_indirect`).
- El login de Google con el APK firmado con la llave de **release** falla con `ApiException 10` hasta que registres su SHA-1 (acción tuya, §5.1). Con la llave debug funciona.
- Límite de uso agotado dos veces (y el semanal de Opus durante la revisión de seguridad): se retomó cada vez al restablecerse; no quedó trabajo a medias.

## 3. Decisiones tomadas (resumen de `docs/DECISIONES.md`)

- **Llaves/cripto:** `biometric_storage` 5.0.1 (D01); Argon2id nativo con `sodium_libs` 3.4.6+4, sin bajar parámetros (D02); SQLCipher con llave cruda `x'hex'` (D03); AES-GCM nativo con `cryptography_flutter` y respaldo a Dart, formato sin cambios (D22–D24).
- **UX/seguridad:** confirmar el PIN al crear (D04); la huella no se bloquea por intentos de PIN (tu decisión, D05); autobloqueo 1 min por defecto, `FLAG_SECURE` activo por defecto (D25–D30); regenerar código de recuperación y límite de intentos del código en restauración (D31–D39).
- **Ingeniería:** id `com.saumnty.vault` (D06); `video_compress` tras interfaz (D07); selector de galería propio (D08); `contentHash` del contenido realmente guardado (D09); `video_player` 2.11.1 por compatibilidad de SDK (D13); archivos "sin conexión" no cuentan en el límite de caché (D14, **revisar**); video con servidor loopback + token (D16–D21); solo Wi-Fi por defecto (D12).
- **Despliegue:** keystore de release fuera del repo (D10); `codemagic.yaml` sin tu correo y sin `flutter test` (goldens generados en Windows) (D11).

## 4. Hallazgos de la revisión de seguridad independiente

Detalle completo en la sección "Revisión de seguridad independiente" (S-01…S-21). **Ninguno crítico.**
- **Altos, corregidos con test de regresión:** S-01 el autobloqueo podía no armarse nunca si la app pasaba a segundo plano durante un diálogo/sincronización; S-02 copia en claro (con nombre) del archivo elegido en el selector de archivos; S-03 miniaturas/originales en claro en la caché de Glide/photo_manager; S-04 el respaldo de recuperación viejo seguía en las revisiones de Drive tras regenerar el código.
- **Medios y bajos, corregidos después con test** (S-05, S-07, S-09, S-10, S-12…S-16, S-19…S-21; S-06 y S-08 también): ver la tabla S-xx. **Pospuesto a v2:** S-11 (rotar la DEK, D47). **Pendientes sin acción:** S-17 y S-18 (ventana de 3 s al bloquear con cambios sin respaldar; logs de plugins de terceros) y la migración de EncryptedSharedPreferences/sodium_libs (S-20, planificada).
- Tras estos cambios cambió el esquema de BD (v6, sin migración: no hay datos reales) y el PIN nuevo es de 6 dígitos (el de 4 de bóvedas antiguas sigue desbloqueando). El formato `.vault` v2 y el respaldo de recuperación NO cambiaron.
- Verificado correcto: AAD/nonce del `.vault`, servidor de streaming (token, Host, loopback), SQL parametrizado, permisos Android, ausencia de secretos en el repo e historial, `key_check` no permite probar el PIN sin Argon2.
- No verificable sin iPhone: Keychain, SceneDelegate, ATS, S-02/S-03 en iOS.
- S-06 (PIN nuevo de 6 dígitos; la llave de hardware extra se evaluó y se descartó, D43) y S-08 (rangos fijos de Argon2id, D44) quedaron corregidos después; repetir una pasada de seguridad tras las pruebas en iPhone.

## 5. CHECKLIST PARA TI (en este orden exacto)

1. **Registrar la SHA-1 de release en Google Cloud.** https://console.cloud.google.com → proyecto `vault-514801` → "APIs y servicios" → "Credenciales" → "Crear credenciales" → "ID de cliente de OAuth" → tipo **Android** → nombre "Vault Android release" → package `com.saumnty.vault` → SHA-1 `98:41:90:61:8B:DA:8C:ED:11:FA:FA:1B:D5:08:65:89:E9:0D:AD:A6`. Espera unos minutos (la propagación puede tardar). No requiere cambios de código. Prueba después instalando `build\vault-release-signed.apk` e iniciando sesión con Google.
2. **Respaldar el keystore** (sin él no podrás publicar actualizaciones con la misma firma): copia `%USERPROFILE%\.vault-keys\vault-release.jks` **y** `android\key.properties` (contiene las contraseñas) a un lugar seguro fuera del repo (gestor de contraseñas o USB cifrado). Verifica que existen las dos copias.
3. **Push de `dev-claude`** (revisa antes el historial con `git log --oneline` y los docs): `git push -u origin dev-claude` (remoto `origin` = https://github.com/saumnty/Vault.git). No toqué `main`: cuando lo revises, abre un Pull Request `dev-claude` → `main` y haz el merge tú.
4. **Configurar Codemagic:** crea cuenta en https://codemagic.io (inicia con GitHub), "Add application" → repo `saumnty/Vault` → rama `dev-claude` → método de configuración **codemagic.yaml** → ejecuta el workflow `ios-unsigned` (manual). Descarga el artefacto `vault-unsigned.ipa`. Si falla la compilación, envíame el log: los puntos más probables son `ios/Runner/AppDelegate.swift` (`engineBridge.applicationRegistrar.messenger()`), `SceneDelegate.swift` y la descarga del binario de libsodium en `pod install`.
5. **Instalar con Sideloadly:** instala iTunes e iCloud desde apple.com (no la Microsoft Store) y Sideloadly desde sideloadly.io; conecta el iPhone por cable y confía en el equipo; arrastra el `.ipa`, ingresa tu Apple ID y pulsa Start. En el iPhone: Ajustes → General → VPN y gestión de dispositivos → confía en tu Apple ID; en iOS 16+ activa Ajustes → Privacidad y seguridad → **Modo desarrollador**. Con Apple ID gratuito la app **caduca a los 7 días** (hay que reinstalar).
6. **Pruebas en el iPhone (en este orden):**
   1. Onboarding: crear PIN (con confirmación), anotar el código de recuperación, confirmar los 4 caracteres, activar **Face ID** (debe pedir permiso; luego desbloquear con el rostro).
   2. **Login de Google** (usa el cliente iOS): conectar Drive; verificar la cuota y que subir una foto llega a "En la nube".
   3. **Fotos de iCloud:** con "Optimizar almacenamiento" activo, importar una foto o video que solo esté en iCloud → debe descargar el original con progreso y cifrarlo.
   4. **Borrado de originales:** debe estar APAGADO por defecto; actívalo, confirma que solo ofrece archivos verificados en la nube y que pide tu confirmación (diálogo del sistema "Eliminar").
   5. **Segundo plano y autobloqueo:** ajusta 15 s; sal de la app y vuelve antes y después del umbral (sigue abierta / pide PIN); Face ID y los selectores del sistema no deben bloquear.
   6. **Multitarea:** abre el selector de apps con la bóveda abierta → la vista previa debe estar cubierta (candado sobre fondo oscuro), no el contenido.
   7. **Respaldo de iCloud:** Ajustes → [tu nombre] → iCloud → Administrar almacenamiento → Copias de seguridad → este iPhone → Vault no debería ocupar espacio significativo (la carpeta del vault está excluida).
   8. **Video:** reproducir un video (streaming local por AVPlayer; ATS permite solo localhost) y hacer seek.
   9. **Restauración:** borra la app, reinstala, "Ya tengo una bóveda", Google, prueba un código incorrecto y luego el correcto, PIN nuevo, y verifica que todo se ve y abre (checklist detallado en la sección F9).
   10. Cambiar PIN, regenerar el código de recuperación y cerrar sesión de Google desde Ajustes.
7. **Después:** envíame el resultado de las pruebas del iPhone (y los logs de Codemagic si algo falla) para corregir; y cuando haya cupo conviene una segunda pasada de revisión de seguridad (S-06 y S-08 ya están tratados).

---

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
- **SHA-1 de release: `98:41:90:61:8B:DA:8C:ED:11:FA:FA:1B:D5:08:65:89:E9:0D:AD:A6`** (re-verificada con `keytool -list -v` sobre el keystore real, alias `vault-release`: SHA-1 y SHA-256 coinciden con las de este documento; todas las apariciones son idénticas, terminan en `…1B:D5:08:65:89…`)
- SHA-256 de release: `9E:C5:D7:7D:48:3F:8C:73:4D:2E:64:3B:03:BE:44:C3:6F:68:AD:FA:6F:0D:D2:B5:B1:56:60:91:3B:57:B2:EA`
- `flutter build apk --release` firmado con esa llave verificado con apksigner (SHA-1 coincide). Si falta `key.properties` el build cae a la llave debug.
- `codemagic.yaml` con workflow `ios-unsigned` (.ipa sin firmar para Sideloadly) y `android-release` opcional.
- Info.plist iOS revisado: GIDClientID + URL scheme (reversed client ID), NSPhotoLibrary*, NSFaceIDUsageDescription presentes. No hay `ios/Podfile` en el repo (lo genera Flutter en la compilación en Codemagic).

---
## F6b — Streaming de video por bloques sin texto plano en disco (🧪 emulador Android)
- **Diseño:** `VaultStreamServer` (lib/core/streaming/) en 127.0.0.1:<efímero>, ruta `/v/<token 256 bits>.mp4`; Range completo (bytes=a-b, a-, -n; 206/200/416/HEAD); descifra bajo demanda con `VaultFileReader.streamRange` + prelectura de 1 bloque y contrapresión (`flush`), ≤2 bloques de 1 MiB en claro por conexión. `StreamingVideoSource` por defecto con caída automática a completo-primero si el reproductor no inicializa. Decisiones D16–D21.
- **Emulador (Pixel_7 API 37, video_grande.mp4 importado en ORIGINAL → .vault 24 913 318 B = 24 bloques):** reproduce por `http://127.0.0.1` sin caer al respaldo; seek a mitad (0:13) y al final (0:24) y reanudar OK (peticiones 206 servidas); `run-as` (build debug): `tmp_plain/` vacío durante y después, ningún `.mp4/.mov` en `files/`, `cache/`, `app_flutter/`, ni en `/sdcard/Android/data/…`. Desde otro uid (adb shell) el puerto es alcanzable pero: token inventado → 404 vacío; Host `evil.example` → 403. HOME durante la reproducción → el listener desaparece de `/proc/net/tcp` y la conexión es rechazada. Estadísticas del servidor: maxBloquesVivos=2. Capturas `docs/screens/emu/f6b_*.png`.
- **Cifras (tiempo desde el toque):**

  | Modo | Inicializado | Posición avanza | Texto plano en disco |
  |---|---|---|---|
  | Streaming, debug | 15,8–17,1 s | 20,1–29,5 s | 0 B |
  | Completo-primero, debug | 18,7 s | 21,7 s | 24,9 MB en tmp_plain |
  | Streaming, profile | 16,5 s | 28,4 s (rebuffering) | 0 B |
  | Completo-primero, profile | 19,6 s | 19,8 s | 24,9 MB en tmp_plain |

  Causa: AES-GCM en Dart puro ≈1–1,3 MB/s en el emulador (igual en JIT y AOT), del orden del bitrate del video (≈8 Mbit/s); además este MP4 sintético concentra ~10 MB en los primeros 15 fotogramas y ExoPlayer pidió 17,8 MB antes de estar listo. Con un video de bitrate normal el arranque sería ~2–3 s, pero **el "inicio casi inmediato" NO se cumple con este video en este equipo**. Siguiente paso recomendado (D21): AES-GCM nativo (`cryptography_flutter`) y/o descifrado en isolates.
- **Corregido durante la prueba:** la purga LRU borraba el .vault en reproducción (D20).
- **No probado:** iOS (AVPlayer + ATS), dispositivo físico, bloqueo explícito de la bóveda desde la UI (no hay botón de bloqueo aún; cubierto con tests vía `VaultSession.clear`), consumo de RAM del proceso con un medidor externo (acotado por diseño/tests).
- **Riesgos residuales:** cualquier proceso local del dispositivo puede conectar al puerto mientras el visor reproduce (necesita el token de 256 bits; la URL solo vive en memoria y en el reproductor nativo, que podría registrarla en logcat ante un error: logcat solo es legible por la propia app/adb); ventana de exposición = mientras el video está abierto en primer plano; el texto plano vive en RAM (búferes de Dart y de ExoPlayer) y no se puede poner a cero de forma fiable; descifrado en el hilo de UI (se observaron frames saltados).

---
## AES-GCM nativo (🧪 emulador Android; iOS sin probar)
- **Paquete:** `cryptography_flutter` **2.3.4** (fijado). Revisado el código del paquete: Android `Cipher.getInstance("AES/GCM/NoPadding")` (Conscrypt/BoringSSL; el emulador expone AES-NI y PCLMUL), iOS `CryptoKit AES.GCM` (podspec iOS 13.0 = nuestro deployment target). Se registra solo (dartPluginClass); `FlutterCryptography.enable()` está obsoleto. Solo se añadió este paquete al lock.
- **Código:** `lib/core/crypto/aes_gcm_backend.dart` (`AesGcmBackend`, `DartAesGcmBackend`, `NativeAesGcmBackend`, `FallbackAesGcmBackend`, `configureCryptography()`); `vault_file_format.dart`, `wrapped_key.dart` y `crypto_service.dart` resuelven el backend en cada operación (inyectable por constructor); `main.dart` llama a `configureCryptography()`; log `[vault-import]` con duraciones (solo debug). Decisiones D22–D24.
- **Pruebas:** `test/aes_gcm_backend_test.dart` (15 tests: vector GCM TC16, caída a Dart ante PlatformException/MissingPlugin/salida corta, tag inválido sin reintento, llave destruida, copia propia de la llave, .vault idéntico entre backends, VaultAuthException con todos). `integration_test/aes_native_test.dart` (10 tests, en verde en emulator-5554 en debug y profile): TC16 en nativo, cruzado nativo↔Dart (0 B…3 MiB+1), mismos errores de autenticación, .vault idéntico, truncado/alterado ⇒ VaultAuthException, concurrencia y benchmarks. `test_driver/integration_test.dart` para `flutter drive --profile`.
- **Cifras (emulador Pixel_7 API 37, profile, bloques de 1 MiB):**

  | | Dart (antes) | Nativo (ahora) |
  |---|---|---|
  | Cifrado | 2,9–3,0 MiB/s (≈330–370 ms/bloque) | 14,5–22,9 MiB/s (≈40–50 ms/bloque) |
  | Descifrado | 2,9–3,5 MiB/s | 17,6–21,4 MiB/s |
  | Bloqueo máx. del isolate de UI | 3,7–4,1 s (no cede en todo el bucle) | 0,1–0,25 s |
  | encryptFile / decryptFile 24,8 MiB | 10,4–13,4 s / 10,6–11,2 s | 2,0–2,4 s / 2,1–2,3 s |
  | Servidor loopback, 24,8 MiB por HTTP | 12,0 s (primer MiB a los 350 ms) | 3,3 s (primer MiB a los 99 ms) |

- **App (debug, video_grande.mp4 de 24,9 MB en Original):** importación: SHA-256 5,6 s + cifrado **11,2 s** (≈19,2 s en total) → SHA-256 3,3 s + cifrado **2,0 s** (≈6,9 s). Streaming: Dart, inicializado a los 23,5 s y primer avance a los 36,2 s; nativo, 25,4 s / 27,1 s y 17,9 s / 18,6 s. **El arranque del video NO mejora claramente en el emulador**: el servidor ya entrega 6–7 MiB/s y el hilo principal estuvo al 17–38 % de CPU. El cuello de botella es ExoPlayer con el decodificador H.264 emulado (este MP4 sintético pide ~18 MB antes de estar listo y el emulador pasa más del 200 % de CPU en sys). En un teléfono real se espera mucho mejor; hay que medirlo allí. Capturas `docs/screens/emu/aes_*.png` (sin correo visible).
- **Compatibilidad comprobada en la app:** bóveda creada e importada con Dart (`VAULT_AES_BACKEND=dart`) y después desbloqueada, con miniatura y video reproducidos con el nativo; ningún `[vault-crypto] … falló` en el log.
- **Riesgos:** iOS sin probar (CryptoKit; faltan las mismas pruebas de integración en dispositivo). La llave viaja por el MethodChannel y queda copiada en el heap de Java/Swift, donde no se puede poner a cero (en Dart se usa una copia propia que sí se borra). El plugin de Android descarta la salida de `cipher.update()` y confía en que GCM entregue todo en `doFinal` (cierto en Conscrypt; el paquete comprueba la longitud y, si fallara, caemos a Dart). En Flutter 3.41 el nativo corre en el hilo de plataforma, que está fusionado con el de UI (≈45 ms por bloque, ver D24). El paquete marca Android como "lento" en un TODO interno; aun así en el emulador es ≈6 veces más rápido que Dart. La SHA-256 de la importación sigue en Dart (3–5,6 s para 25 MB): es la siguiente candidata para acelerar la importación.
- **Nota:** las ejecuciones de `integration_test` reinstalan la app, así que se pierde la bóveda de prueba del emulador (no había datos reales).

---
## F7 — Seguridad del sistema (🧪 emulador Android; iOS 📝 sin probar en dispositivo)
- **Diseño:** D25–D30 en DECISIONES.md. Código: `lib/core/security/{auto_lock,platform_security,security_preferences}.dart`, `lib/shared/widgets/privacy_cover.dart`, `VaultRootNavigator` (main.dart), botón en `vault_top_bar.dart`/`home_vault_screen.dart`, `MainActivity.kt`, manifiesto + `res/xml/{backup_rules,data_extraction_rules}.xml`, `AppDelegate.swift`/`SceneDelegate.swift`.
- **Tres mecanismos (no se mezclan):** FLAG_SECURE = capturas + recientes (Android); `SceneDelegate` + `PrivacyCover` = selector de apps (iOS y 2.ª capa); `isExcludedFromBackup` = respaldo de iCloud (iOS).
- **Pruebas automáticas (total 404 verdes):** `test/f7_security_test.dart` (autobloqueo con reloj falso: inmediato, umbral -1 ms/exacto, varias pausas, suspensión, reentrancia, Timer, reloj de pared atrás/sueño, preferencia; regresión lock vs unlock en vuelo: PIN, a mitad de la apertura, sin fusión, biometría; canal con mock: `setSecure` {secure}, define ignorado en release, `excludeFromBackup` con rutas de AppPaths y NO llamado fuera de iOS; PrivacyCover; botón Bloquear ahora (semántica, >=44 px); app completa: antes/después del umbral, Timer, inmediato, suspensión, bloqueo manual, pila limpia con ruta+diálogo), `test/f7_lock_stream_test.dart` (lock borra temporales y el servidor loopback deja de responder; archivo aparte porque el binding de widgets falsea HttpClient), goldens `home_bloquear_ahora` y `privacy_cover` (docs/screens). `pin_stress_test` actualizado.
- **Emulador (Pixel_7, debug, `docs/screens/emu/f7_*.png`):**
  - (a) Protección activa (sin define): `adb exec-out screencap -p` -> área de la app 100 % negra (Pillow: extremos (0,0),(0,0),(0,0) en y 150–2300; solo se ve la barra de estado del sistema) `f7_screencap_protegida.png`; recientes (`KEYCODE_APP_SWITCH`): la tarjeta de vault es negra (extremos 0) `f7_recientes_protegida.png`; `dumpsys window` muestra el flag SECURE. Con `VAULT_ALLOW_SCREENSHOTS=true` las capturas funcionan (todas las demás).
  - (b) Umbral 15 s: HOME 5 s -> sigue desbloqueada (`f7_autobloqueo_antes_umbral_sigue_abierta.png`); HOME 20 s -> al volver, PinScreen (`f7_autobloqueo_tras_umbral_pide_pin.png`).
  - (c) Candado de la barra superior -> PinScreen (`f7_boveda_bloquear_ahora.png`, `f7_bloqueo_manual_pin.png`).
  - (d) Video reproduciéndose en el visor: al pasar a segundo plano el listener 127.0.0.1 del servidor de streaming desaparece (`/proc/net/tcp`: antes 2 listeners; a los 5 s y a los 25 s solo queda el servicio VM de Flutter), `vault_cache/` queda vacía (sin temporales en claro) y al volver pide PIN (`f7_visor_video_reproduciendo.png`, `f7_visor_bloqueado_pide_pin.png`). OJO: el cierre a los 5 s lo hace D19 (liberar el video en hidden); el cierre por `lock()` (`closeAllNow`) está probado por `f7_lock_stream_test`; en el emulador no se pudo disparar en primer plano (el visor no tiene botón de bloqueo).
  - (e) Permiso de fotos (diálogo del sistema, app en paused >20 s con umbral 15 s): al aceptar sigue desbloqueada en el selector (`f7_permiso_fotos_dialogo.png`, `f7_permiso_fotos_no_bloquea.png`). Prompt biométrico: confirmé con `finger touch` tras >20 s y la bóveda se abrió sin bloquearse; el prompt solo pone la app en `inactive`, así que no es la prueba fuerte (la suspensión se verifica por tests y con el permiso). El prompt biométrico y el de permisos salen negros en `screencap` (ventanas seguras del sistema).
  - Incidencia de prueba: tras varios BACK/relanzamientos seguidos apareció "vault isn't responding" (`Application does not have a focused window`, proceso con 60 % CPU y 45 k fallos de página); el Dart seguía vivo (el prompt biométrico arrancó después). Lo atribuyo al emulador bajo carga (arranques en frío de ~25 s); no se reprodujo al reiniciar la app.
- **iOS sin probar (marcado en comentarios):** AppDelegate (`engineBridge.applicationRegistrar.messenger()`, canal `vault/security`, `URLResourceValues.isExcludedFromBackup`), SceneDelegate (`sceneWillResignActive`/`sceneDidBecomeActive`, vista opaca + `UIImage(systemName: "lock.fill")`). Verificar en Codemagic: que compile, que la cobertura aparezca en el selector de apps y que se excluyan las 4 carpetas.
- **Riesgos:** (1) un usuario puede mover el reloj de pared hacia adelante y solo provoca bloqueos de más; con el dispositivo dormido y el reloj de pared movido hacia atrás podría no bloquear a tiempo (caso extremo). (2) HOME durante un diálogo del sistema no arma el autobloqueo hasta la siguiente transición. (3) `PrivacyCover` tapa también durante diálogos del sistema/cortina (parpadeo). (4) FLAG_SECURE bloquea también las capturas legítimas hasta que F8 exponga "Proteger pantalla". (5) La cobertura iOS no evita capturas de pantalla. (6) `AutoLockController.setDelay` y `ScreenProtection.setEnabled` aún no tienen UI (F8).

## F8 — Onboarding y ajustes (🧪 emulador Android; iOS 📝 sin probar)

**Diseño.** `VaultRootNavigator` tiene 4 fases (cargando, onboarding, PIN, bóveda). Onboarding (`lib/features/onboarding/`): bienvenida -> `PinScreen` (con `onVaultCreated`) -> `RecoveryCodeFlow` (mostrar + confirmar por 4 posiciones aleatorias, `RecoveryCodeChallenge`) -> biometría (si hay) -> Drive (opcional, con aviso). Bandera `vault.v1.onboarding_pending` escrita antes de la envoltura del PIN; el código solo en memoria; proceso muerto -> PIN -> `regenerateRecoveryCode`. Ajustes (`lib/features/settings/`, engranaje en la barra de la raíz, `AppPageRoute`): Seguridad (cambiar PIN, biometría, autobloqueo, proteger pantalla, nuevo código, bloquear ahora), Importación (calidad de video, borrar originales), Almacenamiento (límite 250 MB/500 MB/1/2/5 GB, uso, liberar sin conexión, vaciar caché), Sincronización y cuenta (Solo Wi-Fi, cuenta, cuota, sincronizar, cerrar sesión), Acerca de (versión con `package_info_plus` 9.0.1, privacidad). Decisiones D31–D35.

**Verificación.** `flutter analyze` sin issues; `flutter test` 485 verdes (81 nuevos: `f8_logic_test`, `ui/onboarding_test`, `ui/settings_test`, goldens); `flutter build apk --debug` OK. Goldens nuevos en `docs/screens/`: `onboarding_bienvenida`, `onboarding_codigo`, `onboarding_confirmacion`, `onboarding_confirmacion_error`, `ajustes`, `ajustes_completo` (se eliminó `recuperacion.png`: la hoja ya no existe).

**Emulador (capturas `docs/screens/emu/f8_*.png`; correo difuminado).** Desinstalar -> bienvenida (01) -> PIN (02) -> código (03) -> confirmación (04) con error (05: "2EZ9" rechazado) -> `am force-stop` -> reabrir: PIN (06) -> "Falta tu código" (07) -> PIN incorrecto (09) y luego correcto -> código NUEVO (10) -> confirmación correcta -> biometría (11, huella `finger touch 1`) -> Drive (12) -> cuenta conectada (13) -> bóveda (14); reabrir con huella OK (15). Ajustes (16-17). Autobloqueo 15 s: HOME 22 s -> PIN (19). Cambiar PIN 2468 -> 135790 (20-21); tras force-stop el PIN viejo da "PIN incorrecto" (22) y el nuevo desbloquea; luego se restauró 123456 (log `unlock#1 fin OK`). Biometría off (apagada desde Ajustes) y on. Calidad de video 720p (23), límite 1 GB (24), Solo Wi-Fi off, cuota "61,62 MB de 15,00 GB" (17/36), liberar sin conexión: confirmación (25) y "No había nada que liberar" (26) (bóveda vacía; la lógica real se prueba en tests con BD y archivos), cerrar sesión (27-28) y volver a iniciar (29): el log `[sync] respaldo de recuperación subido` aparece tras reconectar. Regenerar código desde Ajustes (30): tras confirmar, el log muestra la subida con otro SHA (`788d60ae` -> `48a6f7f7`), es decir Drive recibió el respaldo nuevo. Proteger pantalla (build SIN `VAULT_ALLOW_SCREENSHOTS`): captura negra con la protección activa (32), tras desactivarla en Ajustes la captura sale normal AL INSTANTE (33), persiste tras force-stop (34-36), y al reactivar vuelve a negro. Autobloqueo, límite, 720p, Solo Wi-Fi y protección persisten tras `am force-stop`.

**Riesgos / pendientes.**
- Cambiar de cuenta de Google: lo `en_nube` de la cuenta anterior no existe en la nueva (fuera de alcance; el respaldo de recuperación sí se vuelve a subir).
- Liberar/vaciar caché no se pudo probar en emulador con archivos (bóveda vacía; la importación del emulador no se repitió): cubierto por tests con BD real.
- Si el teléfono no tiene red al regenerar el código, el respaldo viejo de Drive sigue valiendo con el código viejo hasta sincronizar.
- Ajustes tarda ~5-8 s en mostrarse en el emulador (varias lecturas del almacén seguro); en dispositivo real debería ser menor.
- iOS: nada probado (biometría, Drive, FLAG_SECURE no aplica).
- `AutoLockSuspension` ya envuelve biometría y Google; el onboarding no añade diálogos nuevos del sistema.

## F9 — Restauración en teléfono nuevo y snapshot fresco (🧪 emulador Android; iOS 📝 sin probar)

**Diseño.** D36–D39 en DECISIONES.md. Flujo: bienvenida "Ya tengo una bóveda (restaurar)" -> Google (autobloqueo suspendido por `AutoLockSuspension` dentro de `GoogleDriveCloudStorage`) -> búsqueda en appDataFolder (sin respaldo: "No hay respaldo en esta cuenta de Google" con "Usar otra cuenta"/"Crear una bóveda nueva"; también "incompleto" e "inválido") -> código (campo tolerante, grupos de 4, validación en vivo; límite 5 fallos -> 30 s... persistido) -> PIN nuevo + confirmación -> descarga con barra (índice, apertura, miniaturas en paralelo x4 reanudables, instalación) -> resumen (archivos/carpetas, aviso de perdidos) -> biometría opcional -> bóveda. `RestoreService` prepara todo en `restore_staging/` y solo al final instala BD + miniaturas y consolida las llaves (`AuthController.commitRestore`, envoltura del PIN nueva, la biometría vieja no se traslada). Cualquier fallo antes de consolidar deja el teléfono como estaba. Limitación documentada (D37): el límite de intentos solo frena la UI; la defensa real es ≈119 bits + Argon2id.

**Snapshot siempre fresco (D38).** Marca "sucio" persistida + debounce 30 s + toma tras la última subida (incluye `driveFileId`/`cloudMd5`) + toma al bloquear (antes de destruir las llaves, subida en segundo plano) + regla de 6 h.

**Verificación (salidas reales).** `flutter analyze`: No issues found. `flutter test`: 536 pruebas, todas verdes ("All tests passed!"; 51 nuevas respecto a las 485 de F8). `flutter build apk --debug`: OK ("Built buildppoutputslutter-apkpp-debug.apk"). Tests nuevos: `test/f9_restore_test.dart` (restauración feliz con misma DEK/items/carpetas/miniaturas/en_nube y PIN nuevo; abrir archivo descarga y verifica MD5; sync de B no re-sube; perdidos y cola; miniatura ausente; sin respaldo / incompleto / ilegible / envoltura del PIN; código incorrecto con límite persistido y reinicio; formato inválido; llave que no abre y snapshot corrupto con rollback; corte de red a mitad y reanudación; fallo al consolidar; ya hay bóveda; barrido de restos; llave x'hex'; nombres de Drive y respaldo sin secretos), `test/f9_snapshot_test.dart` (política sucio/debounce/cola/6 h/toma tras subidas/al bloquear), `test/ui/restore_flow_test.dart` (lógica del campo, pasos, errores, reintento, cancelar, integración con el onboarding) y 3 goldens (`docs/screens/restaurar_{inicio,codigo,progreso}.png`). Se ajustó `f6_env` (el snapshot simulado ya no lanza porque subir una miniatura ahora ensucia el snapshot). Nota: el cifrado real de SQLCipher no existe en los tests de escritorio (sqlite ffi); se simula con un `opener` estricto que exige la llave y la prueba real del cifrado se hizo en el emulador.

**Emulador (Pixel_7, debug con `VAULT_ALLOW_SCREENSHOTS=true`; capturas `docs/screens/emu/f9_*.png`, correo difuminado; el código de recuperación NO se guardó en el repo).**
1. Instalación limpia: onboarding, PIN 123456, código anotado leyendo la pantalla, confirmación, Drive conectado. Carpeta "Vacaciones" con subcarpeta "Playa"; importados 4 elementos (3 imágenes + 1 video corto). Sincronización "al día". (El renombrado de items no tiene UI hoy: cubierto con tests; se movieron items entre carpetas.)
2. Snapshot por log (`[sync] snapshot de la BD subido`): 14:14:52 tras crear carpetas (debounce 30 s), 14:18:27 DESPUÉS de las subidas de las 4 importaciones, 14:20:43 tras mover un item (sin subidas), y `snapshot subido al bloquear` 14:22:05 tras mover otro y pulsar "Bloquear ahora" (el movimiento llegó a la copia: al restaurar `prueba_1` apareció en Playa). La BD del teléfono (`run-as`, mismo contenido que el snapshot) no contiene "SQLite format" ni ninguno de los nombres (Vacaciones, Playa, prueba_1, images.jpeg...): SQLCipher real.
3. `adb uninstall` + reinstalar -> "Ya tengo una bóveda" -> Google (cuenta con respaldo) -> código INCORRECTO `ZZZZ-...` escrito en minúsculas con espacio: "Código incorrecto" (f9_b2; el log muestra una derivación Argon2 de 2,9 s por ese intento) -> código correcto -> PIN nuevo 654321 (+confirmar) -> "Bóveda restaurada: 4 archivos y 2 carpetas" (f9_b3) -> bóveda con "Vacaciones" (f9_b4/b5) y "Playa" con sus miniaturas (f9_b6). Antes de abrir nada `vault/` estaba vacío y `thumbs/` tenía 4 miniaturas; al abrir `prueba_1.png` se descargó `a1fd84c3...vault` (121 155 B, igual que el original; `VaultFileFetcher` verifica tamaño + MD5 antes de renombrar) y se mostró (f9_b7).
4. `force-stop`: el PIN viejo 123456 -> "PIN incorrecto"; 654321 desbloquea (envoltura nueva salt#=1138fcc2). Tras restaurar y desbloquear no aparece ningún `[sync]` de subida: no se re-subió el respaldo ni el snapshot (los .vault/.thumb no registran log; lo prueba el test "sync no re-sube").
5. Sin respaldo (iii): simulado con el fake en tests (la cuenta del emulador siempre tiene respaldo).
- Observaciones: el selector de cuentas y el consentimiento de Google son ventanas seguras (captura negra): se manejaron con `uiautomator`. `adb input text` pierde caracteres al teclear el código de golpe (herramienta, no app). La tipografía del campo del código se redujo (`AppTypography.codeInput`) tras ver en el emulador que 29 caracteres no cabían; ese cambio se verificó solo con el golden (`restaurar_codigo.png`), no se reinstaló en el emulador.

**Riesgos / pendientes.**
- Archivos subidos tras el último snapshot (app muerta antes del debounce): sus .vault quedan huérfanos en Drive (no se muestran ni se borran); ventana típica <= 30 s tras el último cambio, o inmediata si se bloqueó con red.
- Cambio de cuenta: restaurar usa la cuenta elegida; si luego se cambia de cuenta, lo `en_nube` de la anterior no existe en la nueva (como en F8).
- Fuerza bruta offline contra `recovery_backup.json`: ver D37; el límite local no la frena.
- El snapshot se re-sube con cada cambio (como mucho cada 30 s): decenas de KB, crece con el número de items.
- Archivos "perdidos" quedan en `error` sin acción de limpieza propia (se pueden eliminar desde la cuadrícula).
- La reconciliación usa `list()` completo de appDataFolder: con decenas de miles de archivos son muchas páginas (200 por página).
- `sweepOrphans` borra db/ y thumbs/ cuando el almacén seguro dice "sin bóveda"; si el almacén fallara y devolviera eso en un teléfono con datos, se perderían los datos locales (siguen en Drive si se sincronizó).
- iOS: nada probado (Keychain tras reinstalar, Google, rutas del contenedor).

**CHECKLIST MANUAL de restauración (iPhone).**
1. En el iPhone con la bóveda actual: importa 3–4 fotos y un video, crea una carpeta con subcarpeta, conecta Drive y espera "Todo está al día". Ten a mano el código de recuperación (si no: Ajustes -> generar uno nuevo y confírmalo; espera a que sincronice).
2. Mueve algo de carpeta, pulsa "Bloquear ahora" y espera 1 min con Wi-Fi.
3. Desinstala la app (Sideloadly) y reinstala la misma build. Debe salir la bienvenida; si sale el PIN viejo, es el Keychain (anótalo).
4. "Ya tengo una bóveda (restaurar)" -> Iniciar sesión con Google (misma cuenta) -> debe pedir el código (aparece tu correo).
5. Código INCORRECTO: "Código incorrecto". Repite 5 veces: bloquea 30 s; cierra y reabre la app: el bloqueo persiste.
6. Código correcto (minúsculas/espacios/guiones valen) -> PIN nuevo distinto + confirmar -> barra de progreso -> "Bóveda restaurada" con el número de archivos y carpetas.
7. "Activar" Face ID o "Ahora no" -> bóveda: carpetas, nombres y miniaturas visibles; las fotos abren (descargan) y el video reproduce.
8. Cierra la app del selector de apps: el PIN nuevo desbloquea, el viejo no.
9. Sincronización "al día" sin re-subir todo (revisa la hoja de sincronización y el consumo de datos).
10. Modo avión durante la barra de progreso -> "No se pudo restaurar" + Reintentar; NO debe entrar a la bóveda hasta terminar.
11. Restaurar con otra cuenta de Google sin respaldo -> "No hay respaldo en esta cuenta de Google".
12. Anota cualquier diferencia (diálogo de Google, Keychain, rutas).

## Pruebas pendientes cerradas (🧪 emulador Android Pixel_7; iOS 📝 sin probar)

Evidencia en `docs/screens/emu/p_*.png` (sin correos; el código de recuperación de la bóveda de prueba NO se guardó en el repo). Instalación limpia (`adb uninstall` + build debug con `VAULT_ALLOW_SCREENSHOTS=true`), bóveda PIN 123456, huella activada y Drive conectado desde el onboarding.

**1. Compresión con `video_grande.mp4` (1080p, 25 s). OK.** Se añadió un log de depuración (`[vault-import] compresion ...`, solo cifras).

| Calidad | Original (B) | Resultado del compresor (B) | Se usó | Guardado (B) | .vault cifrado (B) | Tiempos |
|---|---|---|---|---|---|---|
| Original | 24 912 622 | sin compresión | original | 24 912 622 | 24 913 318 | SHA-256 9,5 s, cifrado 4,3 s (~14 s total) |
| 1080p | 24 912 622 | 27 490 363 (mayor: +10,3 %) | NO, se conservó el original | 24 912 622 | 24 913 318 | compresión 92,9 s; SHA 1,5 s; cifrado 1,3 s |
| 720p | 24 912 622 | 12 372 658 (-50,3 %) | SÍ (pesa menos) | 12 372 658 | 12 373 018 | compresión 74,6 s; SHA 1,0 s; cifrado 0,7 s |

- El servicio usa el comprimido solo si `sizeBytes < original` (log: `se usa el comprimido: false` en 1080p y `true` en 720p). Con 1080p el original ya era 1080p: no hubo reducción (el compresor lo reencodó más grande) y se conservó; con 720p la hoja final mostró "ahorro de 11,96 MB por compresión". El overhead del .vault es 696 B (360 B en el de 720p).
- Los tres quedaron `En la nube` (verificados tamaño+MD5). El de 720p (11,80 MB) se abrió y reproduce por streaming con duración 0:25 (`p_t1_720p_reproduce.png`, posición 0:07).
- Observación: el plugin `video_compress` lanza `Unsupported value: 'kotlin.Unit'` en `deleteAllCache` (limpieza); el servicio ya lo ignora (best-effort), solo ensucia el log. Los tiempos de compresión son del emulador (CPU por software).

**2. Invalidación de la llave biométrica. OK sin cambios de código.** Con la biometría activa se registró una huella nueva (`FINGERPRINT_ENROLL`, PIN 1234, `adb emu finger touch 2` x12). `force-stop` + reabrir: la app no se cuelga ni entra; muestra el PIN con "Biometría desactivada. Ingresa tu PIN maestro" (`p_t2_biometria_invalidada.png`). El PIN 123456 abre la bóveda con los archivos intactos; en Ajustes el interruptor quedó apagado (`p_t2_ajustes_biometria_off.png`); se reactivó (prompt con la huella 2) y tras `force-stop` el desbloqueo biométrico funcionó con la llave nueva. Ya existía el test `auth_controller_test` "llave invalidada por el SO -> false y se desactiva".

**3. Gestos y háptica. OK (todo probado, incluido el pellizco).**
- Toque largo (`input swipe x y x y 800`) -> modo selección ("1 seleccionado", barra de acciones; `p_t3_seleccion_toque_largo.png`); un toque en otra celda la suma; "Cancelar selección" sale.
- Vista de lista: deslizar la fila revela Mover / Sin conexión / Eliminar (`p_t3_deslizar_fila_acciones.png`). "Sin conexión" marca el archivo y "Eliminar" abre la confirmación ("también se eliminará de la nube") y borra al confirmar.
- Pull-to-refresh (swipe hacia abajo desde arriba): spinner y el icono de nube pasa a "sincronizando" (`p_t3_pull_to_refresh.png`).
- Pellizco: `adb shell input` no lo permite y `sendevent` exige root (`adbd cannot run as root`), pero la consola del emulador sí: `adb emu event send 3:47:<slot> 3:57:<id> 3:53:<x> 3:54:<y> ... 0:0:0` (protocolo MT B, dispositivo `virtio_input_multi_touch`). Separando los dedos la cuadrícula pasa a lista (`p_t3_pellizco_abrir_lista.png`); juntándolos sube a 5 columnas (`p_t3_pellizco_5_columnas.png`).
- Háptica: el emulador SÍ registra vibraciones. `adb shell dumpsys vibrator_manager` ("Recent vibrations") lista cada `performHapticFeedback` de `com.saumnty.vault` con su constante. Cada tecla del PIN y Borrar -> `constant=4`; PIN incorrecto -> `constant=6`; PIN correcto -> `constant=3`; toque largo (entrar a selección) y toque que selecciona -> `constant=4`; confirmar Eliminar -> `constant=0`. Cancelar selección, "Sin conexión" y pull-to-refresh no vibran (no estaba previsto). La sensación física no se puede juzgar en el emulador.

**4. Borrado de originales. Había un hueco y dos bugs; corregidos.**
- Hallazgo A: el flujo de UI para disparar el borrado NO existía: nadie llamaba `deleteOriginalsConfirmedInCloud` y `originalDeletionEnabled` nunca era true (el interruptor de Ajustes era solo una preferencia). Implementado: `GalleryImportService.deletionEnabledProvider` (lee la preferencia en cada intento; apagado por defecto), `verifiedDeleteCandidates()` (consulta a Drive con `cloudVerifier` y lista SOLO lo verificado, una vez por original), hoja `features/gallery/delete_originals_sheet.dart` (lista con tamaños, aviso "no se puede deshacer", botón destructivo y Cancelar) y un tile "Borrar ahora los originales verificados" en Ajustes > Importación, visible solo con el interruptor encendido. Tras borrar, `clearSourceAssetId` en los items (quedan intactos, `en_nube`, con su .vault).
- Hallazgo B (bug visto en el emulador): un mismo original importado 3 veces (original, 1080p, 720p) aparecía como "3 originales, 59,32 MB" aunque era 1 archivo de 23,76 MB (`p_t4_lista_antes_dedupe.png`). Corregido: se lista y borra una vez por `sourceAssetId` (la copia verificada más grande) y se limpian todos los items de ese asset.
- Hallazgo C (bug preexistente): "Importar archivo" ofrecía "Cifrar y eliminar original" y borraba el archivo justo tras cifrar localmente, SIN verificar la nube; además en Android el selector entrega una copia de caché, así que no borraba el original y el mensaje decía "original eliminado" (comprobado: `prueba_video.mp4` siguió en `/sdcard/DCIM/Camera`). Corregido: la hoja solo ofrece "Cifrar e importar" (explica que el original no se toca y remite a Ajustes; `p_t4_importar_archivo_sin_borrar.png`) y `VaultImportService` ignora `deleteOriginal` (`@Deprecated`).
- (a) Apagado por defecto en instalación limpia: Ajustes (`p_t4a_ajustes.png`) y hoja de importación de galería (`p_t4a_hoja_importacion.png`) con el interruptor apagado.
- (b) Interruptor ENCENDIDO con un archivo no verificado: se importó `images.jpeg` con el Wi-Fi apagado y "solo Wi-Fi" activo (`Pendiente de subir`, "2 pendientes"). La hoja listó solo el video verificado y NO el pendiente; `images.jpeg` siguió en `/sdcard/Download` (`p_t4b_lista_solo_verificados.png`). Pendiente/subiendo/error/en_nube sin md5 cubiertos con tests.
- (d) Cancelar: "Cancelar" en la hoja -> `ls /sdcard/DCIM/Camera` idéntico (video_grande.mp4 de 24 912 622 B incluido). Denegar el diálogo del sistema ("Deny") tampoco borra nada (`ls` idéntico, también con 2 archivos).
- (c) Confirmación explícita + verificado: hoja "¿Borrar 1 original del dispositivo? (23,76 MB)" -> "Borrar original" -> Android 11+ muestra "Allow vault to delete this video?" (`p_t4c_dialogo_sistema.png`) -> Allow -> `video_grande.mp4` desaparece de `/sdcard/DCIM/Camera` y de MediaStore. La carpeta `vault/` quedó igual (`ls -l` antes/después idéntico) y los 3 items siguen "En la nube" (`p_t4c_tras_borrar.png`). Reabrir la hoja: "No hay originales para borrar". El original se restauró después con `adb push`.
- Observación no reproducida: una vez, tras tocar Deny, la pantalla se vio en blanco aunque `uiautomator` veía el árbol de Ajustes; no se repitió en dos intentos más. Se atribuye a un artefacto del render por software del emulador.
- Tests nuevos: `test/gallery_import_service_test.dart` (7 casos) y `test/ui/delete_originals_sheet_test.dart` (5 casos, incluido que la hoja de "Importar archivo" ya no ofrece eliminar). Golden `test/ui/goldens/bottom_sheet.png` regenerado y `vault_home_test` actualizado al nuevo texto.

**5. Verificación final.** `flutter analyze`: No issues found. `flutter test`: 548 tests, All tests passed (536 + 12 nuevos). `flutter build apk --debug`: Built build\app\outputs\flutter-apk\app-debug.apk. Nota: bajo carga `test/ui/settings_test.dart` ("PIN actual incorrecto") falló una vez dentro de la suite completa (temporización) y pasa sola y en las corridas siguientes.

**Pendiente (iOS).** Borrado de originales en iOS (PhotoKit tiene su propio diálogo), pellizco/háptica en iPhone e invalidación biométrica con Face ID (`.biometryCurrentSet`) siguen sin probar en dispositivo.

## Revisión de seguridad independiente (2026-11-15)

Revisor independiente (no escribió el código). Lectura línea por línea de `lib/core/crypto/**`, `lib/core/session/**`, `lib/core/security/**`, `lib/core/services/**`, `lib/core/streaming/**`, `lib/data/**` (cloud, sync, restore, gallery, services, repositories) y de las pantallas que manejan PIN/código; configuración Android/iOS, `.gitignore`, `pubspec.yaml`/`pubspec.lock`, `codemagic.yaml` e historial de git (puntual). Comprobaciones en el emulador (build debug, `run-as`) donde ayudaban. El comportamiento de los plugins se verificó leyendo su fuente en el pub-cache (file_picker 8.3.7, photo_manager 3.12.0, googleapis 13.2.0).

### Hallazgos

| id | severidad | ubicación | descripción | impacto / escenario | recomendación | estado |
|---|---|---|---|---|---|---|
| S-01 | alta | `lib/core/security/auto_lock.dart` (`_onBackground`, `_onResumed`) | Si la app pasaba a segundo plano con una `AutoLockSuspension` activa, el autobloqueo NO se armaba (ni temporizador ni comprobación al volver). La suspensión envuelve selector de archivos, permiso de fotos, biometría y **cada** `authenticatedClient`/`signInSilently` de Google, incluidas las llamadas de la sincronización en segundo plano. | Abrir el selector y pulsar HOME desde él, o pulsar HOME mientras la sincronización pedía un token, dejaba la bóveda **abierta indefinidamente**: quien tome el teléfono horas después entra sin PIN. | Hecho: con suspensión activa se aplica un tope (`maxSuspendedBackground` = 5 min, o el tiempo configurado si es mayor) con temporizador y comprobación al volver; si la suspensión termina con la app en segundo plano se arma el autobloqueo normal desde ese instante (mínimo `rearmGrace` = 3 s, para que "inmediato" no bloquee al volver del selector). Tests: `test/security_review_test.dart` grupo S-01 (4 de 6 fallaban con el código anterior; los otros 2 son controles) y `test/f7_security_test.dart` (2 ajustados + 1 de widget nuevo). | corregido |
| S-02 | alta | `lib/data/services/vault_import_service.dart` | "Importar archivo" usa `file_picker`, que en Android copia CADA archivo a `cache/file_picker/<ms>/<nombre original>` (fuente: `FileUtils.openFileStream`) y en iOS a `tmp/`. La copia nunca se borraba. Además el `catch` imprimía `$e` (con la ruta, que lleva el nombre real) y `debugPrint` imprime también en release. | Copia completa EN CLARO, con su nombre original, de todo lo importado como archivo, persistente en la caché (extracción forense/root, dispositivo AFU). Anula "nada en claro en disco". En el emulador quedaba `cache/file_picker/<ms>/`. | Hecho: la copia se borra en `finally` (éxito o fallo) solo si está DENTRO de las carpetas del plugin (`PlainResidue.isWithinRoots`; nunca un archivo del usuario), con su carpeta `<ms>` vacía; barrido al arrancar de `cache/file_picker` (Android) y `vault_cache/import_tmp` (`PlainResidue.sweepAtStartup`); log sin `$e`. Tests: `test/security_review_test.dart` grupo S-02 (4 casos, incluido que un archivo fuera de esas carpetas no se borra). Con el código anterior no compilan (no había inyección); el defecto se confirmó en la fuente del plugin. iOS: borrado por archivo dentro de `Directory.systemTemp`, **sin probar**; no se barre `tmp/` entero al arrancar (lo comparten otros plugins). **v2 fase 6: cerrado de raíz** — `file_picker` eliminado; selector propio (`PlatformDocumentPicker`, canal `vault/picker`) que lee el `content://` (Android) / la URL con alcance de seguridad (iOS, sin probar) por trozos y cifra con `encryptSource`: ya no existe copia en claro. Se conserva el barrido de restos de versiones anteriores. | corregido |
| S-03 | alta | `lib/data/gallery/photo_manager_gallery_source.dart`, `gallery_import_service.dart` | `photo_manager` genera miniaturas con Glide, que las guarda en `cache/image_manager_disk_cache/` en claro (confirmado en el emulador: `PNG image data, 256 x 455`). En Android 10 (API 29) `loadFile(isOrigin: true)` además copia el original completo a `cache/pm_<id>_o_<nombre>` y el código lo trataba como no temporal. | Tras importar y "borrar originales", esas miniaturas (y en Android 10 el original completo con su nombre) son la única copia en claro fuera de la bóveda, sin caducidad. | Hecho: `GalleryAssetSource.clearPlainCaches()` → `PhotoManager.clearFileCache()` (Glide memoria + disco y `pm_*`) al terminar cada lote (éxito/error/cancelación), tras borrar originales y al arrancar. Tests: 2 nuevos en `test/gallery_import_service_test.dart` (fallan con el servicio anterior: 0 limpiezas). iOS sin probar. | corregido |
| S-04 | alta | `lib/data/sync/sync_service.dart` (`_uploadRecoveryBackup`) | El respaldo de recuperación se reemplazaba con `files.update`. Drive conserva el contenido anterior de un binario como **revisión** (≈30 días salvo `keepForever`; `RevisionsResource` en googleapis 13.2.0). "Generar código nuevo" (D32) no rota la DEK: el respaldo viejo envuelve la MISMA DEK. | Si el código viejo se filtró (motivo típico para regenerarlo), quien tenga también la cuenta recupera la revisión vieja y descifra todo durante ~30 días, aunque el usuario crea haberlo invalidado. | Hecho: se crea un archivo NUEVO, se verifica (tamaño+MD5) y se borran permanentemente (`files.delete`: sin papelera, con sus revisiones) todos los anteriores con ese nombre; si el borrado falla el trabajo falla y se reintenta. La nube falsa modela revisiones. Tests: 2 nuevos en `test/sync_service_test.dart` (fallan con el código anterior). Ver también S-11. | corregido |
| S-05 | media | `features/vault/services/thumbnail_loader.dart:80`, `viewer/photo_page.dart:173` | Al bloquear se vacía el LRU propio, pero las imágenes (`MemoryImage`/`Image.memory` de miniaturas y fotos completas) quedan decodificadas en el `ImageCache` global de Flutter, y los `Uint8List` en claro no se ponen a cero. | Un volcado de memoria del proceso tras bloquear (root/depurador) recupera fotos. | En `VaultSession.addOnClear`: `PaintingBinding.instance.imageCache..clear()..clearLiveImages()`; sobrescribir los buffers propios al cerrar el visor. | **corregido** (`test/s05_test.dart`) |
| S-06 | media | `core/crypto/auth_controller.dart:113`, `secure_kv_store.dart` | La envoltura del PIN (Argon2id m=19 MiB, t=2) en EncryptedSharedPreferences no está ligada a hardware ni a autenticación; PIN mínimo de 4 dígitos. | Con root (descifrar EncryptedSharedPreferences vía Keystore) se prueba el PIN offline: 10⁴ PIN en minutos, 10⁶ en horas en un PC. El limitador no aplica offline. | "Pepper" con una llave HMAC no exportable del Keystore/Secure Enclave (cada intento pasa por el hardware del teléfono); PIN mínimo de 6. | **mitigado** (D43: PIN de 6 dígitos; llave de hardware extra evaluada y descartada) |
| S-07 | media | `core/crypto/pin_attempt_limiter.dart` | Retraso con el reloj de pared: adelantar la hora del sistema elimina la espera (documentado en el código). | Fuerza bruta por la interfaz sin esperas (sigue frenada por Argon2 ≈0,1–1 s). | Guardar también `SystemClock.elapsedRealtime` + contador de arranques (canal nativo) y exigir ambos. | **corregido** (D45, `test/s07_monotonic_test.dart`; iOS sin probar) |
| S-08 | media | `core/crypto/kdf.dart:40` | `Argon2Params.fromJson` acepta del JSON de Drive hasta m=1 GiB y t=16. | Quien controle la cuenta puede dejar un `recovery_backup.json` que cuelgue o mate por memoria la restauración (DoS). No debilita: parámetros bajos no sirven sin la DEK. | Tope realista (p. ej. m ≤ 256 MiB, t ≤ 10) y, para el respaldo, solo parámetros ≥ producción. | **corregido** (D43/D44, `test/s06_s08_test.dart`) |
| S-09 | media | `core/crypto/vault_file_format.dart`, tabla `vault_items` | Nada liga un item con SU `.vault`/`.thumb`: todos usan la misma subllave, el `fileId` del encabezado no se guarda en la BD y `contentHash` no se verifica al abrir. | Quien escriba en Drive (o en el almacenamiento local) puede intercambiar `A.vault` por `B.vault` (ambos auténticos) y se muestra otro contenido del propio usuario; las revisiones de `vault_db.snapshot` permiten restaurar un índice antiguo. | Guardar el `fileId` en la BD y comprobarlo al abrir (sin cambiar el formato), o meter el id del item en la AAD en un futuro v3. | **corregido** (D46, esquema v6 sin migración, `test/s09_fileid_test.dart`) |
| S-10 | media | `android/app/build.gradle.kts`, `codemagic.yaml` (android-release) | Sin `key.properties`, `release` se firma EN SILENCIO con la llave debug. Sin `--obfuscate --split-debug-info` (R8 sí está activo por defecto en release en este Flutter: `FlutterPlugin.kt`). | Un APK de release firmado con la llave debug (de CI, efímera) no se puede actualizar y es fácil de suplantar. | Fallar el build de release sin llave; compilar con `--obfuscate --split-debug-info=<dir>` (símbolos fuera del repo). | **corregido** (rama de fallo verificada con gradle sin `key.properties`; `ALLOW_DEBUG_SIGNED_RELEASE` solo para CI) |
| S-11 | media | `core/crypto/auth_controller.dart` (`regenerateRecoveryCode`) | Regenerar el código re-envuelve la misma DEK (D32). Cualquier copia del respaldo viejo obtenida antes (descarga o revisión previa a S-04) sigue abriendo la bóveda para siempre con el código viejo. | Código filtrado + copia antigua del respaldo = acceso permanente. | Ofrecer "rotar llaves" (DEK nueva y re-cifrado de archivos, miniaturas y BD) y explicarlo en la UI. | **pospuesto a v2** (D47) |
| S-12 | baja | `data/sync/offline_service.dart:93,196`, `features/vault/vault_browser_controller.dart:130`, `data/sync/sync_service.dart:415`, `data/gallery/gallery_import_service.dart:423`, `main.dart:61` | `debugPrint` sin `kDebugMode` imprime también en release (logcat) con `$e` completo; `features/gallery/import_progress_sheet.dart:80` muestra `e.toString()` en la UI. Hoy los ids son opacos, pero un `FileSystemException` trae rutas. | Fuga de rutas/nombres a logcat si cambia el tipo de error. | Logger central sin salida en release que registre solo `runtimeType`. | **corregido** (`VaultLog`, `test/s12_test.dart`) |
| S-13 | baja | `features/vault/widgets/vault_sheets.dart:92`, `search_field.dart:45` | Campos de nombre de carpeta y búsqueda sin `enableIMEPersonalizedLearning: false`/`enableSuggestions: false`. | El teclado aprende y sugiere nombres de carpetas/búsquedas fuera de la bóveda. | Desactivarlos, como en el campo del código. | **corregido** (`test/s13_keyboard_privacy_test.dart`) |
| S-14 | baja | `data/restore/restore_service.dart`, `data/cloud/google_drive_cloud_storage.dart:294` | `downloadBytes` del respaldo y la descarga del snapshot sin tope de tamaño; número de miniaturas sin tope. | DoS (memoria/disco/datos) por quien controle la cuenta. | Topes (respaldo ≤ 4 KiB; snapshot razonable). | **corregido** (respaldo ≤ 4 KiB, snapshot ≤ 256 MiB, miniatura ≤ 8 MiB; `test/s14_test.dart`) |
| S-15 | baja | `core/services/app_paths.dart:80` | `validateRelative` acepta cualquier ruta dentro de la base (`vault/../db/vault_secure.db` → `db/...`) y `CacheManager` borra `encryptedPath`; el id del item se usa en nombres de archivo de la restauración sin validar formato. | Solo explotable con la llave SQLCipher (la BD está autenticada): defensa en profundidad. | Exigir `vault/<uuid>.vault` / `thumbs/<uuid>.thumb` y validar el id como UUID. | **corregido** (`test/s15_test.dart`) |
| S-16 | baja | `data/gallery/video_compress_plugin.dart` | La salida comprimida (en claro) vive en la caché del plugin y solo se limpia al terminar un lote. | Un cierre abrupto durante la compresión deja el video en claro hasta la próxima importación. | `VideoCompress.deleteAllCache()` también al arrancar. | **corregido** (`test/s16_video_cache_test.dart`) |
| S-17 | baja | `main.dart` (`_lock` con `beforeLock`) | Con cambios sin respaldar, las llaves siguen en memoria hasta 3 s tras mostrar el PIN (toma del snapshot). | Ventana breve. | Corregido en v2 fase 7: la espera al snapshot se acota a 1 s (`lockWithFlush`, `kLockFlushBudget`); si no alcanza, el estado "sucio" se conserva y se toma al siguiente desbloqueo. Test `test/s17_lock_flush_test.dart`. | corregido |
| S-18 | baja | plugins de terceros | `file_picker` registra `Log.i("Caching from URI: …")` sin condición; photo_manager puede registrar `displayName` con su log activado. | Nombres de archivo en logcat. | v2 fase 6: `file_picker` eliminado (su `Log.i` con la URI desaparece); el selector propio no registra nombres ni rutas (comprobado en logcat del emulador: solo el `MediaProvider` del sistema anota la ruta al abrir, fuera del control de la app). photo_manager no registra salvo con su log activado (desactivado). | corregido |
| S-19 | informativa | `features/vault/services/vault_repository.dart`, `CryptoService.encryptData/decryptData`, `AuthController.restoreFromRecovery` | Código muerto: textos sin AAD en `FlutterSecureStorage`; `restoreFromRecovery` no usa el límite de intentos de restauración. Nada de esto se usa en la app. | Riesgo si alguien lo reutiliza. | Eliminarlo. | **corregido** (borrado `vault_repository` y `encryptData/decryptData`; `restoreFromRecovery` queda `@visibleForTesting`: lo usan ~10 tests) |
| S-20 | informativa | `pubspec.yaml` | Paquetes críticos con `^` (`cryptography`, `flutter_secure_storage`, `sqflite_sqlcipher`; el lock los fija); `sodium_libs` 3.x discontinuado; EncryptedSharedPreferences obsoleto en Jetpack. | `pub upgrade` podría cambiar criptografía sin revisión. | Fijar versiones exactas y planificar migraciones. | **corregido** (versiones exactas, lock sin cambios) |
| S-21 | informativa | `android/.../MainActivity.kt` | FLAG_SECURE correcto; complemento opcional en Android 13+: `setRecentsScreenshotEnabled(false)`. | — | Opcional. | **corregido** (Android 13+) |

### Verificado y sin problemas
- **Jerarquía de llaves**: DEK de 32 B con `Random.secure`; KEK_pin/KEK_rec con Argon2id (salt nuevo de 16 B en cada envoltura; mismo resultado nativo/Dart); envoltura AES-GCM con AAD de propósito (`vault.dek.v1|pin` / `|recovery`) y validación estricta del JSON (versión, propósito, longitudes exactas). Subllaves HKDF separadas (`sqlcipher`, `files`, `thumbs`); la DEK nunca cifra datos. Puesta a cero de copias propias (mejor esfuerzo: el GC de Dart puede dejar copias).
- **`key_check` NO es un oráculo del PIN**: es HKDF(DEK) truncado a 128 bits; comprobarlo exige adivinar la DEK (256 bits). La única forma de verificar un PIN offline es la propia envoltura del PIN (inherente; ver S-06).
- **Formato .vault v2**: AAD = encabezado completo ‖ índice u64 ‖ isFinal; detecta alteración, reordenado, truncado (bloques completos o a mitad) y bloques de otro archivo. Nonce aleatorio de 96 bits por bloque (límite NIST de 2³² por llave, muy por encima del uso). Tamaño de bloque acotado a 1 KiB–16 MiB antes de reservar memoria; offsets en enteros de 64 bits; `verifyFinal` autentica la longitud. El fallback nativo→Dart repite con el mismo nonce y los mismos datos (sin reuso con otro texto). Tag de longitud distinta → error de autenticación. Sin oráculos: los errores de autenticación no distinguen la causa.
- **Código de recuperación**: 24 símbolos de 31 (≈119 bits), sin sesgo de módulo, normalización canónica antes de derivar, comparación en tiempo constante en el desafío; campo sin autocorrección, sugerencias ni aprendizaje, y no seleccionable. Fuerza bruta offline del `recovery_backup.json` inviable (D37 confirmado). Solo salen del teléfono el respaldo (KEK_rec), la BD SQLCipher y los `.vault`/`.thumb` cifrados; `assertRecoveryBackupSafe` impide campos extra.
- **Sesión**: `lock()` incrementa la generación y cancela desbloqueos en vuelo; `VaultSession.clear` destruye llaves, cierra la BD, borra `tmp_plain` de forma síncrona, cierra los servidores de streaming y cancela subidas/descargas. Operaciones de llaves serializadas; intento contado de forma pesimista antes de derivar.
- **Almacén seguro y biometría**: iOS `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; Android EncryptedSharedPreferences. `biometric_storage` con CryptoObject por uso, solo biometría fuerte e invalidación al cambiar huellas (iOS `.biometryCurrentSet`); la DEK leída se valida con `key_check`. La huella no respeta el límite de PIN por decisión del usuario (D05).
- **Servidor de streaming**: solo 127.0.0.1, puerto efímero, token de 256 bits con comparación en tiempo constante, Host obligatorio (anti DNS rebinding), solo GET/HEAD, sin query, Range acotado (≤18 dígitos), cada bloque autenticado antes de enviarse, servidor envenenado tras un fallo, topes de conexiones e inactividad, cierre al bloquear y al pasar a segundo plano. Los logs no llevan token ni rutas.
- **SQL**: todas las consultas usan parámetros (`?`); las listas `IN (...)` se arman solo con marcadores. El snapshot es la BD SQLCipher (HMAC por página) con llave cruda de la DEK: un snapshot hostil no se puede fabricar sin la llave. El MD5 de Drive solo detecta errores de transferencia; la integridad real la dan AES-GCM y SQLCipher (confirmado).
- **Restauración**: todo en `restore_staging/`, instalación al final con reversión; un código con formato inválido no cuenta ni deriva; límite de intentos propio.
- **Plataforma Android**: permisos mínimos (biometría, fotos/videos, `READ_EXTERNAL_STORAGE` ≤ API 32, INTERNET); solo la actividad lanzadora es `exported`; `allowBackup=false` + reglas de exclusión; cleartext solo para 127.0.0.1/localhost y solo CA del sistema; FLAG_SECURE antes del primer frame. Sin deep links, WebViews ni uso del portapapeles en el código.
- **Repositorio**: sin keystores, `key.properties`, tokens ni correos versionados (`git ls-files`, `git grep` e historial); `android/key.properties` está ignorado. Los IDs OAuth del código son públicos por diseño.
- **Logs**: los de llaves, KDF, streaming y sincronización son solo de depuración y no llevan PIN, llaves, salts completos (huella de 4 bytes), código, tokens ni correos; las excepciones están en S-12.

### No verificable aquí (iOS)
Lo de iOS se revisó solo leyendo el código: Keychain y Face ID, `SceneDelegate` (cobertura del selector de apps), `excludeFromBackup`, ATS `NSAllowsLocalNetworking` con AVPlayer, las copias de `file_picker` en `tmp/` (S-02) y `PhotoManager.clearFileCache` en iOS (S-03). La interacción de S-01 con el selector real del sistema se cubrió con pruebas de la lógica del ciclo de vida, no en dispositivo.

### Verificación final
`flutter analyze`: No issues found. `flutter test`: 563 tests, All tests passed (548 + 15 nuevos/ajustados de esta revisión). `flutter build apk --debug`: Built build\app\outputs\flutter-apk\app-debug.apk. No cambia el formato .vault v2, ni el esquema de la BD, ni el formato del respaldo de recuperación: compatible con los datos existentes.

## F10 APK release (2026-11-15)

Comando final: `flutter build apk --release --obfuscate --split-debug-info=build/symbols` (R8 por defecto + ofuscación de Dart, hallazgo S-10). Símbolos en `build/symbols/` (fuera del control de versiones, ignorado por `build/`).

| Campo | Valor |
|---|---|
| Ruta | `build/vault-release-signed.apk` (copia de `build/app/outputs/flutter-apk/app-release.apk`) |
| Tamaño | 74.127.300 bytes (70,7 MB; el debug pesa 203,7 MB) |
| SHA-256 | `8aeaed98ad390354af609e2ea5a7266905368870a98f14b1be834efe99a45145` |
| Firma | `apksigner verify --print-certs`: Verifies; esquema v2; 1 firmante, CN=Vault, O=Saumnty, C=MX, RSA 2048 |
| SHA-1 del certificado | `98:41:90:61:8B:DA:8C:ED:11:FA:FA:1B:D5:08:65:89:E9:0D:AD:A6` (coincide con la esperada) |
| SHA-256 del certificado | `9E:C5:D7:7D:48:3F:8C:73:4D:2E:64:3B:03:BE:44:C3:6F:68:AD:FA:6F:0D:D2:B5:B1:56:60:91:3B:57:B2:EA` |

Ofuscación: con R8 + `--obfuscate` la app funcionó igual en la regresión (onboarding, importación con compresión, SQLCipher, AES nativo, Argon2 nativo, biometría, streaming de video, sincronización con Drive, restauración), sin crashes ni `FATAL` en logcat. Se recomienda y queda documentada en README.md. S-10 sigue parcialmente pendiente: el build sin `key.properties` aún cae en silencio a la llave debug.

Variante de prueba: para ejercitar Google en el emulador se generó `build/vault-release-debugkey.apk` (mismo comando, firmada con la llave DEBUG renombrando temporalmente `android/key.properties`, restaurado después; SHA-256 `ccc3381f1be0fdc0e2a40e95ae638640a603d5982f03a3a77d2be6ed1c5c49f3`). Es solo para pruebas locales: no distribuir. No se subió ningún APK a ningún sitio.

**Acción manual pendiente**: registrar la SHA-1 de release en el cliente Android de Google Cloud. Hasta entonces el inicio de sesión de Google con el APK firmado con la llave de release falla con ApiException 10 (ver paso 1b abajo).

## Regresión final (emulador Pixel_7, APK release con R8 + ofuscación)

APK usados: **[R]** `vault-release-signed.apk` (llave de release; pasos sin Google) y **[D]** `vault-release-debugkey.apk` (misma compilación firmada con la llave debug; pasos con Google, que la SHA-1 de release aún no tiene registrada). Capturas en `docs/screens/emu/reg_*.png` (correo y código difuminados). En release `FLAG_SECURE` está activo: tras crear cada bóveda se desactivó "Proteger pantalla" en Ajustes para capturar (preferencia del usuario, persiste).

| # | Paso | APK | Resultado |
|---|---|---|---|
| 1a | Onboarding completo: PIN con confirmación (un PIN de confirmación distinto da "Los PIN no coinciden"), código de recuperación, confirmación de 4 caracteres (los de posiciones aleatorias; unos incorrectos dan "Esos caracteres no coinciden"), biometría (huella `finger touch`), Drive | R y D | OK |
| 1b | Google con llave de release | R | Falla esperada: selector de cuenta y luego "Google rechazó la configuración OAuth (código 10): revisa que el cliente Android ... tenga el package com.saumnty.vault y el SHA-1 de esta firma". Se omite con "Más tarde". Capturas negras por FLAG_SECURE; evidencia: texto leído con `uiautomator dump` |
| 1c | Google con llave debug | D | OK: cuenta conectada, "Entrar a mi bóveda" |
| 2a | Importar 2 fotos + video corto, sin Google; abrir foto con zoom (doble toque), reproducir video; bloquear con botón, huella y PIN | R | OK (`reg_02`..`reg_06`) |
| 2b | Importar 2 fotos + video corto + video grande a 720p (23,76 MB → 11,80 MB, ahorro 11,96 MB) | D | OK (`reg_07`) |
| 3 | Sincronizar hasta "Todo está al día"; cuota Drive | D | OK: pendientes 0, con error 0, "Espacio de Drive: 133,66 MB de 15,00 GB" (`reg_08`) |
| 4 | Foto con zoom; video grande por streaming, seek a 0:04 y a otra posición | D | OK (`reg_09`..`reg_12`) |
| 5 | Carpeta "Offline" marcada sin conexión (2 fotos); caché vaciada (0 B; sin conexión 236,1 KB); wifi y datos cortados | D | OK: la foto de la carpeta offline abre sin red (`reg_14`); el video no offline muestra "No se pudo reproducir: Sin conexión a internet. Este archivo solo está en la nube; conéctate y vuelve a intentarlo." con Reintentar (`reg_13`); red restaurada y ping OK. Nota: durante este paso el emulador mostró un fotograma obsoleto de la pantalla de bloqueo y un diálogo "System UI isn't responding" (SystemUI del emulador mientras GMS compilaba), se recuperó con el toque habitual; no es de la app |
| 6 | Bloquear (botón); PIN incorrecto ("PIN incorrecto") y luego correcto; huella; autobloqueo a 15 s | D (y R para botón/PIN/huella) | OK: en segundo plano 6 s sigue abierta, 25 s pide desbloqueo (`reg_15`) |
| 7 | Restaurar: `adb uninstall`, reinstalar, "Ya tengo una bóveda", Google, código incorrecto ("Código incorrecto") y luego el correcto, PIN nuevo con confirmación, huella opcional | D | OK: "6 archivos y 1 carpeta recuperados"; la carpeta conserva "disponible sin conexión"; foto, foto de la carpeta offline y video grande (descarga de Drive 100 %, descifrado y reproducción) abren (`reg_16`..`reg_21`) |

Sin bugs nuevos ni cambios de código. La ofuscación no rompió nada.

## Cierre de hallazgos S-05…S-21 (2026-11-16)

Prueba de humo en el emulador (APK debug, instalación limpia, bóveda y cuenta de prueba): PIN nuevo de 6 dígitos (con 4 no avanza; el 6.º envía solo); crear bóveda, código y confirmación por posiciones; Google; importar 1 foto y 2 videos (Original); abrir foto y reproducir video por streaming (sin falsos positivos de S-09); bloquear/desbloquear; **S-07**: 5 PIN incorrectos → 30 s, luego 60 s y 2 min; con la hora de pared adelantada +1 día la espera SIGUE (91 s → 71 s) y el PIN correcto no abre; la espera persiste tras `force-stop`; pasado el plazo real el PIN correcto abre; hora restaurada. **S-09/restauración**: sincronizado todo, `adb uninstall` + reinstalar, código incorrecto → "Código incorrecto", código correcto → PIN nuevo → 3 archivos recuperados; foto y video se descargan de Drive, se verifican y abren. logcat: sin PIN, código ni nombres de archivo emitidos por la app. Capturas del onboarding en `docs/screens/emu/s_*.png`.

Hallazgo extra de la prueba: al bloquear con el visor cerrándose salía `Looking up a deactivated widget's ancestor` en `_VaultMediaViewerScreenState._onLock`; el visor ahora guarda su `NavigatorState` (no se reprodujo en test, se endureció igualmente; test de regresión añadido en `test/ui/viewer_test.dart`).

Tabla S-xx, 'Hacer tú': nada nuevo. Siguen siendo solo del usuario los pasos 1–6 del checklist (SHA-1 de release en Google Cloud, copia del keystore, push, Codemagic, Sideloadly, pruebas en iPhone); en iPhone además hay que probar el canal `monotonic` (S-07) y la verificación de `fileId` (S-09).

## iOS ronda 1 (2026-11-16)

Primeras pruebas del usuario en iPhone (Codemagic `ios-unsigned` + Sideloadly): (a) miniaturas de videos no se ven, (b) quiere cerrar el visor deslizando, (c) esperaba que las fotos importadas se borraran de la galería y verlas en Drive, (d) va a pasar de su cuenta de Google de prueba a su cuenta personal (Google One).

### Qué se hizo
| Tema | Resultado | Pruebas |
|---|---|---|
| (a) Miniaturas de video | Fotograma central del archivo ya materializado por un método nativo propio (`videoThumbnail`: Android MediaMetadataRetriever, iOS AVAssetImageGenerator `// iOS: sin probar`); la fototeca queda de respaldo; si todo falla, ícono ▶ + duración; regeneración automática al desbloquear y manual (Ajustes > Almacenamiento). Causa en D50: `video_compress` en iOS no responde si falla, devuelve resolución completa y `getFileThumbnail` borra el origen. | `test/thumbnails_video_test.dart` (16): video local, solo iCloud, sin ninguna miniatura, fototeca de respaldo, regeneración (fototeca, `.vault` local, solo nube, fileId, topes, fallos recordados, bloqueada), insignia. |
| (b) Cerrar deslizando | `ViewerDismiss` (puntero directo, sin arena de gestos): solo con zoom 1 y movimiento vertical claro; sigue al dedo, el fondo se desvanece; umbral `min(120 px, 15 %)` o 700 px/s; vuelve si no llega; no actúa sobre los controles del video; accesibilidad `onDismiss`. | `test/ui/viewer_dismiss_test.dart` (8). |
| (c) UI sobre borrado/Drive | Bloque "cifrado en una carpeta oculta de Drive" (no se ve en Drive ni en Google Fotos; cómo verla/borrarla: drive.google.com > Configuración > Administrar aplicaciones; recomienda verificación en dos pasos) en Sincronización y Ajustes; aviso al terminar una importación ("Los originales siguen en tu galería…"); aviso en la cuadrícula con "Borrar ahora" si hay originales verificados y el borrado está activado; mismo texto en el interruptor de la hoja de importación; 720p marcado "Recomendado" con el ahorro estimado (sin cambiar el valor por defecto). | `test/ui/clarity_test.dart`. |
| (d) Cambiar de cuenta con migración | Ajustes > Sincronización y cuenta > "Cambiar de cuenta de Google": hoja explicativa (qué pasa, cuánto baja/ocupa, Wi-Fi, espacio local y comprobación), flujo reanudable persistido en la BD (esquema v7, incremental), pausa/cancelación sin perder nada, borrar o conservar la cuenta vieja con confirmación. Detalle en D52; cerrar sesión sin migrar ahora avisa de lo que implica. | `test/account_migration_test.dart` (23: feliz, reanudación con un servicio nuevo, corte de red, Wi-Fi, cuota, otra bóveda, misma cuenta, cancelar, borrar vieja, archivo dañado) y `test/ui/account_migration_screen_test.dart` (7). |
| Diagnóstico | Ajustes > Acerca de > Diagnóstico: búfer en memoria (500 líneas) alimentado por `VaultLog` también en release; solo eventos y `runtimeType`; saneado defensivo (correos, rutas, UUID, tokens); se borra al bloquear; Copiar. **Compartir no está** (no hay `share_plus` en el proyecto y no se añadió una dependencia sin verificarla). | `test/diagnostics_test.dart` (8, incluye que no salgan correos/rutas/UUID/tokens). |
| README | "Depurar en iPhone desde Windows" con libimobiledevice, comandos verificados contra el código fuente oficial. | - |

Decisiones nuevas: D49 (solo Google Drive y una cuenta; iCloud y varias cuentas a v2, con motivos), D50, D51 (esquema v7 incremental porque ya hay datos reales), D52.

### Pruebas de iPhone a repetir (en este orden)
1. **Importar un video local**: debe verse su miniatura (fotograma) y la insignia ▶ con la duración. Es la prueba del método nativo `videoThumbnail` (Swift, sin probar).
2. **Importar un video que solo esté en iCloud** ("Optimizar almacenamiento"): descarga con progreso, se cifra y también debe tener miniatura.
3. **Videos ya importados sin miniatura**: abrir la bóveda (se regeneran solas al desbloquear) o Ajustes > Almacenamiento > "Regenerar miniaturas que faltan". Si alguna sigue sin miniatura, mira Ajustes > Acerca de > Diagnóstico (categoría `thumbs`) y mándame el texto copiado.
4. **Cerrar el visor deslizando hacia abajo** con fotos y con videos; con zoom (pellizco) NO debe cerrar, el deslizar horizontal sigue cambiando de archivo y, en el video, arrastrar sobre la barra de progreso no debe cerrar.
5. **Textos nuevos**: hoja de Sincronización y Ajustes (carpeta oculta de Drive), hoja de importación (borrar originales y 720p recomendado), aviso al terminar una importación.
6. **Borrado de originales**: activarlo en Ajustes, esperar a que estén "En la nube" y usar "Borrar ahora" (diálogo del sistema de iOS).
7. **Diagnóstico**: abrir, copiar y pegar en notas; no debe verse tu correo, rutas ni nombres de archivo.
8. **Espacio libre** (`freeSpace` en iOS): en la hoja de "Cambiar de cuenta" debe mostrar un número real (si dice "no se pudo comprobar", avísame).
9. Lo de rondas anteriores que siga pendiente (Face ID, multitarea, respaldo de iCloud, `monotonic` de S-07).

### Pasar a tu cuenta personal (Google One), paso a paso
**Antes (una sola vez, en Google Cloud):** si tu cuenta personal no está en la lista de usuarios de prueba de la pantalla de consentimiento OAuth (proyecto `vault-514801`, si está en modo "Testing"), agrégala en *APIs y servicios > Pantalla de consentimiento de OAuth > Usuarios de prueba*; si no, el inicio de sesión fallará con "acceso bloqueado". Si quieres que pruebe la migración completa en el emulador con una segunda cuenta, agrégala también ahí y avísame.

**En el iPhone:**
1. Conecta el iPhone a **Wi-Fi** y a la corriente, y deja la app abierta en primer plano.
2. Ajustes > Sincronización y cuenta > **Cambiar de cuenta de Google**. Lee la hoja: confirma que el espacio libre del teléfono alcanza y que tu cuenta personal tiene al menos esa cantidad libre en Google Drive / Google One.
3. **Empezar**. Primero baja de la cuenta de prueba lo que no esté en el teléfono (barra de progreso). Puedes pausar o cancelar cuando quieras; si se interrumpe, continúa al volver a abrir la bóveda.
4. Cuando se abra el selector de Google, elige tu **cuenta personal** (si eliges la misma, te lo dirá). Si esa cuenta ya tiene el respaldo de OTRA bóveda de Vault, el cambio se detiene sin tocar nada.
5. Espera a que suba y verifique todo (barra "n de m"). Al terminar verás "tus archivos están en la cuenta nueva".
6. **Elige**: *Borrar datos de la cuenta anterior* (permanente; te pedirá iniciar sesión un momento con la cuenta de prueba y luego volver a la personal) o *Conservarlos* como copia extra.
7. **Comprueba**: Ajustes > Sincronización y cuenta debe mostrar tu correo personal y todo "En la nube"; abre una foto y un video. Tu **código de recuperación** no cambia (el respaldo nuevo queda en tu cuenta personal).
8. Cuando ya no la uses, quita la cuenta de prueba de los usuarios de prueba de Google Cloud.

### Prueba de humo en el emulador Android (2026-11-16, APK debug, instalación limpia)
- **Miniaturas de video (nativo Kotlin):** importados 1 foto y 2 videos (Original): los videos salen con miniatura + ▶ + duración (0:25, 0:08); el log solo dice "Miniatura generada" (no cayó al respaldo de fototeca). Captura: `docs/screens/emu/s_ios1_cuadricula_video.png`.
- **Regeneración:** borradas las 3 miniaturas del disco (`run-as`), reabierta la app y desbloqueada: "Regenerando miniaturas: 3 elementos / 3 regeneradas" y la cuadrícula las muestra de nuevo; Ajustes > "Regenerar miniaturas que faltan" dice "No falta ninguna".
- **Cerrar deslizando:** con foto y con video, un deslizamiento largo hacia abajo cierra el visor; uno corto (50 px) lo deja abierto.
- **Textos:** hoja de importación con "720p. Recomendado" y el interruptor de borrar originales apagado con su explicación; aviso "Los originales siguen en tu galería…" al terminar; bloque de la carpeta oculta de Drive en Ajustes; Diagnóstico con eventos sin datos personales.
- **Cambiar de cuenta (con UNA cuenta en el emulador):** la hoja previa muestra 3 archivos, 26,05 MB a ocupar y **3,16 GB libres** (el método nativo `freeSpace` funciona en Android); "Empezar" abre el selector de Google; elegir la misma cuenta se rechaza ("Elegiste la misma cuenta. Elige OTRA cuenta de Google."); "Cancelar y volver a la cuenta anterior" restaura y vuelve a la cuenta (el log lo registra como `migration`). **No probado en el emulador:** migración completa a una segunda cuenta (solo hay una); está cubierta por las 30 pruebas automáticas.
- Nota del emulador: tiene PIN de pantalla 1234 y tras un arranque en frío hay que desbloquearlo antes de usar `/sdcard`.

### Dónde retomar / pendiente
- **Compartir** en Diagnóstico: descartado por decisión del usuario (basta Copiar; no se añade `share_plus`).
- La prueba de humo de la migración en el emulador Android solo cubre lo que se puede hacer con UNA cuenta (hoja previa, elegir la misma cuenta, cancelar); el flujo completo con dos cuentas reales queda para tu iPhone o para cuando agregues una segunda cuenta de prueba.
- Swift sin compilar ni probar: `videoThumbnail`, `freeSpace` y (de antes) `monotonic` en `ios/Runner/AppDelegate.swift`.

## v2 · Fase 4 — Guardar en Fotos (2026-11-17)
Visor > ícono "Guardar en Fotos" (foto y video; no aparece en otros tipos). Diálogo previo con "La copia quedará SIN cifrar en tu galería…". `VaultMediaExporter` (lib/features/vault/viewer/media_exporter.dart) descifra por bloques a `tmp_plain/`, entrega a `PhotoManagerPhotoSaver` (photo_manager 3.12.0) y borra el temporal en `finally` (también si se bloquea a mitad). iOS: permiso de solo-agregar con `AutoLockSuspension`. Detalle en D54.
- Tests: `test/f4_export_test.dart` (10: bytes exactos, video, permiso denegado, fallo al guardar, bloqueo, tipo no soportado, diálogo, cancelar, aviso, sin exportador).
- Emulador Android: smoke.mp4 guardado en Movies/ (mismo tamaño, 204 852 B); `tmp_plain/` vacío después; el bloqueo vuelve al PIN.
- Pendiente iPhone: ver "Pruebas de iPhone (v2)" al final.

## v2 · Fase 10 — Gestos en video (2026-11-17)
Doble toque izquierda/derecha = −/+10 s con racha acumulada (indicador animado + háptica), pellizco 1x–4x, a >1x el arrastre mueve la imagen sin cerrar ni paginar, toque simple muestra/oculta controles, la barra y los botones siguen funcionando, el doble toque no hace zoom. Detalle en D55.
- Tests: `test/ui/video_gestures_test.dart` (14: destino acotado, ±10 s, racha +10/+20/+30 con háptica, cambio de lado, inicio y final, toque simple a los 300 ms, sin zoom con doble toque, controles, pellizco ≤4x, zoom sin cerrar/paginar, 1x normal, liberar con zoom).
- Emulador Android (video de prueba con reloj incrustado): doble toque izquierda desde 0:25 → 0:15; doble toque derecha al final no hace nada; el toque simple muestra los controles. El pellizco NO se probó en el emulador (adb `input` no genera multitoque): solo en tests de widgets.

## Pruebas de iPhone (v2) — se irá ampliando por fase
1. **Guardar en Fotos**: abrir una foto y un video > "Guardar en Fotos" > confirmar. iOS pide permiso de SOLO agregar; deben aparecer en Fotos y abrirse. Denegar el permiso debe mostrar el aviso. Con "Face ID/autobloqueo" corto, el diálogo del permiso no debe bloquear la app.
2. **Gestos de video**: doble toque a ambos lados (±10 s), varios toques seguidos (acumulan), cerca del inicio/fin, toque simple (controles), pellizco hasta 4x y arrastrar con zoom (no debe cerrar ni cambiar de archivo), volver a 1x y cerrar deslizando.

## v2 · Fase 5 — Papelera (2026-11-17)
Borrar (un archivo, una carpeta o una selección) ahora manda a la **Papelera** (restaurable 30 días); nada se borra del teléfono ni de Drive hasta "Eliminar definitivamente", "Vaciar Papelera" o los 30 días (al desbloquear). Ajustes > Papelera: lista con tamaño y días restantes, restaurar, eliminar definitivamente y vaciar. BD v8 incremental (D56). Textos de confirmación actualizados.
- Código: `lib/data/trash/trash_repository.dart`, `lib/features/vault/services/trash_service.dart`, `lib/features/settings/trash_screen.dart`; filtros en `VaultDataRepository`; `VaultSchema.addTrashColumns`.
- Tests: `test/f5_trash_test.dart` (16: v7→v8 y v6→v8 conservan los datos, idempotencia, papelera de archivo y de carpeta, restaurar, origen perdido, raíces propias, 29/30 días, borrado con `delete_remote`, `daysLeft`, vaciar, caché no purga, candidatos a borrar originales, marca de cambios del snapshot) y `test/ui/trash_screen_test.dart` (7).
- Emulador Android con la bóveda REAL (v7, 3 archivos): al instalar encima la BD sube a v8 sin perder nada; borrar > Papelera ("Quedan 30 días") > restaurar; encontré y corregí que la cuadrícula no se recargaba al volver de Ajustes tras restaurar.
- Suite completa: 749 tests verdes (2 fallos iniciales de la regla de tokens, corregidos).
- Pruebas de iPhone (añadir a la lista v2): ver abajo.
3. **Papelera**: tras actualizar la app, abre la bóveda (la BD v7 sube a v8 sola; todo lo tuyo debe seguir ahí). Borra una foto y una carpeta: deben desaparecer de la cuadrícula y aparecer en Ajustes > Papelera con "Quedan 30 días". Restaura ambas y comprueba que vuelven a su carpeta. Bórralas de nuevo y usa "Eliminar definitivamente": en Google Drive (drive.google.com > Administrar aplicaciones > Vault) el espacio usado debe bajar tras sincronizar. Si borras originales de la galería, comprueba que algo en la Papelera NO borra su original.

## v2 · Fase 9 — Etiquetas, filtros y búsqueda (2026-11-17)
Etiquetas por archivo (crear, renombrar, borrar en Ajustes > Etiquetas; asignar desde la selección múltiple con "Etiquetas"), botón "Filtros" en la barra (tipo, etiquetas, fechas) con chips de filtros activos, y búsqueda por nombre combinable con los filtros en toda la bóveda. BD v9 incremental; las etiquetas van en el snapshot y en la restauración (D57).
- Código: `lib/data/tags/tag_repository.dart`, `vault_browser_controller.dart` (modo filtros), `widgets/{filter_sheet,active_filters_bar,tags_sheet}.dart`, `settings/tags_screen.dart` (UI hecha por subagente Sonnet y revisada).
- Tests: `test/f9_tags_test.dart` (12: v8→v9, CRUD, duplicados, asignación, búsqueda con %, etiquetas Y, tipo, fechas inclusivas, combinado, sin Papelera, limpieza al borrar), `test/f9_filters_controller_test.dart`, `test/ui/{filter_sheet,tags_sheet,tags_screen,vault_home_filters}_test.dart`.
- Emulador con la bóveda REAL: v8→v9 sin perder nada; etiqueta "Prueba" creada y asignada desde la selección; filtro por esa etiqueta muestra solo el archivo etiquetado con chip y "Resultados en toda la bóveda". Suite completa: 790 tests verdes (un test con la versión de esquema fija, actualizado).
4. **Etiquetas y filtros**: mantén pulsado un archivo > "Etiquetas" > crea "Prueba" y márcala en 2 archivos; abre Filtros > etiqueta "Prueba": deben salir solo esos 2 (aunque estén en carpetas distintas) con "Resultados en toda la bóveda". Combina con Fotos/Videos y un rango de fechas; escribe un texto en la búsqueda. Quita los chips. Ajustes > Etiquetas: renombra y borra (los archivos NO se borran). Tras bloquear/desbloquear y, mejor, tras restaurar en otro teléfono, las etiquetas deben seguir.

## v2 · Fase 6 — Selector de archivos propio (2026-11-17)
`file_picker` eliminado del pubspec. "Importar archivo" usa el canal nativo `vault/picker` y cifra leyendo por trozos del proveedor del sistema: no hay copia en claro en ningún momento (S-02 cerrado de raíz, S-18 corregido). Detalle en D58.
- Tests: `test/security_review_test.dart` grupo S-02 reescrito (7: bytes y SHA-256 exactos con lecturas cortas, vacío y múltiplo de bloque, cancelar, fallo de lectura sin `.vault` parcial, fallo de cifrado cierra el flujo, bóveda bloqueada no abre el selector, barrido de restos antiguos); formato `.vault` sin cambios (tests de formato verdes).
- Emulador Android: selector del sistema (DocumentsUI) → `fase6_prueba.txt` importado y subido; ningún archivo con ese nombre dentro de los datos de la app, `cache/` sin copias; en logcat la app no registra el nombre (solo `MediaProvider`, del sistema).
5. **Importar archivo (iPhone)**: Añadir > Importar archivo > elige un PDF de Archivos (y uno de iCloud Drive). Debe importarse y abrirse; si falla, copia Ajustes > Acerca de > Diagnóstico. Es Swift nuevo sin compilar: si el build de Codemagic falla, mándame el error.

## ⚠️ Aviso importante (2026-11-17): no instalar builds viejos
La revisión del diseño de la fase 1 encontró que las versiones anteriores, al abrir una BD creada por una versión más nueva, la **borraban y recreaban** (se perdía el índice local; Drive conserva los archivos y se podría restaurar con el código). Corregido desde este commit (D59), pero un build viejo sigue teniendo el defecto: en el iPhone instala siempre el build más reciente de `dev-claude`, nunca uno anterior.
