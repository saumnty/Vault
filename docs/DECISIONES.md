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

## D31 — Onboarding obligatorio con bandera `onboarding_pending` (F8)
- Primer arranque (sin bóveda): bienvenida (3 tarjetas) -> crear PIN -> mostrar código -> CONFIRMAR código -> biometría (si hay) -> Drive (opcional) -> bóveda. `VaultRootNavigator` decide entre onboarding, PIN y bóveda; `PinScreen` solo crea/desbloquea y avisa con `onVaultCreated`.
- `AuthController.createVault(pin, onboardingPending: true)` escribe `vault.v1.onboarding_pending` ANTES de la envoltura del PIN (si el proceso muere, nunca hay bóveda sin bandera). `completeOnboarding()` la borra al acertar la confirmación (antes de biometría/Drive, que son opcionales). `restoreFromRecovery` también la borra.
- El código vive SOLO en memoria (en el estado raíz de la app). Reapertura a mitad: mismo proceso (p. ej. autobloqueo en segundo plano) -> PIN -> mismo código; proceso muerto -> PIN -> "Falta tu código": se ofrece GENERAR uno nuevo (D32). No hay forma de entrar a la bóveda sin confirmar. Tras terminar, el código no se vuelve a mostrar nunca; la hoja anterior con `SelectableText` se eliminó (el código ya no es seleccionable ni copiable).
- Aviso del paso de Drive redactado con precisión: sin Drive no hay nada que recuperar (el código solo sirve para lo respaldado en la nube), en vez de "el código es lo único que protege contra la pérdida del teléfono".

## D32 — `regenerateRecoveryCode(pin)` y confirmación por posiciones (F8)
- `AuthController.regenerateRecoveryCode(pin)`: verifica el PIN (cuenta intento, respeta el retraso), genera un código nuevo y vuelve a envolver la MISMA DEK con KEK_rec nueva (salt2 nuevo); reemplaza el respaldo local. DEK, subllaves, envoltura del PIN y biometría no cambian. El código viejo deja de abrir el respaldo local; el de Drive se actualiza en el siguiente `SyncService.run` (compara el SHA-256 del local con el último subido). Si el teléfono está sin red, hasta entonces el respaldo viejo de Drive sigue abriéndose con el código viejo (documentado en la UI).
- Confirmación (`RecoveryCodeChallenge`): 4 posiciones distintas y ordenadas al azar (base 1, `Random` inyectable), el usuario escribe esos caracteres; se normaliza (mayúsculas, sin espacios/guiones) y se compara en tiempo constante. Posiciones nuevas cada vez que se entra a confirmar; "Ver código otra vez" vuelve a mostrarlo. Campo sin autocorrección ni aprendizaje del teclado.
- En Ajustes el flujo es PIN -> código -> confirmación y la pantalla no se puede abandonar hasta confirmar.

## D33 — Ajustes: sin claves nuevas salvo calidad de video; todo en caliente (F8)
- Se reutilizan `AutoLockPreferences`, `ScreenProtectionPreferences`, `CachePreferences`, `SyncPreferences`, `GalleryImportPreferences` y el estado biométrico de `AuthController`. Única clave nueva: `pref.gallery.videoQuality` (la hoja de importación la usa como valor inicial). Dependencia nueva: `package_info_plus` 9.0.1 (fijada; verificada con `flutter pub add`) para la versión en "Acerca de".
- Hot: autobloqueo (`AutoLockController.setDelay` sobre el MISMO controlador del ciclo de vida), FLAG_SECURE (`ScreenProtection.setEnabled`), límite de caché (`CacheManager.setLimitBytes` purga al instante), Solo Wi-Fi (`SyncService.setWifiOnly`; al activarlo con una subida por datos móviles en curso la cancela). La pantalla de Ajustes muestra la PREFERENCIA de "Proteger pantalla" (no el define de depuración, que se avisa aparte).
- La hoja de sincronización y Ajustes comparten `QuotaBar`. El correo de Google solo se muestra en pantalla (verificado por test: ningún `debugPrint` contiene "@").

## D34 — Almacenamiento: liberar sin conexión / vaciar caché (F8)
- `StorageService` (envoltorio de `CacheManager` + repositorio + `OfflineService`). "Vaciar caché" = `enforce(maxBytes: 0)`: solo items con copia VERIFICADA en la nube, no sin conexión, no abiertos. "Liberar espacio sin conexión" = `clearOfflineFlagsForVerified()` (quita la marca de items verificados y de TODAS las carpetas) + `reconcile` + purga total de lo verificado. Nunca toca `pendiente`, `subiendo` ni `error` (conservan archivo, estado y su marca propia; verificado con BD y archivos reales). Ambas piden confirmación y resumen de lo liberado.
- Limitación: quitar la marca de una carpeta con items aún sin subir también la quita para ellos (su copia local no se borra; cuando se verifiquen serán purgables).

## D35 — Cerrar sesión de Google (F8)
- `SyncService.signOut` conserva todo lo local, cancela la subida en curso, deja la fase en `needsSignIn` y olvida el SHA del "respaldo ya subido" para que el próximo inicio de sesión (esta u otra cuenta) vuelva a subir `recovery_backup.json` (verificado en emulador). Riesgo conocido, fuera de F8: items `en_nube` de una cuenta A no existen en la cuenta B si se cambia de cuenta.

## D36 — Restauración en teléfono nuevo: preparar fuera, instalar al final (F9)
- Flujo: bienvenida "Ya tengo una bóveda (restaurar)" -> Google -> buscar `recovery_backup.json` + `vault_db.snapshot` -> código -> PIN nuevo (+ confirmar) -> descarga -> listo -> (biometría opcional) -> bóveda. Código: `lib/data/restore/restore_service.dart`, `lib/features/onboarding/restore_flow.dart`, `AuthController.verifyRecoveryCode/commitRestore`.
- Nada es visible para la app hasta el último paso. El snapshot y las miniaturas se descargan a `restore_staging/` (tamaño + MD5 contra los metadatos de Drive), el snapshot se abre con la llave SQLCipher `x'hex'` derivada de la DEK recuperada y se reconcilia ahí; recién entonces se mueven a `db/` y `thumbs/` (rutas relativas) y se consolidan las llaves (envoltura del PIN NUEVA en este dispositivo, ÚLTIMA escritura). Si falla la consolidación se borra todo lo instalado y lo escrito en el almacén seguro.
- Fallo de red: la preparación se conserva (miniaturas ya verificadas se saltan al reintentar); no hay bóveda ni bandera. Snapshot que no abre ("dañado o no corresponde a este código"): se borra el staging y no se reintenta solo. Restos de una instalación interrumpida (BD/miniaturas sin bóveda) se barren al arrancar (`sweepOrphans`).
- Reconciliación: item con copia en Drive cuyo tamaño/MD5 coinciden con lo registrado -> `en_nube`; sin registro de MD5 pero con copia en Drive -> se adopta con los metadatos de Drive (cada bloque se autentica al abrir); sin copia o distinta -> `error` (visible, se informa cuántos). Miniatura ausente en Drive -> se quita `thumbPath`. La cola del otro teléfono se descarta salvo `delete_remote`. Los .vault completos se bajan al abrir (`VaultFileFetcher`); las marcas "sin conexión" se conservan y `OfflineService.reconcile` las descarga.
- Tras restaurar se guarda el SHA del respaldo (el mismo de Drive, texto idéntico) y `snapshotAt = ahora`: no se re-sube nada.
- iOS: el Keychain sobrevive a desinstalar; si hay envoltura del PIN pero no existe la BD local (y no hay onboarding pendiente) se descartan las llaves locales (`discardLocalKeys`) para poder restaurar. Solo iOS; sin probar.

## D37 — Límite de intentos del código de recuperación y su límite real (F9)
- `PinAttemptLimiter` con clave propia (`vault.v1.restore_attempts`): 5 fallos -> 30 s, luego 60 s, 2 min... (misma tabla que el PIN), persistido, contado antes de derivar y borrado al acertar. Un código con formato inválido (longitud/alfabeto) no cuenta ni deriva. Independiente del límite del PIN.
- LIMITACIÓN (documentada): `recovery_backup.json` está en Drive; quien obtenga la cuenta puede probar códigos SIN la app y sin ningún límite. El límite local solo frena la interfaz. La defensa real es la entropía del código (24 símbolos de 31 ≈ 119 bits) + Argon2id (m=19 MiB, t=2): fuerza bruta inviable. El PIN nunca protege nada que salga del teléfono (sigue igual).
- Logs: ni el código, ni la DEK, ni nombres, ni correos; el campo no autocompleta, no aprende y no se guarda. El correo solo se muestra en pantalla.

## D38 — Snapshot siempre fresco (F9)
- Antes: ≥20 subidas o ≥6 h. Ahora: marca "sucio" persistida (`sync.v1.snapshot_dirty_at`) que ponen los cambios de datos (`VaultDataRepository.onDataChanged`: items, carpetas, renombrar, mover, borrar, "sin conexión", ids de Drive; NO `syncStatus` ni `lastAccessedAt`) y cada subida verificada. `SyncService.notifyDataChanged` reinicia un debounce de 30 s y lanza una pasada. El snapshot se encola cuando ya no quedan trabajos vencidos (se toma DESPUÉS de las subidas e incluye sus `driveFileId`/`cloudMd5`) si hay cambios, o si el último tiene >6 h. La marca solo se limpia si el último cambio es anterior a la TOMA de la copia (un cambio durante la subida exige otro).
- Al bloquear (`VaultServices.beforeLock`, best-effort, 3 s): con cambios pendientes, cuenta y red permitida se toma la copia cifrada ANTES de destruir las llaves y se sube en segundo plano sin necesitar llaves; la UI vuelve al PIN al instante. Si falla, la marca persiste.
- Seguridad: el snapshot es la BD SQLCipher (llave de la DEK); verificado en emulador que el .db no contiene "SQLite format" ni nombres de archivos/carpetas.

