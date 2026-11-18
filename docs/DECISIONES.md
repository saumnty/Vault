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
