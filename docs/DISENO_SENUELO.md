# Bóveda secundaria («señuelo», variante (a) «disimulo»): diseño final (v2 fase 8)

**Estado:** diseño final. No hay código todavía. Incorpora la revisión independiente: críticos C1–C2, altos A1–A2, medios M1–M8 y bajos B1–B7, además de los recortes (g) y las pruebas que faltaban (h). La tabla del §14 recoge qué se decidió con cada hallazgo. Las decisiones nuevas empiezan en **D65**, porque D64 ya existe («Continuar sin ellos»).

Hay datos reales en un iPhone. Rige la misma regla que en la rotación: un corte en cualquier momento (app matada, bloqueo, sin batería) nunca daña la bóveda principal ni su restauración. Ninguna operación destructiva actúa sin comprobar antes el estado real.

**Variante (a), elegida por el usuario el 2026-11-18.** Un SEGUNDO PIN abre una bóveda SEPARADA: otra DEK, otros archivos y otra BD. **No** se oculta en disco ni en Drive cuántas bóvedas hay; eso sería la variante negable, que se descartó. El diseño prioriza la simplicidad y el aislamiento, no la indistinguibilidad.

**Vocabulario:**
- `VaultSlot.primary`: la **principal**, la de hoy (la del iPhone).
- `VaultSlot.secondary`: la **secundaria**, el señuelo.
- En la interfaz nunca aparece «señuelo». En disco y en el almacén seguro se usa el nombre neutro `alt`.

---

## 0. Qué hace y garantías

1. **Crear.** Desde la principal (Ajustes > Seguridad > «Bóveda secundaria»), con el PIN principal, el usuario crea una secundaria con su propio PIN de 6 dígitos (reglas en el §6.10).
2. **Desbloquear.** En la pantalla del PIN de siempre, con la app bloqueada, el PIN principal abre la principal y el secundario abre la secundaria. La pantalla, los textos, los tiempos y el límite de intentos son los mismos para las dos.
3. **Usar.** Dentro de la secundaria se ve una bóveda normal: cuadrícula, carpetas, importar, visor, Papelera, etiquetas y búsqueda. Sus Ajustes son reducidos y no tiene nube.
4. **Gestionar.** Desde la principal se cambia el PIN de la secundaria (hace falta saberlo) y se elimina. Si se olvida el PIN secundario, se elimina la secundaria y se crea otra.

Garantías:

- **G1. La principal no cambia.** Mientras no exista una secundaria, la app se comporta byte a byte como hoy: las mismas claves del almacén seguro, las mismas rutas, el mismo esquema v10, una sola derivación Argon2id y **ninguna escritura nueva en disco** (M2). Usar la secundaria no modifica ninguna clave, archivo ni fila de la principal, con dos excepciones:
  - el contador de intentos compartido, que solo puede **subir** (§3);
  - la biometría, si el usuario elige apagarla.
- **G2. Drive no se toca.** La secundaria no lee ni escribe en Google Drive. `recovery_backup*.json`, `vault_db*.snapshot` y los blobs de la principal quedan idénticos y restaurables. El probe de restauración, la rotación (A5 y el borrado por lista) y la migración de cuenta no ven nada nuevo.
- **G3. Aislamiento criptográfico.** Las dos DEK son aleatorias e independientes. Ninguna se deriva de la otra ni de su PIN, y no hay ninguna envoltura cruzada. Nada de una bóveda se cifra jamás con llaves de la otra. Esto lo aseguran las llaves ligadas a la bóveda y la época de sesión (§4).
- **G4. Aislamiento de ejecución.** Una operación iniciada en una bóveda no puede leer, escribir ni borrar nada de la otra, aunque cruce un «bloquear → desbloquear la otra» (A1). Con la secundaria abierta, ningún servicio de la principal funciona: sincronización, sin conexión, migración, rotación y snapshot.
- **G5. Nada en claro en disco.** Igual que hoy, en el directorio de cada bóveda. Los temporales en claro se borran en `finally` y al bloquear (los ganchos se instalan también para la secundaria, M1), y al arrancar se barren los de **todas** las bóvedas.
- **G6. Un problema de la secundaria nunca impide abrir la principal.** Una envoltura secundaria ilegible, dañada o con otros parámetros de Argon2id (M3) se trata como «no hay secundaria» al desbloquear, sin derivar nada.
- **G7. La interfaz de la secundaria no la delata.** Nada en ella nombra la principal, Google, Drive, la nube, el código de recuperación, la rotación, el Diagnóstico ni la propia «bóveda secundaria». Esto incluye los mensajes de error dinámicos (M8).
- **G8. El límite de intentos no se debilita.** Conocer el PIN secundario no da más intentos contra el PIN principal (C1, C2).

Fuera de alcance: todo lo que distingue a alguien que analiza el disco, el almacén seguro, Drive o el espacio ocupado (§7).

---

## 1. Modelo

| | Principal (`primary`) | Secundaria (`secondary`) |
|---|---|---|
| Cómo nace | onboarding o restauración (como hoy) | Ajustes de la principal, con el PIN principal |
| DEK | la de hoy (generación ≥ 1, rotable) | propia, aleatoria, **siempre generación 1**, no rotable |
| PIN | el de hoy (de 4 a 6 dígitos si es heredado; los nuevos, 6) | 6 dígitos, reglas en el §6.10 |
| Dónde se cambia el PIN | Ajustes de la principal (como hoy) | **Ajustes de la principal**, con el PIN principal + el secundario actual (C2) |
| Código de recuperación | sí | **no** (D68) |
| Google Drive | sí | **no** (D68) |
| Biometría | sí, opcional | **no** (D69) |
| Raíz en disco | `Documents/` (sin cambios) | `Documents/alt/` |
| BD | `Documents/db/vault_secure.db` | `Documents/alt/db/vault_secure.db` (se crea con el esquema vigente) |

Reglas:
- Como mucho hay una secundaria.
- Solo hay una bóveda desbloqueada a la vez.
- Se cambia de bóveda **solo** desde la pantalla del PIN con la app bloqueada (A2). No hay ningún botón de cambio, porque lo delataría.

**Por qué la secundaria no rota ni tiene código.** La rotación existe para que un código filtrado deje de abrir lo que hay en Drive (S-11). La secundaria no tiene ni código ni Drive. Para cambiar su llave: eliminarla y crear otra.

**Por qué no hay envoltura cruzada** (DEK secundaria envuelta con la principal). Crearía un enlace entre llaves, justo lo que D63 eliminó, y más material que probar y borrar. Cambiar el PIN secundario desde la principal exige saberlo (§6.10), y eso basta, porque la secundaria es desechable.

---

## 2. Persistencia

### 2.1 Almacén seguro (`flutter_secure_storage`, el mismo almacén y las mismas opciones)

Claves NUEVAS con el prefijo `vault.v1.alt.`. No cambia ninguna clave existente.

| Clave | Contenido | Vida |
|---|---|---|
| `vault.v1.alt.pin_envelope` | `WrappedKey(purpose: altPin)`: la DEK secundaria envuelta con Argon2id(PIN secundario), con **los mismos parámetros de KDF que la envoltura principal** (M3). Su PRESENCIA marca que la secundaria existe. | de crear a eliminar |
| `vault.v1.alt.db_created` | guarda C1 de la BD secundaria (como `vault.v1.db_created`) | desde su primera apertura hasta eliminarla |

- **`WrapPurpose.altPin`** (AAD `vault.dek.v1|altPin`). Si una envoltura se copia a la clave de la otra bóveda, da `FormatException` por el propósito. Las envolturas `pin` y `recovery` existentes no cambian: el propósito se compara por nombre.
- **Se elimina `alt.key_check`** (recorte g2). Sin biometría en la secundaria no sirve: AES-GCM ya autentica la DEK. Es una escritura menos y un punto de corte menos.
- **Compartidas a propósito:**
  - `vault.v1.pin_attempts` (§3);
  - `security.v1.autolock_ms` y `security.v1.protect_screen`;
  - `cache.v1.limit_bytes` (sin efecto en la secundaria) y `pref.gallery.videoQuality`.

  Son preferencias de la app, no de los datos.
