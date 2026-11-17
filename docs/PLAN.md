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
| 9 | Etiquetas, filtros y búsqueda (BD v9) | Sonnet | ⬜ |
| 6 | Selector de archivos propio (sin file_picker; S-02 residual, S-18) | Sonnet | ⬜ |
| 1 | Rotar la DEK (S-11), diseño revisado por Opus; PARAR al terminar | Opus | ⬜ |
| 8 | Bóveda señuelo: PREGUNTAR variante (disimulo / negable) antes | Opus | ⬜ |
| 11 | Kern: nombre visible e ícono | Haiku | ⬜ |

Dónde retomar: Fase 9 (etiquetas, filtros y búsqueda; BD v9).
