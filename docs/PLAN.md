# Plan Vault

Leyenda: ✅ probado por el usuario · 🧪 pasa analyze/test/emulador · 📝 escrito sin probar · ⬜ pendiente

Rama de trabajo: `dev-claude` (no se hace push ni se toca main sin petición).

| Fase | Descripción | Modelo | Estado |
|---|---|---|---|
| F0 | Auditoría | Sonnet | 🧪 hecha |
| F1 | Llaves (DEK, KEK_pin, KEK_rec, biometría, HKDF, retraso) | Opus | 🧪 analyze/test/build apk OK; biometría real e invalidación por huella nueva probadas en emulador |
| F2 | Formato .vault v2 | Opus | 🧪 analyze/test OK (56 tests) |
| F3 | Base de datos (esquema, rutas relativas) | Sonnet | 🧪 analyze/test OK; SQLCipher real probado en emulador (llave cruda x'hex') |
| F3.5 | Rediseño UI | Sonnet | 🧪 analyze/test OK; capturas en emulador (docs/screens/emu); gestos (toque largo, deslizar fila, pull-to-refresh, pellizco) y háptica probados en emulador |
| F4 | Importación desde la galería | Sonnet | 🧪 parcial: importación real en emulador OK (permiso, selector, compresión, miniaturas cifradas); video real de 24,9 MB (Original/1080p/720p) y borrado de originales con confirmación probados en emulador; iCloud sin probar |
| F5 | Sincronización con Drive | Sonnet | 🧪 analyze/test OK; emulador: login Google, subida verificada (tamaño+MD5), cuota, reanudación y corte de red OK; iOS sin probar; borrado de copias en Drive hecho en F6a |
| F6 | Visor y caché | Sonnet/Opus | 🧪 F6a (visor fotos/video completo-primero, caché LRU, sin conexión, borrado remoto) analyze/test/emulador OK; F6b (streaming por bloques con servidor loopback, sin texto plano en disco, respaldo automático a completo-primero) analyze/test/emulador OK (Android); iOS sin probar; AES-GCM nativo con respaldo Dart; arranque de video en emulador limitado por ExoPlayer (medir en teléfono real) |
| F7 | Seguridad del sistema | Sonnet/Haiku | 🧪 autobloqueo configurable con suspensión por UI del sistema, lock cancela unlock en vuelo, FLAG_SECURE Android, sin respaldo Android: analyze/test/emulador OK; 📝 iOS (cobertura multitarea, exclusión de iCloud) escrito sin probar en dispositivo |
| F8 | Onboarding y ajustes | Haiku/Sonnet | 🧪 onboarding obligatorio (bienvenida, PIN, código + confirmación por posiciones, biometría, Drive), `regenerateRecoveryCode`, Ajustes completos: analyze/test (485)/emulador Android OK; iOS sin probar; liberar/vaciar caché probado con BD real en tests (emulador con bóveda vacía) |
| F9 | Restauración | Sonnet | 🧪 restaurar en instalación limpia (Google -> código -> PIN nuevo -> BD y miniaturas), snapshot siempre fresco (sucio + debounce + al bloquear): analyze/test/emulador Android OK; 📝 iOS sin probar (ver checklist en REPORTE.md) |
| F10 | Despliegue (Codemagic, Sideloadly) | Sonnet/Haiku | 🧪 APK release firmado (SHA-1 verificada) con R8 + `--obfuscate`, regresión final completa en emulador Android OK (REPORTE: F10 APK release y Regresión final); ⬜ acción manual: registrar la SHA-1 de release en Google Cloud; 📝 Codemagic/iOS sin probar |

## Hallazgos F0
- `docs/CONTEXTO.md` NO existe en el repo (tampoco en el historial). Se usó el mensaje de especificación como fuente única.
- `flutter analyze`: 34 problemas, 11 errores. `flutter test`: 2/2 archivos no compilan.
- Emulador Pixel_7 disponible; no se lanzó la app porque no compila.

