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

## D16 — Streaming de video con servidor HTTP en loopback (F6b)
- Contexto: reproducir sin escribir el video en claro en disco; `video_player` 2.11.1 no admite un DataSource/resource loader propio desde Dart.
- Opciones: completo-primero (F6a); plugin nativo propio (Media3 DataSource + AVAssetResourceLoaderDelegate); media_kit/fvp; pipe/memfd; HLS AES-128; servidor HTTP local.
- Elegida: servidor `dart:io` en 127.0.0.1 (puerto efímero) que descifra bloque a bloque bajo demanda con soporte Range. Completo-primero queda como respaldo automático.
- Por qué: única vía con el plugin oficial; una sola implementación del formato .vault (Dart, ya probada); funciona igual en Android/iOS. El plugin nativo duplicaría la criptografía en Kotlin y Swift.

## D17 — Controles de seguridad del servidor local
- Token de 256 bits (Random.secure, base64url) en la ruta y comparación en tiempo constante; cualquier otra ruta/token → 404 vacío e indistinguible; Host obligatorio `127.0.0.1:<puerto>`/`localhost:<puerto>` (anti DNS rebinding); solo GET/HEAD; un archivo por servidor; sin CORS; `no-store` y `nosniff`; tope de 8 respuestas simultáneas; timeout de inactividad 20 s.
- Integridad: el lector se abre con `verifyFinal` (Content-Length autenticado). Cada bloque se autentica ANTES de enviar un byte suyo; si falla antes de cabeceras → 500 vacío; a mitad → se destruye el socket. El servidor queda "envenenado" (500 a todo) y el visor muestra "archivo dañado" sin Reintentar. Sin caída a completo-primero en ese caso.
- Cierre: al liberar el origen (cerrar visor, cambiar de página), al pasar la app a segundo plano (hidden/paused) y al bloquear (`VaultSession.addOnClear` → `VaultStreamServer.closeAllNow`, síncrono para dejar de aceptar y cortar sockets).
- Logs: solo con `!kReleaseMode`, solo contadores/duraciones/códigos; nunca nombres, rutas, tokens ni llaves.

## D18 — Cleartext de Android solo para loopback
- `network_security_config.xml`: base-config `cleartextTrafficPermitted=false` con CA del sistema (sin CA de usuario); domain-config `true` solo para `127.0.0.1` y `localhost`. INTERNET declarado explícitamente (ya llegaba por fusión de plugins).
- iOS: `NSAppTransportSecurity/NSAllowsLocalNetworking=true` (sin NSAllowsArbitraryLoads). Sin probar en dispositivo.

## D19 — Al pasar a segundo plano se libera el video
- Contexto: con la app oculta no debe quedar un servidor escuchando (ni un temporal en claro en el respaldo).
- Elegida: VideoPage libera el origen en `hidden`/`paused`, recuerda la posición y reanuda desde ahí al volver a tocar Reproducir. Coste: hay que tocar Reproducir otra vez al volver.

## D20 — La caché LRU no purga lo que se está reproduciendo
- `CacheManager.markInUse/releaseInUse` (contador por id). Detectado en emulador: tras subir el video, `afterRun → enforce` borró el .vault mientras se reproducía (en Android el fd abierto siguió leyendo; en otra plataforma habría fallado).

## D21 — AES-GCM nativo o en isolates (resuelta en D22)
- Medido en emulador (debug y profile): el descifrado AES-GCM del paquete `cryptography` en Dart puro va a ≈1–1,3 MB/s, del orden del bitrate de un 1080p (≈8 Mbit/s). El streaming arranca cuando hay ~2,5 s de búfer; con videos de bitrate alto o "cargados al principio" el arranque no es inmediato y puede haber rebuffering.
- Opciones: (a) `cryptography_flutter` (AES-GCM nativo de Android/iOS; mismo formato, el AES-GCM es estándar); (b) pool de isolates descifrando bloques en paralelo con prelectura; (c) ambas. Requiere tu visto bueno (cambia el backend criptográfico usado también al importar).

