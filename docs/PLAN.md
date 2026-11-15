# Plan Vault

Leyenda: ✅ probado por el usuario · 🧪 pasa analyze/test/emulador · 📝 escrito sin probar · ⬜ pendiente

Rama de trabajo: `dev-claude` (no se hace push ni se toca main sin petición).

| Fase | Descripción | Modelo | Estado |
|---|---|---|---|
| F0 | Auditoría | Sonnet | 🧪 hecha |
| F1 | Llaves (DEK, KEK_pin, KEK_rec, biometría, HKDF, retraso) | Opus | 🧪 analyze/test/build apk OK; biometría real sin probar |
| F2 | Formato .vault v2 | Opus | 🧪 analyze/test OK (56 tests) |
| F3 | Base de datos (esquema, rutas relativas) | Sonnet | 🧪 analyze/test OK; SQLCipher real probado en emulador (llave cruda x'hex') |
| F3.5 | Rediseño UI | Sonnet | 🧪 analyze/test OK; capturas en emulador (docs/screens/emu); gestos finos/háptica sin probar |
| F4 | Importación desde la galería | Sonnet | 🧪 parcial: importación real en emulador OK (permiso, selector, compresión, miniaturas cifradas); iCloud y video real grande sin probar |
| F5 | Sincronización con Drive | Sonnet | 🧪 analyze/test OK; emulador: login Google, subida verificada (tamaño+MD5), cuota, reanudación y corte de red OK; iOS sin probar; borrado de copias en Drive hecho en F6a |
| F6 | Visor y caché | Sonnet/Opus | 🧪 F6a (visor fotos/video completo-primero, caché LRU, sin conexión, borrado remoto) analyze/test/emulador OK; F6b (streaming por bloques con servidor loopback, sin texto plano en disco, respaldo automático a completo-primero) analyze/test/emulador OK (Android); iOS sin probar; rendimiento limitado por AES-GCM en Dart puro (pendiente: AES nativo o isolates) |
| F7 | Seguridad del sistema | Sonnet/Haiku | 🧪 autobloqueo configurable con suspensión por UI del sistema, lock cancela unlock en vuelo, FLAG_SECURE Android, sin respaldo Android: analyze/test/emulador OK; 📝 iOS (cobertura multitarea, exclusión de iCloud) escrito sin probar en dispositivo |
| F8 | Onboarding y ajustes | Haiku/Sonnet | ⬜ |
| F9 | Restauración | Sonnet | ⬜ |
| F10 | Despliegue (Codemagic, Sideloadly) | Sonnet/Haiku | ⬜ |

## Hallazgos F0
- `docs/CONTEXTO.md` NO existe en el repo (tampoco en el historial). Se usó el mensaje de especificación como fuente única.
- `flutter analyze`: 34 problemas, 11 errores. `flutter test`: 2/2 archivos no compilan.
- Emulador Pixel_7 disponible; no se lanzó la app porque no compila.

## Bloqueos
- (RESUELTO) Emulador Android Pixel_7: arranca con `-no-snapshot -gpu swiftshader_indirect`. Antes: no arrancaba en esta máquina (qemu levanta pero adb nunca lo ve; probado con/sin ventana, swiftshader). Efecto: SQLCipher real (F3), biometría real (F1) y toda la UI en dispositivo quedan sin probar. Verificación sustituta: tests de widgets y goldens (docs/screens).

## Ronda 2
- Argon2id nativo (sodium_libs 3.4.6+4) en isolate ✅🧪; SQLCipher llave cruda ✅🧪; Fase 1 en emulador ✅🧪 (PIN, bloqueo persistente, huella); recuperación en grupos ✅🧪; F4 en emulador ✅🧪.
