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
| 1 | Rotar la DEK (S-11), diseño revisado por Opus; PARAR al terminar | Opus | 🧪 pasos 1–11 implementados y en tests (D60–D63); ⬜ rotación real contra Drive sin probar; PARADA: simulacro de restauración del usuario (REPORTE "v2 · Fase 1") antes de rotar en el iPhone |
| 8 | Bóveda señuelo: variante (a) «disimulo» (decisión del usuario 2026-11-18, sustituye a la de ambas del 17): segundo PIN que abre una bóveda SEPARADA; NO hace falta ocultar en disco ni en Drive cuántas bóvedas hay. Diseño final revisado por Opus independiente en `docs/DISENO_SENUELO.md` (2 críticos y 2 altos incorporados); mismas reglas que la fase 1 | Opus | 🔧 implementación por pasos (abajo) |
| 11 | Kern: nombre visible e ícono | Haiku | ⬜ |

Dónde retomar: Fase 1 PARADA. El usuario hace el simulacro de restauración (REPORTE.md "v2 · Fase 1") y después la rotación en el iPhone con la lista de pruebas. Pendiente de la fase: prueba de punta a punta en el emulador con Drive real (§10, a mano), limpieza manual de generaciones abandonadas (M11), botón de borrar la cuenta anterior desde el aviso M7 y goldens de la pantalla. Después: fase 8.

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
| 12 | Punta a punta en emulador + docs; PARAR: simulacro de restauración | 📝 docs (D60–D63, REPORTE, CONTEXTO, PLAN) hechas; ⬜ punta a punta con Drive real sin hacer (no autorizado en este paso) |

### Fase 8 · pasos (ver docs/DISENO_SENUELO.md §12; D65–D71)
| Paso | Qué | Estado |
|---|---|---|
| 1 | `VaultSlot` y `VaultPaths` por bóveda, barridos de las dos raíces, exclusión de iCloud sin crear `alt/` | ✅🧪 |
| 2 | Sesión con bóveda, época, `SessionTicket`, llaves ligadas a la bóveda, `SessionHooks` | ✅🧪 |
| 3 | BD por bóveda (`VaultDatabase.secondaryInstance`), comprobaciones de época en `_open`/`rekeyTo` | ✅🧪 suite 1087; emulador: principal idéntica, sin `alt/` |
| 4 | Guardas solo-principal: `SlotGuardedCloudStorage`, sync, sin conexión, `onDataChanged`, rotación, migración | ✅🧪 |
| 5 | Época en operaciones largas (importar, regenerar, Papelera, caché, descargas, exportar, re-cifrado) + arnés de cruce | ✅🧪 suite 1109; emulador: archivos, Papelera y restaurar OK |
| 6 | `AuthController` y arranque: `altPin`, desbloqueo en paralelo (C1), `reauthPrimary`, crear/cambiar/eliminar, `_reconcileSecondary` | ✅🧪 suite 1142; emulador: desbloqueo normal con 1 derivación, sin `alt/` |
| 7 | `VaultServices.secondary()` y navegación por bóveda en `main.dart`, sin biometría automática | ⬜ |
| 8 | UI: `SecondaryVaultScreen` y Ajustes reducido con textos neutros | ⬜ |
| 9 | Batería transversal: aislamiento, principal intacta, convivencia con la rotación, cortes, esquema, SQLCipher real | ⬜ |
| 10 | Emulador y documentación (D65–D71) | ⬜ |