## D39 — Campo del código: formato en vivo, tolerante (F9)
- Acepta minúsculas, espacios, guiones, `_` y `.`; agrupa de 4 en 4 y limita a 24; no reemplaza caracteres ambiguos (0/O, 1/I/L no existen en el alfabeto: se avisa). Tipografía propia `AppTypography.codeInput` para que quepan 29 caracteres.

## D40 — Revisión de seguridad independiente: autobloqueo con suspensión acotada (S-01)
- Contexto: `AutoLockSuspension` (D29) anulaba el autobloqueo sin límite si la app pasaba a segundo plano durante un diálogo del sistema o una petición de token de Google de la sincronización.
- Elegida: con suspensión activa se arma un tope (`AutoLockController.maxSuspendedBackground` = 5 min, o el tiempo configurado si es mayor; temporizador + comprobación al volver). Si la suspensión termina con la app aún en segundo plano, se arma el autobloqueo normal desde ese instante con un mínimo de `rearmGrace` = 3 s (el resultado del selector llega justo antes de `resumed`; con "inmediato" no debe bloquear ahí). Sustituye la limitación documentada en D29.
- Coste: un selector/diálogo abierto más de 5 min bloquea la bóveda al volver (la importación en curso falla limpiamente porque la llave se destruye).

## D41 — Restos en claro de plugins se borran (S-02, S-03)
- `file_picker`: la copia que entrega (Android `cache/file_picker/<ms>/<nombre>`, iOS `tmp/`) se borra siempre tras importar, SOLO si está dentro de esas carpetas (`PlainResidue.isWithinRoots`). Al arrancar se barren `cache/file_picker` (Android) y `vault_cache/import_tmp`. En iOS no se barre `tmp/` entero (compartido con otros plugins).
- `photo_manager`: `PhotoManager.clearFileCache()` (Glide memoria+disco y copias `pm_*` de Android 10) al terminar cada lote, tras borrar originales y al arrancar. Coste: la cuadrícula del selector regenera miniaturas.

## D42 — El respaldo de recuperación nunca se reemplaza in situ en Drive (S-04)
- `files.update` deja el contenido anterior como revisión (≈30 días). Ahora: crear archivo nuevo → verificar tamaño+MD5 → `files.delete` (permanente, con revisiones) de todos los anteriores con ese nombre; si el borrado falla el trabajo se reintenta. La DEK sigue sin rotarse al regenerar el código (S-11, pendiente).

## D43 — PIN nuevo de 6 dígitos y sin llave de hardware adicional (S-06)
- Cambio: crear, cambiar o restaurar el PIN exige exactamente 6 dígitos (`AuthController.minNewPinLength`; el teclado ya limitaba a 6, así que el PIN nuevo es de 6 fijos y se envía solo al 6.º dígito). Desbloquear sigue aceptando 4–6 (`minPinLength`) para bóvedas creadas antes del cambio. 10^6 combinaciones con Argon2id m=19 MiB elevan 100× el coste del ataque offline frente a 4 dígitos.
- Evaluado y NO implementado: envolver además la envoltura/DEK local con una llave del Keystore/StrongBox (Android) o Secure Enclave (iOS) propia.
  - La envoltura del PIN (`vault.v1.pin_envelope`) YA vive en `flutter_secure_storage` (Android: EncryptedSharedPreferences con clave maestra del Android Keystore; iOS: Keychain `WhenUnlockedThisDeviceOnly`). Un volcado de archivos (copia de `/data`, backup, imagen del disco) no contiene la envoltura en claro: requiere además la clave del Keystore, que no sale del dispositivo. El ataque offline "solo con archivos" ya exige el teléfono.
  - Quien ejecuta código como la app en un teléfono rooteado puede usar la misma llave de Keystore para descifrar cualquier capa nueva (sería otra clave del mismo Keystore): la capa extra no añade protección frente a ese atacante, que es justo el del hallazgo. Solo la ataría a hardware con autenticación del usuario (biometría), que ya existe como camino opcional (`biometric_storage`).
  - Requeriría código nativo propio (Kotlin/Swift) y no es verificable sin iPhone; riesgo de dejar la bóveda sin PIN si se invalida la llave (aún quedaría el código de recuperación). Coste/beneficio desfavorable.
- Riesgo residual aceptado: teléfono rooteado con acceso en ejecución + PIN de 6 dígitos ⇒ fuerza bruta limitada solo por Argon2id (≈0,1–1 s por intento en el teléfono). Mitigación futura si se quiere: PIN alfanumérico o frase.

## D44 — Rangos fijos de Argon2id al leer parámetros externos (S-08)
- `Argon2Params.fromJson` (envolturas locales y `recovery_backup.json` de Drive) acepta solo m ∈ [8·p, 256 MiB], t ∈ [1, 10], p ∈ [1, 4] (producción: 19456 KiB / 2 / 1). Fuera de rango lanza `FormatException` con mensaje claro (valores y rangos, sin datos secretos) ANTES de derivar nada; en `probe()` el respaldo se marca inválido y `restoreFromRecovery` lanza sin tocar la bóveda local.
- No se exige un mínimo igual a producción: no debilita (parámetros bajos no abren nada sin la DEK) y los tests usan valores reducidos.


## D45 — Retraso del PIN con reloj monotónico y contador de arranques (S-07)
- Cada bloqueo guarda, además de la hora de pared, una lectura monotónica nativa (Android: `SystemClock.elapsedRealtime` + `Settings.Global.BOOT_COUNT` por el canal `vault/security`, método `monotonic`; iOS: `mach_continuous_time`, `// iOS: sin probar`) y la duración impuesta. La espera restante es el MAYOR de las dos (se exigen ambas): adelantar la fecha del sistema no quita la espera. Aplica al PIN y al código de restauración (mismo `PinAttemptLimiter`).
- Reinicio (otro `BOOT_COUNT`, o el monotónico baja): el monotónico no mide el tiempo apagado, así que solo se abona el tiempo desde el arranque (cota inferior del real). Es fail-closed: reiniciar nunca acorta la espera; coste: tras apagar el teléfono con un bloqueo activo puede tocar esperar de nuevo hasta 1 h como máximo (y solo si además la hora de pared lo exige en ese plazo).
- iOS no tiene un contador de arranques fiable (`kern.boottime` cambia con la hora de pared y permitiría falsear el reinicio), así que `boot = -1` y el reinicio se detecta porque el valor monotónico baja; si tras un reinicio sube por encima del anterior solo se abona la diferencia (nunca de más).
- Sin reloj monotónico disponible (tests, escritorio, canal ausente) se usa solo la hora de pared, como antes. Hora de pared atrasada: la espera sigue acotada al nivel actual (no bloqueo eterno).
- Sin cambio de formato de nada persistido relevante: el estado `vault.v1.pin_attempts` gana campos opcionales (`lockElapsed`, `lockBoot`, `lockDur`) y los estados antiguos siguen leyéndose.

## D46 — El fileId del encabezado se guarda en la BD y se verifica (S-09)
- Esquema v6 (SIN migración, recrea tablas; no hay datos reales): `vault_items.fileId` y `vault_items.thumbFileId` = UUID del encabezado del `.vault` / `.thumb` al cifrarlos. El formato `.vault` v2 NO cambia (el fileId ya estaba en el encabezado y en la AAD).
- Se comprueba (antes de descifrar nada) al abrir foto/archivo, descifrar video completo, streaming (`CryptoService.openReader(expectedFileId:)`), mostrar miniaturas (`decryptBytes(expectedFileId:)`), al descargar de Drive (`VaultFileFetcher`, sobre el `.part` antes del rename) y al restaurar miniaturas (se descartan y cuentan como perdidas). Si no coincide: `VaultFileMismatchException` (subclase de `VaultCryptoException`, la UI lo muestra como archivo dañado) / `VaultFetchVerificationException`.
- Alcance: impide servir el `.vault`/`.thumb` auténtico de OTRO item (intercambio en Drive o en disco) y un índice (snapshot) viejo cuyos fileId ya no corresponden a los archivos. `fileId` nulo (items sin registro) = sin comprobación; hoy todo item nuevo lo registra. Un snapshot v5 antiguo se rechaza como incompatible (ya existía esa comprobación de versión).

## D47 — S-11 (rotar la DEK) pospuesto a v2
- Regenerar el código de recuperación (D32) re-envuelve la MISMA DEK. Quien tenga el código viejo y una copia antigua del respaldo conserva acceso. La mitigación completa es rotar la DEK (re-cifrar archivos, miniaturas y BD, y subir todo de nuevo), que cambia el modelo de datos/sincronización y es grande y arriesgado sin pruebas en iPhone. Decisión: POSPUESTO a v2. Mitigaciones ya hechas: S-04 (las revisiones viejas del respaldo en Drive se borran) y la advertencia al usuario al regenerar.

## D48 — Topes de tamaño, rutas estrictas y otros cierres menores (S-05, S-10, S-12, S-14, S-15, S-19, S-20)
- S-14: `recovery_backup.json` ≤ 4 KiB (un respaldo real mide ~0,6 KiB); snapshot ≤ 256 MiB (la BD cifrada de una bóveda con decenas de miles de items ocupa pocos MiB; el tope solo evita agotar disco/datos si la cuenta es hostil, inyectable en pruebas); miniatura ≤ 8 MiB (las reales son ~30 KiB); el número de miniaturas ya está acotado por el número de items del snapshot. Se verifica el tamaño declarado por Drive y los bytes realmente recibidos.
- S-15: los archivos de items solo pueden ser `vault/<uuid v4>.vault` y `thumbs/<uuid v4>.thumb`; los ids se validan como UUID al restaurar. Las pruebas históricas usan ids cortos (`i1`): `AppPaths.allowNonUuidIdsForTesting` (por defecto `false`, solo `@visibleForTesting`) se activa en `test/flutter_test_config.dart`; `test/s15_test.dart` lo apaga.
- S-05: al bloquear se vacía el `ImageCache` global y se ponen a cero los buffers propios (miniaturas en caché del loader, foto del visor al cerrarlo). No se pone a cero una miniatura expulsada del LRU porque un `MemoryImage` vivo aún podría leerla.
- S-10: un build de release sin `android/key.properties` falla con mensaje claro; `ALLOW_DEBUG_SIGNED_RELEASE=true` (entorno o `-P`) lo permite explícitamente y solo se usa en el workflow opcional `android-release` de Codemagic, que además compila con `--obfuscate --split-debug-info`.
- S-12: `VaultLog` (solo `kDebugMode`; los errores registran solo el `runtimeType`).
- S-19: eliminados `vault_repository.dart` y `encryptData/decryptData`; `restoreFromRecovery` se queda como `@visibleForTesting` (sin límite de intentos; la app restaura por `RestoreService`).
- S-20: versiones exactas (sin `^`) de los paquetes de cripto/seguridad/Google/almacenamiento, iguales al lock.