- **Solo de la principal:** todo lo demás (`recovery_backup`, `key_check`, `biometric_enabled`, `onboarding_pending`, `restore_attempts`, `key_gen`, `db_created`, `vault.v1.rotation*`, `sync.v1.*`, `migration.v1.*` y `pref.gallery.deleteOriginalsInCloud`).
- **API en `AuthController`:** `altPinEnvelopeKey`, `altDbCreatedKey` y `allAltKeys`, la lista explícita que se añade a `createVault`, `_commit` y `discardLocalKeys`. Hoy esos tres trabajan con listas explícitas y no tocarían `alt.*` sin ella.

### 2.2 Disco: un resolutor de rutas por bóveda, sin enlace global (D67)

Nueva clase **`VaultPaths`** (instancia) en `lib/core/services/vault_paths.dart`. Tiene `root`, `vaultDir`, `thumbsDir`, `dbDir`, `cacheDir`, `tmpPlainDir`, `importTmpDir`, `resolve(rel)`, `relative(abs)` y `dbFile`. La validación S-15 sigue siendo estática y la misma.

- `VaultPaths.primary` tiene como raíz el directorio de documentos. **`AppPaths` (estático) sigue existiendo y delega en `VaultPaths.primary`**: todo el código actual sigue resolviendo contra la principal, que es lo correcto, y sin cambios.
- `VaultPaths.secondary` tiene como raíz `Documents/alt`. Solo la reciben, por inyección, los servicios de la secundaria (§4.4).
- **No hay `AppPaths.bind` ni ninguna raíz mutable** (A1, alternativa estructural). Una operación tardía de la principal siempre resuelve contra la raíz principal, y una de la secundaria contra `alt/`.

| Recurso | Principal (sin cambios) | Secundaria |
|---|---|---|
| archivos | `vault/<uuid>[.kN].vault` | `alt/vault/<uuid>.vault` |
| miniaturas | `thumbs/<uuid>[.kN].thumb` | `alt/thumbs/<uuid>.thumb` |
| BD | `db/vault_secure.db` | `alt/db/vault_secure.db` |
| `vault_cache/{tmp_plain,import_tmp}` | sí | `alt/vault_cache/{tmp_plain,import_tmp}` |
| `restore_staging/`, `vault_cache/rotation/` | sí | no existen |

- Las rutas que se guardan en la BD siguen siendo RELATIVAS y con el mismo formato. Cada bóveda las resuelve con su propio `VaultPaths`.
- **Invariante (con test):** los ids de los items son UUID v4. Por eso un borrado por id resuelto por error contra la otra raíz no encuentra nada.
- **iOS** (M2): `excludeVaultFromBackup` excluye `alt/` **solo si existe y sin crearlo**. Al crear la secundaria se excluye en el acto. Así un arranque sin secundaria nunca escribe `alt/`.

### 2.3 BD: una instancia por bóveda (D67)

- `VaultDatabase.instance` es la principal (la de siempre). `VaultDatabase.secondaryInstance` es nueva. Cada instancia fija su **bóveda**, su **ruta** (de su `VaultPaths`) y su **marca C1** (`db_created` o `alt.db_created`) al construirse.
- **Sin cambio de esquema.** La principal sigue en v10 y no hay migración. La secundaria se crea con `VaultSchema.create` en su primera apertura. Sus tablas `sync_queue`, `migration_*` y `rotation_*` quedan vacías para siempre.
- **Esquemas futuros (h12):** cada `vN → vN+1` se prueba también sobre una BD secundaria v10, que puede actualizarse muchas versiones más tarde, la próxima vez que se abra.

---

## 3. Desbloqueo y límite de intentos (D66)

### 3.1 Con la sesión BLOQUEADA (pantalla del PIN): las dos envolturas

`AuthController.unlockWithPin(pin)` conserva su contrato: está serializado, fusiona duplicados, se cancela con `lock()` y lanza `StateError` si no hay bóveda principal. Con la sesión bloqueada usa `_verifyPinAny`:

```
raw    = read(pin_envelope)                       // sin ella: StateError (como hoy)
rawAlt = read(alt.pin_envelope)                   // null = no hay secundaria
alt    = _usableAlt(rawAlt, primaryKdf)           // M3: null si no decodifica o si su kdf ≠ el de la principal
before = limiter.rawState()                       // C1: estado ANTES del +1
limiter.ensureNotLocked()                         // contador COMPARTIDO: vault.v1.pin_attempts
limiter.registerFailure()                         // pesimista, antes de derivar (como hoy)
[dP, dS] = await Future.wait([
   primary.unwrap(pin),                           // los errores de la principal, como hoy
   alt == null ? null : _safe(alt.unwrap(pin)),   // G6: cualquier excepción -> null
])
si dP != null: poner a cero dS; limiter.reset(); abrir PRINCIPAL (camino de hoy: rotación incluida)
si dS != null: limiter.restoreRaw(before); abrir SECUNDARIA      // C1: sin reset
si no:         false ("PIN incorrecto")
```

- **C1: solo acertar la principal pone el contador a cero.**
  - Acertar la secundaria **deshace únicamente su propio +1 pesimista**: reescribe tal cual el estado anterior (`failures`, `lockedUntil`, `lockElapsed`, `lockBoot` y `lockDur`). Si no había estado, borra la clave. Los fallos previos y las esperas en curso se conservan.
  - Si la app muere durante la derivación, el +1 se queda, como hoy.
  - `PinAttemptLimiter` gana `rawState()` y `restoreRaw(String?)`, ambos dentro de `_serialized`.
  - Así, intercalar el PIN secundario entre intentos no impide que las esperas escalen.
  - Coste aceptado en (a): quien conoce la secundaria ve que los fallos anteriores siguen contando. Que exista otra bóveda ya se admite como visible (§7).
- **Tiempos.**
  - Con secundaria se lanzan **siempre las dos** derivaciones **en paralelo**, y se decide cuando terminan ambas. El tiempo es ≈ max(t₁, t₂), acierte la principal, la secundaria o ninguna: `SodiumArgon2Backend.runIsolated` y `Isolate.run` dan un isolate a cada una. Si el sistema las serializa, el total sigue sin depender de cuál acierta.
  - Sin secundaria hay una sola derivación (G1). Por eso quien mide puede saber que existe una secundaria; se acepta en (a).
  - B2: la igualdad vale **hasta la decisión**. Después, la principal lee el registro de rotación y, en `prepared..freezing`, hace un tercer Argon2id (`_unwrapNextWithPin`). Es irrelevante, porque el que mira ve qué bóveda se abrió.
- **M3: parámetros fijos.** Una envoltura secundaria cuyos `kdf` no son **exactamente** los de la envoltura principal no se deriva: queda como «Dañada». Esto impide que una envoltura manipulada (por ejemplo, de 256 MiB) ralentice o tumbe por falta de memoria cada desbloqueo de la principal, o que haga caer el Argon2id nativo a Dart.
- **Abrir la secundaria** (`_openSecondary(dek, gen)`):
  - `KeyHierarchy.fromDek` + `VaultKeyring.single(1, keys)` + `_openChecked(ring, gen, slot: secondary)`. B2: respeta la cancelación por `lock()`.
  - **No** lee ni toca nada de la rotación (`sweepOrphans` y `load`). Si lo hiciera, una rotación de la principal en curso pasaría a `blockedForeign`.
  - B5: al abrir **cualquier** sesión se vacía también el `DiagnosticsBuffer`.
- La biometría (`unlockWithBiometrics`) no cambia y abre solo la principal (D69).

### 3.2 Con la sesión ABIERTA: nunca se cambia de bóveda (A2)

- `unlockWithPin` con la sesión abierta solo prueba la envoltura **de la bóveda abierta** y **nunca** cambia de bóveda.
  - Si la abierta es la principal, sigue el camino de hoy: una derivación, porque el dueño no necesita disimulo.
  - Si es la secundaria, prueba solo `alt`.
  - Un PIN de la otra bóveda da `false` («PIN incorrecto»). La sesión, la navegación y los servicios quedan intactos.