## Bloqueos
- (RESUELTO) Emulador Android Pixel_7: arranca con `-no-snapshot -gpu swiftshader_indirect`. Antes: no arrancaba en esta máquina (qemu levanta pero adb nunca lo ve; probado con/sin ventana, swiftshader). Efecto: SQLCipher real (F3), biometría real (F1) y toda la UI en dispositivo quedan sin probar. Verificación sustituta: tests de widgets y goldens (docs/screens).

## Ronda 2
- Argon2id nativo (sodium_libs 3.4.6+4) en isolate ✅🧪; SQLCipher llave cruda ✅🧪; Fase 1 en emulador ✅🧪 (PIN, bloqueo persistente, huella); recuperación en grupos ✅🧪; F4 en emulador ✅🧪.

## v2
Reglas: una fase a la vez; migraciones de BD incrementales (v7 → v8…), nunca recrear tablas ni borrar datos sin confirmar; al cerrar cada fase: analyze + test + build apk --debug + prueba en emulador + commit en `dev-claude` (sin push) + PLAN/CONTEXTO/REPORTE (sección por fase y "Pruebas de iPhone"). Orden pedido: 7 → 4 → 10 → 5 → 9 → 6 → 1 (parar y dar simulacro de restauración) → 8 (preguntar variante antes) → 11.

| Fase | Tema | Modelo | Estado |
|---|---|---|---|
| 7 | S-17: ventana de llaves en memoria al bloquear ≤ 1 s | Opus | 🧪 `lockWithFlush` (1 s), 5 tests |
| 4 | Guardar en Fotos (visor, foto y video) | Sonnet | 🧪 `VaultMediaExporter` + `PhotoManagerPhotoSaver` (photo_manager 3.12.0 ya fijado, sin paquete nuevo), 10 tests, emulador Android OK; 📝 iOS (permiso solo-agregar) sin probar |
| 10 | Gestos en video (doble toque ±10 s, zoom 1x–4x) | Sonnet | 🧪 `video_gestures.dart`, 14 tests, emulador: −10 s y controles OK; pellizco solo en tests (adb no hace multitoque) |
| 5 | Papelera (30 días, BD v8) | Sonnet | 🧪 BD v8 incremental, `TrashRepository`/`TrashService`, pantalla Ajustes > Papelera, 23 tests |
| 9 | Etiquetas, filtros y búsqueda (BD v9) | Sonnet | 🧪 BD v9 incremental, `TagRepository`, filtros globales, hoja de etiquetas, Ajustes > Etiquetas; tests + emulador |
| 6 | Selector de archivos propio (sin file_picker; S-02 residual, S-18) | Sonnet | 🧪 canal `vault/picker` (Kotlin probado en emulador; Swift sin compilar), `encryptSource`, `file_picker` fuera; tests |
| 1 | Rotar la DEK (S-11), diseño revisado por Opus; PARAR al terminar | Opus | 🧪 pasos 1–11 implementados y en tests (D60–D63); 🧪 pendientes cerrados: contador N/T, borrar cuenta anterior M7, limpieza M11 (D72–D74); ⬜ rotación real contra Drive sin probar; PARADA: simulacro de restauración del usuario (REPORTE "v2 · Fase 1") antes de rotar en el iPhone |
| 8 | Bóveda señuelo: variante (a) «disimulo» (decisión del usuario 2026-11-18, sustituye a la de ambas del 17): segundo PIN que abre una bóveda SEPARADA; NO hace falta ocultar en disco ni en Drive cuántas bóvedas hay. Diseño final revisado por Opus independiente en `docs/DISENO_SENUELO.md` (2 críticos y 2 altos incorporados); mismas reglas que la fase 1 | Opus | 🧪 pasos 1–10 (abajo, D65–D71); ⬜ test de integración SQLCipher con dispositivo; 📝 iPhone sin probar (REPORTE «v2 · Fase 8») |
| 11 | Kern: nombre visible e ícono (`CFBundleDisplayName`/`android:label` «Kern»; ícono `flutter_launcher_icons` 0.14.4 desde `assets/icon/kern.png`, adaptive en Android; applicationId y bundle id intactos) | Haiku | 🧪 analyze y `flutter build apk --debug` OK; ⬜ captura del emulador (la hace el usuario); 📝 iOS sin probar (nombre e ícono en pantalla de inicio, REPORTE «v2 · Fase 11») |