## D49 — Solo Google Drive y una cuenta a la vez; iCloud y varias cuentas, a v2
- Se sigue SOLO con Google Drive (`appDataFolder`) y con UNA cuenta de Google a la vez. `CloudStorage` ya es la interfaz donde se enchufarían otros proveedores o cuentas.
- **iCloud como proveedor → v2:** exige una cuenta de Apple Developer de pago (CloudKit/iCloud Drive con entitlement) que hoy no hay (Sideloadly con Apple ID gratuito), y una bóveda guardada solo en iCloud **no se podría restaurar en Android**, que es uno de los dos objetivos del producto.
- **Reparto entre varias cuentas → v2:** exige OAuth con tokens por cuenta (varias sesiones de Google a la vez, que `google_sign_in` no ofrece de forma simple), decidir qué archivo va a qué cuenta y volver a unir todo al restaurar; la restauración (que hoy es "una cuenta + un código") pasaría a ser frágil: faltaría UNA cuenta y la bóveda quedaría incompleta.
- Mientras tanto, cambiar de cuenta se resuelve con la migración completa (D52), no con varias cuentas.

## D50 — Miniaturas de video: fotograma del archivo propio, no el de la fototeca ni el de video_compress (iOS ronda 1)
- Síntoma (iPhone): las miniaturas de videos importados no se veían (las de fotos sí). Sin dispositivo para depurar, se rehizo la ruta para que NO dependa de la fototeca.
- Los videos ahora sacan un fotograma central del archivo YA materializado (también sirve si venía de iCloud) con un método nativo propio `videoThumbnail` (canal `vault/security`): Android `MediaMetadataRetriever` (verificado en emulador), iOS `AVAssetImageGenerator` (`// iOS: sin probar`), JPEG con lado máximo 256. La fototeca (`photo_manager.thumbnailDataWithSize`) queda de respaldo.
- No se usa `video_compress.getByteThumbnail/getFileThumbnail` (leído en su fuente iOS): si no puede generar el fotograma **nunca responde** (el `Future` se cuelga), devuelve el fotograma a **resolución completa** sin reducir, la posición por defecto (-1) no es válida en iOS y `getFileThumbnail` **borra el archivo de origen**.
- Si todo falla: el video sale con ícono de reproducción + duración (siempre, también sobre la miniatura) y `thumbPath` nulo; el error se registra (categoría `thumbs`, solo `runtimeType`), ya no se traga en silencio.
- Regeneración (`ThumbnailRegenerationService`): al desbloquear, acotada (40 por pasada, solo videos locales ≤ 100 MB para descifrar; lo que falló no se reintenta hasta cerrar la app) y manual en Ajustes > Almacenamiento > "Regenerar miniaturas que faltan" (sin topes). Orden por item: fototeca (`sourceAssetId`) → fotograma del `.vault` local descifrado a un temporal (siempre borrado). Los `.vault` solo en la nube NO se descargan solos. La miniatura nueva se sube sola (`thumbDriveFileId` nulo → la cola la detecta).

## D51 — Esquema v7 con actualización INCREMENTAL (ya hay datos reales)
- Antes de v6 cualquier cambio de versión recreaba las tablas porque no había datos reales. **Ya hay una bóveda real en un iPhone**, así que desde v6 la actualización es incremental (`VaultSchema.upgrade`): v6→v7 solo añade `migration_state` y `migration_items` (`CREATE TABLE IF NOT EXISTS`), sin tocar nada más. Versiones anteriores a 6 siguen recreándose.
- Restauración: se acepta un snapshot v6 o v7 (al abrirlo la app lo actualiza); al restaurar se VACÍAN las tablas de migración del snapshot (el estado de un cambio de cuenta pertenece al teléfono que lo hizo).

## D52 — Cambio de cuenta de Google con migración
- Flujo en fases persistidas en la BD cifrada (`migration_state`, una fila): `downloading` → `signInNew` → `checkingNew` → `uploading` → `finalizing` → `askDeleteOld`, más `blockedOtherVault` y `blockedQuota`. Sobrevive a matar la app y al bloqueo (se retoma solo al desbloquear si no necesita al usuario). Mientras dura: la sincronización normal en pausa (`SyncService.pausedForMigration`) y la caché LRU sin purgar (`CacheManager.suspended`).
- (1) Baja de la cuenta vieja lo que no esté local, verificando tamaño + MD5 y el `fileId` (S-09); un archivo ausente o dañado en la cuenta vieja se cuenta como perdido y no frena el resto (queda en `error`). (2) Cierra sesión e inicia con la nueva; elegir la misma cuenta se rechaza. Si la nueva ya tiene un `recovery_backup.json` distinto del local → `blockedOtherVault`, sin subir ni borrar NADA; si es idéntico (migración reanudada) se sigue. (3) Comprueba la cuota de la nueva (necesario ≥ lo estimado) → `blockedQuota` antes de subir. (4) Reinicia las referencias a la nube (guardando antes las antiguas en `migration_items`, en una transacción) y sube con la verificación habitual de `SyncService` (`run(force: true)`), más `recovery_backup.json` y un snapshot fresco; marca `en_nube` con los nuevos `driveFileId/cloudMd5`. (5) Con confirmación explícita ofrece borrar los datos de la cuenta vieja (solo nombres de Vault: respaldo, snapshot y `<uuid>.vault/.thumb`; borrado permanente, como S-04) o conservarlos.
- Cancelar (en cualquier fase antes de terminar) restaura las referencias antiguas y vuelve a iniciar sesión con la cuenta vieja; lo ya subido a la nueva no se borra.
- **Limitación aceptada:** la cuota de la cuenta nueva solo se puede leer después de iniciar sesión en ella (hay una sola sesión de Google a la vez), así que se comprueba justo después de elegirla y ANTES de subir; la hoja previa muestra cuánto ocupará y comprueba el espacio local (nativo `freeSpace`; si no se puede saber, no bloquea). Borrar la cuenta vieja o cancelar tras cambiar exige un selector de cuenta más.
- Cambiar de cuenta SIN migrar (cerrar sesión + otra cuenta) ahora avisa de lo que implica y "Cerrar sesión" se desactiva mientras hay una migración en curso.

## D53 · S-17: ventana de llaves al bloquear ≤ 1 s (v2 fase 7)
La subida del snapshot ya no esperaba la red (solo la copia local cifrada), pero el tope era 3 s. `lockWithFlush` (lib/core/security/lock_flush.dart) bloquea a más tardar 1 s después, pase lo que pase con el flush (colgado o con error); el flush tardío no vuelve a bloquear. Si el snapshot no se tomó, la marca "sucio" sigue y se toma al desbloquear: no se pierde ningún cambio, solo se retrasa el respaldo.

## D54 · Guardar en Fotos (v2 fase 4)
Sin paquete nuevo: `photo_manager` 3.12.0 (ya fijado para importar) trae `saveImageWithPath`/`saveVideo` y el permiso iOS de solo-agregar (`IosAccessLevel.addOnly`, `NSPhotoLibraryAddUsageDescription` ya estaba en Info.plist). Flujo: diálogo "La copia quedará SIN cifrar…" → permiso (con `AutoLockSuspension`) → descifrado por bloques a un temporal de `tmp_plain/` (se verifica el `fileId` y se aborta si se bloquea) → guardar → borrar el temporal en `finally`. Android 10+ no necesita permiso para escribir en MediaStore; en Android 7-9 (minSdk 24) puede fallar y se informa "No se pudo guardar" (no se pide almacenamiento). Las copias guardadas quedan fuera del control de Vault: no se borran al borrar el archivo.

## D55 · Gestos de video (v2 fase 10)
Reconocimiento propio de toques (`VideoGestureLayer`) en lugar de `onDoubleTap`: así los toques SIGUIENTES a un doble toque suman sin esperar otro doble (+10, +20, +30; racha de 700 ms; cambiar de lado la reinicia desde la posición actual). El toque simple espera 300 ms (`kVideoDoubleTap`) para distinguirse del primero de un doble. Los saltos se acotan a [0, duración] y no se cuentan en los extremos. El zoom (1x–4x) es un `InteractiveViewer` bajo la capa de gestos; con >1x el visor deshabilita paginar y cerrar deslizando (`onZoomChanged`), y se reinicia si el video se libera con zoom. El doble toque NO hace zoom en video (sí en fotos).

## D56 · Papelera (v2 fase 5, BD v8)
* **Esquema v8 incremental** (`VaultSchema.addTrashColumns`, idempotente, no toca datos): `deletedAt` (epoch ms) y `trashRoot` en `vault_items` y `folders`. v6 y v7 suben a v8 sin perder nada; un snapshot de Drive v6/v7/v8 se acepta al restaurar (la app lo actualiza al abrirlo).
* **`trashRoot`**: al borrar una carpeta se marcan ella, sus subcarpetas y sus archivos con el id de la carpeta; se restaura o se elimina todo junto. Lo que ya estaba en la papelera por su cuenta conserva su propia raíz. La lista de la Papelera muestra solo las raíces (`trashRoot = id`).
* **Mover a la papelera no borra nada**: ni el `.vault`, ni la miniatura, ni la copia de Drive; no se encola `delete_remote`. El borrado real (filas, archivos locales y `delete_remote`) ocurre al "Eliminar definitivamente", "Vaciar Papelera" o a los 30 días (`purgeExpired` al desbloquear). Mismo orden que el borrado directo anterior (ids de Drive leídos antes de borrar la fila: ante un corte queda un huérfano en Drive, nunca un item sin archivo).
* **Exclusiones**: `getItemsByFolder`, `getFoldersByParent` (cuadrícula y búsqueda del navegador), `getCloudVerifiedItems` y `getCachedItemsLru` (la caché no purga ni re-descarga lo de la papelera) y los candidatos a borrar originales (`getItemsBySyncStatus(includeTrashed: false)`: tirar algo a la papelera no debe provocar además el borrado de su original de la galería). Las subidas pendientes SÍ continúan y el cambio de cuenta migra también lo de la papelera (hay que poder restaurarlo luego).
* **Restaurar** vuelve a su carpeta; si ya no existe o también está en la papelera, va a la raíz.
* **Texto de confirmación**: "¿Mover N elementos a la Papelera?… restaurable 30 días… después permanente, también en Google Drive". Sin servicio de papelera (pruebas) se conserva el texto del borrado directo.
* La papelera vive en Ajustes (no en la raíz) para no ocupar la cuadrícula.