- Nuevo **`reauthPrimary(pin)`**: exige una sesión principal y hace `_verifyPin` + `_openKeys` de la principal. Es lo que hoy hace `unlockWithPin` dentro de la sesión para recuperar la llave nueva de la rotación. `key_rotation_screen.dart` (`_enterPin`) pasa a usarlo.
- `VaultSession.openKeyring(ring, slot:)` con una sesión ya abierta de **otra** bóveda lanza `StateError`. Para cambiar de bóveda hay que pasar por `clear()`.

### 3.3 Operaciones que exigen sesión principal

Estas operaciones exigen sesión principal (`_requirePrimarySession()`; si no, `StateError`): `changePin`, `regenerateRecoveryCode`, `prepareRotation`, `regenerateNextRecoveryCode`, `confirmRotationCode`, `enterReencrypting`, `switchPrimary`, `finishRotation`, `enableBiometricUnlock`, `verifyLocalRecoveryCode`, `reauthPrimary`, `createSecondaryVault`, `changeSecondaryPin` y `deleteSecondaryVault`.

B6: la comprobación se **repite después de cada `await` largo** (cada derivación) antes de escribir, porque varios `AuthController` conviven en `vault_services.dart`. Su `_verifyPin` interno solo prueba la envoltura principal.

---

## 4. Aislamiento en ejecución (D67)

### 4.1 Época de sesión y llaves ligadas a la bóveda

**`VaultSession`** (sigue siendo única: hay una sola bóveda abierta a la vez):
- `slot` (`null` si está bloqueada) e `isUnlockedAs(VaultSlot)`.
- `epoch` (entero): se incrementa en cada `clear()` y en cada `openKeyring` que abre desde el estado bloqueado.
- `ticket()` devuelve un `SessionTicket{slot, epoch}`. `ticket.check()` lanza `SessionChangedException` si la sesión cambió de bóveda o de época, o si se bloqueó. `ticket.isValid` devuelve un booleano.
- **Llaves ligadas a la bóveda:** `filesKeyFor(gen, {required VaultSlot slot})` y `thumbsKeyFor(gen, {required slot})` devuelven `null` si la sesión abierta no es de esa bóveda. Los servicios de la principal pasan `primary` y los de la secundaria `secondary`. Una operación nunca puede obtener a mitad de bucle la llave de la otra bóveda (A1-2).

**Regla para toda operación larga** (importar un archivo o de la galería, regenerar miniaturas, re-cifrar, `rekeyTo`, `purgeExpired`, `onUnlocked`, `CacheManager.enforce`, descargas sin conexión, exportar a Fotos, flush):
1. Al empezar captura un `SessionTicket`, su `VaultPaths` (rutas absolutas) y sus llaves. Usa esas llaves, comprobando `!isDestroyed`, y **nunca** vuelve a leerlas de la sesión.
2. Llama a `ticket.check()` **inmediatamente antes de cada escritura o borrado en disco y de cada escritura en BD**.
3. Las de importación y regeneración se **cancelan al bloquear** (`ImportCancelToken` / `isCancelled` registrados en `onClear`), sin esperar a un error.

**`VaultDatabase`** (cada instancia, §2.3):
- El getter `database` exige `session.slot == mySlot`; si no, `WrongVaultSlotError`, que es subclase de `StateError`.
- La conexión se liga a la `epoch` con la que se abrió, y un `database` pedido en otra época obliga a reabrir.
- En `_open`, la ruta y la marca C1 son campos fijos de la instancia. La bóveda y la época se capturan al empezar y se vuelven a comprobar **antes de publicar `_db`** y **antes de `onCreate`**. Si cambiaron, se cierra y se lanza sin escribir la marca (A1-5).
- `rekeyTo` solo existe en la principal. Las rutas (`dbFile`, `tmp`, `backup`, `-wal/-shm/-journal`) se capturan una vez al principio, y `ticket.check()` se hace antes de la copia, del borrado del WAL y del `rename` (A1-4). Como la ruta es fija por instancia, aunque fallara la comprobación nunca podría escribir encima de `alt/db`.
- `exportEncryptedSnapshot()` solo existe en la principal. Con otra bóveda abierta lanza.
- Fallo cerrado: la llave de una bóveda no abre la BD de la otra.

### 4.2 Qué es de cada bóveda

| Componente | Principal | Secundaria | Cómo |
|---|---|---|---|
| DEK y subllaves HKDF (`sqlcipher`/`files`/`thumbs`) | propias | propias | DEK independientes ⇒ subllaves independientes. Sin separación de dominio en `info`: no cambia nada para la principal |
| Archivos, miniaturas, BD, caché, `tmp_plain`, `import_tmp` | `Documents/…` | `Documents/alt/…` | `VaultPaths` + `VaultDatabase` por bóveda |
| Papelera, etiquetas, carpetas, búsqueda y filtros | su BD | su BD | repositorios con `dbProvider` de su instancia (ya inyectable) |
| Importación, regeneración y cargador de miniaturas (con su progreso y su estado) | instancias de `_Core`/`_shared*` | **instancias propias** (M1, recorte g3) | el `progress`/`currentName` de una nunca se ve en la otra |
| Cola de sync, snapshot y estado «sucio» | sí | no existen | servicios de la principal con compuerta (§4.3) |
| Caché LRU | sí | no aplica (todo es local) | la secundaria no tiene `CacheManager` |
| Ganchos de bloqueo (purga de `tmp_plain`, `VaultStreamServer.closeAllNow`, `DiagnosticsBuffer.clear`, `wipeImageCache`, cancelar importación y regeneración) | sí | sí | `SessionHooks.ensureInstalled()` común, independiente de `_Core` (M1) |
| Límite de intentos | compartido | compartido | §3 |
| Autobloqueo, «Bloquear ahora», `PrivacyCover`, FLAG_SECURE | compartidos | compartidos | el mismo `AutoLockController` |
| Biometría | sí | no | D69 |

### 4.3 Guardas: con la secundaria abierta no corre nada de la principal

`_Core` (sincronización, sin conexión, migración y rotación) sigue siendo **solo de la principal**:

1. **Compuerta de servicios.**
   - `SyncService.isUnlocked` y `OfflineService.isUnlocked` pasan a ser `() => session.isUnlockedAs(VaultSlot.primary)`.
   - `VaultDataRepository.onDataChanged` pasa a ser `() { if (session.isUnlockedAs(primary)) sync.notifyDataChanged(); }`.
   - `KeyRotationService` y `AccountMigrationService` se reanudan solo desde el `onUnlocked` de la principal y comprueban un `SessionTicket` en cada paso. Si falla, lanzan `_Stop` **sin escribir el registro ni ningún estado bloqueado** (A1-6).
2. **Guarda de nube** (`lib/data/cloud/slot_guarded_cloud.dart`). `CloudProvider.instance` es `SlotGuardedCloudStorage(GoogleDriveCloudStorage())`.
   - Con `session.slot == secondary`, todo método lanza `CloudSlotException extends CloudException`, incluidos `signIn` y `signOut`, y `currentAccountEmail` devuelve `null`.
   - La comprobación se hace al entrar. La subida del snapshot de la principal que sigue tras bloquear (D38/D53) termina por su cuenta: solo toca `SyncPreferences`. Si una nueva llamada choca con la guarda, el estado queda «sucio» y se reintenta. No se pierde nada.
3. **Repositorios solo de la principal.** `SyncQueueRepository`, `MigrationRepository` y `RotationRepository` usan `VaultDatabase.instance`, que ya lanza `WrongVaultSlotError` con la secundaria abierta (§4.1).

Las guardas 2 y 3 son defensa en profundidad. Hay un test por guarda y uno que recorre `VaultServices.real()` con la secundaria abierta y falla ante cualquier llamada a la nube o a la BD principal.

### 4.4 Servicios de la secundaria (`VaultServices.secondary()`)

