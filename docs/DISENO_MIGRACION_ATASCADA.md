# Diseño: cambio de cuenta atascado y verificación de la copia en la nube

Estado: **diagnóstico y diseño, sin código** (2026-11-18). Rama `dev-claude`.
Origen: bug real en el iPhone (datos reales; hoy el iPhone es la única copia de 2 fotos).
Regla de este documento: nunca correos, rutas de datos del usuario, nombres de archivo, PIN ni tokens. Se dice «cuenta principal» y «cuenta de pruebas».

Leyenda: **[H]** = hecho visto en el código (con archivo y función) · **[Hip]** = hipótesis (encaja con los síntomas, no se puede confirmar sin mirar el teléfono).

---

## 0. Síntomas y explicación corta

| Síntoma en el iPhone | Explicación | Tipo |
|---|---|---|
| Nunca apareció Borrar/Conservar | Esos botones solo existen en la fase `askDeleteOld` (`account_migration_screen.dart`, `_active`). El flujo no llegó al final. | [H] |
| «Sincronizar ahora» de Ajustes no hace nada | `SyncService.run` empieza con `if (pausedForMigration && !force) return;` y el botón es `() => unawaited(sync.run(manual: true))`, sin mensaje (`settings_screen.dart`, `_syncSection`). | [H] |
| «Cerrar sesión de Google» de Ajustes no hace nada | `onTap: migrating \|\| _rotating ? null : _signOut`. `SettingsTile` con `onTap == null` solo pone el icono en gris; el título sigue en rojo y no hay subtítulo ni mensaje. | [H] |
| Hoja de Sincronización «al día», 0 pendientes | Los contadores salen SOLO de `sync_queue` (`SyncQueueRepository.counts`). Las filas se crean en `_reconcile`, que corre dentro de `run`; con la pausa nunca corre. Antes de `uploading` la migración no toca `vault_items`, así que las fotos siguen `en_nube`/`en_cache` con el `driveFileId`/`cloudMd5` de la cuenta de pruebas, y nada comprueba que existan en la cuenta actual. | [H] |
| Restaurar con la principal: «No hay respaldo en esta cuenta» | `RestoreService.probe` devuelve `noBackup` si no hay NINGÚN `recovery_backup*`/puente, aunque haya snapshot u otros archivos. La principal no tiene respaldo de llaves. | [H] |
| ~120 KB de datos ocultos en la principal | `flushSnapshotBeforeLock` sube el snapshot de la BD al bloquear y **no mira `pausedForMigration`** ni la cuenta. Con la sesión ya en la principal, cada bloqueo con cambios pudo subir el snapshot. Un snapshot sin respaldo de llaves sale como `noBackup`. | [H] el camino existe · [Hip] que esos 120 KB sean eso |
| Diagnóstico perdido al bloquear | `SessionHooks` registra `DiagnosticsBuffer.instance.clear` al bloquear. El búfer solo vive en memoria. | [H] |
| «Inicio/cierre de sesión» en el Diagnóstico | Ningún `VaultLog` registra el inicio ni el cierre de sesión de Google. Lo que se vio debieron de ser `Cambio de cuenta iniciado`, `Sincronización iniciada/terminada` o `Cambio de cuenta en pausa (<tipo>)`. | [H] no hay ese log · [Hip] lo que se leyó |

**Causa más probable [Hip, muy consistente]:** quedó un cambio de cuenta en una fase anterior a la subida, casi seguro `signInNew` (o `checkingNew`/`blocked*`), con la sesión de Google ya en la cuenta principal. Así quedaron la pausa de la sincronización y la de la caché, y las referencias de la cuenta de pruebas. Secuencia más verosímil:

1. «Empezar» → `downloading` (las fotos ya estaban en el teléfono; no baja nada) → `signInNew`.
2. `_signInNew` cierra la sesión de la cuenta de pruebas y abre el selector. El selector se cancela o falla (`sign_in_canceled`/`sign_in_failed`), o se elige la misma cuenta. Queda `signInNew` con `lastError`, sin sesión y sin reanudación automática (`_autoResumable` excluye `signInNew`).
3. Ajustes deja de mostrar la cuenta y muestra «Iniciar sesión con Google» (o la hoja de la cuadrícula, que no tiene ninguna guarda). Se inicia sesión con la principal por ese botón, **fuera de la migración**: `SyncService.signIn` → `run(manual: true)` → retorno silencioso por la pausa.
4. Desde entonces: sesión en la principal, `migration_state` vivo, sincronización en pausa, nada subido, contadores a 0. Ajustes solo muestra la fila «Cambio de cuenta en curso», fácil de pasar por alto.

Hay una variante con `checkingNew`: una excepción que no es `CloudException` (ver §A.3) deja la fase sin `lastError` y se reintenta en silencio en cada desbloqueo. Para distinguir las variantes, la fila «Cambio de cuenta en curso» de Ajustes muestra la fase (ver §C.0).

---

## A. Máquina de estados persistida (tal como está hoy)

### A.1 Qué se guarda y dónde