## D57 · Etiquetas, filtros y búsqueda (v2 fase 9, BD v9)
* **Esquema v9 incremental** (`createTagTables`, idempotente): `tags(id, name UNIQUE NOCASE, createdAt)` e `item_tags(itemId, tagId)`. Viven en la BD cifrada: viajan en el snapshot de Drive y vuelven al restaurar (un snapshot v8 se acepta y la app lo sube a v9 al abrirlo). El nombre es único sin distinguir mayúsculas, hasta 40 caracteres.
* **Borrado**: borrar una etiqueta quita sus asignaciones, nunca archivos; borrar un archivo (directo o definitivo desde la Papelera) limpia sus filas de `item_tags`. Las cuentas de la etiqueta cuentan solo archivos vivos (no los de la Papelera).
* **Filtros** (`ItemFilter`, todos combinables con Y): texto (nombre, sin mayúsculas, `%`/`_` literales), etiquetas (el archivo debe tener TODAS), tipo (foto/video/otro, con la misma `fileKindOf` que el resto de la app) y rango de fechas de importación (día completo, ambos extremos incluidos; comparación de texto ISO con inicio de día `AAAA-MM-DDT00:00:00`).
* **Con filtros la vista pasa a ser una búsqueda en TODA la bóveda** (sin carpetas, sin la Papelera) con título "Resultados en toda la bóveda"; sin filtros, el buscador sigue filtrando solo la carpeta actual como antes.
* El selector de fechas queda en inglés (no hay `flutter_localizations`); solo los textos propios están en español. Añadirlo queda para una ronda de pulido.

## D58 · Selector de archivos propio (v2 fase 6)
`file_picker` copiaba cada archivo elegido EN CLARO a la caché (Android `cache/file_picker/<ms>/<nombre>`, iOS `tmp/`) y registraba la URI; el arreglo S-02 borraba la copia después, pero la copia existía. Ahora: canal propio `vault/picker` con `pick` / `read(handle, length)` / `close(handle)`.
* Android: `ACTION_OPEN_DOCUMENT` (`CATEGORY_OPENABLE`, `*/*`), nombre/tamaño con `OpenableColumns`, `ContentResolver.openInputStream`, lecturas en un hilo propio, trozos de hasta 1 MiB (tope 4 MiB). `onActivityResult` clásico (una sola petición a la vez). Flujos cerrados en `close` y en `onDestroy`.
* iOS (sin compilar ni probar, `// iOS: sin probar`): `UIDocumentPickerViewController` en modo abrir (`asCopy: false`; iOS 13 con `documentTypes:in: .open`), `startAccessingSecurityScopedResource`, `FileHandle` por trozos (`read(upToCount:)` en 13.4+), `stopAccessing…` al cerrar. Vive en `AppDelegate.swift` para no tocar el proyecto de Xcode.
* Dart: `PickedDocument` es un `VaultByteSource`; `VaultFileFormat.encryptSource` cifra desde la fuente con el MISMO formato `.vault` v2 (`encryptFile` ahora delega en él) y el SHA-256 se calcula en la misma pasada. El tamaño registrado es el de los bytes leídos. Sin logs de nombres ni rutas. El selector va dentro de `AutoLockSuspension`.
* Se conserva `PlainResidue.sweepAtStartup` para barrer copias que hayan dejado versiones anteriores de la app.

## D59 · Nunca recrear la BD al bajar de versión (hallazgo M9 de la revisión de la fase 1)
`onDowngrade` llamaba a `VaultSchema.recreate`: instalar un build MÁS VIEJO que el que creó la BD borraba todo el índice local. Ahora lanza `VaultSchemaTooNewException` y no toca el archivo (test `test/m9_downgrade_test.dart`). Los builds viejos ya compilados conservan el comportamiento peligroso: **no instalar en el iPhone un build anterior al último instalado**.

## D60 · Generaciones de llave, nombres `.kN` y `keyGen` (v2 fase 1, S-11)
Diseño completo en `docs/DISENO_ROTACION.md` §1.
* Cada DEK tiene una generación. La bóveda actual es la **gen 1** y conserva TODOS sus nombres (locales y de Drive): una bóveda que nunca rota funciona exactamente igual que antes. Desde la gen 2 cada nombre lleva `.kN` (`<uuid>.k2.vault`, `.k2.thumb`, `vault_db.k2.snapshot`, `recovery_backup.k2.json`), más el puente `recovery_backup.bridge.k<from>.json` y la cuarentena `lost_<uuid>.kN.vault`.
* `toGen = max(key_gen local, mayor gen visto en Drive) + 1`: nunca se reutiliza un nombre, aunque otro teléfono haya rotado antes.
* **La fuente de verdad de qué llave abre un item es `vault_items.keyGen`** (BD v10 incremental, `DEFAULT 1`); `encryptedPath`, `thumbPath` y los nombres de Drive se derivan de `(id, keyGen)` y cambian en la misma transacción. `VaultItemModel.keyGen` es requerido. `CloudNames` (`lib/data/cloud/cloud_names.dart`) construye y valida los nombres (UUID v4, gen 2..9999; S-15 ampliado).
* La sesión lleva un `VaultKeyring` (una llave, o dos durante la rotación); los lectores piden `filesKeyFor(item.keyGen)`. La BD se abre probando las llaves candidatas (`openedGen`). `vault.v1.key_gen` (ausente = 1) guarda la generación vigente.

## D61 · Orden en Drive, puente, congelación y borrado por lista (v2 fase 1)
* **Orden:** congelar → snapshot gen 1 propio → puente (DEK vieja envuelta con el código NUEVO B, patrón S-04) → re-cifrar y subir `.kN` → re-cifrar la BD → PIN a la llave nueva → snapshot `kN` → **respaldo `recovery_backup.kN.json` el ÚLTIMO (corte)** → borrar el conjunto viejo empezando por **`recovery_backup.json` el PRIMERO**, luego puente, snapshot y blobs. Así nunca hay un conjunto a medias restaurable, y B basta desde que se confirma (tabla del §8).
* **Congelación** (de `freezing` al corte): la sincronización no sube respaldo ni snapshot y se niega a subir nombres de la generación vieja; se descongela con los nombres nuevos en el corte (M10). Borrar originales de la galería queda bloqueado mientras haya registro (A1).
* **Borrado solo por lista** (`rotation_old_files`, llenada al congelar con id y MD5) y con **huellas** del respaldo y del snapshot viejos: si algo cambió (otro dispositivo) o aparece un nombre gen 1 fuera de la lista → `blockedCorrupt`, 0 borrados (A5). 404 cuenta como éxito. Los dañados aceptados con "Omitir" se renombran a `lost_*` (M6), nunca se borran.
* Cancelar solo hasta `freezing` (nada re-cifrado): se borra el puente y lo local; el snapshot gen 1 recién subido se queda (es válido).
* Precondiciones duras para congelar (A4): sesión en la cuenta de inicio, red permitida, 0 subidas pendientes/en error. Cambio de cuenta y rotación son excluyentes; "Cerrar sesión de Google" desactivado durante la rotación.

## D62 · BD por copia (`sqlcipher_export`) con `rename` atómico; nunca crear una BD con bóveda; triggers de cardinalidad (v2 fase 1)
* La BD se re-cifra exportándola a `db/vault_secure.db.k<to>.tmp` (`ATTACH … KEY "x'hex'"` + `sqlcipher_export` + `user_version`), se verifica que abre con la llave nueva y la vieja NO, se guarda la original como `db.k<from>` y se reemplaza con `rename` atómico. No hay ningún instante sin BD. SQLCipher real probado en el emulador (`integration_test/db_rekey_sqlcipher_test.dart`).
* **Guarda C1:** con `vault.v1.db_created` la app nunca crea una BD vacía si falta el archivo (`VaultDatabaseMissingException`; reparación desde `.tmp`/`.k<from>`); el arranque (`VaultBootstrap.decide`) nunca descarta llaves si hay restos de una rotación.
* **Triggers de cardinalidad** (`rot_items_*`, `rot_folders_*`) creados al congelar y quitados al terminar; antes de cualquier paso destructivo se exige `COUNT == congelados + altas − bajas` y `rotation_state.rotationId == registro.id`. Una BD vacía, restaurada o de otra instalación no cuadra → bloqueo (`blockedCorrupt`/`blockedForeign`), nada se borra.