- **No crea `_Core`.** No arranca ni `sync.start()` ni `OfflineService.start()`.
- **Instancias propias:**
  - `VaultDataRepository`, `TrashRepository` y `TagRepository` con `dbProvider: () => VaultDatabase.secondaryInstance.database`;
  - `VaultImportService`, `GalleryImportService` y `ThumbnailRegenerationService` con `paths: VaultPaths.secondary`, llaves `…For(gen, slot: secondary)` y `cloudVerifier: (_) async => false`;
  - `EncryptedThumbnailLoader` con `resolve: VaultPaths.secondary.resolve`;
  - `PlainTempManager(dirProvider: secondary.tmpPlainDir)`;
  - `VaultMediaOpener` con un `VaultFileFetcher` sobre la nube con guarda (si falta un `.vault`, falla con un mensaje neutro, M8) y `markInUse/releaseInUse` sin efecto;
  - `VaultMediaExporter`;
  - `TrashService` sin `remoteDeleter`.
- `GalleryImportService` y `VaultImportService` ganan un parámetro `paths` (por defecto `VaultPaths.primary`). Hoy llaman a `AppPaths.resolve` y a `AppPaths.init` directamente.
- **No tiene:** `sync`, `storage`, `migration`, `rotation`, `cache` ni `beforeLock`. La UI ya oculta lo que cuelga de ellos: la nube de la barra, los banners de rotación y migración, «sin conexión» y el estado de subida.
- `syncRunner` no hace nada. `offlineToggler` devuelve `false` y se oculta. `fileCleaner` borra solo los locales, con `VaultPaths.secondary`.
- `onUnlocked`: con un `SessionTicket` propio, ejecuta `temp.sweep()`, `trash.purgeExpired()` y la regeneración (A1-3: si cambió la época, no hace nada).

**`VaultRootNavigator`** (M7). Los servicios y el `SettingsEnvironment` se recalculan en **cada** desbloqueo según `session.slot`; se acaban `_realServices ??=` y `late final _settings` sin bóveda.
- La principal usa `VaultServices.real()` (cacheado, como hoy) y la secundaria `VaultServices.secondary()`, que se crea nuevo en cada desbloqueo y se desecha al bloquear.
- `_lock()` toma el `beforeLock` de los servicios **de la bóveda abierta**: es `null` en la secundaria.
- `_handleAuthenticationSuccess` no consulta `onboarding_pending` con la secundaria.

---

## 5. Nube (D68)

| Opción | Qué es | Coste y riesgo | Decisión |
|---|---|---|---|
| **1. Sin respaldo** | La secundaria vive solo en el teléfono | Ningún cambio en sincronización, restauración, rotación ni migración. Perder el teléfono = perder la secundaria (es un señuelo) | **Elegida** |
| 2. El mismo appDataFolder con prefijo (`alt_recovery_backup.json`, `alt_vault_db.snapshot`, `alt_<uuid>.vault/.thumb`) | Segundo `SyncService` | Ver la lista bajo esta tabla | Descartada en esta fase (posible «8b») |
| 3. Otra cuenta de Google | — | Imposible: hay una sola sesión (D49) | Descartada |

Por qué se descarta la opción 2 (≈ 6–8 días más, y toca la restauración):
- exige un código propio, porque el PIN nunca protege nada que salga del teléfono;
- exige prefs propias y una restauración en la que se elija qué bóveda;
- exige que la migración mueva los `alt_*` (hoy `_isVaultFile` los ignora);
- exige que `deleteOldAccountData` los borre;
- la secundaria mostraría la misma cuenta de Google, lo que delata el vínculo.

Comprobado en el código (y confirmado por la revisión): `CloudNames.parse` devuelve `null` para `alt_*`, porque las expresiones están ancladas y el id debe ser un UUID v4. Por tanto, si algún día se hace la opción 2:
- `probe` no los toma como respaldo;
- la guarda A5 y `_oldKind` de la rotación los ignoran: no bloquean, no se listan y no se borran;
- `nextGeneration`, `GenerationSweeper` y la migración no los ven.

Con la opción 1, G2 se cumple por construcción y además lo aseguran las guardas del §4.3.

**Restauración de la principal:** sin ningún impacto. En un teléfono restaurado no hay secundaria, y el texto de creación lo avisa.

---

## 6. Interacciones

1. **Rotación de la DEK de la principal:**
   - es independiente;
   - con la secundaria abierta queda en pausa, porque la compuerta y el ticket impiden avanzar;
   - el registro no se toca, porque `_openSecondary` no lo lee;
   - **crear** la secundaria queda **prohibido** mientras hay un registro de rotación («Disponible al terminar el cambio de llave maestra»), para acotar la matriz de pruebas;
   - **cambiar el PIN** de la secundaria y **eliminarla** sí se permiten, porque son operaciones solo locales;
   - el banner no aparece en la secundaria;
   - la reautenticación de la pantalla de rotación usa `reauthPrimary` (A2).
2. **Cambio de cuenta (D52):** solo en la principal. En pausa con la secundaria abierta, y oculto en ella.
3. **Papelera, etiquetas, búsqueda y filtros:** van por BD. `purgeExpired` de cada bóveda corre con su ticket y su repositorio, así que nunca toca la otra (A1-3).
4. **Importación** (galería y selector propio). Va a la bóveda **abierta al empezar** el lote (con su ticket): su BD, sus rutas y sus llaves. Si se bloquea, el lote se cancela y el ticket impide toda escritura posterior.
   - En la secundaria no se ofrece «borrar originales». Sus entradas en Ajustes y en la hoja de importación se ocultan con `sync == null`.
5. **Guardar en Fotos:** en las dos bóvedas, con el mismo aviso de «sin cifrar» y con ticket.
6. **Onboarding:** la secundaria nunca aparece. `createVault` y `_commit` borran `allAltKeys`. El directorio `Documents/alt/` lo borra el arranque (§9, fila 1), con la lectura del almacén comprobada.
7. **«Comprobar mi código», código de recuperación y rotación:** solo en la principal.
8. **Autobloqueo y «Bloquear ahora»:** compartidos. `clear()` cierra la BD abierta y ejecuta los ganchos comunes: purga del `tmp_plain` de **las dos** raíces, cierre del servidor loopback, vaciado de la caché de miniaturas, del `ImageCache` y del `DiagnosticsBuffer`, y cancelación de la importación y la regeneración en curso. Después incrementa `epoch`.
9. **Biometría (D69):**
   - solo abre la principal;
   - al crear la secundaria con la biometría activa, la pantalla lo avisa y ofrece «Desactivar Face ID/huella (recomendado)», marcado por defecto;
   - **M5:** si el usuario la desactiva, se apaga **antes** de escribir `alt.pin_envelope`;
   - `SecondaryVaultScreen` vuelve a avisar si ve las dos cosas activas a la vez;
   - mientras exista una secundaria, la `PinScreen` **no lanza sola** el diálogo biométrico; solo con su botón.
10. **PIN (D71)**
    - *Reglas del PIN secundario*, al crearlo y al cambiarlo; se comparan **en memoria** con el principal recién verificado:
      - debe tener 6 dígitos y ser distinto del principal;
      - si el principal también tiene 6, debe diferir en al menos 2 posiciones;
      - **M6:** si el principal es heredado de 4 o 5 dígitos, el secundario **no puede empezar por el principal**. Si no, pulsar «Entrar» antes de tiempo abriría la principal (el botón se activa desde 4 dígitos).

      Textos: «Debe ser distinto del PIN principal» / «Elige uno más distinto: con un dígito mal tecleado entrarías en la otra».
    - *Cambiar el PIN de la principal* (`changePin`):
      - tras verificar el viejo, si existe una secundaria utilizable y `altEnvelope.unwrap(newPin) != null` → `PinNotAllowedException` («Ese PIN no está disponible. Elige otro.») y no se escribe nada;
      - cuesta un Argon2id más, y no hay oráculo, porque exige la sesión principal;
      - B3: aquí solo se detecta la **igualdad**, no la distancia 1 ni el prefijo (probar los vecinos costaría demasiado). Queda documentado.
    - *Cambiar el PIN de la secundaria* (**C2: solo desde la principal**, `SecondaryVaultScreen` → `changeSecondaryPin(primaryPin, currentAltPin, newAltPin)`):
      - exige sesión principal;
      - `_verifyPin(primaryPin)` (cuenta como intento);
      - desenvuelve `alt.pin_envelope` con `currentAltPin`; si falla, «PIN de la bóveda secundaria incorrecto», sin contador propio, porque el dueño ya está autenticado como principal;
      - aplica las reglas en memoria contra `primaryPin`;
      - vuelve a envolver la MISMA DEK (con el kdf de la principal), la escribe y la relee para verificarla.
    - **Dentro de la secundaria no existe «Cambiar PIN»**: desaparecen el oráculo y su regla de contador. Si el PIN secundario se olvidó: Eliminar + Crear.
