# Vault

Bóveda cifrada de fotos, videos y archivos para **Android e iOS** (Flutter), con respaldo opcional en tu propio Google Drive (carpeta oculta `appDataFolder`). Todo se cifra en el dispositivo antes de guardarse o subirse.

## Cómo funciona (resumen)

- **Llaves:** una DEK aleatoria de 256 bits. El PIN (Argon2id) y un código de recuperación de 24 caracteres (Argon2id) envuelven cada uno una copia de la DEK. El PIN **nunca** protege nada que salga del teléfono. La biometría guarda la DEK en el Keystore/Keychain del sistema. Subllaves HKDF para la base de datos, los archivos y las miniaturas.
- **Archivos:** formato `.vault` v2 (AES-256-GCM por bloques de 1 MiB, con encabezado, índice y bandera de bloque final autenticados).
- **Base de datos:** SQLCipher con llave derivada de la DEK.
- **Nube:** cola persistente con reintentos, verificación de tamaño + MD5 y respaldo del código de recuperación (envuelto) y de la base de datos cifrada.
- **Video:** streaming descifrado al vuelo por un servidor loopback; sin copias en claro en disco.
- **Seguridad del sistema:** autobloqueo, `FLAG_SECURE` (Android), cobertura en multitarea e exclusión del respaldo de iCloud (iOS).

Detalles y decisiones: [docs/CONTEXTO.md](docs/CONTEXTO.md), [docs/DECISIONES.md](docs/DECISIONES.md), [docs/DISENO.md](docs/DISENO.md), estado en [docs/PLAN.md](docs/PLAN.md) y resultados/hallazgos en [docs/REPORTE.md](docs/REPORTE.md).

## Requisitos

- Flutter **3.41.6** (Dart 3.11.4). No subas dependencias que exijan un SDK mayor sin revisar `docs/DECISIONES.md`.
- Android: Android Studio + SDK. La primera compilación descarga un JDK 17 (toolchain foojay) y los binarios de libsodium (verificados por SHA-512).
- iOS: se compila en Codemagic (no hace falta Mac local), ver más abajo.

## Compilar y ejecutar (Android)

```bash
flutter pub get
flutter run -d <dispositivo>                 # debug
flutter build apk --debug
flutter build apk --release                  # firmado con la llave de release si existe android/key.properties
```

**Comando de release recomendado** (R8 + ofuscación de Dart; verificado en la regresión final, ver `docs/REPORTE.md` F10/Regresión final):

```bash
flutter build apk --release --obfuscate --split-debug-info=build/symbols
```

Guarda `build/symbols/` fuera del repo (ya está ignorado por `build/`) para desofuscar trazas. Verifica la firma con `apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk` (SHA-1 esperada en la sección de firma). Cuidado: sin `android/key.properties` el build se firma con la llave debug.

Emulador (en Windows con WHPX, el arranque fiable es con GPU por software):

```bash
emulator -avd Pixel_7 -no-snapshot -gpu swiftshader_indirect
```

Opciones de depuración (`--dart-define`):

| Define | Efecto |
|---|---|
| `VAULT_ALLOW_SCREENSHOTS=true` | Desactiva `FLAG_SECURE` en builds **no release** (para capturas con adb). Se ignora en release. |
| `VAULT_AUTOLOCK_MS=15000` | Fija el tiempo de autobloqueo (solo no release). |
| `VAULT_VIDEO_STREAMING=false` | Fuerza descifrado completo antes de reproducir video. |
| `VAULT_AES_BACKEND=dart` | Fuerza AES-GCM en Dart (por defecto nativo con respaldo). |
| `VAULT_CACHE_LIMIT=<bytes>` | Límite de caché para pruebas (solo debug). |
| `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_WEB_CLIENT_ID` | IDs OAuth (tienen valor por defecto en `lib/core/config/google_config.dart`). |

## Pruebas

```bash
flutter analyze
flutter test                                  # unitarias, widgets y goldens
flutter test --update-goldens test/ui/goldens # regenerar goldens (copiar a docs/screens si cambian)
flutter test integration_test/<archivo> -d <emulador>   # SQLCipher y AES nativo (requieren dispositivo)
```

`tokens_test` impide colores o tamaños literales fuera de `lib/core/theme/`.

## Google Drive (OAuth)

Proyecto de Google Cloud con Drive API y scope `drive.appdata`. El cliente Android se resuelve por package (`com.saumnty.vault`) + SHA-1 del certificado de firma: hay que registrar la SHA-1 de **debug** y la de **release** (ver `docs/REPORTE.md`). El cliente iOS y el Web están en `lib/core/config/google_config.dart`.

## Firma de release (Android)

`android/key.properties` (no versionado) apunta a un keystore **fuera del repo**. Sin ese archivo el build cae a la llave debug. Haz copia de seguridad del keystore y de `key.properties`: sin ellos no podrás publicar actualizaciones.

## iOS (Codemagic + Sideloadly)

`codemagic.yaml` genera un `.ipa` **sin firmar** (`ios-unsigned`) que se instala con Sideloadly (firma con tu Apple ID). Pasos y checklist de pruebas en el iPhone: sección final de `docs/REPORTE.md`.

