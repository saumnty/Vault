# DISENO – Sistema de diseño de Vault (F3.5)

Identidad: fondo OLED `#0B0B0E` y acento morado neón `#7C3AED`. Todo el aspecto sale de `lib/core/theme/`; las pantallas y widgets (`lib/features`, `lib/shared`, `lib/main.dart`) **no** contienen colores ni tamaños literales. `test/ui/tokens_test.dart` falla si aparecen `Color(0x`, `Colors.` (salvo `transparent`), `CupertinoColors.`, `fontSize:`, `EdgeInsets` con números, `Radius.circular(n)` o `SizedBox(width|height: n)` fuera del tema.

Capturas: `docs/screens/*.png` (generadas por `test/ui/goldens/goldens_test.dart`).

## Tokens (`lib/core/theme/`)
| Archivo | Contenido |
|---|---|
| `app_colors.dart` | Superficies (`background`, `surface`, `surfaceHigh`, `surfaceHighest`, `border`), acento (`accent`, `accentLight`, `accentContainer`, `onAccent`), texto, semánticos (`success`, `warning`, `danger`, `info`), utilidades (`scrim`, `glow`, `transparent`...). |
| `app_typography.dart` | Estilos `display/title/titleSmall/body/bodySecondary/label/caption/pinDigit/button/code` y `textTheme`. Fuente del sistema (Roboto en Android, SF en iOS): **no se descargan ni empaquetan fuentes**, `google_fonts` no se añadió. |
| `app_spacing.dart` | `AppSpacing` (escala 2-48, paddings), `AppSizes` (área táctil 44, íconos, teclado, FAB, filas), `AppGrid` (columnas 1-5, umbrales de pellizco). |
| `app_radii.dart`, `app_shadows.dart` | Radios y sombras (incl. brillo morado y desenfoque de sheets). |
| `app_motion.dart` | Duraciones (`instant 80 ms`, `fast 150`, `medium 280`, `slow 450`, `stagger 45`, `shake 420`, `unlock 380`) y curvas (`standard`, `emphasized`, `spring`). |
| `app_theme.dart` | `ThemeData` oscuro (Material 3) y `SystemUiOverlayStyle` (con ajuste `// iOS:` de `statusBarBrightness`). |

### Contraste (WCAG, verificado en `tokens_test.dart`)
Texto principal ~18:1, secundario ~7.7:1, `accentLight` ~7:1 sobre el fondo. `accent` (~3,1:1) solo se usa como relleno/elemento grande; el texto sobre él es blanco (~6,4:1). Para texto/enlaces en morado se usa `accentLight`.

## Componentes
Compartidos (`lib/shared/`): `Shimmer`/`SkeletonBox` (ShaderMask + AnimationController propios), `StaggeredAppear`, `ShakeWidget`, `PinchDetector`, `EmptyState` + `EmptyIllustrationPainter` (CustomPainter), `BlurSheet`/`showBlurSheet`/`SheetHeader`/`SheetActionTile` (BackdropFilter), `AppIconButton`/`AppFilledButton`/`AppTextButton`, `AppPageRoute`, `AppHaptics`, `formatBytes`.

Bóveda (`lib/features/vault/`):
- `VaultBrowserController` (estado: carpetas, archivos, migas, selección, columnas, búsqueda, borrar/mover/sin conexión) y `VaultServices` (dependencias inyectables: repositorio real `VaultDataRepository`, importación, sincronización, miniaturas, visor, limpieza de archivos).
- `HomeVaultScreen` (pantalla), `VaultTopBar` (título/búsqueda animados + migas + barra de selección), `VaultGrid` (cuadrícula/lista, refresh, skeletons, vacío), `FileTile`, `FolderTile`, `EntryRow`, `TileFrame`, `ThumbnailView`, `SyncStatusIcon`, `SwipeActionRow`, `SelectionBar`, `ExpandableFab`, `BreadcrumbBar`, `VaultSearchField`, `vault_sheets.dart` (importar, nueva carpeta, confirmar borrado, mover), `VaultMediaViewerScreen`.

Autenticación (`lib/features/auth/`): `PinScreen` (flujo intacto: crear bóveda, código de recuperación una sola vez, oferta de biometría, biometría al abrir, retraso con cuenta atrás, `AuthController` inyectable), `PinDots`, `PinKeypad`, `auth_sheets.dart`.

### Mapeo `SyncStatus` -> ícono
`pendiente` reloj (ámbar) · `subiendo` anillo de progreso (determinado si hay `progress`) · `enNube` nube con check (azul) · `enCache` descarga completada · `sinConexion` pin offline (verde) · `error` triángulo/círculo de error (rojo). Cada uno con etiqueta semántica en español.