11. **Ajustes dentro de la secundaria** (`SettingsEnvironment.slot == secondary`):
    - *Se ve:*
      - Seguridad: Autobloqueo, Bloquear ahora.
      - Importación: Calidad de video por defecto.
      - Almacenamiento: Regenerar miniaturas que faltan; espacio usado en este teléfono.
      - Etiquetas y Papelera.
      - Acerca de: Versión; Privacidad con texto neutro: «Tus archivos se cifran en este teléfono antes de guardarse. El PIN y las llaves nunca salen del dispositivo.».
    - *No se ve:* Cambiar PIN, biometría, Proteger pantalla (es global y no se debe poder rebajar desde el señuelo), el código de recuperación, rotar, «Comprobar mi código», Sincronización y cuenta, borrar originales, el límite de caché, sin conexión, Diagnóstico y la sección «Bóveda secundaria».
    - *Mensajes dinámicos (M8):* un `.vault` ausente, `CloudSlotException`, `VaultSchemaTooNewException`, `VaultDatabaseMissingException` y los errores de importación se muestran en la secundaria con textos neutros: «Este archivo no está disponible», «No se pudo abrir la bóveda», «Actualiza Vault para abrir esta bóveda», «No se pudo importar». Nunca dicen «nube», «Drive» ni «Google».
12. **Ajustes de la principal:** en Seguridad, la fila «Bóveda secundaria» (subtítulo «Desactivada», «Activa» o «Dañada») abre `SecondaryVaultScreen`, con:
    - **Crear** (§8);
    - **Cambiar PIN** (§6.10);
    - **Eliminar**, con PIN principal y la confirmación «Se borrará para siempre todo su contenido (X MB). No tiene copia en la nube.». X es el tamaño de `alt/`;
    - el aviso de biometría (M5).

    El Diagnóstico de la principal muestra «Bóveda secundaria: sí/no/dañada», sin rutas ni tamaños.
13. **Eliminar** (`deleteSecondaryVault(primaryPin)`). Es la **única** vía que borra una secundaria «Dañada» o con contenido. Orden:
    1. `_verifyPin`;
    2. `ticket.check()` (B6);
    3. borrar `alt.pin_envelope` **primero** y releerlo (si sigue, se repite: cubre `apply()`);
    4. borrar `alt.db_created`;
    5. borrar `Documents/alt/` recursivamente: es solo texto cifrado. Antes se comprueba que la ruta sea exactamente `VaultPaths.secondary.root`, que termine en `/alt` y que esté dentro de los documentos.

---

## 7. Qué protege y qué no (D65)

| Situación | ¿Protege? | Por qué |
|---|---|---|
| Alguien te obliga a abrir Vault y le das el PIN secundario | **Sí** | Ve solo la secundaria. La interfaz no nombra la principal (G7) |
| Ese alguien prueba PIN en la pantalla después | **Sí** (como sin secundaria) | Límite compartido; acertar la secundaria no pone el contador a cero (C1). Solo baja de 1/10⁶ a 2/10⁶ por intento |
| Ese alguien busca dentro de la secundaria la forma de probar PIN | **Sí** | No hay cambio de PIN ni ningún oráculo dentro de ella (C2) |
| Ese alguien te obliga a usar Face ID o la huella | **No** | La biometría abre la principal (por eso se recomienda apagarla y no salta sola) |
| Análisis del teléfono (archivos, Keychain, tamaño de `Documents/alt/` frente a `Documents/vault/`) | **No** | Se ve que hay dos bóvedas y cuál pesa más |
| Ajustes del sistema: almacenamiento de la app | **No** | Muestra el total de Vault, más que lo que enseña el señuelo |
| Acceso a tu Google Drive | **No** | Se ve que Vault guarda datos, cuánto y la cuota usada |
| Medir el tiempo del desbloqueo | **Parcial** | Se puede saber que hay una segunda bóveda (dos derivaciones), no cuál se abrió |
| Alguien que conoce Vault | **Parcial** | Puede notar que el señuelo no tiene nube, código ni biometría |
| Contenido poco creíble o vacío | **No** | Depende del usuario |
| PIN secundario válido pero la BD de la secundaria está dañada | **No** (B7) | «No se pudo abrir la bóveda» en lugar de «PIN incorrecto» confirma que es un PIN válido. Se acepta en (a) |
| Perder el teléfono o restaurar en otro | La secundaria **se pierde** | No tiene copia (D68) |
| Instalar una versión anterior (B4) | — | No excluye `alt/` de iCloud. Solo hay texto cifrado y las llaves son `ThisDeviceOnly`; D59 sigue vigente |

**Textos** (`SecondaryVaultScreen`):
1. **Bóveda secundaria.**
   - «Crea una segunda bóveda con otro PIN. Si alguien te obliga a abrir Vault, puedes darle ese PIN: verá solo lo que guardes ahí.»
   - «Sirve para disimular, no para ocultar. Quien examine el teléfono o tu Google Drive puede notar que hay más datos de los que se ven.»
   - «No se copia a Google Drive ni tiene código de recuperación. Si pierdes el teléfono o su PIN, su contenido se pierde.»
2. Con la biometría activa: «Face ID / tu huella abren la bóveda principal. Para que esto sirva, desactívalos.» [✓] Desactivar (recomendado).
3. Al terminar: «Listo. Bloquea Vault y entra con el PIN nuevo para llenarla con archivos creíbles.»

---

## 8. Creación (`AuthController.createSecondaryVault(primaryPin, newPin, {disableBiometrics})`)

Se ejecuta dentro de `_serialized`. Exige sesión principal, que no haya registro de rotación y que **la clave `alt.pin_envelope` no esté presente**: una lectura que devuelve `null` sin error (M4). Si está presente aunque sea ilegible, la secundaria es «Activa» o «Dañada» y crear se rechaza: primero hay que eliminarla.

1. `_verifyPin(primaryPin)`: cuenta como intento y lo pone a cero si acierta, porque es la principal. Después, `ticket.check()`.
2. Validar `newPin` con las reglas del §6.10, contra `primaryPin` en memoria.
3. Generar `dekS = randomBytes(32)`.
4. Si existe `Documents/alt/` (restos de un borrado o de una creación interrumpidos, ya sin envoltura, como se comprobó arriba), se borra. Después se crean `alt/{vault,thumbs,db,vault_cache}` y, en iOS, se aplica `excludeFromBackup(alt/)`.
5. **M5:** si `disableBiometrics`, `disableBiometricUnlock()` **ahora**.
6. Borrar `alt.db_created`.
7. `alt.pin_envelope = wrap(dekS, newPin, purpose: altPin, kdf: <kdf de la envoltura principal>)`. Es la **ÚLTIMA** escritura, la que marca que existe. Después se relee, se decodifica y se comprueba el kdf.
8. No se abre la sesión secundaria. Su BD se crea en el primer desbloqueo (la marca C1 está ausente).

Coste: 2 Argon2id.

---

## 9. Arranque, cortes y anomalías

`VaultBootstrap.decide` gana `_reconcileSecondary`, que corre DESPUÉS de la decisión sobre la principal y nunca la cambia.

**M4:** si leer `alt.pin_envelope` o `alt.db_created` **lanza** (por ejemplo `errSecInteractionNotAllowed` en iOS o un `EncryptedSharedPreferences` corrupto), el error se propaga al paso y **no se borra nada**: se registra y se sigue a la decisión de la principal. Nunca se hace `catch → null`.