## D63 · Sin enlaces entre DEK; biometría apagada; `changePin` prohibido; regenerar B solo antes de confirmar (v2 fase 1)
* **No se guarda ningún enlace entre DEK** (ni `link_fwd` ni `link_bwd`): la DEK nueva solo existe envuelta con el PIN (`next_pin_envelope`) o con B (`next_recovery_backup`). Nada derivado del código anterior A la envuelve (test que recorre todo el almacén seguro). Mientras no se cambia la envoltura del PIN, la DEK nueva se mantiene **solo en memoria** (`RotationKeyStore.shared`), obtenida al preparar, al confirmar B o al desbloquear con PIN (segundo Argon2id que no cuenta intento); `lock()` la destruye.
* **Biometría:** se desactiva al entrar en `reencrypting` (el archivo guardaba la DEK vieja) y al terminar se ofrece "Reactivar huella o Face ID". Con huella, entrar en `reencrypting` pide el PIN.
* **`changePin` prohibido** mientras haya registro (M2); en Ajustes aparece desactivado con "Disponible al terminar el cambio de llave maestra".
* **Regenerar B** ("Ver otro código nuevo") solo en `prepared`; después de confirmar, B es definitivo (M1). "Comprobar mi código" (Ajustes > Seguridad) prueba un código contra el respaldo LOCAL vigente, sin red, y cuenta en el límite de intentos del código de recuperación.
* "Generar nuevo código de recuperación" ya no es solo re-envolver: con el servicio de rotación disponible abre la rotación completa (motivo "código nuevo"), porque si no el código anterior seguiría abriendo lo que ya está en Drive.

## D64 · Archivos SIN NINGUNA copia durante la rotación: "Continuar sin ellos" (v2 fase 1, 2026-11-18)
* **Dos categorías distintas al re-cifrar.** *Dañado* (hay copia, pero no abre o no coincide) → M6 sin cambios: "Omitir los dañados" deja la fila como perdida (`error`, gen nueva) y el blob viejo de Drive en cuarentena `lost_*`, nunca borrado. *Sin ninguna copia* (`ReencryptOutcome.missing`: el `.vault` local falta o no abre, y en Drive no hay copia registrada: sin `driveFileId` o 404) → nuevo "Continuar sin ellos".
* **Nunca se quita algo que todavía exista en Drive:** si el `.vault` de la generación vieja del item está en la lista exacta del conjunto viejo (`rotation_old_files`), aunque la fila no lo apunte, se clasifica como dañado (cuarentena).
* **"Continuar sin ellos"** vuelve a intentar cada item justo antes de actuar (si la copia apareció, se re-cifra y se queda) y, para los que siguen sin copia, borra lo local que quede (miniatura, `.vault` que no abre) y en UNA transacción la fila (condicional a `keyGen = fromGen`; el trigger cuenta la baja, así la cardinalidad sigue cuadrando), sus `item_tags` y sus trabajos `file`/`thumb` de la cola. Da igual que esté en la Papelera. **No se encola `delete_remote` ni se toca `rotation_old_files`:** lo que aún exista del item en Drive (su miniatura) es parte del conjunto viejo y se borra POR LISTA después del corte; borrarlo antes rompería "A restaura el conjunto viejo completo hasta el corte". Confirmación explícita: "se quitarán de la bóveda (también de la Papelera y de sus etiquetas) y NO se podrán recuperar".
* **"Reintentar"** sigue disponible (p. ej. un 404 que no era real o una copia que vuelve).
* **Nombres solo en pantalla.** La lista (`KeyRotationService.problems`, en memoria) lleva id y nombre para la UI; el registro de la rotación (y por tanto el Diagnóstico) guarda solo cuentas ("1 archivo(s) sin ninguna copia y 1 archivo(s) dañado(s)"). Tras reiniciar la app la lista se recalcula (`loadProblems`, necesita el PIN).
* **Un item sin ninguna copia no cuenta como pendiente** en las precondiciones A4 (`_nothingPending`) ni en la verificación de subida (`_unverified`): nunca podrá subirse y esperarlo atascaría la rotación para siempre. Corrige también un atasco latente: un perdido M6 de una rotación anterior (en `error`, sin archivo) impedía empezar la siguiente. La hoja previa cuenta los que ya se sabe que no tienen copia (`RotationPlan.noCopyItems`) y avisa, sin bloquear "Empezar".

## D65 · Bóveda adicional (señuelo, variante (a) «disimulo»): modelo, nombres y límites (v2 fase 8, 2026-11-18)
Diseño completo en `docs/DISENO_SENUELO.md` (revisado por un Opus independiente).
* Un SEGUNDO PIN abre una bóveda SEPARADA: otra DEK aleatoria, otros archivos (`Documents/alt/{vault,thumbs,db,vault_cache}`) y otra BD (`alt/db/vault_secure.db`). La de siempre es la **principal** (`VaultSlot.primary`) y NO cambia nada: mismas rutas, claves `vault.v1.*`, esquema v10 sin migración. En la UI se llama «Bóveda adicional» y solo aparece en Ajustes > Seguridad de la principal; nunca «señuelo».
* Claves nuevas: `vault.v1.alt.pin_envelope` (`WrapPurpose.altPin`, su presencia marca que existe) y `vault.v1.alt.db_created` (C1). Sin `alt.key_check` (sin biometría no hace falta).
* **No oculta** que hay dos bóvedas (eso era la variante negable, descartada): se ve en el disco, el Keychain, el espacio ocupado, Drive y los tiempos. Tabla de qué protege y qué no en `DISENO_SENUELO.md` §7 y en la propia pantalla.

## D66 · Desbloqueo: dos derivaciones en paralelo, un solo contador (C1), A2 y `reauthPrimary` (v2 fase 8)
* Con la app bloqueada y una adicional, las dos envolturas se derivan SIEMPRE y EN PARALELO (`Future.wait`) y se decide al terminar ambas: el tiempo no dice cuál abrió. Sin adicional es exactamente el camino de siempre (UNA derivación).
* Un solo contador (`vault.v1.pin_attempts`). **Solo acertar la principal lo pone a cero**; acertar la adicional devuelve el contador a su estado previo (`PinAttemptLimiter.rawState/restoreRaw`): intercalar su PIN no evita las esperas (C1).
* Una envoltura adicional ilegible o con otros parámetros de Argon2id (M3: deben ser los de la principal o los de la app) no se deriva: «Dañada», y la principal abre igual (G6).
* Con la sesión ABIERTA `unlockWithPin` solo prueba la envoltura de esa bóveda y nunca cambia de bóveda (A2); la pantalla de rotación usa `reauthPrimary`. Abrir la adicional no lee ni toca nada de la rotación. Tras la decisión la principal puede hacer un 3.er Argon2id (rotación en `prepared..freezing`): irrelevante, porque ya se ve qué bóveda se abrió.

## D67 · Aislamiento por bóveda: `VaultPaths`/`VaultDatabase` por bóveda, época de sesión y guardas (v2 fase 8)
* Sin raíz global mutable: `AppPaths` sigue siendo la principal (delega en `VaultPaths.primary`); la adicional usa `VaultPaths.secondary` y `VaultDatabase.secondaryInstance` (ruta y marca C1 fijas; con la otra bóveda abierta, `WrongVaultSlotError`).
* `VaultSession` tiene bóveda (`slot`) y época (`epoch`, cambia al bloquear y al abrir); las llaves de lectura van ligadas a la bóveda (`filesKeyFor(gen, slot)`, la principal por defecto: con la otra abierta, `null`). Toda operación larga (importar, regenerar, Papelera, caché, descargas, exportar, re-cifrar, `rekeyTo`, abrir la BD) captura un `SessionTicket` y lo comprueba antes de cada escritura; importación y regeneración se cancelan al bloquear. Arnés de cruce en `test/secondary/crossing_test.dart`.
* Ganchos de bloqueo comunes (`SessionHooks`): temporales en claro de las DOS raíces, streaming, diagnóstico, `ImageCache`. `excludeVaultFromBackup` excluye `alt/` solo si existe (no la crea).
* Guardas solo-principal: compuertas de sync, sin conexión, `onDataChanged`, migración y rotación (`PrimaryGates`); `SlotGuardedCloudStorage` lanza `CloudSlotException` en toda operación con la adicional abierta; repositorios de cola, migración y rotación usan la BD principal (que lanza).

## D68 · La bóveda adicional no tiene Drive ni código de recuperación (v2 fase 8)
* Vive solo en el teléfono. `recovery_backup*.json`, `vault_db*.snapshot` y los blobs de la principal quedan byte a byte igual (revisiones incluidas) y restaurables; el probe, la rotación (A5) y la migración no ven nada nuevo. Restaurar en otro teléfono trae solo la principal. Si se pierde el teléfono o su PIN, su contenido se pierde (se avisa al crearla). Para una llave nueva: eliminar y crear otra.
* Descartada en esta fase (posible «8b»): respaldo con prefijo `alt_` en el mismo appDataFolder (exige código propio, prefs, restauración con elección y migración; mostraría la misma cuenta de Google). `CloudNames.parse` ya ignora `alt_*`.

## D69 · Biometría solo para la principal y sin diálogo automático (v2 fase 8)
* Face ID / la huella abren SOLO la principal. Al crear la adicional, si están activos se ofrece «Desactivar (recomendado)» y se apagan ANTES de escribir su envoltura (M5); la pantalla avisa si conviven. Con una adicional, la pantalla del PIN no lanza sola la biometría (solo con su botón).

## D70 · Interfaz de la adicional neutra (v2 fase 8)
* Ajustes reducido: Autobloqueo, Bloquear ahora, Calidad de video, Regenerar miniaturas, Etiquetas, Papelera y Acerca de (privacidad neutra). Sin Cambiar PIN (C2), biometría, Proteger pantalla, código, rotación, «Comprobar mi código», sincronización, borrar originales, caché, sin conexión ni Diagnóstico.
* `VaultUiMode.cloudless` (lo fija la raíz al abrir/bloquear) oculta el estado de subida («En este teléfono»), «sin conexión», el borrado de originales y cualquier mención a la nube en hojas y errores (M8: «Este archivo no está disponible.»). Test que recorre la pantalla y falla ante palabras prohibidas.
* Servicios propios (`VaultServices.secondary()`, una instancia por proceso; sus cachés y lotes se vacían/cancelan al bloquear) y servicios/Ajustes recalculados por bóveda en cada desbloqueo (`main.dart`, M7).