## Gestos
- **Mantener presionado**: entra al modo selección (háptica); tocar suma/quita; la barra superior se sustituye por `SelectionBar` con animación (cerrar, contador, seleccionar todo, mover, sin conexión, eliminar). El botón atrás sale de la selección.
- **Pellizco**: `PinchDetector` usa `Listener` con dos punteros (no entra en la arena de gestos, así no pelea con el scroll; el scroll se bloquea mientras hay dos dedos). Cambia entre 1 y 5 columnas. **Con 1 columna se muestra la lista**, que es donde funciona el deslizamiento. (Se usa un detector propio en lugar de `ScaleGestureRecognizer` por la competencia con el scroll.)
- **Deslizar** (`SwipeActionRow`, propio): en la vista de lista, deslizar a la izquierda revela Mover / Sin conexión / Eliminar; también se exponen como acciones semánticas personalizadas para lectores de pantalla.
- **Pull-to-refresh**: `RefreshIndicator` llama a `VaultServices.syncRunner` (= `SyncQueueService.processSyncQueue`) y recarga.
- **FAB expandible**: Nueva carpeta · Importar archivo (`VaultImportService`) · Importar desde galería (`TODO(F4)`, muestra aviso).

## Movimiento
Aparición escalonada de celdas (un solo controlador por celda, retraso incluido en el `Interval`; solo la primera vez que aparece cada celda), `Hero` (`vault-item-<id>`) de celda a visor, skeleton shimmer mientras carga la miniatura, puntos del PIN con escala elástica, sacudida al fallar, transición de desbloqueo (puntos en acento + candado abierto + fundido) y fundido/deslizamiento compartido en rutas (`AppPageRoute`). Con "reducir animaciones" del sistema (`MediaQuery.disableAnimations`) el shimmer, el escalonado y la sacudida se desactivan.

## Háptica (`AppHaptics`)
Selección (long press, tocar en selección, teclas del PIN, cambio de columnas/vista, FAB) · PIN correcto (`mediumImpact`) · PIN incorrecto (`heavyImpact`) · eliminar (`vibrate`).

## Accesibilidad
- Áreas táctiles >= 44 px (`AppSizes.minTouch`); verificado con `meetsGuideline(androidTapTargetGuideline / iOSTapTargetGuideline / labeledTapTargetGuideline / textContrastGuideline)`.
- `Semantics` en español: celdas ("Imagen X, 2,00 MB, En la nube"), insignias de estado, teclas ("Dígito 5", "Borrar"), puntos del PIN ("PIN: 3 de 6 dígitos"), migas ("Ir a Viajes", "Carpeta actual: 2025"), mensajes en `liveRegion` (estado del PIN, contador de selección).
- Contraste según la tabla anterior; el color nunca es el único indicador (cada estado tiene ícono y etiqueta).

## Plataformas
`SafeArea` en barra superior, FAB, sheets y PIN (notch/isla/barra de gestos). Lo específico de iOS se limita a `statusBarBrightness` (marcado `// iOS:`).

## Limitaciones conocidas
- Miniaturas: desde F4 `EncryptedThumbnailLoader` descifra `thumbPath` (subllave thumbs, LRU 96); sin miniatura la celda muestra ícono por tipo. El progreso de subida por archivo (`uploadProgress`) está cableado en `VaultGrid` pero `SyncQueueService` aún no lo emite (`TODO(F5)`).
- Reproductor de video (`TODO(F6)`).
- El deslizamiento solo existe en la vista de lista; en cuadrícula las acciones están en la selección.
- El modo selección no persiste al cambiar de carpeta.
- Las goldens se generaron con Roboto del SDK sobre Windows; en otra plataforma pueden diferir en subpíxeles (regenerar con `flutter test --update-goldens test/ui/goldens`).
- No se probó en dispositivo: gestos reales, háptica, notch, rendimiento ni accesibilidad con TalkBack/VoiceOver (ver reporte de F3.5).

## F4 parcial: importación desde galería
- Paquetes: `photo_manager` 3.12.0 (acceso a galería, miniaturas JPEG, originFile, borrado, descarga iCloud con `PMProgressHandler`) y `video_compress` 3.1.4. Selector propio (`lib/features/gallery/`) con tokens en vez de `wechat_assets_picker`: evita otra dependencia grande con su propio tema/textos y mantiene accesibilidad coherente.
- Compresión: `video_compress` es el único plugin simple con presets 1080p/720p en Android e iOS y cancelación. Contras: último release hace ~21 meses, cancelación en Android poco fiable, una compresión a la vez. Alternativas descartadas: `light_compressor` (hace ~3 años, solo calidades abstractas very_low..very_high, no 1080/720 explícitos) y forks de ffmpeg-kit (el proyecto upstream fue retirado; binarios pesados/GPL, +decenas de MB). Está tras la interfaz `VideoCompressor`: se puede cambiar sin tocar el servicio.
- Estimación de tamaño: bitrates de referencia (5 Mbps 1080p, 2,5 Mbps 720p) x duración; el tamaño real se muestra durante la importación (antes -> después).
- `contentHash` = SHA-256 del contenido que realmente se guarda (el original si no se comprimió; el comprimido si sí).
- Borrado de originales: apagado (bandera `originalDeletionEnabled` + `cloudVerifier` de F5 + confirmación explícita). La preferencia de la UI solo se guarda.
- Sin probar en dispositivo: permisos reales, selector real, miniaturas de video, compresión real, descarga de iCloud, borrado de originales.