## Depurar en iPhone desde Windows (libimobiledevice)

Sin Mac, el log del sistema y los reportes de cierre (crash) del iPhone se leen desde Windows con [libimobiledevice](https://libimobiledevice.org/). Todo lo de esta sección se verificó contra la documentación y el código fuente oficiales (ver "Fuentes").

**Qué hay que saber antes**
- La app **no escribe nada en el log del sistema en builds de release** (el logger central solo imprime en depuración y nunca registra PIN, códigos, rutas ni nombres de archivo). Por eso `idevicesyslog` sirve sobre todo para ver errores del sistema y de plugins; para lo que hace la app usa **Ajustes > Acerca de > Diagnóstico** (copiar o compartir) y los reportes de cierre.
- El log del iPhone puede traer datos del dispositivo y de otras apps: revísalo antes de compartirlo.

**Instalación en Windows**
- La documentación oficial **no ofrece binarios para Windows**: en la página de descarga solo hay tarballs de código fuente. El método oficial es compilar con **MSYS2** ("Using MSYS2 is the official way of compiling this project on Windows").
- Prerrequisitos (shell *MSYS2 MinGW 64-bit*): `pacman -S base-devel git mingw-w64-x86_64-gcc make libtool autoconf automake-wrapper`.
- La página oficial indica un script de compilación (`limd-build-msys2.sh`, enlazado desde https://libimobiledevice.org/). No se revisó el contenido de ese script: léelo antes de ejecutarlo.
- Requisito de Apple: según la documentación, "usbmuxd is currently not fully supported on Windows" y hace falta el paquete **Apple Mobile Device Support** (parte de iTunes). Si el controlador USB de "Apple Devices" (Microsoft Store) sirve como alternativa **no está verificado** en la documentación.
- En el iPhone: conéctalo por cable y pulsa "Confiar en este equipo". (Que el Modo desarrollador no haga falta para leer el syslog **no está verificado**.)

**Ver el dispositivo**

```powershell
idevice_id -l          # lista los UDID de los dispositivos conectados por USB
idevice_id -n          # los disponibles por red
```

**Log del sistema (`idevicesyslog`)**

```powershell
idevicesyslog                              # todo el log (Ctrl+C para parar)
idevicesyslog -p Runner                    # solo mensajes del proceso Runner (la app)
idevicesyslog -p Runner -o runner.log      # y guardarlo en un archivo (lo sobrescribe)
idevicesyslog -m Vault                     # solo mensajes que contengan "Vault"
idevicesyslog -q                           # excluye procesos ruidosos comunes
idevicesyslog -u <UDID>                    # elegir dispositivo concreto
idevicesyslog pidlist                      # pid y nombre de los procesos en ejecución
```

Opciones verificadas en el fuente (`tools/idevicesyslog.c`): `-u/--udid`, `-n/--network`, `-x/--exit`, `-d/--debug`, `-o/--output FILE`, `--no-colors`, `--colors`, filtros `-m/--match`, `-M/--unmatch`, `-t/--trigger`, `-T/--untrigger`, `-p/--process` (acepta nombres o PID), `-e/--exclude`, `-q/--quiet`, `-k/--kernel`, `-K/--no-kernel`. El nombre del proceso de la app instalada con Sideloadly es el ejecutable de la app (`Runner` en este proyecto); si no ves nada, prueba `idevicesyslog pidlist` para confirmar el nombre real. Alternativa sin opciones del propio programa: `idevicesyslog | Select-String -Pattern "Runner|Vault"` en PowerShell.

**Reportes de cierre (`idevicecrashreport`)**

```powershell
mkdir crashes
idevicecrashreport crashes                 # copia los reportes a ./crashes y los BORRA del iPhone
idevicecrashreport -k crashes              # copia sin borrarlos del iPhone
idevicecrashreport -k -f Runner crashes    # solo los que coinciden con "Runner" (distingue mayúsculas)
idevicecrashreport -e -k crashes           # además extrae el reporte en bruto a archivos .crash
```

Opciones verificadas (`tools/idevicecrashreport.c`): `-u/--udid`, `-n/--network`, `-e/--extract`, `-k/--keep`, `-d/--debug`, `-f/--filter NAME`, `--remove-all`. La extensión y el formato exacto de los archivos que deja en la carpeta **no están verificados** en la documentación. Para analizar un cierre de la app, comparte el reporte (sin datos personales) y, si el build era ofuscado, los símbolos `build/symbols/` del mismo build.

**Fuentes** (leídas el 2026-11-16): https://libimobiledevice.org/ · https://github.com/libimobiledevice/libimobiledevice · `tools/idevicesyslog.c`, `tools/idevicecrashreport.c` y `tools/idevice_id.c` de ese repositorio.

## Estructura

```
lib/
  core/        config, crypto, session, security, services, streaming, theme
  data/        cloud, sync, restore, gallery, models, repositories
  features/    auth, onboarding, vault, viewer, sync, settings, gallery
  shared/      widgets, navegación, utilidades
docs/          contexto, plan, decisiones, diseño, reporte, capturas
```
