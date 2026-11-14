# REPORTE — trabajo autónomo (rama dev-claude, sin push)

## Completado (todo con `flutter analyze` limpio y `flutter test` en verde; 148 tests al final)
- **Baseline** de tus archivos sin commit.
- **F1 Llaves** (Opus): DEK + KEK_pin + KEK_rec (Argon2id), subllaves HKDF (sqlcipher/files/thumbs), biometría atada al sistema (`biometric_storage` 5.0.1; `local_auth` eliminado), cambio de PIN por re-envoltura, retraso creciente persistido. Corregidos los 11 errores iniciales.
- **F2 Formato .vault v2** (Opus): encabezado VLT+0x02+fileId+blockSize, AAD = encabezado+índice+isFinal; pruebas de los 4 ataques y de tamaños 0 B / 1 B / 1 MiB / 1 MiB+1 / varios MB; lectura desde cualquier bloque.
- **F3 Base de datos** (Sonnet): esquema v3 (campos de sync, thumbPath, LRU, hash, sourceAssetId, durationMs, isOffline en carpetas), rutas relativas (`AppPaths`), llave SQLCipher derivada de la DEK, repositorio, snapshot cifrado para F5.
- **F3.5 Rediseño** (Sonnet): tema centralizado (`lib/core/theme`), PIN con teclado propio, cuadrícula escalonada, shimmer, íconos de estado, gestos, FAB expandible, breadcrumbs, búsqueda, estados vacíos, sheets con blur, accesibilidad. Decisiones en `docs/DISENO.md`; capturas (goldens) en `docs/screens/`.
- **F4 parcial** (Sonnet): selector de galería (`photo_manager` 3.12.0), importación por lote con hash, cifrado, miniatura cifrada, compresión opcional (`video_compress` 3.1.4, tras interfaz), borrado de originales protegido (4 condiciones, apagado por defecto), loader de miniaturas. `flutter build apk --debug` compila.

## Probado
Solo con analyze, tests unitarios/widget/golden y `build apk --debug`. **Nada se probó en emulador ni dispositivo.**

## Bloqueado
- **Emulador Pixel_7 no arranca** (qemu levanta pero adb no lo ve; probado con/sin ventana y GPU por software). Consecuencias: SQLCipher real, biometría real, permisos, selector de galería, compresión, gestos y háptica sin probar.
- **F5 en adelante** no se inició: F5 y F9 requieren tu configuración de Google Cloud/OAuth/SHA-1 para probarse. Pendiente además: iCloud (F4 iOS), F6, F7, F8, F10.
- Nota: 7 archivos quedaron con cambios solo de formato (`dart format`), incluidos en el commit; son inocuos.

## Qué debes probar, en orden
1. Arreglar el emulador (Android Studio → Device Manager, borrar/recrear AVD, o usar un teléfono real con depuración USB) y correr `flutter run`.
2. Correr `flutter test integration_test/vault_database_sqlcipher_test.dart -d <id>` (SQLCipher con la llave derivada).
3. Crear bóveda: ver código de recuperación, activar biometría, desbloquear con biometría, añadir una huella (debe pedir PIN), equivocar el PIN 5 veces (bloqueo 30 s que sobreviva al cerrar la app).
4. Importar fotos/videos desde la galería (permisos, miniaturas, compresión 1080p/720p); importar un archivo; navegar carpetas, selección, pinch, deslizar.
5. Primera compilación Android descarga JDK 17 (foojay) — confirma que te parece bien.
6. iOS (Codemagic + Sideloadly): Face ID, descarga desde iCloud, hereda pendiente F10.

## Siguiente
F5 (sincronización) necesita: proyecto en Google Cloud, Drive API, pantalla de consentimiento, cliente OAuth Android (SHA-1 debug/release) e iOS. Dime cuando quieras que te dé los pasos exactos.