| Dónde | Qué | Vida |
|---|---|---|
| BD SQLCipher, `migration_state` (1 fila, `id = 1`) | `phase`, `oldEmail`, `newEmail`, `startedAt`, `updatedAt`, `neededBytes`, `downloadTotal`, `downloadDone`, `lastError` | De `begin()` a `clear()`. Sobrevive a matar la app, bloquear y reinstalar encima. |
| BD, `migration_items` | Por item: `oldStatus`, `oldDriveFileId`, `oldCloudMd5`, `oldCloudSize`, `oldThumbDriveFileId` | Solo tras `resetForUpload` (entrada a `uploading`). |
| Memoria | `status` (ValueNotifier), `_running`, `_token`, `_cancelRequested`; `SyncService.pausedForMigration`; `CacheManager.suspended` | Se pierde al matar la app. Se recalcula **solo** con `refresh()`/`resume()`/`start()`. |
| Almacén seguro (prefs) | `recoveryUploadedSha` (se vacía en `signInNew` y en `uploading`); `old_account_kept` (al «Conservar») | Persistente. |

### A.2 Etapas e interrupciones

Se reanudan solas al desbloquear (`VaultServices.onUnlocked` → `refresh()` + `resume()` si `_autoResumable`): `downloading`, `checkingNew`, `uploading`, `finalizing`. Esperan al usuario: `signInNew`, `blockedOtherVault`, `blockedQuota`, `askDeleteOld`.

| Etapa | Qué hace / guarda | Cierre de app | Bloqueo | Fallo de red | Inicio/cierre de sesión a mitad (hoja de Sincronización) | Cancelar el selector |
|---|---|---|---|---|---|---|
| `downloading` | Baja de la cuenta vieja lo que no está en el teléfono; `downloadDone` por item; al final pasa a `signInNew`. | Fila intacta; se reanuda al desbloquear. | `pause()` cancela el token; `_Cancelled`/`_Stop`; se reanuda. | `_pause` + `lastError` «Se reanudará al volver la red». **[H] Es falso mientras sigue desbloqueada: la migración no escucha la red**; solo se reanuda al desbloquear o con «Reanudar». | **[H] Peligroso:** si la sesión cambia a otra cuenta, los `getMetadata`/`download` dan 404, se cuentan como «ausente» y el flujo sigue. En `signInNew`, `current != old` acepta esa cuenta como la nueva sin selector. | n/a |
| `signInNew` | Si la sesión es la vieja: `signOut()` y SHA del respaldo a `''`. Guarda el aviso como `lastError` y abre `cloud.signIn()`. | Si el selector nativo ya terminó, `signInSilently` restaura la nueva; si no, queda sin sesión. Fila `signInNew`. **No se reanuda sola.** | Suspensión del autobloqueo (máx. 5 min). Si se bloquea igualmente, el `migration.update` posterior puede encontrar la BD cerrada → `StateError` **no capturado** (§A.3). | `CloudSignInFailedException`/sin red → `CloudException` → `lastError` + log `Cambio de cuenta en pausa (tipo)`. | Iniciar sesión por la hoja con otra cuenta funciona, pero la sincronización sigue en pausa y nada lo dice (**el caso del iPhone**). | `lastError` «No elegiste ninguna cuenta», `_Stop`, **sin sesión**, sin log. Misma cuenta: `signOut` + «Elegiste la misma cuenta», sin log. |
| `checkingNew` | `list()` (respaldos ajenos) y `findByName`/cuota → `uploading` o `blocked*`. | Se reanuda. | Se reanuda. | `lastError`; se reanuda al desbloquear. | Usa la cuenta que haya en ese momento. | n/a |
| `uploading` | **Una vez:** `resetForUpload` en una transacción (guarda las referencias viejas, deja `pendiente`/`error`, borra referencias, **vacía `sync_queue`**). Después hasta 40 rondas de `sync.run(force: true)`. | Se reanuda (`hasSavedRefs` → `retryErrors`). | Se reanuda. | `_pause` (offline/Wi-Fi/sesión). | **[H] `_upload` no comprueba la cuenta:** si la sesión cambia, sube a la cuenta que haya. Cerrar sesión → `needsSignIn` → pausa. | n/a |
| `finalizing` | Comprueba respaldo + snapshot en la nueva; si faltan, los encola y sube. | Se reanuda. | Se reanuda. | `_pause`. | Igual que arriba. | n/a |
| `askDeleteOld` | Espera Borrar/Conservar. | Espera. | Espera. | Al borrar: error genérico. | — | **[H]** `deleteOldAccountData` hace `signOut()` y luego `signIn()`. Si se cancela, sale `CloudSignInCancelledException` (no `MigrationException`): la pantalla dice «No se pudo completar», queda **sin sesión** y en `askDeleteOld`. |
| `blocked*` | Espera «Elegir otra cuenta» o «Cancelar». | Espera. | Espera. | — | — | `chooseAnotherAccount` → `signInNew` → mismo caso que arriba. |

`cancelAndRestore` (cualquier fase salvo `askDeleteOld`): restaura las referencias viejas, cierra sesión y pide la cuenta VIEJA. Si se elige otra: `signOut` y `MigrationException`; la fila sigue. **En este iPhone la cuenta vieja (pruebas) está vacía:** cancelar devolvería unas referencias que ya no existen.

