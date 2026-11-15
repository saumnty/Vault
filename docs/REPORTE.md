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
