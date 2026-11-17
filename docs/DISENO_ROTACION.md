# Rotación de la llave maestra (DEK) — diseño final (S-11, v2 fase 1)

Estado: diseño aprobado para implementar; sin código todavía. Incorpora la revisión independiente (críticos C1–C2, altos A1–A5, medios M1–M11, bajos L1–L8). Las decisiones nuevas empiezan en **D60** (D59 ya existe: `onDowngrade` lanza `VaultSchemaTooNewException`).

Hay datos reales en un iPhone. Por eso todo se diseña para que un corte en cualquier instante (app matada, bloqueo, sin red, sin batería) deje SIEMPRE una forma de recuperar la bóveda, y para que nada destructivo ocurra sin verificar antes el estado real.

---

## 0. Qué hace y garantías

"Generar código nuevo" y "Rotar llave maestra" (Ajustes > Seguridad) lanzan el MISMO proceso (`KeyRotationService`); solo cambia el texto de la introducción.

1. Crea una DEK nueva y un código de recuperación nuevo **B**. B se muestra y se confirma por posiciones, igual que en el onboarding.
2. Re-cifra todos los `.vault` y `.thumb` (también los que solo están en Drive y los de la Papelera) y la BD SQLCipher.
3. Sube a Drive un conjunto nuevo completo y lo verifica (tamaño + MD5).
4. Borra de forma permanente (`files.delete`) el conjunto viejo, incluidos sus respaldos y revisiones.
5. Deja el PIN envolviendo la DEK nueva y ofrece reactivar la biometría.

Garantías:

- **G1. B basta desde que se confirma.** Desde ese momento hay en Drive un respaldo "puente" que B abre. Antes del corte da el conjunto viejo completo; después, el nuevo. El código anterior **A** funciona hasta que se borra su respaldo y después no abre nada.
- **G2. Nunca hay un conjunto a medias que se pueda restaurar.** El respaldo nuevo se sube el ÚLTIMO y el viejo se borra el PRIMERO.
- **G3. La BD nunca falta en disco.** La app nunca crea una BD vacía si ya existe una bóveda.
- **G4. Nada en claro en disco.** El re-cifrado se hace bloque a bloque en memoria. Los temporales son siempre texto cifrado y se barren.
- **G5. Nada se borra en Drive** si el conjunto viejo cambió desde la congelación (otro dispositivo) o si las cuentas de la BD no cuadran.
- **G6. Al terminar, nada abre con la DEK vieja.** Ni en el teléfono ni en Drive (revisiones incluidas). No existe ningún material que dé la DEK nueva a partir de A.

Fuera de alcance (se dice al usuario): las copias que alguien con A ya descargó antes siguen abriéndose. La rotación protege desde ahora en adelante. Lo importado durante la rotación solo queda respaldado a partir del corte (por eso se bloquea el borrado de originales de la galería, ver §7).

---

## 1. Generaciones y nombres

Cada DEK tiene una generación `gen`. La bóveda actual es `gen 1` y conserva TODOS sus nombres actuales. La rotación va de `fromGen` a `toGen = max(key_gen local, mayor gen visto en Drive) + 1`; así nunca se reutiliza un nombre, aunque otro teléfono haya rotado antes.

| Recurso | gen 1 (actual) | gen N ≥ 2 |
|---|---|---|
| Archivo local | `vault/<uuid>.vault` | `vault/<uuid>.kN.vault` |
| Miniatura local | `thumbs/<uuid>.thumb` | `thumbs/<uuid>.kN.thumb` |
| Archivo en Drive | `<uuid>.vault` | `<uuid>.kN.vault` |
| Miniatura en Drive | `<uuid>.thumb` | `<uuid>.kN.thumb` |
| Snapshot de la BD | `vault_db.snapshot` | `vault_db.kN.snapshot` |
| Respaldo de llaves | `recovery_backup.json` | `recovery_backup.kN.json` |
| Respaldo puente (DEK de `fromGen` envuelta con B) | — | `recovery_backup.bridge.k<fromGen>.json` |
| Item dañado en cuarentena (M6) | `lost_<uuid>.k1.vault` | `lost_<uuid>.kN.vault` |
| BD local | `db/vault_secure.db` (nombre fijo). Durante la rotación también `db/vault_secure.db.k<fromGen>` (copia de seguridad cifrada con la llave vieja) y `db/vault_secure.db.k<toGen>.tmp` (exportación en curso) | |

API:
- `lib/data/cloud/cloud_names.dart` (se saca de `sync_service.dart`): `CloudNames.file(id, {gen = 1})`, `thumb(id, {gen})`, `recoveryBackup({gen})`, `bridgeBackup(fromGen)`, `dbSnapshot({gen})`, `quarantine(id, gen)` y `CloudNames.parse(name) → CloudNameInfo?{kind, itemId?, gen}`. `parse` valida UUID v4 y `gen` en 2..9999 con sufijo (en `gen 1` no hay sufijo), y rechaza cualquier otra cosa.
- `AppPaths.vaultRelativePath(id, {gen = 1})`, `thumbRelativePath(id, {gen = 1})`. La expresión S-15 acepta `(?:\.k[2-9][0-9]{0,3})?` antes de `.vault`/`.thumb` y nada más.
- **Fuente de verdad de qué llave abre un item: `vault_items.keyGen`.** `encryptedPath`, `thumbPath` y los nombres de Drive se derivan de `(id, keyGen)` y cambian en la misma transacción.

---

## 2. Persistencia

### 2.1 Almacén seguro (`flutter_secure_storage`)

| Clave | Contenido | Vida |
|---|---|---|
| `vault.v1.rotation` | `RotationRecord` JSON: `{v, id, fromGen, toGen, phase, reason, oldKeyCheck, newKeyCheck, accountEmail, biometricWasEnabled, startedAt, updatedAt, lastError, resumePhase}` | de `prepared` a `finalizingLocal` (se borra lo último) |
| `vault.v1.rotation.next_pin_envelope` | `WrappedKey(purpose: pin)` de DEK_new con el PIN | de `prepared` a `switchingLocal` |
| `vault.v1.rotation.next_recovery_backup` | `RecoveryBackup` de DEK_new con B | de `prepared` a `switchingLocal` (pasa a `vault.v1.recovery_backup`) |
| `vault.v1.key_gen` (nueva, permanente) | generación vigente; ausente = 1 | permanente |
| `vault.v1.db_created` (nueva, permanente) | la BD de esta bóveda ya se creó (C1) | permanente |

**No hay enlaces entre DEK** (se descartan `link_fwd`/`link_bwd`, ver D63). Durante las fases con dos llaves, la DEK nueva se obtiene con `next_pin_envelope` (un Argon2id más al desbloquear, ≈ 0,5–1,5 s). Después de `switchingLocal` no queda en el teléfono nada que dé la DEK vieja.

### 2.2 BD — esquema v10 incremental (`VaultSchema.upgrade`: `if (from < 10) await addRotationSchema(db)`, idempotente)