### A.3 Cómo puede quedar «activa» sin pantalla visible [H]

1. **No hay ningún aviso fuera de Ajustes.** La migración no tiene banner en la cuadrícula (la rotación sí: `RotationBanner` en `home_vault_screen.dart`). `onUnlocked` solo hace `refresh()`/`resume()` y nunca navega a ninguna pantalla.
2. **Cuatro fases esperan al usuario sin decírselo:** `signInNew`, `blocked*` y `askDeleteOld`.
3. **Retornos silenciosos:**
   - `SyncService.run`: `if (pausedForMigration && !force) return;` (y `if (_running ...)`, `if (!isUnlocked()) return;`).
   - `AccountMigrationService.resume`: `if (_running) return;`, `if (ticket == null) return;`, `if (first == null \|\| stale()) return;`.
   - `chooseAnotherAccount`: `if (_running) return;`.
   - `SyncService.signIn`: `on CloudSignInCancelledException { return; }`.
   - En Ajustes, `onTap: null` sin explicación (Cerrar sesión) y `unawaited(sync.run(...))` sin mensaje (Sincronizar ahora).
4. **Excepciones que escapan sin log ni `lastError`:** `resume()` solo captura `_Cancelled`, `_Stop` y `CloudException`. Escapan sin dejar rastro un `StateError` (BD cerrada a mitad), un `PlatformException` del almacén seguro (`prefs.setRecoveryUploadedSha`), un `FormatException`, etc. El `finally` publica el estado sin mensaje y la fila no cambia: en `checkingNew` se reintenta en silencio en cada desbloqueo.
5. **Orden en `onUnlocked`:** `temp.sweep`, `trash.purgeExpired`, `offline.reconcile` y **`cache.enforce()` corren ANTES de `migration.refresh()`**, sin try/catch entre pasos. En un arranque en frío:
   - la caché purga con `suspended == false`, aunque haya una migración en la BD;
   - si un paso anterior lanza, `refresh()` no se llama: no hay pausa, no hay fila en Ajustes y la sincronización corre con referencias de otra cuenta.
6. **[Hip] Selector de Google colgado en iOS.** Si el `Future` de `GoogleSignIn.signIn()` no completa (selector descartado por el sistema, presentación fallida), `_running` queda en `true` durante todo el proceso. Desde entonces «Elegir cuenta nueva»/«Reanudar» no hacen nada, y `refresh()` no actualiza `status` (`else if (!_running)`). Solo se arregla matando la app.

### A.4 Por qué Sincronizar / Cerrar sesión no dan mensaje; diferencias de iOS

- **[H]** Las dos guardas de §0. En la hoja de la cuadrícula, «Cerrar sesión» **no tiene guarda** (`sync_sheet.dart`, `_account`: `_sync.signOut()` directo) y «Iniciar sesión» tampoco. Las dos pantallas se contradicen.
- **[H]** `GoogleDriveCloudStorage.signOut` en iOS es local (`GIDSignIn signOut`) y no revoca nada. `signIn` va envuelto en `AutoLockSuspension.run`: ASWebAuthenticationSession deja la app en `inactive` (no bloquea), pero si el usuario sale a otra app pasa a `paused` (tope de 5 min).
- **[Hip] iOS:** después de `signOut`, la sesión web de Google (cookies del navegador del sistema) puede preseleccionar la última cuenta usada. El usuario «elige» sin querer la misma cuenta o cancela el aviso del sistema («… quiere usar google.com para iniciar sesión»). Las dos salidas acaban en `signInNew` con `_Stop`. google_sign_in 6.3.0 no expone una sesión efímera ni un `loginHint` en `signIn()` (comprobar en pub.dev antes de suponer otra cosa).

### A.5 Cómo pudo marcarse «al día» con items `en_nube` sin archivos en la cuenta nueva

- **[H]** Antes de `uploading`, ninguna fase toca `vault_items`. Las referencias (`driveFileId`, `cloudMd5`, `cloudSize`, `thumbDriveFileId`) siguen siendo las de la cuenta de pruebas y el estado sigue `en_nube`/`en_cache`.
- **[H]** No existe ninguna comprobación de «este `driveFileId` es de la cuenta actual». `_reconcile` solo encola `pendiente`/`subiendo` y miniaturas sin `thumbDriveFileId`. Un `en_nube` de otra cuenta se considera subido para siempre, también sin migración: es el riesgo D35, documentado y nunca resuelto.
- **[H]** «al día» = `sync_queue` vacía. Con la pausa la cola nunca se rellena. Incluso en `uploading`, `resetForUpload` vacía la cola y, si `sync.run(force: true)` no llega a reconciliar (otro `run` en marcha, sesión bloqueada), la hoja muestra 0 aunque haya items `pendiente`. Por eso «al día» no descarta del todo `uploading`. Lo que distingue el caso es el icono de cada foto en la cuadrícula: nube = `en_nube`/`en_cache`, flecha = `pendiente`.
- **[H]** Lo que sí protege: `cloudVerifier` (borrar originales) consulta `getMetadata` en la cuenta actual: con un id de otra cuenta da 404 y devuelve `false`.