## D22 — AES-GCM nativo: `cryptography_flutter` 2.3.4 con respaldo Dart
- Contexto: D21. AES-GCM en Dart puro ≈3 MiB/s por bloque de 1 MiB en el emulador (profile) y bloquea el isolate de UI todo el tiempo (sus `await` no ceden).
- Opciones: (a) `cryptography_flutter` (Android `javax.crypto` "AES/GCM/NoPadding" = Conscrypt/BoringSSL; iOS CryptoKit `AES.GCM`, iOS 13+); (b) pool de isolates con Dart (≈3 MiB/s por núcleo, 4 núcleos en el emulador ⇒ techo ≈12 MiB/s); (c) plugin propio.
- Elegida: (a), versión fija 2.3.4 (la última; exige cryptography ^2.8.1 —el lock ya tenía 2.9.0— y Dart ≥3.3; no cambia ninguna otra dependencia). Interfaz `AesGcmBackend` (`lib/core/crypto/aes_gcm_backend.dart`): `FallbackAesGcmBackend(NativeAesGcmBackend → DartAesGcmBackend)` en Android/iOS; Dart en escritorio, `flutter test`, isolates secundarios y con `--dart-define=VAULT_AES_BACKEND=dart`. Se resuelve en cada operación (no en campos estáticos).
- Mismo algoritmo estándar ⇒ formato .vault v2, AAD y nonce sin cambios. Verificado bit a bit: vector GCM Test Case 16 en ambos; nativo↔Dart con 14 tamaños de 0 B a 3 MiB+1; archivo .vault idéntico con el mismo Random; en la app, bóveda y video cifrados con Dart se abren con el nativo.
- Semántica de errores: tag inválido ⇒ `SecretBoxAuthenticationError` en ambos (el plugin traduce INCORRECT_MAC) ⇒ `VaultAuthException`/`null` como antes; no se reintenta con Dart. Llave destruida y longitudes inválidas se validan antes del nativo y no lo desactivan. Cualquier otro error del canal (PlatformException, MissingPlugin, salida de longitud incorrecta) ⇒ se repite con Dart y el nativo queda apagado el resto de la sesión (repetir un cifrado con el mismo nonce produce los mismos bytes: no hay reuso de nonce con otro texto).
- Los datos de menos de 1 KiB (envolturas de la DEK, textos cortos) siguen en Dart: el viaje por el canal cuesta más.
- Por qué no (b): menos de la mitad de rendimiento que (a) y más copias de memoria entre isolates; queda como alternativa si el canal falla en algún dispositivo (el respaldo actual es Dart en el mismo isolate).

## D23 — `Cryptography.instance` se restaura a la de `package:cryptography`
- El plugin se registra solo (dartPluginClass) y cambia `Cryptography.instance`, lo que llevaría HMAC/HKDF al canal sin avisar. `configureCryptography()` (en `main`, antes de cualquier uso) restaura la instancia original: el ÚNICO cambio de backend es AES-GCM y es explícito. `FlutterCryptography.enable()` está obsoleto en 2.3.x (y congelaría la instancia del plugin); no se usa.

## D24 — El descifrado del servidor de streaming sigue en el isolate de UI
- Con el nativo, el servidor entrega los 24,9 MB en 3,3 s (antes 12,0 s) y el primer MiB a los 99 ms; durante la reproducción el hilo principal estuvo al 17–38 % de CPU. El arranque del video en el emulador (≈18–25 s) lo domina ExoPlayer con el decodificador H.264 emulado, no el cifrado ⇒ no se mueve trabajo a otro isolate (no hay ganancia medible).
- Coste aceptado: en Flutter 3.41 el hilo de plataforma y el de UI están fusionados; cada bloque de 1 MiB ocupa el hilo ≈40–50 ms (mediana; picos de 100–250 ms en el emulador). Antes, con Dart, eran ≈300–470 ms por bloque sin ceder. Revisar en dispositivo real (allí el canal y AES son mucho más rápidos).

## D25 — Autobloqueo al pasar a segundo plano
- Contexto F7. Opciones de tiempo: inmediato, 15 s, 30 s, **1 min (por defecto)**, 5 min, 15 min; preferencia `security.v1.autolock_ms` (`AutoLockPreferences`; API `AutoLockController.setDelay` para F8). Para pruebas en emulador: `--dart-define=VAULT_AUTOLOCK_MS=15000` (ignorado en release).
- Mecanismo (`lib/core/security/auto_lock.dart`): `WidgetsBindingObserver` que marca el instante al pasar a `hidden`/`paused` (NO `inactive`: también ocurre con diálogos del sistema y la cortina de notificaciones) y, al volver (`resumed`), bloquea si transcurrió >= el tiempo. Además un `Timer` bloquea mientras el proceso sigue vivo en segundo plano; puede no dispararse (Android congela procesos), por eso la comprobación al reanudar es la garantía.
- Reloj: `AutoLockClock` lee un reloj monotónico (`Stopwatch`) y el de pared (`DateTime`) y usa el MAYOR transcurrido. El monotónico no avanza con el dispositivo dormido (Android/Linux) y el de pared lo puede mover el usuario; hacia atrás se ignora y hacia adelante solo provoca un bloqueo de más (seguro). Inyectable en pruebas.
- "Bloquear" = `AuthController.lock()` (-> `VaultSession.clear`: cierra BD, borra temporales en claro, cierra visor y servidor loopback, cancela subidas/descargas sin perder la cola persistente) + `VaultRootNavigator` hace `popUntil(isFirst)` (visor, hojas, diálogos) y vuelve a la PinScreen. Solo se navega si había sesión (no se destruye el flujo de creación/código de recuperación). Botón "Bloquear ahora" (candado) en la barra superior.
- La biometría automática de la PinScreen espera a que la app esté en primer plano (tras un autobloqueo la pantalla puede construirse en segundo plano).