```sql
-- solo si falta (PRAGMA table_info), como addTrashColumns:
ALTER TABLE vault_items ADD COLUMN keyGen INTEGER NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS idx_items_keygen ON vault_items(keyGen);

CREATE TABLE IF NOT EXISTS rotation_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  rotationId TEXT NOT NULL,          -- = RotationRecord.id (A3)
  fromGen INTEGER NOT NULL, toGen INTEGER NOT NULL,
  frozenAt INTEGER NOT NULL,
  frozenItems INTEGER NOT NULL, frozenFolders INTEGER NOT NULL,
  itemsInserted INTEGER NOT NULL DEFAULT 0, itemsDeleted INTEGER NOT NULL DEFAULT 0,
  foldersInserted INTEGER NOT NULL DEFAULT 0, foldersDeleted INTEGER NOT NULL DEFAULT 0,
  oldBackupDriveId TEXT, oldBackupMd5 TEXT,
  oldSnapshotDriveId TEXT, oldSnapshotMd5 TEXT,
  bridgeDriveId TEXT
);
CREATE TABLE IF NOT EXISTS rotation_old_files (   -- A5: lista exacta del conjunto viejo
  driveId TEXT PRIMARY KEY, name TEXT NOT NULL, md5 TEXT, itemId TEXT,
  kind TEXT NOT NULL,                              -- backup | snapshot | file | thumb
  quarantine INTEGER NOT NULL DEFAULT 0            -- M6: no se borra, se renombra
);
```

Las tablas quedan vacías fuera de una rotación (como `migration_*`). Los **triggers de cardinalidad** (C1) se crean al congelar y se borran en `finalizingLocal`. No son tablas: crearlos o quitarlos no recrea nada.

```sql
CREATE TRIGGER IF NOT EXISTS rot_items_ins AFTER INSERT ON vault_items BEGIN UPDATE rotation_state SET itemsInserted = itemsInserted + 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS rot_items_del AFTER DELETE ON vault_items BEGIN UPDATE rotation_state SET itemsDeleted = itemsDeleted + 1 WHERE id = 1; END;
-- ídem rot_folders_ins / rot_folders_del
```

Guarda de cardinalidad: `COUNT(vault_items) == frozenItems + itemsInserted − itemsDeleted` (ídem carpetas) y `rotation_state.rotationId == RotationRecord.id`. Una BD vacía, una BD restaurada o una de otra instalación no tienen la fila o no cuadran, y lo destructivo se bloquea.

`VaultItemModel` gana `final int keyGen` como parámetro **requerido** (el compilador señala todos los sitios que crean items). `fromMap`: `?? 1`.

### 2.3 Disco

- `vault_cache/rotation/` guarda fuentes `gen 1` descargadas (cifradas).
- Los `*.part` de salida (cifrados con la llave nueva) se escriben al lado del destino.
- Ambos se barren al reanudar la rotación y al arrancar.
- Nunca hay texto en claro: el claro solo existe en búferes de memoria de ≤ 2–3 bloques de 1 MiB, que se ponen a cero al soltarlos (mejor esfuerzo).

---

## 3. Máquina de estados

Regla general: **la fase es una pista**. Cada paso es idempotente y, antes de actuar, comprueba el mundo: qué llave abre la BD, qué DEK da `pin_envelope`, qué archivos existen y con qué `fileId`, las huellas de Drive y la cardinalidad. Esto cubre también escrituras perdidas del almacén seguro (Android puede escribir con `apply()`).

| # | Fase | Qué hace | ¿Cancelable? | Siguiente |
|---|---|---|---|---|
| 1 | `prepared` | Escritos `next_pin_envelope`, `next_recovery_backup` y el registro (en ese orden; los huérfanos sin registro se barren). B mostrado, **sin confirmar**. Sesión todavía con una sola llave (gen 1). | sí | `confirmed` |
| 2 | `confirmed` | B confirmado. Espera las **precondiciones duras** (A4): sesión de Google en `accountEmail`, red permitida (Wi-Fi si "solo Wi-Fi"), 0 trabajos `file`/`thumb` pendientes o en error, ningún item `pendiente`/`subiendo`/`error` salvo los aceptados como perdidos en la hoja previa. | sí | `freezing` |
| 3 | `freezing` | (a) Registro `phase = freezing` (de aquí en adelante `SyncService` ve la rotación y no sube metadatos). (b) Espera o cancela cualquier flush o subida de snapshot en vuelo. (c) Con la puerta de la BD tomada: cuentas, exportación de la copia (todas las filas `keyGen = 1`), creación de `rotation_state` + triggers; se suelta la puerta. (d) Sube ESA copia como `vault_db.snapshot` (crear, verificar, borrar los demás con ese nombre, patrón S-04) y guarda su id/MD5. (e) Sube el puente `recovery_backup.bridge.k1.json` (S-04) y guarda su id. (f) Lista appDataFolder y llena `rotation_old_files` con todos los nombres `gen 1` + `recovery_backup.json` (id/MD5) + snapshot + puente. | sí (deshacer: borrar el puente en Drive, quitar triggers y filas, borrar secretos y registro) | `reencrypting` |
| 4 | `reencrypting` | Al entrar: si la biometría estaba activa, se desactiva (`biometricWasEnabled = true`; el archivo guardaba la DEK vieja) y la sesión pasa a dos llaves (`current = toGen`, `previous = fromGen`). Re-cifra item por item (§5). La sincronización sube los `.k2` en paralelo. | **no** (solo pausa) | `uploading` |
| 5 | `uploading` | Espera a que cada item `keyGen = toGen` (no perdido) tenga copia en Drive con nombre `.k2` cuyo tamaño/MD5 (por `list()`) coincidan con `cloudSize/cloudMd5` y con el `.k2` local si existe (M4). Comprueba también que cada `.k2` local abre con la llave nueva (`verifyFinal` + `fileId`). | no | `rekeyingDb` |
| 6 | `rekeyingDb` | BD → llave nueva por copia verificada (§6). | no | `switchingLocal` |
| 7 | `switchingLocal` | `recovery_backup` ← `next_recovery_backup`; `key_check` ← nuevo; `key_gen` ← `toGen`; `pin_envelope` ← `next_pin_envelope` (la ÚLTIMA de las tres que importan); borrar `next_*`; borrar `db.k<fromGen>`. La sesión queda con una sola llave (nueva). | no | `uploadingSnapshot` |
| 8 | `uploadingSnapshot` | Guardas: `rotationId` coincide, cardinalidad cuadra, todas las filas `keyGen = toGen`, 0 pendientes. Exporta la copia (gen nueva) y la sube como `vault_db.k2.snapshot` (crear, verificar, S-04). | no | `uploadingBackup` |
| 9 | `uploadingBackup` | Guarda A5 (huellas del conjunto 1 intactas, ningún nombre `gen 1` fuera de la lista). Sube `recovery_backup.k2.json` (crear, verificar, S-04). **CORTE.** Fija `recoveryUploadedSha` = SHA(B). **Descongela** la sincronización con nombres de `toGen` (M10). | no | `deletingOldCloud` |
| 10 | `deletingOldCloud` | Guarda A5 antes de cada pasada. Borra POR LISTA (`rotation_old_files`), en orden: `recovery_backup.json` → puente → `vault_db.snapshot` → blobs. 404 cuenta como éxito. Los marcados `quarantine` se renombran a `lost_*` (solo metadatos) en lugar de borrarse. | no | `finalizingLocal` |
| 11 | `finalizingLocal` | Barre restos locales `gen 1` y `*.part`; `DROP TRIGGER rot_*`; vacía `rotation_state` y `rotation_old_files`; borra el registro (lo último). Muestra "Rotación terminada" y ofrece reactivar la biometría. | — | (sin rotación) |