## D71 · Reglas del PIN adicional y cambio solo desde la principal (v2 fase 8)
* 6 dígitos, distinto del principal y a ≥ 2 posiciones de él; con un principal heredado de 4–5 dígitos, no puede empezar por él (M6: un «Entrar» temprano abriría la principal). Mensaje neutro: «Ese PIN no está disponible. Elige otro.».
* `changePin` de la principal rechaza un PIN que abra la adicional (solo igualdad; la distancia 1 no se comprueba, B3).
* El PIN de la adicional se cambia SOLO desde la principal (PIN principal + PIN actual de la adicional, que cuenta en el mismo límite): dentro de la adicional no hay oráculo (C2). Crear y eliminar exigen la principal abierta y su PIN; eliminar borra la envoltura PRIMERO (con relectura), luego la marca y `alt/`.
* Arranque (`reconcileSecondaryAtStartup`, 5 estados del §9): sin principal se borra todo lo `alt`; sin envoltura y con `alt/`, se borra `alt/`; con envoltura y sin `alt/`, se borran las claves; «Dañada» nunca se borra sola; un error al leer el almacén no borra nada (M4). `discardLocalKeys`/`commitRestore` no tocan `alt.*` (lo reconcilia el arranque).

## D72 · Contador «37/120 archivos» del aviso de rotación, sin estado nuevo (v2 fase 1, pendientes)
* El avance se **deriva de lo ya persistido**, sin columnas ni migración (la BD sigue en v10): `RotationRepository.progress()` cuenta en `vault_items` los que ya están en `toGen` (**hechos**) y de ellos los `syncStatus = en_nube` (**subidos**), contra la cardinalidad esperada de `rotation_state` (`frozenItems + altas − bajas`). Así sobrevive a reiniciar la app y refleja los items quitados con «Continuar sin ellos» (D64) o las altas del usuario.
* `KeyRotationService.progress` (`ValueNotifier<RotationProgress?>`) se refresca tras cada item re-cifrado, en cada ronda de subida y al cambiar de fase; con la BD cerrada conserva el último valor (nunca lanza) y sin rotación vale `null`. `rotationCounter(fase, avance)` da el texto: «Re-cifrando: N/T archivos» (re-cifrado, cuenta hechos) o «Subiendo: N/T archivos» (subida, cuenta subidos); en el resto de fases y bloqueos no hay cifras. Lo usan el aviso (`RotationBanner`, cuadrícula y Ajustes) y la barra de la pantalla de rotación (la cifra en memoria queda de respaldo).
* El contador solo cuenta; no decide nada (ninguna guarda lo lee).

## D73 · Borrar los datos de la cuenta de Google anterior desde la hoja previa (M7, v2 fase 1, pendientes)
* Botón «Borrar datos de la cuenta anterior» en la hoja previa de la rotación, **solo si** hay `migration.v1.old_account_kept` y su correo **no es el de la cuenta actual** (`RotationPlan.oldAccountKept` ya lo filtra). Confirmación explícita (borrado permanente, sin papelera ni versiones; la cuenta actual no se toca).
* `KeyRotationService.deleteOldAccountData()`: exige bóveda **principal** abierta, **sin rotación** (registro ni bucle), sin cambio de cuenta y sin otra limpieza en curso; usa `CloudStorage` (en la app, `SlotGuardedCloudStorage`, que además corta con la secundaria abierta). Pausa la sincronización normal (`pausedForMigration`) para que NADA se suba a la cuenta anterior mientras esté iniciada; cierra sesión, abre el selector y **comprueba que el correo elegido es el guardado y distinto del actual ANTES de borrar nada** (si no, 0 borrados); borra solo nombres reconocidos por `CloudNames.parse` (nada ajeno a Vault); quita la marca M7 solo si terminó; y **siempre** vuelve a la cuenta actual (también si falla o se cancela). Reutiliza la idea de `AccountMigrationService.deleteOldAccountData` (D52) pero sin necesitar un cambio de cuenta en curso.
* Límite: si el selector de Google se cancela al volver a la cuenta actual, queda sin sesión y se pide «Inicia sesión con X» (la bóveda y Drive no se tocan).

## D74 · Limpieza manual de generaciones abandonadas (M11, v2 fase 1, pendientes)
* Botón «Limpiar restos de cambios de llave» en la hoja previa (solo cuando NO hay rotación). Dos pasos: vista previa (`scanLeftovers`, solo lee) con cifras (archivos y MB en Drive, archivos locales) y, tras confirmar, `cleanLeftovers`.
* **Drive** (`GenerationSweeper`): (a) generaciones **mayores** que la vigente **sin `recovery_backup.kN.json`** (`findAbandoned`/`sweepAbandoned`: restos de una rotación cancelada o de otra rama que nadie puede restaurar); (b) generaciones **menores** con la guarda existente de `sweep` (solo si el conjunto vigente está completo y es el de este teléfono; si no, no borra nada de (b) y lo dice). Nunca toca la cuarentena `lost_*` (M6), una generación mayor que SÍ tiene respaldo (otra rama viva), ni nombres ajenos a Vault.
* **Teléfono:** `<id>[.kN].vault|thumb` de un item que existe pero cuya generación no es la de su fila (`keyGen`). No toca archivos de ids sin fila (barrido de huérfanos aparte) ni `.part`.
* **Nunca durante una rotación:** se rechaza (vista previa incluida) si hay registro de rotación, bucle en marcha, cambio de cuenta u otra limpieza, y se vuelve a comprobar justo antes de borrar; mientras limpia, `start()` de la rotación se niega. Solo la bóveda principal.
* Límite honesto: no puede saber si OTRO teléfono está rotando en este momento (sus `.kN` sin respaldo aún parecerían abandonados); por eso el texto de confirmación pide no hacerlo si se está cambiando la llave desde otro teléfono.