---

## B. Diseño

Principio común: **ningún estado bloqueante puede existir sin estar a la vista, y todo botón desactivado dice por qué.** Todo es solo de la bóveda principal (D67) y respeta la exclusión con la rotación (D61).

### B.1 Pantalla «Cambio de cuenta sin terminar» al desbloquear

**Comportamiento**
- Nuevo `MigrationGate` (ValueNotifier derivado de `migration.load()`) que se calcula **lo primero** en `onUnlocked`, antes de cualquier purga, y también en `refresh()`.
- Si hay fila y el flujo no está corriendo (`!_running` o colgado, ver §B.4), la raíz (`main.dart`/`home_vault_screen.dart`) empuja **una vez por desbloqueo** `UnfinishedMigrationScreen`:
  - Título «Cambio de cuenta sin terminar». Fase en lenguaje claro. Cuenta anterior y cuenta actual: correos **solo en pantalla**, nunca en `VaultLog` ni en `lastError`. Hoy `lastError` puede llevar el correo vía `MigrationException('… $old')`: no debe persistirse.
  - Qué pasa ahora: «La sincronización está en pausa. N archivos no tienen copia comprobada en la cuenta actual».
  - **Continuar** → `resume()` (o el selector si la fase lo exige).
  - **Cancelar y quedarme en «cuenta actual»** → nueva operación `abandonStayOnCurrent()`, distinta de `cancelAndRestore`:
    - Si la cuenta actual es la vieja → como `cancelAndRestore` (restaura las referencias y termina).
    - Si la cuenta actual es otra:
      - si hay `migration_items`, se conservan las referencias actuales (las de la nueva);
      - si no hay, se marcan **todos** los items como «por verificar» (tag `NULL`, §B.2);
      - después `migration.clear()`, quitar las guardas y lanzar **Verificar copia en la nube** de inmediato. No se restauran referencias de una cuenta en la que ya no estamos.
    - Sin sesión → el botón dice «Inicia sesión primero» y abre el selector.
  - «Volver a la cuenta anterior» (`cancelAndRestore`) queda como opción secundaria, con aviso si la verificación ya vio que esa cuenta no tiene los archivos.
- **Invariante:** `migration_state != null ⇒` la pantalla abierta, o el banner de §B.3 visible en la cuadrícula **y** la fila de Ajustes con la fase. El test lo comprueba fase por fase.
- La reanudación automática sigue en las fases sin decisión, pero **con la pantalla visible** (o el banner con progreso). Nunca en silencio.

**Archivos:** `lib/features/vault/vault_services.dart` (`onUnlocked`: orden y try/catch por paso), `lib/main.dart` o `home_vault_screen.dart` (navegación), `lib/features/settings/unfinished_migration_screen.dart` (nuevo), `account_migration_service.dart` (`abandonStayOnCurrent`, `resume` con `on Object`), `account_migration_screen.dart` (fila con la fase).

**Casos límite**
- Bloqueo con la pantalla abierta: al desbloquear se vuelve a mostrar.
- Secundaria abierta: no se muestra nada (D70: la secundaria no puede saber de la nube).
- Rotación registrada a la vez (no debería, D61): mostrar las dos, con la rotación bloqueada.
- Fila con una fase desconocida: hoy `fromDb` cae en `downloading` en silencio. Debe registrarse y mostrarse como «estado desconocido», con solo «Cancelar y quedarme».
- Sin red: «Continuar» dice por qué no avanza.

**Tests:** widget del gate por cada fase × (con/sin sesión, cuenta igual/distinta a la vieja); `abandonStayOnCurrent` antes y después de `resetForUpload` (sin restaurar referencias de otra cuenta; verificación encolada); `onUnlocked` con la caché por encima del límite y migración en la BD (**no purga**); un paso anterior que lanza no impide `refresh()`; `resume()` con `StateError`/`PlatformException` deja `lastError` y log; ningún correo en `DiagnosticsBuffer` (barrido por regex).

### B.2 «Verificar copia en la nube»

**Identificador de cuenta (BD v11)**
- `accountTag = hex(SHA-256(salt ‖ "google:" ‖ idEstable))`, con `idEstable` = `GoogleSignInAccount.id` (id estable de Google; `CloudAccount` gana el campo `id` y `CloudStorage` un `currentAccountId`). Si no hay id, el correo en minúsculas.
- `salt`: 32 bytes aleatorios en una nueva tabla `vault_meta` (clave `account_salt`), creada en v11.
- **Por qué hash con sal aunque la BD sea SQLCipher:**
  1. La BD sale del teléfono como snapshot a Drive y como copia en la rotación (`rekeyTo`).
  2. Las filas acaban en pruebas, exportaciones y diagnósticos.
  3. Solo hace falta comparar igualdad, no saber el correo.
  4. La sal vive en la BD: sobrevive a la rotación de la DEK (un HMAC con subllave de la DEK cambiaría al rotar y forzaría una verificación) y viaja en el snapshot, así que tras restaurar con la misma cuenta el tag coincide.

  No se cifra aparte: la BD ya va cifrada y un tag no es reversible sin la sal. `migration_state.oldEmail/newEmail` siguen en claro dentro de la BD porque la pantalla los necesita; se borran con `clear()`.