Bloqueos (guardan `resumePhase`; la UI ofrece la acción): `blockedQuota`, `blockedLocalSpace`, `blockedSignIn` (sin sesión o con otra cuenta), `blockedCorrupt` (§9) y `blockedForeign` (registro y BD no coinciden, A3/L8: "Hay restos de una rotación que no corresponde a esta bóveda — Descartar restos"; descartar no borra nada en Drive). Las pausas por red no son fases: es un mensaje en `RotationStatus`, como en la migración.

Se reanuda sola al desbloquear (`VaultServices.onUnlocked`) y al volver la red, salvo en `prepared`, `confirmed` sin precondiciones y `blocked*`.

---

## 4. Llaves en sesión y desbloqueo

### 4.1 Preparar (`AuthController.prepareRotation(pin, {reason, toGen})`, dentro de `_serialized`)

Exige: sesión abierta, sin registro de rotación, sin `migration_state` y con sesión de Google. Pasos: `_verifyPin` (cuenta intento) → DEK_old. DEK_new = 32 B de `Random.secure()`. Código B nuevo. Se escriben `next_recovery_backup = createBackup(DEK_new, B)`, `next_pin_envelope = wrap(DEK_new, PIN)` y el registro (`prepared`). Devuelve el código formateado, que vive solo en memoria. Coste: 3 Argon2id.

Además: `regenerateNextRecoveryCode(pin)` **solo en `prepared`** (M1), `confirmRotationCode()` (→ `confirmed`) y `abandonRotation()` (hasta `freezing`).

El respaldo puente se crea en `freezing` con DEK_old (en sesión) y el mismo B. B no se guarda: el puente se genera al confirmar, cuando el código aún está en memoria, y se escribe en `vault.v1.rotation.bridge_backup` hasta subirlo (se borra al subirlo). Si la app muere en `confirmed` antes de generarlo, se vuelve a `prepared` y se muestra un código nuevo.

**¿El puente le da a A algo nuevo?** No. El puente es DEK_old envuelta con Argon2id(B) y un salt propio. Quien tiene A ya tenía DEK_old y no puede abrir el puente. Quien tiene B obtiene DEK_old, que es un código de confianza y una llave que ya se da por expuesta. DEK_new nunca se envuelve con nada derivado de A, ni en Drive ni en el teléfono (no hay enlaces), y los blobs y el snapshot nuevos se cifran solo con subllaves de DEK_new. El puente se borra con el conjunto viejo.

### 4.2 Desbloqueo

```
DEK_p = pin_envelope.unwrap(PIN)              // 1 Argon2id, cuenta 1 intento
rec   = RotationKeyStore.load()
si rec == null                          -> keyring simple (gen = key_gen)
si kc(DEK_p) == rec.newKeyCheck         -> keyring simple (gen = toGen)        // tras switchingLocal
si kc(DEK_p) == rec.oldKeyCheck:
     si fase <= freezing                -> keyring simple (gen = fromGen)
     si no: DEK_n = next_pin_envelope.unwrap(PIN)   // 2.º Argon2id, NO cuenta otro intento
            -> keyring doble (current = toGen, previous = fromGen)
            (si next_pin_envelope falta o no abre: blockedCorrupt; la sesión abre solo con la vieja y la UI pide el código B para recuperar DEK_new desde next_recovery_backup)
si no coincide con ninguno              -> blockedForeign (L8), sesión con DEK_p
```

- **Biometría:** desactivada desde `reencrypting` hasta el final, en que se ofrece reactivarla. En `prepared`, `confirmed` y `freezing` sigue funcionando con la DEK vieja.
- **`changePin`:** prohibido mientras exista el registro (M2). El botón aparece deshabilitado con "Disponible al terminar la rotación".
- **`lock()`:** sin cambios (destruye ambas jerarquías).

### 4.3 `VaultKeyring` (`lib/core/session/vault_keyring.dart`)

```dart
class VaultKeyring {
  final int currentGen; final KeyHierarchy current;      // con la que se CIFRA
  final int? previousGen; final KeyHierarchy? previous;  // solo reencrypting..rekeyingDb
  KeyHierarchy forGen(int gen);                          // StateError si no está
  List<(int, KeyHierarchy)> get dbCandidates;            // previous primero, luego current
  void destroy();
}
```

`VaultSession.keys`, `filesKey` y `keysOrNull?.thumbs` siguen siendo `current` (importar y escribir). Novedades: `filesKeyFor(gen)`, `thumbsKeyFor(gen)` y `dbCandidates`. `VaultDatabase` abre probando `dbCandidates` (con una consulta de verificación `SELECT count(*) FROM sqlite_master`) y recuerda qué generación abrió (`openedGen`). Así sobra `dbGen` en el registro.

---

## 5. Re-cifrado de un item (`lib/data/rotation/item_reencryptor.dart`)

Orden: items locales pequeños → grandes → solo en la nube; también los de la Papelera (`getItemsByKeyGen(fromGen, includeTrashed: true)`). Se salta un item `inUse` (visor o streaming) y se deja para el final de la vuelta. Mientras se trabaja con él, `markInUse` propio.

1. **Fuente.** Si existe `vault/<id>.vault` local con el `fileId` registrado, esa. Si no, o si falla la autenticación, se baja de Drive a `vault_cache/rotation/<id>.src.part` verificando tamaño + MD5 + `fileId`. Esa descarga no marca `en_cache`.
2. **Re-cifrado en streaming.** `VaultFileReader.open(src, oldFiles, verifyFinal, expectedFileId)` → `DecryptingByteSource implements VaultByteSource` (SHA-256 del claro al vuelo, búferes a cero) → `encryptSource(dest: vault/<id>.k2.vault.part, newFiles)` con un encabezado nuevo (`fileId` aleatorio nuevo).
3. **Comprobaciones.** SHA-256 == `contentHash`. Pasada de verificación completa del `.part` con la llave nueva (`verifyFullPass`, activa por defecto). Se calcula su MD5 para la verificación de `uploading`.
4. **Miniatura.** `decryptBytes(old, expectedFileId)` → `encryptBytes(new)` → `thumbs/<id>.k2.thumb.part`. Si falta y no se puede bajar, `thumbPath = NULL` y se cuenta (L5: el preflight avisa de cuántas miniaturas de items solo-nube se perderían).
5. `rename` de los `.part` (mismo directorio, atómico).
6. **Transacción condicional** (M4), dentro de la misma transacción borrando y re-encolando las filas `file`/`thumb` de `sync_queue` (nunca `delete_remote`):
   `UPDATE vault_items SET keyGen=?, encryptedPath=?, fileId=?, thumbPath=?, thumbFileId=?, driveFileId=NULL, cloudMd5=NULL, cloudSize=NULL, thumbDriveFileId=NULL, syncStatus='pendiente' WHERE id=? AND keyGen=? AND encryptedPath=?`
   Si no afecta a ninguna fila (otro cambio entretanto), se borran los `.k2` y se reintenta en la siguiente vuelta.