## D26 — TRES mecanismos distintos de privacidad (no se sustituyen)
| Mecanismo | Plataforma | Qué cubre | Qué NO cubre |
|---|---|---|---|
| `FLAG_SECURE` (`vault/security`.`setSecure`) | Android | capturas de pantalla, grabación, proyección y la miniatura en recientes | nada más |
| Cobertura del selector de apps: `SceneDelegate` (UIView sólida #0B0B0E + candado en `sceneWillResignActive`, se quita en `sceneDidBecomeActive`) + `PrivacyCover` de Flutter (capa multiplataforma en inactive/hidden/paused) | iOS (nativo) y todas (Flutter) | vista previa en multitarea/selector de apps. En Android el `PrivacyCover` es segunda capa y también tapa durante diálogos del sistema (parpadeo aceptado) | NO impide capturas de pantalla en iOS |
| `NSURLIsExcludedFromBackupKey` (`vault/security`.`excludeFromBackup`) sobre vault/, thumbs/, db/ y vault_cache/ | iOS | respaldo de iCloud/iTunes (los .vault y la BD no viajan) | nada de pantalla. Se repite en cada arranque (tras `AppPaths.init`, que crea las carpetas) |
- iOS: escrito sin probar en dispositivo (no se puede compilar aquí). A verificar en Codemagic: `engineBridge.applicationRegistrar.messenger()` (API de `FlutterImplicitEngineBridge`) y las firmas de `sceneWillResignActive/sceneDidBecomeActive` en `FlutterSceneDelegate`.

## D27 — "Proteger pantalla" (FLAG_SECURE) activa por defecto, también en debug
- Preferencia `security.v1.protect_screen` (activa si no existe), `ScreenProtection` (`apply`/`setEnabled`, API para F8). `MainActivity.onCreate` pone FLAG_SECURE ANTES de dibujar (seguro por defecto); Dart lo apaga en el arranque solo si la preferencia está desactivada.
- Para tomar capturas con `adb screencap` en pruebas: `--dart-define=VAULT_ALLOW_SCREENSHOTS=true` fuerza la protección APAGADA solo si `kReleaseMode == false`; en release el define se IGNORA (verificado por test). Sin el define, debug también protege (verificado en emulador: captura y miniatura de recientes salen negras).
- Las pantallas del sistema (prompt biométrico, permisos) salen negras en `screencap` por ser ventanas seguras del sistema.

## D28 — Sin respaldo del sistema en Android
- `android:allowBackup="false"`, `fullBackupContent=@xml/backup_rules` y `dataExtractionRules=@xml/data_extraction_rules` (todo excluido en cloud-backup y device-transfer). La bóveda se recupera con el código de recuperación + Drive (F9), no con el respaldo del sistema. Debug y release compilan.

## D29 — Suspensión del autobloqueo por UI del sistema
- `AutoLockSuspension.instance.run(...)` (contador reentrante) envuelve: biometría (`SystemBiometricKeyStore.readKey/writeKey`), selector de archivos (`FilePicker`), permiso de fotos (`PhotoManager.requestPermissionExtend`) y Google (`signIn`, `signInSilently`, `authenticatedClient`). Mientras haya una activa, pasar a segundo plano no arma el autobloqueo. Verificado en emulador con el permiso de fotos (app en `paused` >20 s con umbral 15 s: no bloquea).
- Limitación: si el usuario sale de la app (HOME) DURANTE esos diálogos, no se arma hasta la siguiente transición. No hay función de compartir aún; cuando exista debe envolverse igual. `openSettings` NO se envuelve (sale de la app a propósito).

## D30 — `lock()` cancela un desbloqueo en vuelo (pendiente conocido resuelto)
- `AuthController` lleva un contador de generación (`_lockGeneration`): `unlockWithPin`/`unlockWithBiometrics` lo capturan al llamar y, antes de abrir la sesión, si cambió destruyen las llaves y lanzan `UnlockCancelledException` (la PinScreen lo ignora). Un unlock lanzado antes de un lock ya no se fusiona con uno nuevo del mismo PIN. Crear/restaurar bóveda NO se cancelan (flujo explícito del usuario, ya persistió). `pin_stress_test` actualizado (antes esperaba que la sesión se abriera).