Dónde retomar: Fase 1 PARADA. El usuario hace el simulacro de restauración (REPORTE.md "v2 · Fase 1") y después la rotación en el iPhone con la lista de pruebas. La prueba de punta a punta con Drive real ya se hizo (REPORTE 2026-11-18). Pendiente: goldens de la pantalla. Hecho (🧪, D72–D74): contador «N/T archivos» del aviso, botón de borrar la cuenta anterior (M7) y limpieza manual de generaciones abandonadas (M11). Fase 8 (bóveda adicional) implementada en tests y emulador; pendiente: `flutter test integration_test/secondary_sqlcipher_test.dart -d ID_DISPOSITIVO` y la lista de iPhone de REPORTE «v2 · Fase 8». Después: fase 11.

### Fase 1 · pasos (ver docs/DISENO_ROTACION.md §11)
| Paso | Qué | Estado |
|---|---|---|
| 1 | Nombres por generación (`.kN`) | ✅🧪 |
| 2 | Guarda "nunca una BD vacía" (C1) + `VaultBootstrap` | ✅🧪 |
| 3 | Esquema v10 (`keyGen`, `rotation_state`, `rotation_old_files`) | ✅🧪 emulador: bóveda real v9→v10 OK |
| 4 | `VaultKeyring`, lectores por generación, escrituras condicionales | ✅🧪 |
| 5 | Sincronización consciente de la rotación (C2, A1, M7) | ✅🧪 |
| 6 | Llaves de rotación en `AuthController` (puente, PIN, biometría) | ✅🧪 suite 917 verde; emulador gen 1: foto, video en streaming, sync OK |
| 7 | Re-cifrado de la BD por copia (`rekeyTo`) | ✅🧪 SQLCipher real en emulador OK |
| 8 | `ItemReencryptor` | ✅🧪 |
| 9 | Restauración multi-generación + puente + barrido por lista | ✅🧪 suite 953 verde |
| 10 | `KeyRotationService` con inyección de cortes | ✅🧪 (10a hasta el corte + 10b borrado y finalización; 1027 tests; cableado a la app, sin UI aún) |
| 11 | UI de rotación | 🧪 `key_rotation_screen.dart`, entradas en Ajustes, banner, "Comprobar mi código", Diagnóstico; `test/ui/key_rotation_screen_test.dart` (16) + `settings_test` ampliado |
| 12 | Punta a punta en emulador + docs; PARAR: simulacro de restauración | 📝 docs (D60–D63, REPORTE, CONTEXTO, PLAN) hechas; ✅ punta a punta con Drive real hecha el 2026-11-18 (REPORTE) |

### Fase 8 · pasos (ver docs/DISENO_SENUELO.md §12; D65–D71)
| Paso | Qué | Estado |
|---|---|---|
| 1 | `VaultSlot` y `VaultPaths` por bóveda, barridos de las dos raíces, exclusión de iCloud sin crear `alt/` | ✅🧪 |
| 2 | Sesión con bóveda, época, `SessionTicket`, llaves ligadas a la bóveda, `SessionHooks` | ✅🧪 |
| 3 | BD por bóveda (`VaultDatabase.secondaryInstance`), comprobaciones de época en `_open`/`rekeyTo` | ✅🧪 suite 1087; emulador: principal idéntica, sin `alt/` |
| 4 | Guardas solo-principal: `SlotGuardedCloudStorage`, sync, sin conexión, `onDataChanged`, rotación, migración | ✅🧪 |
| 5 | Época en operaciones largas (importar, regenerar, Papelera, caché, descargas, exportar, re-cifrado) + arnés de cruce | ✅🧪 suite 1109; emulador: archivos, Papelera y restaurar OK |
| 6 | `AuthController` y arranque: `altPin`, desbloqueo en paralelo (C1), `reauthPrimary`, crear/cambiar/eliminar, `_reconcileSecondary` | ✅🧪 suite 1142; emulador: desbloqueo normal con 1 derivación, sin `alt/` |
| 7 | `VaultServices.secondary()` y navegación por bóveda en `main.dart`, sin biometría automática | ✅🧪 |
| 8 | UI: `SecondaryVaultScreen` y Ajustes reducido con textos neutros | ✅🧪 suite 1152; emulador: crear, entrar con el 2.º PIN (bóveda vacía y separada), importar, aislamiento OK |
| 9 | Batería transversal: aislamiento, principal intacta, convivencia con la rotación, cortes, esquema, SQLCipher real | 🧪 `test/secondary/{isolation,primary_restore_intact,rotation_coexistence,crash_points,schema_upgrade_secondary}_test.dart`; ⬜ `integration_test/secondary_sqlcipher_test.dart` escrito, sin ejecutar (necesita dispositivo) |
| 10 | Emulador y documentación (D65–D71) | 📝 DECISIONES D65–D71, REPORTE «v2 · Fase 8» (límites y pruebas de iPhone), CONTEXTO, PLAN; emulador: ver pasos 3–8 |