7. Se borran los locales `gen 1` y la fuente. Si el item está en uso, se aplaza hasta `releaseInUse`. El barrido de la reanudación borra las rutas `gen 1` de todo item ya en `toGen`.

**Espacio:** los items solo en la nube se procesan de uno en uno, con un tope `maxPendingLocalBytes` (= límite de caché, 500 MB por defecto) de `.k2` locales pendientes de subir. Si se alcanza, se espera a que drene la subida.

**Dañados** (fuente local y de Drive fallan, o el SHA no coincide): se pasa a `blockedCorrupt` con la lista. "Omitir" deja el item como `error` con `keyGen = toGen` y marca su blob en `rotation_old_files.quarantine = 1`: no se borra, se renombra a `lost_<uuid>.k1.vault` (M6). Desde Ajustes > Almacenamiento se puede eliminar después.

---

## 6. BD y snapshot

### 6.1 `VaultDatabase.rekeyTo(newKeys)` (C1, L6)

1. Toma la puerta exclusiva `_gate` (la BD mide pocos MiB, así que es < 1 s). Pausa el worker de sincronización. Copia los bytes de ambas llaves SQLCipher a cadenas propias: un `lock()` a mitad no las pone a cero bajo el código. Si se bloquea antes del paso 6, se aborta sin tocar el archivo; después, se termina el registro.
2. Cuentas de todas las tablas (`vault_items`, `folders`, `sync_queue`, `migration_*`, `tags`, `item_tags`, `rotation_*`) y `PRAGMA wal_checkpoint(TRUNCATE)`.
3. `ATTACH DATABASE '<db>.k2.tmp' AS k2 KEY "x'<hex nuevo>'"`; `SELECT sqlcipher_export('k2')`; `PRAGMA k2.user_version = 10`; `DETACH`; se cierra la conexión.
4. Verifica `.k2.tmp`: abre con la llave nueva; `PRAGMA integrity_check` = ok; `cipher_integrity_check` sin filas; mismas cuentas; `user_version`; los triggers `rot_*` existen; con la llave vieja NO abre.
5. **Copia** (no mueve) `db → db.k1`, con flush.
6. `rename(db.k2.tmp → db)`: reemplazo atómico en el mismo directorio (POSIX `rename(2)`, Android e iOS). **No hay instante sin `db`.**
7. Siguiente fase. `db.k1` se borra en `switchingLocal`.

Cortes: antes de 6, la `db` vieja está intacta y se repite el paso (se borran `.k2.tmp` y `db.k1`). Después de 6, la apertura por candidatos encuentra la llave nueva.

### 6.2 La app nunca crea una BD vacía con una bóveda existente (C1)

- `VaultDatabase._open`: si `vault.v1.db_created == 'true'` y el archivo no existe → `VaultDatabaseMissingException` (nunca `onCreate`). Si el archivo existe y falta la marca (bóvedas actuales del iPhone) → se escribe la marca. La creación solo ocurre con la marca ausente (primer uso tras `createVault`). `RestoreService._install` escribe la marca al instalar.
- `main.dart` (iOS, "Keychain sin BD"): solo se llama a `discardLocalKeys` si NO existen `db/vault_secure.db*` NI `db.k*` / `*.tmp`. Con un registro de rotación pero sin ningún archivo, es una reinstalación: se descarta todo, registro incluido (A3). Si hay restos `db.k*`/`.tmp` sin `db`, no se descarta nada: se pide el PIN y la reparación elige `.tmp` si abre con la llave nueva y verifica, o restituye `db.k1` si abre con la vieja.
- `discardLocalKeys()` y `_commit()` (restauración) borran además `vault.v1.rotation*`, `key_gen`, `db_created` (`_commit` vuelve a escribir `key_gen` y `db_created` restaurados) (A3/L7).

### 6.3 Snapshot ligado a su generación (C2)

- `exportEncryptedSnapshot()` devuelve `SnapshotCopy{file, dbGen (= openedGen), minKeyGen, maxKeyGen}` (consultados bajo la puerta).
- `SyncService._uploadSnapshotFile(copy)` es la guarda en el punto más bajo: nombre = `CloudNames.dbSnapshot(gen: copy.dbGen)`, y **se niega** (lanza `StateError` de programa y el trabajo queda en error) si `minKeyGen ≠ dbGen` o `maxKeyGen ≠ dbGen`, o si hay un registro de rotación en fase `freezing`..`uploadingBackup` y quien llama no es la rotación (parámetro `rotationTicket`). Esto cubre el flush al bloquear en vuelo, `AccountMigrationService._finalize`, `run(force: true)` y cualquier regresión futura.
- Las subidas de snapshot y de respaldo de la rotación son "crear archivo nuevo → verificar → borrar los demás con ese nombre" (S-04). Fuera de la rotación, la sincronización normal sigue como hoy (snapshot con `files.update`; sus revisiones se borran junto con el archivo en la próxima rotación).

---

## 7. Interacciones con el resto de la app

`SyncService` recibe un `RotationGuard { RotationPhase? phase; int fromGen, toGen; }`, que lee el registro y se actualiza con `KeyRotationService.status`.

- **Sincronización:**
  - `_uploadItemFile` usa `CloudNames.file(id, gen: item.keyGen)` y **se niega a subir nombres `fromGen`** entre `freezing` y el corte.
  - `markCloudVerified` es condicional (`WHERE id=? AND keyGen=? AND encryptedPath=?`): si no afecta a ninguna fila, el trabajo se da por hecho **sin borrar nada en Drive** (M4).
  - Respaldo y snapshot congelados entre `freezing` y el corte; después, con nombres de `toGen`.
  - `delete_remote` busca y borra los nombres de todas las generaciones del item, más `lost_*`.
  - `VaultFileFetcher._markLocal` es condicional a `encryptedPath` (M4).