- Columnas nuevas en `vault_items`: `cloudAccountTag TEXT` (cuenta del `.vault`) y `thumbAccountTag TEXT` (cuenta de la `.thumb`). `NULL` = sin comprobar (todas las filas tras la actualización).
- `markCloudVerifiedIf` y `setThumbDriveFileIdIf` reciben el tag de la cuenta **capturado al empezar el trabajo**. Si la cuenta cambió durante la subida, no se marca: el trabajo se repite.
- `recoveryUploadedSha` pasa a guardarse como `sha@tag`. Un cambio de cuenta fuerza la resubida aunque nadie llame a `signOut`.

**Algoritmo `CloudVerificationService.verify()`** (nuevo, `lib/data/sync/cloud_verification_service.dart`)
1. Precondiciones: principal abierta (ticket), sin rotación, sin migración (salvo llamada desde `abandonStayOnCurrent`), sesión iniciada, red permitida (Wi-Fi si está «solo Wi-Fi»). La sincronización normal se pausa mientras dura, con un motivo visible (§B.4).
2. **Un solo `cloud.list()`** del appDataFolder → índice por id y por nombre (puede haber duplicados). Solo lee.
3. **Respaldo de recuperación** (`CloudNames.recoveryBackupFor(gen)`): debe existir uno con el MD5 del JSON local. Si no, se vacía el SHA y se encola `recoveryBackup`. Con respaldos de **otra** bóveda, se detiene sin subir nada y se muestra el mismo aviso que `blockedOtherVault`.
4. **Snapshot** (`dbSnapshotFor(gen)`): si falta (o el tag de la última subida no es el actual), `markDirty` + encolar `dbSnapshot`, que se sube al final, cuando las referencias ya son correctas.
5. **Por cada item** con `.vault` subido o supuestamente subido (`en_nube`, `en_cache`, `sin_conexion` con `driveFileId`, y los de la Papelera, que también se restauran):
   - **OK:** el `driveFileId` está en el listado con `size == cloudSize` y `md5 == cloudMd5` → se pone `cloudAccountTag = actual`.
   - **Reparable:** no está por id, pero hay un archivo con el nombre esperado (`CloudNames.file(id, gen: keyGen)`) y el mismo tamaño + MD5 que la fila (ese MD5 se comprobó contra la copia local al subir) → se adopta ese id y el tag.
   - **Falta y hay `.vault` local** → `pendiente`, `driveFileId/cloudMd5/cloudSize = NULL`, `cloudAccountTag = NULL`, se encola `file`. Se sube con la verificación habitual.
   - **Falta y NO hay copia local** → `error` con motivo «Sin copia en ninguna parte». La fila no se borra; se cuenta y se muestra.
   - **Miniatura:** igual con `thumbDriveFileId`. Si falta y hay `.thumb` local → `thumbDriveFileId = NULL` (la recoge `getItemsNeedingThumbUpload`). Sin `.thumb` local, la regeneración la rehace.
   - Todas las escrituras son condicionales (misma `keyGen`/ruta, como M4), en lotes con transacción, comprobando el ticket entre lotes.
6. Se reanuda la sincronización (`run(manual: true)`). Resultado persistido (§B.5) y visible: «Comprobados N · K vuelven a subirse · L sin copia en ninguna parte».

**Cuándo corre**
- Botón en Ajustes > Sincronización y cuenta.
- Sola al desbloquear (después del gate de §B.1) si hay sesión y existe algún item «en la nube» con `cloudAccountTag IS NULL OR != tag actual`. Tras v11 todos son `NULL`, así que **la primera apertura con sesión verifica todo**: eso arregla el iPhone sin pedirle nada al usuario.
- Tras `SyncService.signIn` con una cuenta distinta de la de los tags.

**Ligado a la seguridad de los datos (obligatorio en el mismo cambio)**
- `CacheManager._enforce` solo purga items con `cloudAccountTag == tag actual` (no nulo). Sin sesión o sin verificar, no purga nada. «Vaciar caché» y «Liberar espacio sin conexión» dicen «N archivos pendientes de comprobar no se tocan».
- `cloudVerifier` (borrar originales) exige además el tag actual.
- `flushSnapshotBeforeLock` no sube con `pausedForMigration`, con una verificación en curso ni con el tag de la sesión distinto del de la última subida.

**Casos límite**
- Duplicados con el mismo nombre: se elige el que coincide en MD5; los demás no se tocan.
- Item de otra generación (rotación terminada): se usa el nombre de su `keyGen`.
- Archivo en Drive con el nombre correcto y otro MD5: no se adopta, se re-sube (la subida usa `findByName` + `replaceFileId` y lo reemplaza con el contenido local verificado; eso no es un borrado).
- Lista paginada enorme: se pagina dentro de `list()`.
- Bloqueo a mitad: se para; lo ya escrito es coherente por item y se retoma al desbloquear.
- Sesión que cambia a mitad: se compara el tag al principio y al final; si cambió, se descarta el resultado.
- Cuota llena al re-subir: `quotaFull` normal, visible.