| Estado al arrancar (lecturas sin error) | Acción |
|---|---|
| 1. Sin bóveda principal | borrar `allAltKeys` y `Documents/alt/` (Keychain de iOS o restos) |
| 2. Principal, sin la clave `alt.pin_envelope` y con `alt/` | borrar `alt/` y `alt.db_created` (creación o borrado interrumpidos) |
| 3. Principal, con `alt.pin_envelope` (aunque sea ilegible) y sin `alt/` | borrar `allAltKeys`: sin directorio no hay datos (reinstalación en iOS) |
| 4. Principal, `alt.pin_envelope` legible, `alt/` presente, `alt.db_created` presente y sin BD | **Dañada**: no se borra nada. En la secundaria, «No se pudo abrir la bóveda»; en la principal, «Dañada → Eliminar» |
| 5. `alt.pin_envelope` ilegible o con un kdf distinto (M3), con `alt/` | **Dañada**: no se deriva al desbloquear (G6) y no se borra nada. En la principal, «Dañada → Eliminar» |

- **Arranque (`main.dart`).** Se barre `tmp_plain` e `import_tmp` de las **dos** raíces: `PlainTempManager.sweepAll([VaultPaths.primary, VaultPaths.secondary])`, que es un no-op si `alt/` no existe y no lo crea.
- **Bloqueo.** El `purgeSync` común barre las dos raíces.

Cortes:
- **Crear:**
  - antes de escribir la envoltura (paso 7) no existe secundaria, y la fila 2 limpia;
  - si se pierde esa escritura (`dropLastWrites`), también aplica la fila 2;
  - entre el paso 5 y el 7, la biometría ya está apagada y la secundaria no existe, que es el lado seguro (M5).
- **Borrar:**
  - tras borrar la envoltura, aplica la fila 2;
  - si se pierde el borrado de la envoltura, la relectura lo repite;
  - si aun así quedara y faltara el directorio, aplica la fila 3.
- **Cambiar el PIN secundario:** es una sola escritura. Si se pierde, sigue valiendo el PIN viejo (misma DEK).

Ninguno de estos caminos toca `Documents/{vault,thumbs,db,vault_cache}` ni una clave de la principal. Todo borrado de `alt/` pasa por la comprobación de ruta del §6.13.

---

## 10. Datos del iPhone (migración)

**No hay migración.** La bóveda actual pasa a ser la principal sin cambiar nada: las mismas rutas, las mismas claves `vault.v1.*`, el mismo esquema v10, la misma envoltura (`purpose: pin`) y el mismo `pin_attempts`. `AppPaths` sigue resolviendo igual (ahora delega en `VaultPaths.primary`) y `VaultDatabase.instance` sigue siendo la principal.

Sin la clave `vault.v1.alt.pin_envelope`, los caminos nuevos solo leen:
- una lectura de esa clave;
- `alt/` existe → no.

Hay una sola derivación, y **no se crea ni se escribe nada** (M2). La interfaz cambia únicamente en una fila nueva de Ajustes.

Bajar de versión después de crear una secundaria deja `alt/` y `alt.*` sin usar, lo que es inocuo (B4).

---

## 11. Plan de pruebas

### 11.1 Infraestructura (`test/secondary/support/secondary_env.dart`)

Reutiliza `rotation_env.dart`: almacén en memoria con `dropLastWrites(n)` y un modo **`throwOnRead(key)`** nuevo (M4), directorio temporal, BD `sqflite_common_ffi` con dos instancias, `FakeCloud` con revisiones y Argon2 reducido.

Añade:
- `CountingArgon2Backend`: retardo configurable, contador de derivaciones concurrentes y de kdf usados.
- `snapshotOfPrimary()` / `expectPrimaryUntouched(before)`: hash de cada archivo bajo `Documents/` fuera de `alt/`, de cada clave no `alt` del almacén y del listado de Drive (nombres, MD5 y revisiones).
- `snapshotOfSecondary()` / `expectSecondaryUntouched(before)`: lo mismo para `alt/` y `alt.*`.
- **Arnés de cruce** (`crossing_harness.dart`). Fakes con `Completer` en cada `await` de una operación (galería, selector, fotograma, cifrado, nube, BD). Para cada punto de pausa: pausar → `lock()` → desbloquear la OTRA bóveda → reanudar → afirmar `expect…Untouched` de la otra bóveda, «ningún archivo de una raíz abre con la llave de la otra» y «registro de rotación sin cambios».

### 11.2 Pruebas

1. **G1 sin secundaria** (`g1_no_secondary_test`):
   - 1 derivación;
   - N arranques y desbloqueos (iOS y Android simulados) dejan el listado de `Documents/` y el almacén idénticos y **no crean `alt/`** (M2);
   - toda la suite actual pasa sin tocarla (`auth_controller_test`, `pin_stress_test`, `bootstrap_test`, `rotation/*`, `f9_restore_test`, `restore_generations_test`, `account_migration_test`, `sync_service_test`…).
2. **El PIN de una no abre la otra:**
   - con la sesión bloqueada, el principal abre `primary`, el secundario abre `secondary` y uno incorrecto da `false`;
   - envolturas intercambiadas → ninguna abre (`altPin` frente a `pin`) y la principal no se rompe;
   - `alt` ilegible o con otro kdf → la principal abre igual, sin derivar `alt` (M3) y en el mismo tiempo que sin secundaria.
3. **Con la sesión abierta (A2):**
   - `unlockWithPin(PIN secundario)` con la principal abierta → `false`, misma sesión y misma época;
   - al revés, igual;
   - `key_rotation_screen` con el PIN secundario → «PIN incorrecto» y la rotación intacta;
   - `reauthPrimary` con la secundaria abierta → `StateError`.
4. **Límite de intentos (C1):**
   - «4 fallos + secundaria», repetido ×N → la espera escala exactamente igual que con 4N fallos sin secundaria;
   - secundaria ×20 seguidos → no bloquea, y el estado queda igual al previo;
   - matar la app durante la derivación de la secundaria → queda el +1;
   - acertar la principal pone a cero;
   - un solo contador.
5. **Tiempos** (FakeAsync): con secundaria, 2 derivaciones concurrentes siempre y el mismo tiempo simulado hasta la decisión en los 3 casos.
6. **Aislamiento criptográfico:**
   - los `.vault`/`.thumb` de una no abren con las llaves `files`/`thumbs` de la otra;
   - recorrido del almacén: nada se desenvuelve con el PIN de la otra bóveda;
   - `filesKeyFor(gen, slot: X)` devuelve `null` con la otra bóveda abierta.
7. **Arnés de cruce (A1)**, en los dos sentidos: importación de galería (incluida la pausa en `source.thumbnail`, el fotograma de video y `insertItem`), importación por selector, regeneración de miniaturas, `onUnlocked` de cada bóveda, `trash.purgeExpired`, `CacheManager.enforce`, `VaultDatabase._open` (incluido el `onCreate`), `rekeyTo` (en cada paso), `ItemReencryptor` y el bucle de `reencrypting`, descargas sin conexión, exportar a Fotos y flush del snapshot.
8. **Cancelación al bloquear (M1):**
   - un lote de importación y la regeneración se cancelan;
   - el `progress` de una bóveda nunca se ve en la otra;
   - **los ganchos `onClear` están activos con la secundaria abierta primero tras arrancar**: ver un video completo primero, bloquear y comprobar que el `tmp_plain` de `alt/` está vacío;
   - matar la app → el arranque barre las dos raíces.
9. **Guardas:**
   - con la secundaria abierta: `sync.run()`, `notifyDataChanged()`, `flushSnapshotBeforeLock()` y `offline.reconcile()` no hacen nada (0 llamadas a la nube y `snapshot_dirty_at` igual);
   - cada método de `SlotGuardedCloudStorage` lanza;
   - `VaultDatabase.instance.database` y los repositorios de cola, migración y rotación lanzan `WrongVaultSlotError`;
   - recorrido de `VaultServices.real()`: ninguna llamada a la nube ni a la BD principal;
   - con la principal abierta, `VaultDatabase.secondaryInstance` lanza.
10. **La restauración de la principal queda intacta** (`primary_restore_intact_test`):
    - crear la secundaria, importar 20 items, usar Papelera y etiquetas, alternar bóvedas varias veces, cambiar el PIN secundario y eliminarla;
    - Drive y sus revisiones idénticos;
    - después, restaurar en un entorno limpio con el código → se descifra TODO lo de la principal y nada de la secundaria.