- **Borrar originales de la galería (A1):** mientras exista un registro (cualquier fase), `SyncService.cloudVerifier` devuelve `false` y `GalleryImportService.pendingOriginalsCount` devuelve 0. Aviso: "Podrás borrar los originales cuando termine la rotación".
- **Caché LRU:** no se suspende. En `reencrypting`, `CacheManager.enforce` excluye `keyGen = fromGen` (evita bajarlos dos veces).
- **Visor, streaming, exportar, miniaturas:** la llave sale de `filesKeyFor(item.keyGen)`/`thumbsKeyFor(item.keyGen)`. Antes de abrir se relee la fila (`items.getItem`); si el archivo desapareció entre la lectura y la apertura, se reintenta una vez con la fila fresca. La caché de miniaturas ya usa `id|ruta` como clave.
- **Regeneración de miniaturas (D50):** en pausa mientras haya registro.
- **Importar, mover, renombrar, etiquetar, Papelera:** permitidos. Lo nuevo nace en `currentGen`. `purgeExpired` y "Eliminar definitivamente" funcionan: el `cleaner` borra las rutas reales del item y las de todas las generaciones, y los triggers cuentan las bajas.
- **Etiquetas (v9):** no se tocan; viajan en ambos snapshots.
- **Cambio de cuenta (D52):**
  - Excluyentes en ambos sentidos (`start` de cada uno comprueba al otro). "Cerrar sesión de Google" desactivado durante la rotación.
  - Cuenta distinta al reanudar → `blockedSignIn`.
  - `_isVaultFile` de la migración usa `CloudNames.parse`.
  - **M7:** `keepOldAccountData` persiste `migration.v1.old_account_kept = <correo>`. La hoja previa de la rotación avisa: "Tu cuenta anterior (correo) todavía guarda una copia que abre tu código anterior" y ofrece borrarla (reutiliza el borrado de `deleteOldAccountData` con su selector de cuenta).
- **Bloqueo, autobloqueo, app matada:** `session.addOnClear(rotation.pause)`. Se pierde como mucho el item en curso (sus `.part` se barren). La rotación solo avanza con la app desbloqueada y en primer plano.
- **Sin red / solo Wi-Fi:** en `reencrypting` los items locales siguen sin red; lo demás espera con el mensaje de pausa.
- **Restauración en otro teléfono:**
  - `probe()` lista todos los archivos de respaldo (`recovery_backup*.json`, incluidos duplicados, M1) y los empareja con su snapshot. `verifyCode` prueba, en orden, respaldos principales de mayor `gen`, puentes y principales menores (cuenta como 1 intento).
  - Si el código abre una generación menor que la mayor completa → aviso M8 (texto en §8).
  - `_reconcileStaged` usa `CloudNames.file(id, gen: row.keyGen ?? 1)`, vacía `rotation_state`/`rotation_old_files`, hace `DROP TRIGGER IF EXISTS rot_*` y acepta v6–v10.
  - `commitRestore` escribe `key_gen`.
  - Un teléfono restaurado en `gen G` barre en segundo plano los nombres `gen < G` (respaldo primero, siempre por lista y con la guarda A5 sobre su propio estado). Nunca borra generaciones mayores.
- **Generaciones abandonadas (M11):** si se detectan nombres `.kN` con `N > key_gen` sin `recovery_backup.kN.json` y sin rotación local, Ajustes > Almacenamiento muestra "Limpiar restos de una rotación interrumpida (X MB)", con confirmación. No es automático.

---

## 8. Qué código sirve en cada momento y textos

| Momento | Restaurar con A | Restaurar con B | Qué le decimos al usuario |
|---|---|---|---|
| `prepared` (B en pantalla, sin confirmar) | ✅ | ❌ | "Anota este código nuevo." |
| `confirmed` (esperando red, subidas…) | ✅ | ❌ | "Aún no empezó. Mientras tanto sigue valiendo tu código anterior." |
| `freezing`, tras subir el puente | ✅ | ✅ (conjunto viejo) | — |
| `reencrypting` … `uploadingBackup` | ✅ (estado al congelar) | ✅ (vía puente, estado al congelar) | "Ya basta con tu código NUEVO. El anterior dejará de servir al terminar." |
| Corte (`recovery_backup.k2.json` verificado) | ✅ (hasta el paso siguiente) | ✅ (conjunto nuevo completo) | — |
| `deletingOldCloud`, tras borrar `recovery_backup.json` | ❌ | ✅ | — |
| Terminado | ❌ | ✅ | "Rotación terminada. Tu código anterior ya no abre nada: destrúyelo." |

Lo importado durante la rotación solo se restaura tras el corte (con B). Por eso se bloquea el borrado de originales (A1).

Pantallas (`lib/features/settings/key_rotation_screen.dart`, en el estilo de `account_migration_screen.dart`):

1. **Introducción.**
   - "Generar código nuevo": "Para que tu código anterior deje de servir del todo, Vault cambia la llave con la que está cifrado todo y vuelve a subirlo a Google Drive."
   - "Rotar llave maestra": "Vault cambiará la llave que cifra todos tus archivos y volverá a subirlos."
   - Texto común: "Puede tardar (subir N GB). Mantén Vault abierta, con Wi-Fi y cargador. Puedes seguir usándola. Las copias que alguien haya descargado antes con tu código anterior no se pueden revocar."
2. **Comprobación previa** (`RotationPlan`): cantidad y tamaño, lo que hay que bajar, espacio en Drive necesario (≈ el doble durante la rotación), espacio libre en el teléfono, miniaturas que no se podrán recuperar (L5), archivos sin ninguna copia (se ofrece "Continuar sin ellos", que los acepta como perdidos), aviso M7 y precondiciones no cumplidas ("Hay 3 archivos sin subir: espera a que terminen").
3. **PIN** ("Confirma tu PIN").
4. **Código nuevo + confirmación por posiciones** (`RecoveryCodeFlow`, sin poder salir): "Este es tu código NUEVO. Anótalo y guárdalo donde guardabas el anterior."
5. **Progreso.**
   - Fase en palabras ("Re-cifrando 37 de 120", "Subiendo…", "Preparando el índice…", "Borrando la copia anterior de Drive…"), con barra y "En pausa: sin conexión / esperando Wi-Fi".
   - Banner en la raíz: "Rotando la llave · 37/120 · Mantén Vault abierta".
   - Hasta `freezing`, botón "Cancelar". Después solo "Pausar".
6. **Bloqueos** con su acción (Reintentar, Iniciar sesión, Liberar espacio, Omitir dañados, Descartar restos).
7. **Terminado**: "Rotación terminada. Tu código anterior ya no abre nada." Si `biometricWasEnabled`, también "Reactivar Face ID / huella".
8. **Ajustes > Seguridad > "Comprobar mi código"** (M1): un Argon2id contra el respaldo local, sin red. Responde "Este código es el vigente" o "No coincide".
9. **Restauración**, aviso M8: "Este es un código ANTERIOR. Hay una copia más reciente que abre tu código nuevo. ¿Restaurar igualmente el estado antiguo?" Con el puente: "Esto restaura el estado de antes de la rotación; después vuelve a rotar la llave".

---

## 9. Corrupción y anomalías