**Tests** (`test/cloud_verification_test.dart`, con `MultiAccountCloud` de `rotation_extras_test.dart`): `en_nube` de la cuenta A verificado en la B → `pendiente` + re-subida + tag B; reparable por nombre; sin copia local → `error` sin borrar la fila; miniaturas; respaldo y snapshot ausentes → encolados; respaldo de otra bóveda → se detiene sin subir; **cero llamadas a `delete`/`rename`** en el fake (comprobado); bloqueo en cada `await`; caché sin purga con tags nulos; `cloudVerifier` con un tag distinto → `false`; flush al bloquear con pausa → no sube; arranque v10→v11 con datos → todos `NULL` → la verificación se dispara sola.

### B.3 Aviso en la cuadrícula

`CloudStatusBanner` en `home_vault_screen.dart`, junto a `RotationBanner`. Un solo aviso, por prioridad:
1. «Cambio de cuenta sin terminar» → abre §B.1.
2. «Comprobando tu copia en la nube… N/T».
3. «K archivos solo están en este teléfono: subiéndolos a tu cuenta» (desaparece al terminar).
4. «L archivos sin copia en ninguna parte» (peligro; persiste mientras existan).
5. «Sin cuenta de Google: tu bóveda no se respalda».
6. «Sincronización en pausa: <motivo>» (§B.4).

Cada aviso lleva `Semantics(liveRegion)`, textos sin correos y nada en la secundaria (`VaultUiMode.cloudless`). El icono de nube de la barra (`SyncCloudButton`) deja de decir «al día» si hay pausa, items sin verificar o `pendiente` en `vault_items`. El conteo pasa a ser `cola ∪ items pendiente/subiendo/error`, no solo la cola.

**Archivos:** `lib/features/vault/home_vault_screen.dart`, `lib/features/sync/cloud_status_banner.dart` (nuevo), `sync_cloud_button.dart`, `sync_service.dart` (`SyncSummary` con `pauseReason` y `unverified`).
**Tests:** un widget test por estado y por prioridad; ninguno en el modo secundario; barrido de palabras prohibidas (D70); «al día» imposible con `pendiente` en `vault_items` o con la pausa activa.

### B.4 Sincronizar / cerrar sesión sin fallos silenciosos (iOS incluido)

- **`SyncService.run` devuelve `SyncRunOutcome`** (`started`, `alreadyRunning`, `locked`, `paused(reason)`, `noAccount`) y el campo `pausedForMigration` pasa a `pauseReason` (`migration`, `rotationMaintenance`, `verification`). Los usos actuales (rotación M7, migración) ponen y quitan su motivo. Toda llamada manual muestra un mensaje según el resultado: «En pausa: hay un cambio de cuenta sin terminar» con la acción «Ver».
- **Ajustes y la hoja de la cuadrícula, con las mismas guardas**, compartidas en un helper:
  - Cerrar sesión durante una migración: la fila tiene subtítulo «No disponible: termina o cancela el cambio de cuenta» y el toque abre una hoja con el motivo y «Ver cambio de cuenta». Nunca `onTap: null` sin subtítulo.
  - En la hoja de la cuadrícula, «Cerrar sesión» e «Iniciar sesión» durante una migración **llevan a la pantalla de la migración** en lugar de cambiar la sesión por fuera.
- **Migración y cuenta:** `_download`, `_upload` y `_finalize` comparan el tag de la sesión con el esperado (vieja o nueva) antes de cada ronda. Si no coincide: `_pause('La sesión de Google cambió…')`, sin bajar como «ausente» ni subir a otra cuenta.
- **Selector colgado (iOS):** el selector se ejecuta con un contador de intentos. Si al volver a `resumed` el `Future` no ha terminado tras 60 s, se libera `_running` para ese intento, se guarda `lastError` «El selector de Google no respondió; vuelve a intentarlo» y, si el `Future` viejo completa más tarde, se ignora su resultado (si dejó una sesión no esperada, se cierra). `resume()`/`chooseAnotherAccount()` con `_running` lanzan `MigrationException('Ya está en curso')` en lugar de `return`.
- **Cancelación del selector:** se registra (`VaultLog.d('Selector de Google cancelado', category: 'auth')`) y el mensaje dice qué hacer en iOS: «Si aparece la cuenta anterior, toca *Usar otra cuenta*». No se inventan APIs: google_sign_in 6.3.0 no tiene sesión efímera; antes de añadir algo, comprobar en pub.dev.
- **Logs nuevos (sin datos):** inicio/cierre de sesión (`auth`), selector abierto/cancelado/fallido (tipo), transición de fase de la migración (nombre de la fase), `run` bloqueado (motivo), resultado de la verificación (conteos).
- **`onUnlocked`:** cada paso en su try/catch con log y la migración/verificación primero.
- **`deleteOldAccountData` (migración):** en `try/finally` como D73, volver siempre a la cuenta nueva y convertir la cancelación en un mensaje propio.

