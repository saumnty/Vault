# Plan Vault

Leyenda: ✅ probado por el usuario · 🧪 pasa analyze/test/emulador · 📝 escrito sin probar · ⬜ pendiente

Rama de trabajo: `dev-claude` (no se hace push ni se toca main sin petición).

| Fase | Descripción | Modelo | Estado |
|---|---|---|---|
| F0 | Auditoría | Sonnet | 🧪 hecha |
| F1 | Llaves (DEK, KEK_pin, KEK_rec, biometría, HKDF, retraso) | Opus | 🧪 analyze/test/build apk OK; biometría real sin probar |
| F2 | Formato .vault v2 | Opus | 🧪 analyze/test OK (56 tests) |
| F3 | Base de datos (esquema, rutas relativas) | Sonnet | 🧪 analyze/test OK (71); SQLCipher en emulador NO probado (test de integración escrito) |
| F3.5 | Rediseño UI | Sonnet/Haiku | ⬜ ← estás aquí |
| F4 | Importación desde la galería | Sonnet | ⬜ |
| F5 | Sincronización con Drive | Sonnet | ⬜ |
| F6 | Visor y caché (streaming aparte) | Sonnet/Opus | ⬜ |
| F7 | Seguridad del sistema | Sonnet/Haiku | ⬜ |
| F8 | Onboarding y ajustes | Haiku/Sonnet | ⬜ |
| F9 | Restauración | Sonnet | ⬜ |
| F10 | Despliegue (Codemagic, Sideloadly) | Sonnet/Haiku | ⬜ |

## Hallazgos F0
- `docs/CONTEXTO.md` NO existe en el repo (tampoco en el historial). Se usó el mensaje de especificación como fuente única.
- `flutter analyze`: 34 problemas, 11 errores. `flutter test`: 2/2 archivos no compilan.
- Emulador Pixel_7 disponible; no se lanzó la app porque no compila.