| Caso | Respuesta |
|---|---|
| Fuente `gen 1` local no autentica | Copia de Drive. Si también falla → `blockedCorrupt` con la lista; "Omitir" = cuarentena (M6), nunca se borra el blob |
| SHA del claro ≠ `contentHash` | `blockedCorrupt` (sería un error de programa); "Reintentar" / "Omitir" (cuarentena) |
| `.k2` nuevo no verifica | se borra y se reintenta 2 veces; disco lleno → `blockedLocalSpace` |
| Exportación de la BD no verifica | se borra `.tmp`; la `db` original queda intacta; `blockedCorrupt` + Diagnóstico |
| Falta `db` (no debería ocurrir) | `VaultDatabaseMissingException`; reparación con `.tmp`/`db.k1` (§6.2); nunca se crea vacía |
| Cardinalidad o `rotationId` no cuadran | `blockedCorrupt` / `blockedForeign`; nada destructivo |
| Huellas del conjunto 1 cambiadas, o nombres `gen 1` fuera de la lista (otro dispositivo, A5) | `blockedCorrupt` "Otro dispositivo está usando esta bóveda en Drive": no se borra nada |
| `next_pin_envelope` ausente o dañado en fases de dos llaves | se pide el código B y se recupera DEK_new con `next_recovery_backup`; si falta también → `blockedCorrupt` (el conjunto viejo sigue intacto en Drive y B abre el puente) |
| Subida `.k2` o respaldo con MD5 distinto | se borra lo subido y se repite (S-04) |
| Almacén seguro borrado entero | restaurar desde Drive con B (o A según la tabla) |

Regla: nunca se entra en `deletingOldCloud` con items en `fromGen` (salvo cuarentena), con `.k2` sin verificar o con guardas en rojo.

---

## 10. Plan de pruebas

### 10.1 Infraestructura (`test/support/rotation_env.dart`)

- Almacén seguro en memoria compartido entre "arranques", con modo **`dropLastWrites(n)`** que simula el `apply()` de Android.
- Directorio temporal como `AppPaths` y BD con `sqflite_common_ffi`. `FakeDbRekeyer`: como ffi no tiene SQLCipher, copia la BD y guarda un marcador de llave, de modo que "la llave vieja no abre" se simula.
- `FakeCloud` con **revisiones** (`files.update` conserva el contenido anterior; `delete` lo borra todo) y con un cliente "segundo dispositivo".
- `Argon2Params` reducidos. `Platform.isIOS` inyectable en `_bootstrap` (que se extrae a `VaultBootstrap.decide(...)`, testeable).
- `RotationCrashPoint` (enum) + `CrashInjector` (`@visibleForTesting`). Tras el corte se construyen objetos nuevos sobre el mismo almacén, disco y nube, y se ejecuta el **arranque completo** (`VaultBootstrap`) antes de desbloquear y reanudar.
- Comprobadores:
  - `expectRecoverable(cloud, {aWorks, bWorks})`: restaura en un entorno limpio y descifra TODO.
  - `expectAllItemsOpen(session)`.
  - `expectNoOldKeyMaterial()`: ningún blob de la nube (revisiones incluidas), ningún archivo local y ninguna entrada del almacén seguro se abre con la DEK vieja o con A.
  - `expectSnapshotNameInvariant()`: ninguna escritura en `vault_db.snapshot` después de `freezing`.

### 10.2 Cortes por etapa (una prueba por punto)

En cada punto, tras reanudar, la rotación termina, se cumple `expectAllItemsOpen` y `expectRecoverable` según la tabla del §8 EN ESE INSTANTE. También se repite cada punto con `dropLastWrites(1)`.

1. `prepared`: tras `next_recovery_backup`; tras `next_pin_envelope`; tras el registro; con el código en pantalla sin confirmar (→ código nuevo o cancelar; A sigue valiendo).
2. `confirmed`: sin red (no avanza); con 1 item pendiente (no avanza, A4); cancelar.
3. `freezing`: tras persistir la fase con un flush en vuelo (se espera); tras exportar; tras crear triggers; tras subir el snapshot sin verificarlo; tras subir el puente; a mitad de llenar `rotation_old_files`; cancelar aquí (el puente se borra y no queda nada).
4. Item: tras bajar la fuente; a mitad del `.part`; tras el `rename` sin transacción; tras la transacción sin borrar `gen 1`; tras borrar `gen 1`; lo mismo con la miniatura.
5. `uploading`: subida cancelada; subida hecha sin `markCloudVerified`; `markCloudVerified` condicional contra una fila que cambió (no borra nada en Drive).
6. `rekeyingDb`: tras exportar; tras verificar; tras copiar `db.k1`; tras el `rename`; bloqueo a mitad (L6).
7. `switchingLocal`: entre cada escritura (el PIN abre siempre lo necesario).
8. `uploadingSnapshot`: subido sin verificar; con la cardinalidad alterada (BD con una fila menos → bloquea).
9. `uploadingBackup`: creado sin verificar; verificado sin escribir la fase (A y B valen).
10. `deletingOldCloud`: tras borrar el respaldo viejo (A falla, B vale); tras el puente; tras el snapshot; a mitad de los blobs.
11. `finalizingLocal`: entre cada borrado; antes de borrar el registro.

### 10.3 Escenarios

12. Arranque iOS simulado en cada punto: nunca `discardLocalKeys` ni `sweepOrphans` con `db.k*`/`.tmp`; reinstalación (registro sin archivos) → todo descartado, incluido el registro (A3). `VaultDatabase` con `db_created` y sin archivo lanza y nunca crea (C1).
13. Snapshot: flush en vuelo, `AccountMigrationService._finalize` forzado y `run(force: true)` después del primer `keyGen = 2` → `vault_db.snapshot` intacto; `_uploadSnapshotFile` con filas mixtas lanza (C2).
14. `cloudVerifier` = false y `pendingOriginalsCount` = 0 durante la rotación (A1).
15. Desinstalar y restaurar (con A y con B) en cada fase con el Keychain conservado: no se reanuda ninguna rotación ajena; `rotationId` distinto → `blockedForeign` (A3).
16. Segundo dispositivo escribe `vault_db.snapshot`, `recovery_backup.json` o un `<uuid>.vault` nuevo tras congelar → `blockedCorrupt`, 0 borrados (A5).
17. Duplicados de `recovery_backup.k2.json` (M1) → la restauración prueba todos; `regenerateNextRecoveryCode` fuera de `prepared` lanza.
18. `changePin` con registro → rechazado (M2). La biometría queda desactivada desde `reencrypting` y se ofrece al final; en `prepared` sigue funcionando (M3).
19. Fetcher y sync en vuelo contra la transacción del item (M4); dañados → cuarentena, el blob renombrado no se borra (M6).
20. Aviso M7 con cuenta anterior conservada; aviso M8 al restaurar con A o con el puente cuando existe `k2`.
21. Bloqueo y autobloqueo en cada fase; sin red y solo Wi-Fi; cuota llena en el preflight y a mitad; espacio local y tope `maxPendingLocalBytes`.
22. Importar, mover, renombrar, etiquetar, Papelera y `purgeExpired` durante la rotación → todo termina en `gen 2`, la cardinalidad cuadra y los triggers cuentan.
23. Exclusión mutua con la migración y "Cerrar sesión" desactivado.
24. **Restaurar con el código nuevo funciona** (todos los items, etiquetas y Papelera) y **con el viejo falla** después de terminar. `expectNoOldKeyMaterial()`.
25. `toGen` = máximo de Drive + 1; teléfono restaurado en `gen 2` barre `gen 1` por lista y no toca `gen 3`; limpieza manual de una generación abandonada (M11).
26. Segunda rotación seguida (`gen 2 → 3`).
27. `integration_test/db_rekey_sqlcipher_test.dart` (emulador, SQLCipher real): `ATTACH … KEY "x'..'"`, `sqlcipher_export`, `user_version`, triggers copiados, la llave vieja no abre.