**Archivos:** `sync_service.dart`, `settings_screen.dart`, `sync_sheet.dart`, `account_migration_service.dart`, `google_drive_cloud_storage.dart` (log del selector), `key_rotation_service.dart` (`pauseReason`).
**Tests:** cada botón deshabilitado tiene subtítulo (barrido de `SettingsTile(onTap: null)` sin `subtitle`); `run` con cada motivo devuelve el resultado correcto y Ajustes muestra el mensaje; la hoja de la cuadrícula durante una migración no llama a `signOut`; cambio de sesión durante `downloading`/`uploading` → pausa, 0 «ausentes» y 0 subidas a la otra cuenta; selector que nunca completa → libera, mensaje y resultado tardío ignorado.

### B.5 Diagnóstico persistente cifrado (500 eventos)

- **BD v11, misma migración:** `diag_events(id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, level TEXT NOT NULL, category TEXT NOT NULL, message TEXT NOT NULL)`. Anillo de 500: después de cada lote de inserciones se ejecuta `DELETE FROM diag_events WHERE id <= (SELECT MAX(id) FROM diag_events) - 500`.
- **Escritura:** `DiagnosticsBuffer` sigue igual (memoria, `sanitize`) y gana un *sink* `DiagnosticsStore`:
  - escrituras en lote cada ~2 s, serializadas;
  - **solo con la principal abierta**; en la secundaria no se persiste nada (D70);
  - eventos con la sesión bloqueada (p. ej. el flush tras bloquear): se guardan en memoria y se vuelcan al siguiente desbloqueo de la principal;
  - nunca llama a `onDataChanged`, así que el diagnóstico no marca sucio el snapshot;
  - **suspendido durante `rekeyTo`**, porque la verificación de la copia cuenta filas por tabla;
  - un error al escribir se ignora (y nunca se registra a sí mismo).
- **Fuera de la nube y de la restauración:** `exportEncryptedSnapshot` hace `DELETE FROM diag_events` en la COPIA antes de subirla, y la restauración vacía la tabla, igual que `migration_*` (D51).
- **Al bloquear:** la memoria se vacía como hoy; la tabla persiste (cifrada). La pantalla Diagnóstico lee la tabla (y la memoria reciente) y tiene un botón **Borrar** con confirmación (`DELETE` + `clear()`). «Copiar» sigue exportando con `sanitize`.
- **Estado de la nube en el Diagnóstico (solo lectura, sin datos):** fase de la migración o «ninguna», `hasSavedRefs`, items por `syncStatus`, cuántos sin tag o con un tag distinto, motivo de pausa, último resultado de la verificación.

**Archivos:** `vault_database.dart` (v11), `lib/core/logging/diagnostics_store.dart` (nuevo), `diagnostics_buffer.dart`, `session_hooks.dart`, `diagnostics_screen.dart`, `restore_service.dart` (vaciar la tabla), `vault_database.dart` (`exportEncryptedSnapshot`, `rekeyTo`).
**Tests:** anillo de 500; sobrevive a bloquear y reabrir; borrar; nada con la secundaria abierta; el snapshot exportado tiene 0 filas; la restauración la vacía; `rekeyTo` con eventos entrando no falla la verificación; barrido de correos/rutas/UUID.

### B.6 Mensaje de restauración que dice qué encontró

- `RestoreService.probe` devuelve además un `CloudInventory`, calculado del mismo `list()`: respaldos (por generación), puentes, snapshots (por generación y tamaño), `.vault`/`.thumb` (número y bytes), cuarentena y otros archivos. Solo conteos y tamaños: sin nombres, ids ni correos.
- Mensajes:
  - **Nada:** «Esta cuenta no tiene ningún dato de Kern».
  - **Snapshot sin respaldo:** «Esta cuenta tiene un índice (118 KB) y N archivos, pero no el respaldo de tus llaves, así que no se puede restaurar desde aquí. Si tu bóveda sigue en otro teléfono, ábrela allí: se completará sola al comprobar la copia en la nube».
  - **`incomplete`/`invalid`:** igual que hoy, con las cifras.
- Log: `Restauración: sin respaldo; índices=1, archivos=N` (solo números).

**Archivos:** `restore_service.dart`, `lib/features/onboarding/restore_flow.dart` (`_noBackup`).
**Tests:** un caso por combinación (vacío, solo snapshot, snapshot + archivos, respaldo sin snapshot, respaldo inválido, varias generaciones), texto sin datos personales.

---

## C. Riesgos para los datos del iPhone al instalar encima

### C.0 Antes de instalar (con la build actual, solo mirar)
- Mirar en Ajustes si aparece la fila «Cambio de cuenta en curso» y abrirla **solo para leer la fase**. Mirar en la cuadrícula el icono de las 2 fotos: nube o flecha.
- Abrir las 2 fotos para comprobar que se ven: así se sabe que su `.vault` está en el teléfono.
- **No tocar:** «Cancelar y volver a la cuenta anterior», «Vaciar caché ahora», «Liberar espacio sin conexión», bajar el «Límite de caché», «Cerrar sesión» de la hoja de la cuadrícula, «Borrar originales», desinstalar.
  - Si la migración termina o se cancela, la caché vuelve a purgar y las fotos son candidatas a purga: su copia «en la nube» no existe.
  - «Vaciar caché» con la migración activa no hace nada hoy (`suspended`), pero en un arranque en frío `onUnlocked` purga antes de aplicar la guarda (§A.3.5). Con 2 fotos no se llega al límite de 500 MB, pero no conviene arriesgarse.