11. **Convivencia con la rotación**, en cada `RotationPhase`:
    - desbloquear la secundaria no cambia `vault.v1.rotation` (byte a byte) ni la hace avanzar;
    - al volver a la principal, la rotación se reanuda y termina; `expectRecoverable` según el §8 de DISENO_ROTACION;
    - con un registro: crear → `RotationInProgressException`; cambiar PIN y eliminar → permitidos.
12. **Cortes:**
    - crear tras cada paso del §8 y borrar tras cada paso del §6.13, con y sin `dropLastWrites(1)` → arranque completo → estado del §9, la principal desbloquea y `expectPrimaryUntouched`;
    - corte entre apagar la biometría y escribir la envoltura → biometría apagada y sin secundaria (M5).
13. **Arranque:**
    - las 5 filas del §9;
    - `throwOnRead(alt.pin_envelope)` → no se borra `alt/` (M4);
    - crear sobre una «Dañada» → rechazado, sin borrar nada;
    - reinstalación en iOS sin la BD principal → se descartan las llaves de las dos.
14. **Reglas del PIN:**
    - crear con un PIN igual, a distancia 1 o, con principal heredado `1234`, con `1234xx` → rechazado y no se escribe nada (M6);
    - `changePin` de la principal igual al secundario → `PinNotAllowedException` y envoltura sin cambios;
    - `changeSecondaryPin` con el PIN secundario actual incorrecto → rechazo y nada escrito;
    - correcto → el PIN viejo deja de abrir, el nuevo abre, misma DEK (el archivo abre).
15. **Operaciones de la principal con la sesión secundaria** → `StateError`, en todas las del §3.3, y también tras un `await` simulado (B6).
16. **UI:**
    - `test/ui/secondary_settings_test`: recorre Ajustes y la pantalla de inicio de la secundaria (textos y semántica) y además **provoca cada error dinámico** (M8): `.vault` ausente, `CloudSlotException`, esquema demasiado nuevo, BD ausente, fallo de importación. Falla si aparece «Google», «Drive», «nube», «código de recuperación», «llave maestra», «secundaria», «principal», «Face ID», «huella», «Diagnóstico», «Sincroniz», «sin conexión», «Cambiar PIN» o un correo;
    - `settings_test` ampliado (fila, crear, cambiar PIN, eliminar, «Dañada», aviso de biometría);
    - `pin_screen_test`: sin biometría automática si hay secundaria y con ella si no;
    - **ciclo `VaultRootNavigator`** (M7): principal → bloquear → secundaria → bloquear → principal, con los servicios y ajustes correctos en cada paso y el flush solo en la principal;
    - goldens de `SecondaryVaultScreen`.
17. **Esquemas futuros (h12):** plantilla `test/secondary/schema_upgrade_secondary_test.dart`. Cada migración futura se prueba también sobre una BD secundaria v10.
18. **SQLCipher real** (`integration_test/secondary_sqlcipher_test.dart`):
    - las dos BD; ninguna abre con la llave de la otra;
    - la principal abre igual tras crear y borrar la secundaria.

**Emulador, a mano.** Partir de una principal con datos reales, Drive y Papelera.
- Crear la secundaria y llenarla (fotos, el video de 24,9 MB, archivos).
- `am force-stop` a mitad de una importación en cada bóveda.
- Bloquear durante una importación de la principal y abrir la secundaria enseguida.
- Autobloqueo en las dos.
- Cambiar el PIN secundario y eliminar la secundaria.
- Antes y después: `files.list` de appDataFolder y `run-as … ls -R`. Fuera de `alt/` no cambia nada y `tmp_plain` queda vacío en las dos.
- Restaurar la principal en una instalación limpia.

---

## 12. Pasos de implementación

Cada paso cierra con analyze + test + build apk debug + commit en `dev-claude`. Hasta el paso 8 no hay nada visible para el usuario. Los pasos 1 a 6 son inocuos para el iPhone: sin secundaria, todo sigue igual, y lo cubre el test G1 de cada paso.

| # | Paso | Archivos | Tests | Est. |
|---|---|---|---|---|
| 1 | **`VaultSlot` y `VaultPaths` por bóveda** | nuevos `core/session/vault_slot.dart`, `core/services/vault_paths.dart`; `app_paths.dart` (delega en `VaultPaths.primary`); `plain_temp_manager.dart` (`sweepAll`, `purgeSync` de las dos raíces sin crearlas); `plain_residue.dart`; `platform_security.dart` (excluir `alt/` solo si existe); `main.dart` (barridos) | nuevo `test/secondary/vault_paths_test.dart`; nuevo `test/secondary/g1_no_secondary_test.dart` (no se crea `alt/`); `s15_test`, `plain_temp_manager_test` y `f7_security_test` de regresión | 0,5 d |
| 2 | **Sesión con bóveda, época y llaves ligadas** | `vault_session.dart` (`slot`, `epoch`, `ticket()`, `isUnlockedAs`, `…KeyFor(gen, slot:)`, `StateError` al cambiar de bóveda sin `clear`); nuevo `core/session/session_ticket.dart`; nuevo `core/session/session_hooks.dart` (`ensureInstalled`: ganchos comunes de bloqueo); adaptar a `slot: primary` las llamadas actuales de `vault_services.dart`, `media_opener.dart`, `thumbnail_loader.dart`, la regeneración y `item_reencryptor.dart` | nuevo `test/secondary/session_epoch_test.dart`; `keyring_test`, `f6a_*`, `f6b_streaming_test` y `s05_test` de regresión | 1 d |
| 3 | **BD por bóveda** | `vault_database.dart` (`secondaryInstance`; bóveda, ruta y marca fijas por instancia; conexión ligada a la época; comprobaciones en `_open` antes de `onCreate`/publicar y en `rekeyTo` antes de copiar/WAL/`rename`; snapshot solo de la principal) | nuevo `test/secondary/db_per_slot_test.dart`; `db_missing_guard_test`, `db_rekey_test`, `vault_database_test` y `m9_downgrade_test` de regresión | 1 d |
| 4 | **Guardas y compuertas de la principal** | nuevo `data/cloud/slot_guarded_cloud.dart` + `cloud_provider.dart`; `vault_services.dart` (`isUnlockedAs(primary)` en sync y sin conexión, `onDataChanged` con compuerta, `onUnlocked` con ticket); `key_rotation_service.dart` y `account_migration_service.dart` (ticket por paso, `_Stop` sin escribir estado) | nuevo `test/secondary/guards_test.dart`; `sync_service_test`, `rotation/*`, `account_migration_test` y `s17_lock_flush_test` de regresión | 1 d |
| 5 | **Época en las operaciones largas** | `gallery_import_service.dart`, `vault_import_service.dart`, `thumbnail_regeneration_service.dart` (`paths` inyectable, ticket y llaves capturadas, `check()` antes de cada escritura, cancelación en `onClear`); `trash_service.dart`, `cache_manager.dart`, `offline_service.dart`, `vault_file_fetcher.dart`, `media_exporter.dart`, `item_reencryptor.dart` (ticket) | nuevos `test/secondary/support/crossing_harness.dart` y `test/secondary/crossing_test.dart` (§11.2-7 y 8); `gallery_import_service_test`, `thumbnails_video_test`, `item_reencryptor_test`, `f5_trash_test` y `f4_export_test` de regresión | 1,5 d |
| 6 | **Llaves de la secundaria en `AuthController` + arranque** | `wrapped_key.dart` (`altPin`); `pin_attempt_limiter.dart` (`rawState`/`restoreRaw`); `auth_controller.dart` (`_verifyPinAny` en paralelo con C1, sesión abierta solo con su envoltura (A2), `reauthPrimary`, `_openSecondary` con `_openChecked`, `_requirePrimarySession` + recomprobación, `createSecondaryVault` (M4, M5, M6), `changeSecondaryPin` (C2), `deleteSecondaryVault`, colisión en `changePin`, `secondaryStatus` (M3), `allAltKeys` en `createVault`/`_commit`/`discardLocalKeys`, `PinNotAllowedException`); `vault_bootstrap.dart` (`_reconcileSecondary` sin `catch → null`); `key_rotation_screen.dart` (`reauthPrimary`) | nuevos `test/secondary/support/secondary_env.dart`, `test/secondary/auth_secondary_test.dart` (§11.2-2 a 6, 14 y 15) y `test/secondary/bootstrap_secondary_test.dart` (§11.2-13); `auth_controller_test`, `auth_rotation_test`, `pin_stress_test`, `s07_monotonic_test`, `bootstrap_test` y `key_rotation_screen_test` de regresión | 2 d |
| 7 | **Servicios de la secundaria y navegación** | `vault_services.dart` (`VaultServices.secondary()`: instancias propias, sin `_Core`); `main.dart` (servicios y ajustes recalculados por bóveda en cada desbloqueo y bloqueo, `beforeLock` de la bóveda abierta, `_handleAuthenticationSuccess`); `pin_screen.dart` (sin biometría automática con secundaria) | nuevo `test/secondary/secondary_services_test.dart` (importar → solo `alt/`); ciclo de `VaultRootNavigator` (M7); `vault_home_test` y `pin_screen_test` ampliados | 1 d |
| 8 | **UI de Ajustes** | nuevo `features/settings/secondary_vault_screen.dart` (crear, cambiar PIN, eliminar, «Dañada», aviso de biometría); `settings_screen.dart` (fila en la principal y Ajustes reducido sin «Cambiar PIN» en la secundaria); `settings_environment.dart` (`slot`); `pin_flows.dart` (flujos nuevos y `PinNotAllowedException`); textos neutros de errores en la secundaria (M8); `diagnostics_screen.dart` (sí/no/dañada) | nuevo `test/ui/secondary_settings_test.dart` (palabras prohibidas, también en errores dinámicos); `settings_test` ampliado; goldens | 1,5 d |
| 9 | **Batería transversal** | — | `test/secondary/{isolation,primary_restore_intact,rotation_coexistence,crash_points,schema_upgrade_secondary}_test.dart`; `integration_test/secondary_sqlcipher_test.dart` | 1 d |
| 10 | **Emulador y documentación** | `DECISIONES.md` (D65–D71), `REPORTE.md` (sección de la fase y «Pruebas de iPhone»), `CONTEXTO.md`, `PLAN.md` | prueba manual del §11 | 0,5–1 d |