Emulador, a mano: unos 30 items (fotos, el video de 24,9 MB, items solo en la nube, Papelera, etiquetas) con Drive real. `am force-stop` en `freezing`, `reencrypting` y `deletingOldCloud`, y un corte de red. `revisions.list` antes y después de `files.delete`. Restaurar en una instalación limpia con B (funciona) y con A (falla).

---

## 11. Pasos de implementación (cada uno: analyze + test + build apk debug + commit en `dev-claude`)

Hasta el paso 11 ningún cambio es visible para el usuario. Los pasos 1–3 son seguros por sí solos para el iPhone: en `gen 1` todo sigue igual.

| # | Paso | Archivos | Tests | Est. |
|---|---|---|---|---|
| 1 | **Nombres por generación** | nuevo `lib/data/cloud/cloud_names.dart`; `sync_service.dart`, `restore_service.dart`, `account_migration_service.dart` (usos y `_isVaultFile` → `parse`); `core/services/app_paths.dart` | nuevo `test/cloud_names_gen_test.dart`; `test/s15_test.dart` ampliado; regresión de `sync_service_test`, `f9_restore_test`, `account_migration_test` | 0,5 d |
| 2 | **Guarda "nunca BD vacía" (C1), independiente de la rotación** | `data/repositories/vault_database.dart` (`db_created`, `VaultDatabaseMissingException`); `core/crypto/auth_controller.dart` (`discardLocalKeys`/`_commit`); `data/restore/restore_service.dart` (`_install`); `main.dart` → `VaultBootstrap.decide` | nuevos `test/db_missing_guard_test.dart` y `test/bootstrap_test.dart` (iOS simulado) | 0,5 d |
| 3 | **Esquema v10** (`keyGen`, `rotation_state`, `rotation_old_files`) + `VaultItemModel.keyGen` requerido | `vault_database.dart`; `data/models/vault_item_model.dart`; `gallery_import_service.dart`, `services/vault_import_service.dart`; `restore_service.dart` (acepta v10, vacía tablas, `DROP TRIGGER`); fakes de test | nuevo `test/schema_v10_test.dart` (v6..v9→v10, idempotente, Papelera y etiquetas intactas); `f9_restore_test` con snapshot v10 | 0,5 d |
| 4 | **Keyring y lectores por generación + actualizaciones condicionales (M4)** | nuevo `core/session/vault_keyring.dart`; `vault_session.dart`; `vault_database.dart` (`dbCandidates`, `openedGen`); `features/vault/viewer/media_opener.dart`, `services/thumbnail_loader.dart`, `viewer/media_exporter.dart`; `data/sync/vault_file_fetcher.dart`; `data/repositories/vault_data_repository.dart` (`markCloudVerified`/`updateSyncStatus` condicionales, `getItemsByKeyGen`); `vault_services.dart` (`cleaner` multi-gen) | nuevo `test/keyring_test.dart`; `s09_fileid_test`, `f6a_*`, `f6b_streaming_test` en dos generaciones | 1 d |
| 5 | **Sincronización con la rotación en cuenta (C2, A1)** | `sync_service.dart` (`RotationGuard`, `SnapshotCopy`, guarda en `_uploadSnapshotFile`, negativa a nombres `fromGen`, `delete_remote` multi-gen, `cloudVerifier`); `vault_database.dart` (`exportEncryptedSnapshot` → `SnapshotCopy`); `gallery_import_service.dart` (`pendingOriginalsCount`); `account_migration_service.dart` (excluye rotación, M7 `old_account_kept`) | nuevo `test/sync_rotation_guard_test.dart` (flush en vuelo, migración, `force`); `security_review_test` (S-04) | 1 d |
| 6 | **Llaves de la rotación en `AuthController`** | nuevo `core/crypto/key_rotation_store.dart` (`RotationRecord`, `RotationPhase`, `RotationKeyStore`, barrido de huérfanos); `auth_controller.dart` (`prepareRotation`, `regenerateNextRecoveryCode` solo en `prepared`, `confirmRotationCode`, `createBridgeBackup`, `abandonRotation`, desbloqueo con dos llaves, `switchPrimary`, `changePin` prohibido, biometría desactivada/ofrecida, `verifyLocalRecoveryCode`) | nuevo `test/auth_rotation_test.dart` (incluye `dropLastWrites`, `blockedForeign`, PIN cuenta 1 intento) | 1,5 d |
| 7 | **Re-cifrado de la BD por copia** | `vault_database.dart` (`rekeyTo`, `_gate`, copias propias de llaves, reparación `.tmp`/`.k1`); nuevo `data/repositories/db_rekeyer.dart` (SQLCipher real + fake) | nuevo `test/db_rekey_test.dart` (cortes del §6.1); nuevo `integration_test/db_rekey_sqlcipher_test.dart` | 1 d |
| 8 | **Re-cifrado de un item** | nuevo `data/rotation/item_reencryptor.dart` (+ `DecryptingByteSource`) | nuevo `test/item_reencryptor_test.dart` (0 B, 1 B, 1 MiB exacto, 3 MiB+1; SHA; `fileId` nuevo; miniatura; fuente dañada → Drive; ambas → dañado; escaneo de disco sin claro) | 1 d |
| 9 | **Restauración multi-generación + puente** | `restore_service.dart` (`probe` con todos los respaldos, orden de `verifyCode`, emparejado por generación, aviso M8, `key_gen`); `features/onboarding/restore_flow.dart` (texto M8); barrido de generaciones viejas por lista | `f9_restore_test` ampliado; nuevo `test/restore_generations_test.dart` | 1 d |
| 10 | **Servicio de rotación (máquina de estados)** | nuevos `data/rotation/key_rotation_service.dart`, `rotation_plan.dart`, `rotation_repository.dart` (`rotation_state`, `rotation_old_files`, triggers); `vault_services.dart` (cableado, `onUnlocked`, `addOnClear(pause)`); `cache_manager.dart` (exclusión `fromGen`); `thumbnail_regeneration_service.dart` (pausa) | nuevo `test/support/rotation_env.dart`; nuevo `test/rotation/` con §10.2 (1–11) y §10.3 (12–26) | 3 d |
| 11 | **UI** | nuevo `features/settings/key_rotation_screen.dart`; `settings_screen.dart` (dos entradas, `changePin` y "Cerrar sesión" deshabilitados, "Comprobar mi código", limpieza M11); `pin_flows.dart` (`runRegenerateCodeFlow` → pantalla de rotación); banner en `home_vault_screen.dart`; `diagnostics_screen.dart` (estado de la rotación, sin secretos) | nuevos `test/ui/key_rotation_screen_test.dart`, `test/ui/settings_test.dart` ampliado; goldens de la pantalla | 1,5 d |
| 12 | **Emulador de punta a punta + documentación** | `docs/DECISIONES.md` (D60–D63), `REPORTE.md` (sección de la fase y "Pruebas de iPhone"), `CONTEXTO.md`, `PLAN.md` | prueba manual del §10 | 1 d |