- Protección opcional (decisión del usuario, por privacidad): «Guardar en Fotos» de las 2 fotos antes de instalar. Deja una copia descifrada en la fototeca.

### C.1 Instalación
- Firmar con **el mismo Apple ID/equipo y el mismo bundle id**. Otro equipo cambia el grupo de llavero: la envoltura de la DEK del almacén seguro no se lee y la bóveda no abre. Otro bundle id crea un contenedor nuevo y vacío. Nunca desinstalar.

### C.2 BD v10 → v11 (incremental, D51/D59)
- Solo `ALTER TABLE vault_items ADD COLUMN cloudAccountTag TEXT` y `thumbAccountTag TEXT` (con comprobación por `PRAGMA table_info`), más `CREATE TABLE IF NOT EXISTS vault_meta` y `diag_events`. No se toca ninguna fila; `migration_state`/`migration_items` quedan intactas. La sal se crea al primer uso, no en la migración.
- `upgrade`: `if (from < 11 && to >= 11) await addV11(db);`, idempotente. Mismo cambio en la BD de la bóveda adicional (`schema_upgrade_secondary_test`).
- Restauración: aceptar snapshots v6–v11. Una app antigua con un snapshot v11 → `VaultSchemaTooNewException` (D59), sin recrear nada.
- Tests: BD v10 real (fixture con `migration_state` en `signInNew` y items `en_nube` con referencias de otra cuenta) → v11 con todas las filas y columnas intactas; doble apertura; `rekeyTo` sobre v11; snapshot v11 restaurable; v11 → v10 bloqueado.

### C.3 Primer desbloqueo tras instalar (orden exigido)
1. Gate de la migración (§B.1). La pantalla aparece; **no** se reanuda nada ni se purga nada antes.
2. El usuario elige. En este caso: **«Cancelar y quedarme en la cuenta principal»** (o «Continuar», que tras el arreglo también sube a la principal).
3. Verificación (§B.2): las 2 fotos (con `.vault` local) pasan a `pendiente`, se suben a la principal con tamaño + MD5, luego el respaldo de llaves y el snapshot. Al terminar: restaurar con la principal debe dar `found`.

### C.4 Lo que la verificación NO debe hacer nunca
- **No borrar, renombrar ni mover nada en Drive.** Solo `list`/`getMetadata` y las subidas normales (`create`, o `update` del contenido de un archivo con su mismo nombre de item, igual que hoy). El fake de los tests falla si se llama a `delete` o `rename`.
- No borrar ningún `.vault`/`.thumb` local ni ninguna fila de la BD. No vaciar la Papelera.
- No marcar `en_nube` nada que no haya pasado por la subida verificada (o por la coincidencia exacta tamaño + MD5 del §B.2).
- No adoptar un archivo por nombre si el MD5 no coincide.
- No correr durante una rotación, una migración en curso (salvo desde `abandonStayOnCurrent`) ni con la secundaria abierta.
- No habilitar la purga de la caché ni el borrado de originales hasta que el item tenga el tag de la cuenta actual.
- No sobrescribir el respaldo de otra bóveda: si lo encuentra, se para (como `blockedOtherVault`).
- No escribir correos, ids de Drive ni nombres en logs: solo conteos.

---

## Resumen

- **Qué se encontró:** la migración solo se ve desde una fila de Ajustes. Varias fases esperan al usuario en silencio. `SyncService.run` vuelve sin hacer nada con `pausedForMigration`. «Cerrar sesión» se desactiva sin explicación, mientras que la hoja de la cuadrícula deja cambiar la sesión sin ninguna guarda. Los contadores solo miran la cola. Nada comprueba que un `en_nube` exista en la cuenta actual (D35). El flush del snapshot al bloquear ignora la pausa. `resume()` se traga en silencio los errores que no son de la nube. `onUnlocked` purga la caché antes de aplicar la guarda de la migración.
- **Causa más probable:** un cambio de cuenta quedó en `signInNew` (selector cancelado o fallido, o la misma cuenta preseleccionada en iOS) y después se inició sesión con la principal por fuera del flujo. Resultado: sincronización en pausa sin aviso, fotos `en_nube` con referencias de la cuenta de pruebas (ya vaciada), la principal solo con un snapshot (sin respaldo de llaves) y ninguna fase llegó a Borrar/Conservar.
- **Qué implementar (en este orden):**
  1. BD v11 incremental: tags de cuenta, `vault_meta`, `diag_events`.
  2. Gate y pantalla «Cambio de cuenta sin terminar», con `abandonStayOnCurrent`.
  3. «Verificar copia en la nube», automática con un tag distinto o nulo, y purga y borrado de originales solo con el tag actual.
  4. Guardas y mensajes consistentes en Ajustes y la hoja, `SyncRunOutcome`, comprobación de cuenta en la migración, selector con plazo, flush respetando la pausa.
  5. Banner en la cuadrícula.
  6. Diagnóstico persistente con Borrar.
  7. Inventario en el mensaje de restauración.