### Cierre v2
- Estado: **v2 CERRADA (2026-11-18)** en la rama dev-claude, sin push. Regresión completa en el emulador hecha (un bug hallado y corregido: Papelera bloqueada si fallaba el aviso). M11 probado contra Drive real; M7 sin probar contra Drive real (no hay segunda cuenta de pruebas).
- Lista final de pruebas de iPhone (v2), en orden 0 → 1 → 1 bis (simulacro) → 2 … 12 (el 11, rotación, es OPCIONAL: solo si el código se filtra y después del simulacro): `docs/REPORTE.md`, sección «Lista final de pruebas de iPhone (v2) — en orden». Todo sin probar en iOS.
- Dónde retomar: esperar los resultados del iPhone del usuario; nunca instalar una build antigua en el iPhone ni desinstalar la app.

### Migración atascada (iPhone) — diseño `docs/DISENO_MIGRACION_ATASCADA.md`
| Paso | Qué | Estado |
|---|---|---|
| A1 | BD v11 incremental: `cloudAccountTag`/`thumbAccountTag`, `vault_meta` (sal), `diag_events`; tests v10→v11 (con datos, adicional, `rekeyTo`, restauración) | 🧪 D75 |
| A2 | «Cambio de cuenta sin terminar» al abrir, `abandonStayOnCurrent`, fase desconocida, `resume` sin errores silenciosos, `onUnlocked` por pasos con la guarda primero | 🧪 D76/D77 |
| A3 | «Verificar copia en la nube» (Ajustes y automática), caché/originales/flush solo con el tag de la cuenta actual | 🧪 D75 |
| B4 | Guardas y mensajes de «Sincronizar ahora»/«Cerrar sesión» (Ajustes y hoja), `SyncRunOutcome`, cuenta comprobada dentro de la migración, selector con plazo (iOS) | 🧪 D78 (`test/sync_guards_test.dart`, `test/ui/sync_guards_ui_test.dart`) |
| B5 | Banner en la cuadrícula, «al día» honesto | 🧪 D79 (`test/ui/sync_guards_ui_test.dart`, `test/sync_guards_test.dart`) |
| B6 | Diagnóstico persistente cifrado con Borrar (tabla ya creada en v11) | 🧪 D80 (`test/diagnostics_store_test.dart`, `test/db_rekey_test.dart`) |
| B7 | Mensaje de restauración con inventario | 🧪 D81 (`test/restore_inventory_test.dart`) |
| B6b | BUG-1: diagnóstico que dejaba de guardar. Sin esperas sin fin, reintento con espera creciente, «no pudo guardar N eventos» en la pantalla, desbloqueo sin esperarlo | 🧪 D83 (`test/diagnostics_store_test.dart`, grupo D83); emulador sin repetir |

Dónde retomar: partes A y B hechas, más la corrección del diagnóstico (D83). Analyze y tests en verde; emulador e iPhone sin probar. Siguiente: pruebas a mano en el emulador con la cuenta de pruebas (REPORTE «Migración atascada (iPhone) — parte B») y después los pasos del iPhone.