Total ≈ 13 días. Al terminar el paso 12: **PARAR** y dar al usuario el simulacro de restauración (PLAN v2) **antes** de rotar en el iPhone.

Decisiones a registrar:
- **D60**: generaciones de llave, nombres `.kN` y `keyGen` como fuente de verdad.
- **D61**: orden en Drive (congelar → snapshot `gen 1` propio → puente → re-cifrar → … → respaldo nuevo el último → respaldo viejo el primero; borrado por lista con huellas).
- **D62**: BD por `sqlcipher_export` con copia y `rename` atómico; guarda "nunca crear con bóveda"; triggers de cardinalidad.
- **D63**: sin enlaces entre DEK (la nueva se obtiene con `next_pin_envelope`), biometría desactivada durante la rotación, `changePin` prohibido, regenerar B solo antes de confirmar.

---

## 12. Decisiones sobre los hallazgos de la revisión

| Hallazgo | Decisión |
|---|---|
| C1 | **Aplicado**: copia + `rename` atómico (no hay instante sin BD), `db_created`, `main.dart` sin `discardLocalKeys` con restos, triggers de cardinalidad. |
| C2 | **Aplicado**: el nombre del snapshot sale de la generación de la copia; guarda en `_uploadSnapshotFile`; orden congelar → esperar lo que está en vuelo → snapshot `gen 1` propio → re-cifrar. |
| A1 | **Aplicado**: `cloudVerifier` false y 0 originales durante toda la rotación. |
| A2 | **Aplicado**: respaldo puente (comprobado en §4.1 que no da DEK_new a partir de A). |
| A3 | **Aplicado**: limpieza en `discardLocalKeys`/`_commit` y `rotationId` atado a la BD (`blockedForeign`). |
| A4 | **Aplicado**: precondiciones duras en `confirmed`. |
| A5 | **Aplicado**: huellas y lista en `rotation_old_files`; borrado solo por lista; bloqueo sin borrar. |
| M1 | **Aplicado**: S-04 en las subidas de la rotación, regenerar solo en `prepared`, restauración con todos los respaldos y "Comprobar mi código". **Descartada** la huella corta del código: "Comprobar mi código" cubre la necesidad sin guardar nada derivado del código. |
| M2 | **Aplicado**: `changePin` prohibido. |
| M3 | **Aplicado**, variante simple: biometría desactivada desde `reencrypting` y ofrecida al final. Un solo archivo biométrico; desaparece el riesgo iOS del segundo archivo. |
| M4 | **Aplicado**: actualizaciones condicionales sin borrar en Drive y salida de `uploading` con datos verificables. |
| M5 | **Aplicado**: sin `link_fwd` ni `link_bwd`. |
| M6 | **Aplicado**: cuarentena `lost_*`, solo con "Omitir" explícito. |
| M7 | **Aplicado**: aviso y opción de borrar la cuenta anterior conservada. |
| M8 | **Aplicado**: aviso al restaurar con una generación menor. |
| M9 | Ya resuelto (D59). |
| M10 | **Aplicado**: descongelar en el corte. |
| M11 | **Aplicado** como limpieza manual (no automática, por seguridad). |
| L1 | **Aplicado**: decisiones D60–D63. |
| L2 | **Descartado** en esta fase: la generación sale de nombres que fija el registro de la rotación (no de `key_gen`); un emparejamiento equivocado solo produce `RestoreCorruptException` (la llave no abre) y no tiene impacto de seguridad. Una envoltura v2 con `vaultId`/`gen` en la AAD exigiría mantener v1 en la restauración; queda para más adelante. |
| L3 | Ya no aplica (sin enlaces). |
| L4 | **Documentado**: el snapshot `gen 1` fresco da a quien tenga A los metadatos al congelar; es inevitable para que A siga completo. |
| L5 | **Aplicado**: el preflight cuenta y avisa. |
| L6 | **Aplicado**: `rekeyTo` usa copias propias de las llaves. |
| L7 | **Aplicado** vía A3. |
| L8 | **Aplicado**: `blockedForeign` en lugar de `StateError`. |

**Recortes respecto al diseño anterior:** fuera los enlaces entre DEK, el segundo archivo biométrico por generación, `dbGen` en el registro (lo sustituye la apertura por candidatos), `changePin` doble y regenerar B a mitad. El cambio a la envoltura nueva del PIN se adelanta a justo después de re-cifrar la BD, así la DEK vieja vive en el teléfono lo menos posible.

---

## 13. Riesgos abiertos y lo que solo se puede probar en el iPhone

1. **SQLCipher en iOS** (`sqflite_sqlcipher 3.4.1`): `ATTACH … KEY "x'hex'"` + `sqlcipher_export` + copia de triggers. Si falla, alternativa: `PRAGMA rekey` sobre una COPIA, con la misma verificación y el mismo `rename`.
2. **`rename` atómico con reemplazo** en el contenedor de iOS: POSIX lo garantiza; confirmarlo en el dispositivo.
3. **Durabilidad de `flutter_secure_storage` 9.2.4** (Android `apply()`, iOS Keychain): cubierta por diseño y por `dropLastWrites`; confirmarlo con `force-stop` en el emulador y en el iPhone.
4. **Segundo plano en iOS**: la rotación solo avanza con la app abierta. La subida domina el tiempo (10 GB a 20 Mbit/s ≈ 1 h 10 min); medirlo con los datos reales.
5. **Espacio**: Drive necesita ≈ el doble de la bóveda durante la ventana, y el iPhone el item más grande × 2 + el tope de pendientes + margen. Comprobarlo con el preflight antes de lanzarla.
6. **`files.delete`** borra el archivo con todas sus revisiones y appDataFolder no tiene papelera (supuesto heredado de S-04): verificar con `revisions.list` y `files.list`.
7. **Bajar de versión**: con D59 un build nuevo ya no destruye la BD, pero un build anterior a D59 sí. No instalar en el iPhone nada anterior al último instalado.
8. **Rendimiento**: 3 pasadas AES-GCM por archivo (descifrar, cifrar, verificar). Medirlo en el iPhone; `verifyFullPass` permite reducirlo a un muestreo si hace falta.
9. Todo el código específico de iOS va marcado `// iOS: sin probar` (bootstrap, Keychain, exclusión de respaldo de los archivos nuevos en `vault/`, `thumbs/` y `db/`).