**Total:** ≈ 11–11,5 días. Son ≈ 3 días más que la primera versión, sobre todo por la época y el arnés de cruce (A1).

**Decisiones a registrar:**
- **D65**: modelo principal/secundaria, nombres `alt` y la tabla de qué protege y qué no.
- **D66**: desbloqueo bloqueado = dos derivaciones en paralelo con el mismo kdf. El contador es compartido y solo acertar la principal lo pone a cero. Con sesión abierta nunca se cambia de bóveda; `reauthPrimary`.
- **D67**: `VaultPaths` y `VaultDatabase` por bóveda (sin raíz global mutable), época de sesión, llaves ligadas a la bóveda, ganchos de bloqueo comunes y guardas solo de la principal.
- **D68**: la secundaria no tiene Drive ni código de recuperación.
- **D69**: la biometría solo abre la principal, sin diálogo automático, y se ofrece apagarla antes de crear la secundaria.
- **D70**: Ajustes reducido y textos neutros (también en los errores).
- **D71**: reglas del PIN (distancia ≥ 2, prefijo con el heredado, colisión) y el cambio del PIN secundario solo desde la principal.

---

## 13. Riesgos abiertos y lo que solo se puede probar en el iPhone

1. **Dos Argon2id a la vez en iOS** (`runIsolated` ×2, 2 × 19 MiB). Medir el tiempo y la memoria. Si se serializan, el desbloqueo con secundaria tarda ≈ el doble (1–3 s), pero el tiempo sigue sin delatar cuál se abrió. Si una de las dos falla en nativo, `FallbackArgon2Backend` pasa a Dart el resto de la sesión, que es más lento. Hay que medir que no ocurra.
2. **Keychain que sobrevive a desinstalar** (claves `alt`): cubierto por las filas 1 y 3 del §9, simulado. Hay que confirmarlo en el dispositivo.
3. **Exclusión de iCloud de `Documents/alt/`** (`NSURLIsExcludedFromBackupKey` sobre un directorio que se crea después): `// iOS: sin probar`.
4. **Face ID sin diálogo automático**: comprobar que no salta solo tras el autobloqueo.
5. **Durabilidad** del borrado de `alt.pin_envelope` (Android `apply()`, Keychain): la cubren la relectura y `dropLastWrites`. Confirmarlo con `force-stop`.
6. **Errores de lectura del almacén en el arranque** (iOS `errSecInteractionNotAllowed` con el teléfono bloqueado): el §9 nunca borra ante un error. Confirmar que la app arranca igual.
7. **Cobertura del arnés de cruce.** Toda operación futura que escriba en disco o en la BD debe usar un ticket. Hay que añadirlo a la lista de revisión de cada fase siguiente.
8. **El límite forense del §7** no es un riesgo de implementación, pero el usuario debe aceptarlo antes de codificar.
9. Todo lo específico de iOS va marcado `// iOS: sin probar`.

---

## 14. Decisión sobre cada hallazgo de la revisión

| Hallazgo | Decisión |
|---|---|
| C1 | **Aplicado:** solo acertar la principal pone el contador a cero; acertar la secundaria devuelve el estado previo (`rawState`/`restoreRaw`). Tests §11.2-4 |
| C2 | **Aplicado** (opción recomendada): sin «Cambiar PIN» dentro de la secundaria. Se cambia desde la principal, con el PIN principal + el secundario actual, comparando en memoria. Sin oráculo |
| A1 | **Aplicado**, con la alternativa estructural: `VaultPaths` y `VaultDatabase` por bóveda en lugar de `AppPaths.bind` global, **más** época de sesión con ticket, llaves ligadas a la bóveda y cancelación al bloquear. Arnés de cruce (§11.2-7). Se eligió la combinación porque la instancia por bóveda hace imposible por construcción que una operación tardía resuelva contra la otra raíz o la otra BD; la época cubre las llaves y las escrituras entre bloqueos de la misma bóveda |
| A2 | **Aplicado:** con sesión abierta solo se prueba la envoltura propia; `reauthPrimary` en la pantalla de rotación; `openKeyring` de otra bóveda sin `clear` → `StateError` |
| M1 | **Aplicado:** `SessionHooks.ensureInstalled()`, instancias propias de la secundaria, sin `_Core` |
| M2 | **Aplicado:** excluir `alt/` solo si existe, sin crearlo; test G1 en disco |
| M3 | **Aplicado:** el kdf de `alt` debe ser idéntico al de la principal; si no, «Dañada» sin derivar |
| M4 | **Aplicado:** crear exige que la clave esté ausente; un error de lectura nunca borra |
| M5 | **Aplicado:** la biometría se apaga antes de escribir la envoltura |
| M6 | **Aplicado:** con un PIN principal heredado más corto, el secundario no puede empezar por él |
| M7 | **Aplicado:** servicios y ajustes recalculados por bóveda en `main.dart`; test del ciclo |
| M8 | **Aplicado:** textos neutros y barrido de los errores dinámicos |
| B1 | **Aplicado:** las decisiones van de D65 a D71 |
| B2 | **Aplicado:** se precisa en D66; `_openSecondary` usa `_openChecked` |
| B3 | **Documentado** (§6.10) |
| B4 | **Documentado** (§7) |
| B5 | **Aplicado:** el `DiagnosticsBuffer` se vacía también al abrir sesión |
| B6 | **Aplicado:** `_requirePrimarySession` se repite tras cada `await` largo |
| B7 | **Documentado y aceptado** (§7) |
| g1 | Aplicado (= C2) |
| g2 | **Aplicado:** sin `alt.key_check` |
| g3 | **Aplicado** (= M1) |
| g4 | **Aplicado:** sin `openedSlot` (la instancia es de una sola bóveda) |
| g5 | Se mantienen las guardas |
| h1–h12 | Incorporadas en el §11.2 (4, 3, 7, 8, 1, 2, 13, 12, 14, 16, 16 y 17) |