## Fase 11: Kern (nombre visible e ícono)
* Nombre visible «Kern» en iOS (`CFBundleDisplayName` y `CFBundleName`) y Android (`android:label`). NO cambian `PRODUCT_BUNDLE_IDENTIFIER` ni el `applicationId` (`com.saumnty.vault`), ni los textos internos ni la configuración de Google Cloud.
* Ícono generado con `flutter_launcher_icons` 0.14.4 (versión exacta, última estable publicada) desde `assets/icon/kern.png` (1024×1024, RGB sin transparencia, fondo #7C3AED, «>|<» blanco con margen amplio). Android adaptive: fondo `#7C3AED` y `assets/icon/kern_foreground.png` (símbolo blanco en transparente, dentro del 66 % central). iOS: `remove_alpha_ios: true`.
* El script de generación del PNG vive fuera del repo (scratchpad); los PNG fuente sí están en `assets/icon/`.

## D75 · Tag de cuenta por archivo (BD v11) y «Verificar copia en la nube» (cambio de cuenta atascado, parte A, 2026-11-18)
Diseño en `docs/DISENO_MIGRACION_ATASCADA.md` (§B.2, §C.2). Resuelve D35 («un `en_nube` de otra cuenta se da por subido para siempre»).
* **BD v11 estrictamente incremental** (`VaultSchema.addAccountTagSchema`, `if (from < 11 && to >= 11)`): `ALTER TABLE vault_items ADD COLUMN cloudAccountTag TEXT` y `thumbAccountTag TEXT` (con comprobación por `PRAGMA table_info`), `CREATE TABLE IF NOT EXISTS vault_meta(key, value)` y `diag_events(id, at, level, category, message)` (la tabla del diagnóstico persistente se crea YA para no necesitar una v12; vacía hasta la parte B). Ninguna fila se toca: tras actualizar, todos los tags son `NULL` (= «sin comprobar»). `migration_state`/`migration_items` intactas. Misma migración en la BD de la bóveda adicional. Restauración: acepta v6–v11; con un snapshot v11 vacía `diag_events` y pone los tags a `NULL`. `rekeyTo` cuenta también `vault_meta` y `diag_events` (la sal sobrevive a la rotación).
* **Tag = `hex(SHA-256(sal ‖ "google:" ‖ id estable))`** (`CloudAccountTagger`; `CloudStorage.currentAccountId` = `GoogleSignInAccount.id`; sin id, el correo en minúsculas con otro prefijo). Sal de 32 bytes en `vault_meta.account_salt`, creada al PRIMER uso (no en la migración). Nunca se registra ni el correo ni el tag.
* **Quién escribe el tag:** la subida verificada (`markCloudVerifiedIf`/`setThumbDriveFileIdIf` con el tag capturado AL EMPEZAR; si al terminar la cuenta es otra, `SyncAccountChangedException`: no se registra y el trabajo vuelve a pendiente sin contar intento) y la verificación. Lo ponen a `NULL`: `resetForUpload`, `restoreOldRefs`, la rotación (`swapItemGeneration`, `markItemLost`), regenerar miniatura y la restauración.
* **Respaldo de llaves por cuenta:** en lugar de `sha@tag` en una sola clave (diseño), se guarda el tag aparte (`sync.v1.recovery_uploaded_tag`): mismo efecto (otra cuenta ⇒ se vuelve a subir aunque nadie llame a `signOut`) y la rotación y la restauración, que solo escriben el SHA, no provocan una resubida extra. Igual para el snapshot (`sync.v1.snapshot_uploaded_tag`).
* **Guardas ligadas (mismo cambio):** la caché (`CacheManager.accountTag`) solo purga items con `cloudAccountTag` igual al de la sesión; sin sesión no purga nada; `CacheStats.unverifiedCount` alimenta «N pendientes de comprobar (no se tocan)» en Almacenamiento, «Vaciar caché» y «Liberar espacio sin conexión». `cloudVerifier` (borrar originales) exige el tag actual y no actúa con pausa de migración o verificación. `flushSnapshotBeforeLock` no sube con `pausedForMigration`, con una verificación en curso ni a una cuenta distinta de la del último snapshot.
* **`CloudVerificationService.verify()`** (`lib/data/sync/cloud_verification_service.dart`): precondiciones (principal abierta por ticket, sin rotación, sin migración, sesión, red/Wi-Fi), pausa de la sincronización puesta de forma SÍNCRONA al lanzarla (`pausedForVerification`) y quitada siempre; espera a la sincronización en curso (30 s). Un solo `list()`. Respaldo: falta ⇒ se sube; con el mismo nombre y otro MD5 ⇒ **otra bóveda: se para sin cambiar nada** y la sincronización no lo reemplaza en esa cuenta (`recoveryBackupBlockedTag`, en memoria). Por item (Papelera incluida): id con tamaño+MD5 ⇒ tag; si no, mismo nombre con tamaño+MD5 ⇒ se adopta; si no y hay `.vault` local ⇒ `pendiente` sin referencias (re-sube la sincronización con su verificación; `findByName`+`replaceFileId` reemplaza un mismo nombre con otro MD5: no es un borrado); si no ⇒ `error` («sin copia en ninguna parte», la fila y sus referencias se conservan). Miniaturas igual (con copia local se compara su MD5; sin copia en ningún sitio se olvida la ruta para que la regeneración la rehaga). Escrituras condicionales (misma generación, ruta e id remoto) en lotes con transacción, comprobando sesión y cuenta entre lotes; snapshot «sucio» al final (se sube cuando las referencias ya son correctas). **Cero llamadas a `delete`/`rename`** (comprobado en los tests).
* **Cuándo corre:** botón en Ajustes > Sincronización y cuenta (muestra el correo y el resultado; «No disponible» con un cambio en curso), sola al abrir la bóveda si hay sesión y algún item «en la nube» sin tag o con otro (tras actualizar, todos), tras «Cancelar y quedarme» y tras `SyncService.signIn` (`afterSignIn`). La rotación no empieza mientras verifica.
* Límites: el resultado y el bloqueo «otra bóveda» viven en memoria (diagnóstico persistente = parte B); un cambio de cuenta iniciado durante los segundos de una verificación no se impide (sí la rotación).

## D76 · «Cambio de cuenta sin terminar» al abrir, `abandonStayOnCurrent` y apertura sin fallos silenciosos (parte A, 2026-11-18)
* **Pantalla** `UnfinishedMigrationScreen`: la raíz (`HomeVaultScreen`, una por desbloqueo) la muestra si hay un cambio guardado y no corre. Fase en lenguaje claro, cuenta anterior y actual (correos SOLO en pantalla), «La sincronización está en pausa. N archivo(s) no tienen copia comprobada en la cuenta actual», **Continuar** (pantalla del cambio + `resume()`), **Cancelar y quedarme en «cuenta actual»** (sin sesión: «Inicia sesión primero», abre el selector sin tocar el cambio), «Volver a la cuenta anterior» (`cancelAndRestore`, con aviso) y «Ahora no» (sigue en pausa; la fila de Ajustes muestra la fase).
* **Cambio respecto al diseño:** al abrir NO se reanuda nada solo (antes `downloading/checkingNew/uploading/finalizing` se retomaban en silencio): el usuario elige en la pantalla (§C.3: «no se reanuda nada ni se purga nada antes»). Cuesta un toque por desbloqueo en un cambio largo; a cambio, nunca corre sin que se vea.
* **`abandonStayOnCurrent()`** (distinto de `cancelAndRestore`, nunca pide otra cuenta): sesión en la cuenta ANTERIOR ⇒ restaura las referencias guardadas (si las hay) y termina; en OTRA cuenta ⇒ con referencias guardadas conserva las actuales (las de la nueva), sin ellas pone todos los tags a `NULL`; sin sesión ⇒ `MigrationException`. Siempre quita las guardas y lanza la verificación (`onAbandoned`). No borra nada (`MigrationRepository.finishKeepingCurrentRefs`).
* **Fase desconocida:** `MigrationPhase.unknown` (antes caía en `downloading` en silencio); no ejecuta nada, deja un mensaje y solo ofrece «Cancelar y quedarme».
* **`resume()`** captura también `on Object`: log («Cambio de cuenta detenido por un error», solo el tipo) y `lastError` genérico; nunca un `StateError`/`PlatformException`/`FormatException` sin rastro.
* **Apertura (`onUnlocked`)**: `runUnlockSteps` (`lib/features/vault/unlock_sequence.dart`) aísla cada paso en su try/catch con log; orden: migración (`refresh()`, pausa sync y caché) → rotación → verificación → temporales → Papelera → sin conexión → caché → miniaturas → reanudar rotación. La sincronización de la raíz corre DESPUÉS de `onUnlocked` (antes corría primero, sin la guarda en un arranque en frío).

## D77 · Ajustes muestra la fase del cambio de cuenta (parte A, 2026-11-18)
* La fila «Cambio de cuenta en curso» dice «Fase: <fase>. La sincronización está en pausa.» (distingue `signInNew` de `checkingNew`, §C.0). Las guardas y mensajes de «Sincronizar ahora»/«Cerrar sesión», el banner de la cuadrícula, el diagnóstico persistente y el mensaje de restauración quedan para la parte B (D78–D82).
* Efecto colateral del generador: añade a `Contents.json` del AppIcon tres tamaños iPad legacy (50, 57, 72) y el `pubspec.lock` gana las dependencias transitivas del generador. Se revirtió a mano `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS`, que el generador cambió de `YES` a `AppIcon` (ajeno a esta fase).

## D78 · «Sincronizar ahora» y «Cerrar sesión» sin fallos silenciosos (parte B §B.4, 2026-11-18)
* **`SyncService.run` devuelve `SyncRunOutcome`** (`completed`, `alreadyRunning`, `locked`, `otherVault`, `paused(+motivo)`, `noAccount`, `offline`, `waitingWifi`, `quotaFull`, `cancelled`, `failed(+mensaje)`) y `syncRunMessage` da el texto. Cada bloqueo deja un evento en el Diagnóstico (`Sincronización no iniciada: <tipo> (<motivo>)`): las pasadas manuales siempre; las automáticas solo cuando cambia el motivo (sin ruido).
* **Motivo de la pausa** (`SyncPauseReason`: `migration`, `verification`, `rotationMaintenance`) en `SyncService.pauseReason` y en `SyncSummary.pauseReason`. **Desvío del diseño:** en lugar de sustituir `pausedForMigration` por un campo único, se conservan los booleanos (ahora con setter que publica) y se añade `pausedForAccountCleanup` para M7 (antes usaba `pausedForMigration`); `pauseReason` se deriva con prioridad migración > mantenimiento > verificación. Menos cambio, mismo efecto y los tests existentes siguen valiendo.
* **Guardas comunes** (`SyncService.accountActionBlock` + `lib/features/sync/sync_actions.dart`): Ajustes y la hoja de la cuadrícula usan las mismas. `signIn`/`signOut` del servicio lanzan `SyncAccountActionBlockedException` con un cambio de cuenta, un mantenimiento M7, una rotación registrada o una verificación en curso (la sesión nunca se cambia «por fuera»). En la hoja, «Iniciar/Cerrar sesión» durante un cambio de cuenta cierran la hoja y abren su pantalla (sin terminar → «Cambio de cuenta sin terminar»; corriendo → la del cambio). En Ajustes «Cerrar sesión» lleva el motivo como subtítulo y el toque abre una hoja con el motivo y «Ver cambio de cuenta»; «Iniciar sesión» con un cambio sin terminar lleva a su pantalla. «Sincronizar ahora» se puede tocar siempre: subtítulo con la pausa y SnackBar con el resultado («Ver» en la pausa del cambio de cuenta, «Detener» si ya corre). En la hoja, el resultado se muestra dentro de ella (una SnackBar quedaría debajo) y con una pasada en curso aparece «Detener la sincronización» (`SyncService.stop`, salida si se cuelga). Barrido: ninguna `SettingsTile` con `onTap: null` sin subtítulo (se añadió el de «Vaciar caché» y «Liberar espacio» ocupados).
* **Selector de Google con plazo** (`lib/data/cloud/guarded_sign_in.dart`, `GuardedSignIn`): 3 min por defecto (bajo el tope de 5 min de la suspensión del autobloqueo); al vencer, `CloudSignInTimeoutException` («El selector de Google no respondió… si se repite, cierra Kern del todo»); `abandon()` libera en el acto (lo llama `AccountMigrationService.pause()`, es decir «Pausar» y el bloqueo). Un resultado tardío se ignora y se registra; **desvío:** la sesión que deje NO se cierra (podría ser de un intento más nuevo); la siguiente ronda mira la sesión actual como siempre. Límite honesto: google_sign_in 6.3.0 encola las llamadas, así que un selector nativo colgado puede colgar también el siguiente intento; por eso el mensaje dice cerrar la app. Lo usan la migración (`_signInNew`, `signInCurrent`, `cancelAndRestore`, `deleteOldAccountData`) y `SyncService.signIn`. Registra abierto / cancelado / fallido (tipo) / sin respuesta / sesión iniciada / sesión cerrada (`auth`, sin correo ni id).
* **Migración**: `resume()` y `chooseAnotherAccount()` con el flujo en marcha lanzan `MigrationException` («ya está en curso… toca Pausar») en vez de volver en silencio. Antes de cada archivo de la descarga y de cada ronda de la subida/finalización se compara la sesión con la cuenta que espera la fase (`oldEmail`/`newEmail`, en memoria, sin minúsculas/mayúsculas); si no coincide: pausa con mensaje, **0 descargas como «ausente» y 0 subidas a otra cuenta**. Sin la cuenta esperada guardada no se puede comprobar y sigue como antes. Transiciones de fase y retornos sin hacer nada (`no hay ninguno`, `bóveda no disponible`) al Diagnóstico. `deleteOldAccountData` en try/finally (como D73): siempre vuelve a la cuenta nueva y la cancelación del selector da «No elegiste ninguna cuenta: no se borró nada.».

## D79 · Aviso de la nube en la cuadrícula y «al día» honesto (parte B §B.3, 2026-11-18)
* `SyncSummary.cloud` (`CloudCopyCounts`, de `VaultDataRepository.cloudCopyCounts`, una sola consulta sobre `vault_items`): `localOnly` (`pendiente`/`subiendo` o `error` sin referencia remota), `unverified` («en la nube» con tag nulo o de otra cuenta), `noCopy` (`error` con referencia remota = lo que la verificación no encontró en ninguna parte). Se recalcula en cada publicación del resumen; sin proveedor de tags (pruebas antiguas) no cuenta «sin comprobar».
* **`CloudStatusBanner`** (`lib/features/sync/cloud_status_banner.dart`, lógica pura en `cloudBannerFor`): un solo aviso, prioridad **cambio de cuenta** («Ver») > (con rotación registrada, el aviso propio de la rotación y este no) > **comprobando… N/T** > **N sin copia en ninguna parte** («Verificar copia») > **sin cuenta de Google** > **«Tus archivos no tienen copia en la nube»: N sin comprobar en esta cuenta** («Verificar copia») > **«Tus archivos no tienen copia en la nube»: K solo están en este teléfono + motivo** («Ver» abre la hoja) > **en pausa: <motivo>**. **Desvío del orden del diseño:** «sin copia en ninguna parte» y «sin cuenta» suben por delante de «sin comprobar»/«solo en el teléfono» (lo más grave primero; sin sesión todo está «sin comprobar» y el aviso útil es «inicia sesión»). `Semantics(liveRegion)`, sin correos, nada en la adicional (`VaultUiMode.cloudless`).
* El icono de la barra (`SyncCloudButton`/`syncSummaryLabel`) y la hoja (`syncPhaseText`) dejan de decir «al día» con pausa, archivos sin comprobar o pendientes en `vault_items`; los conteos de la hoja son cola ∪ `vault_items` (`pendingTotal`, `errorTotal`); `SyncSummary.upToDate` es la única definición.

## D80 · Diagnóstico persistente cifrado (parte B §B.5, 2026-11-18)
* `DiagnosticsStore` (`lib/core/logging/diagnostics_store.dart`), enganchado al búfer como `sink`: lotes cada 2 s, serializados, en `diag_events` (BD SQLCipher de la principal; tabla creada en v11), anillo de **500** (`DELETE … WHERE id <= MAX(id) - 500`). Mismas entradas ya saneadas que el búfer. Escribe directo en la BD (no marca «sucio» el snapshot). Un fallo se ignora y nunca se registra a sí mismo.
* **Solo la principal:** con la adicional abierta las entradas se descartan; con la sesión bloqueada se guardan en memoria y se escriben al siguiente desbloqueo de la principal (paso «diagnóstico» de `onUnlocked`, el primero); al cambiar de bóveda (`DiagnosticsBuffer.slotChanged`, desde `AuthController`, B5) lo pendiente se descarta. Al instalarse recoge lo que el búfer ya tenía (arranque).
* **Suspendido** mientras la BD se re-cifra o se copia (`VaultDatabase.isBusyForCopy`): una escritura a mitad de la copia del snapshot la rompería y la verificación de `rekeyTo` cuenta filas.
* **Fuera de la nube:** `exportEncryptedSnapshot` abre la COPIA con la misma llave, borra `diag_events` y hace `VACUUM` (sin páginas libres con eventos); si no puede, borra la copia y falla (no se sube con el diagnóstico). La restauración ya la vaciaba (D75).
* La pantalla Diagnóstico lee tabla + pendientes, muestra el **estado de la nube** (fase del cambio de cuenta, sesión sí/no, motivo de la pausa, conteos de archivos y de la cola, última verificación; sin datos) y tiene **«Borrar diagnóstico»** con confirmación (tabla, pendientes y memoria). Al bloquear la memoria se sigue vaciando; la tabla queda (cifrada).

## D81 · Restauración: el mensaje dice qué encontró (parte B §B.6, 2026-11-18)
* `RestoreService.probe` calcula, del mismo `list()`, un `CloudInventory` (respaldos y sus generaciones, puentes, índices con generaciones y bytes, `.vault`/`.thumb` con bytes, cuarentena, ajenos): solo conteos y tamaños. **Desvío:** `probe()` sigue devolviendo `RestoreProbeResult` (muchos llamadores y tests) y el inventario queda en `lastInventory`.
* `describeRestoreProbe(resultado, inventario)` da título y texto: vacía → «Esta cuenta no tiene ningún dato de Kern»; índice sin respaldo → «Falta el respaldo de tus llaves: Solo hay una copia de la base de datos (120 KB) en esta cuenta, pero falta el respaldo de la llave… Si tu bóveda sigue en otro teléfono, ábrela allí…» (con archivos/miniaturas si los hay); incompleto e inválido con sus cifras. Log `Restauración: <resultado>; respaldos=…, índices=…, archivos=…` (solo números).

## D82 · iOS en la parte B
* Sin cambios de Swift. Todo el comportamiento nuevo es Dart; el plazo del selector cubre la hipótesis de iOS (§A.3.6) sin APIs nuevas de google_sign_in (6.3.0 no tiene sesión efímera ni `loginHint` en `signIn()`). Sin probar en el iPhone.

## D83 · Diagnóstico persistente sin esperas sin fin ni fallos silenciosos (BUG-1 del emulador, 2026-11-18)
* **Defecto (demostrado con una prueba sobre el código anterior):** `flush()` esperaba sin tope a `_flushing`. Si UNA escritura no terminaba nunca (apertura de la BD o transacción que no vuelve), todos los `flush()` siguientes y `entries()` (lo que lee la pantalla) se quedaban esperando para siempre, **aunque la BD volviera a responder**. La pantalla se quedaba en lo que tenía la memoria al abrirla y nunca se refrescaba. Además, el paso «diagnóstico» de `onUnlocked` era el PRIMERO y se esperaba: con él colgado, la guarda del cambio de cuenta, la verificación, la papelera, la caché, etc. no corrían (ni registraban nada). Los errores al escribir se tragaban sin dejar rastro.
* **Qué se cambió (`DiagnosticsStore`):** cada operación con la BD tiene tope (`opTimeout`, 10 s); una operación que lo supera se da por colgada y nadie más la espera, pero no se empieza otra encima (sin duplicados): si termina bien, quita su lote de pendientes. Un fallo conserva lo pendiente (hasta 500), cuenta el intento y reintenta solo con espera creciente (2 s·2ⁿ, tope 1 min), sin esperar a que llegue otro evento. Escritura, lectura y «Borrar» son exclusivas entre sí. «Borrar diagnóstico» pone el estado a cero.
* **Estado visible:** `DiagnosticsStore.health` (`DiagnosticsStoreHealth`: sin guardar, intentos fallidos, NOMBRE del tipo del último error o «tiempo agotado», descartados por el límite, lectura fallida). La pantalla Diagnóstico lo muestra en rojo («El diagnóstico no pudo guardar N eventos (…; M intentos). Se reintenta solo.») y lo incluye en «Copiar». Al volver a guardar se relee la tabla. Nunca se registra en el búfer (sin recursión) y nunca lleva mensajes de error (podrían llevar rutas).
* **`onUnlocked`:** el paso «diagnóstico» lanza el `flush()` SIN esperarlo. **Búfer:** `takeUndelivered()`. El almacén solo recoge al engancharse lo que se registró sin destino; antes recogía todo `entries`, y un almacén re-creado volvía a guardar lo que el anterior ya tenía (duplicados).
* Sin cambios de esquema (v11 igual). La causa exacta de que se colgara en el emulador no se ha confirmado (ver REPORTE).

## D84 · Miniaturas en la Papelera (v2.1)
* `TrashEntry` lleva ahora la fila del archivo (`item`, `null` en carpetas). `TrashScreen` recibe el MISMO `ThumbnailLoader` de la cuadrícula (`VaultServices.thumbnailLoader` = `EncryptedThumbnailLoader` con LRU de 96) y pinta cada archivo con `ThumbnailView` (64×64): miniatura con fundido, ícono de respaldo por tipo si no hay o falla, y en videos ▶ + duración (el widget ya lo hacía). Las carpetas conservan su ícono (no hay patrón de mosaico en la cuadrícula). Sin cambios de esquema (v11 igual) ni de logs.
* **Las miniaturas no se purgan mientras el item está en la Papelera (revisado, no hizo falta código):** `CacheManager` solo purga `.vault` (nunca `thumbs/`), la Papelera solo marca filas, no hay barrido/GC de `thumbs/` fuera de rotación y restauración (ambos recorren todas las filas), y «Regenerar miniaturas que faltan» usa `getAllItems()` (incluye la Papelera: si falta una, se rehace, lo que ayuda). El borrado definitivo sigue como en D56 (el `FileCleaner` borra `.vault` y `.thumb`). Tests: `test/v21_test.dart`.

## D85 · Búsqueda por etiqueta (v2.1)
* `ItemFilter.text` casa ahora con el nombre del archivo O con el nombre de CUALQUIERA de sus etiquetas, sin distinguir mayúsculas ni acentos. Se combina en Y con `tagIds`, tipo y fechas (esos filtros y la semántica «TODAS las etiquetas» no cambian). La Papelera sigue excluida (`deletedAt IS NULL`).
* **Sin migración:** la normalización se hace en Dart (`TagRepository.fold`: minúsculas + quitar acentos y marcas combinantes; `ñ` NO equivale a `n`). La consulta SQL ya no lleva el `LIKE`: filtra por papelera/fechas/etiquetas y, solo si hay texto, trae una columna calculada `matchTagNames` (`group_concat` de los nombres de sus etiquetas); el texto se compara en Dart. Coste: O(archivos vivos) por búsqueda con texto, aceptable para una bóveda personal.
* Efecto lateral aceptado: la búsqueda por nombre de archivo también ignora acentos (antes `LIKE NOCASE` solo ignoraba mayúsculas ASCII). `likeEscape` se eliminó (`%` y `_` son literales).
* **Controlador (`VaultBrowserController`):** con filtros activos la BD aplica el texto (nombre o etiqueta) y `entries` ya no vuelve a filtrar archivos por nombre (eso descartaba los que casaban solo por etiqueta). Sin filtros la cuadrícula sigue filtrando la carpeta actual en memoria: coincide por nombre (ya sin acentos) o porque el id está en `_tagMatchIds`, que calcula `TagRepository.itemIdsByTagText` (mejor esfuerzo; si falla queda la búsqueda por nombre; se refresca al cambiar el texto, al recargar y al (des)etiquetar con búsqueda activa; una respuesta tardía se descarta). Las carpetas siguen casando solo por nombre.
