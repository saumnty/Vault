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

