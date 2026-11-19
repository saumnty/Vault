import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/crypto/auth_controller.dart' show AuthController;
import '../../core/crypto/key_hierarchy.dart';
import '../../core/crypto/secure_kv_store.dart';
import '../../core/services/app_paths.dart';
import '../../core/session/vault_session.dart';
import 'db_rekeyer.dart';

export 'db_rekeyer.dart';

/// La copia re-cifrada de la BD no superó la verificación (§6.1): la BD
/// original queda intacta y la copia se borra.
class VaultRekeyVerificationException implements Exception {
  const VaultRekeyVerificationException(this.detail);
  final String detail;
  @override
  String toString() => 'VaultRekeyVerificationException: $detail';
}

/// C1 (D62): la BD de una bóveda que YA existió no está en disco. No se crea
/// una vacía en su lugar (se subiría a Drive como si fuera la verdad); hay que
/// reparar o restaurar.
class VaultDatabaseMissingException implements Exception {
  const VaultDatabaseMissingException();

  @override
  String toString() =>
      'Falta la base de datos de la bóveda; no se crea una vacía.';
}

/// La BD la creó una versión MÁS NUEVA de la app. No se toca: hay que
/// instalar una versión igual o más reciente.
class VaultSchemaTooNewException implements Exception {
  const VaultSchemaTooNewException(this.found, this.supported);
  final int found;
  final int supported;

  @override
  String toString() =>
      'La bóveda la creó una versión más nueva de la app (esquema $found > '
      '$supported). Instala la versión más reciente.';
}

/// Esquema de la BD. Desde v6 se actualiza de forma incremental; antes de v6
/// se recreaba (ver [upgrade] y [recreate]).
///
/// Historial: v2 = esquema anterior (rutas absolutas); v3 = F3 (rutas
/// relativas, syncStatus, driveFileId, thumbPath, lastAccessedAt,
/// contentHash, sourceAssetId, durationMs, folders.isOffline, índices);
/// v4 = F5 (tabla `sync_queue`; vault_items.cloudMd5/cloudSize/
/// thumbDriveFileId); v5 = F6a (sync_queue.payload para borrados remotos);
/// v6 = S-09 (vault_items.fileId y thumbFileId: UUID del encabezado del
/// `.vault`/`.thumb`, comprobado al abrir/descargar);
/// v7 = cambio de cuenta de Google (tablas `migration_state` y
/// `migration_items`);
/// v8 = papelera (v2 fase 5: `deletedAt` y `trashRoot` en `vault_items` y
/// `folders`). DESDE v6 la actualización es INCREMENTAL (conserva los datos:
/// ya hay bóvedas reales en iPhone); versiones anteriores se recrean.
/// v9 = etiquetas (v2 fase 9: tablas `tags` e `item_tags`).
/// v10 = rotación de la DEK (D60: `vault_items.keyGen`, por defecto 1; tablas
/// `rotation_state` y `rotation_old_files`, vacías fuera de una rotación).
/// v11 = cambio de cuenta atascado (D75: `vault_items.cloudAccountTag` y
/// `thumbAccountTag`, `NULL` = sin comprobar en la cuenta actual; tabla
/// `vault_meta` con la sal del tag y tabla `diag_events` para el diagnóstico
/// persistente, vacía hasta la parte B). Solo `ADD COLUMN` y
/// `CREATE TABLE IF NOT EXISTS`: ninguna fila se toca.
/// v12 = importar álbumes (v2.2, D86: `vault_items.sourceHash`, índice por
/// `sourceAssetId` y tablas `import_batches`/`import_queue`, la cola
/// reanudable de importación de ESTE teléfono; nunca sale en el snapshot).
/// Igual de incremental: `ADD COLUMN` y `CREATE … IF NOT EXISTS`.
class VaultSchema {
  VaultSchema._();

  static const int version = 12;

  /// Tablas que pertenecen a ESTE teléfono y NO viajan en el snapshot de
  /// Drive (se vacían en la copia antes de subirla y al restaurar): el
  /// diagnóstico (D78) y la cola de importación (D86: lleva ids de la
  /// fototeca local, que no significan nada en otro teléfono).
  static const List<String> localOnlyTables = [
    'diag_events',
    'import_queue',
    'import_batches',
  ];

  /// Triggers de cardinalidad de una rotación en curso (D62). Se crean al
  /// congelar el conjunto viejo y se quitan al terminar; un snapshot que los
  /// traiga los pierde al restaurar.
  static const List<String> rotationTriggerNames = [
    'rot_items_ins',
    'rot_items_del',
    'rot_folders_ins',
    'rot_folders_del',
  ];

  /// Primera versión que se actualiza sin perder datos (y que un snapshot de
  /// Drive puede traer al restaurar).
  static const int minUpgradableVersion = 6;
  static const String dbFileName = 'vault_secure.db';

  static const List<String> indexNames = [
    'idx_items_folder',
    'idx_items_sync',
    'idx_items_lastAccessed',
    'idx_items_drive',
    'idx_folders_parent',
    'idx_sync_queue_due',
    'idx_items_deleted',
    'idx_item_tags_tag',
    'idx_items_keygen',
    'idx_items_source',
    'idx_import_queue_state',
  ];

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        parentId TEXT,
        createdAt TEXT NOT NULL,
        isOffline INTEGER NOT NULL DEFAULT 0,
        deletedAt INTEGER,
        trashRoot TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE vault_items (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        folderId TEXT,
        encryptedPath TEXT NOT NULL,
        fileSize INTEGER NOT NULL,
        mimeType TEXT,
        createdAt TEXT NOT NULL,
        isOffline INTEGER NOT NULL DEFAULT 0,
        isFavorite INTEGER NOT NULL DEFAULT 0,
        driveFileId TEXT,
        syncStatus TEXT NOT NULL DEFAULT 'pendiente',
        thumbPath TEXT,
        lastAccessedAt INTEGER,
        contentHash TEXT,
        sourceAssetId TEXT,
        durationMs INTEGER,
        cloudMd5 TEXT,
        cloudSize INTEGER,
        thumbDriveFileId TEXT,
        fileId TEXT,
        thumbFileId TEXT,
        deletedAt INTEGER,
        trashRoot TEXT,
        keyGen INTEGER NOT NULL DEFAULT 1
      )
    ''');
    // Cola de sincronización persistente (F5). Una fila por (itemId, kind);
    // para respaldos sin item itemId = '_'. Se borra al completarse.
    // state: pendiente | subiendo | error.
    await db.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        itemId TEXT NOT NULL,
        kind TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pendiente',
        attempts INTEGER NOT NULL DEFAULT 0,
        nextAttemptAt INTEGER NOT NULL DEFAULT 0,
        lastError TEXT,
        createdAt INTEGER NOT NULL,
        payload TEXT,
        UNIQUE (itemId, kind)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_sync_queue_due ON sync_queue(state, nextAttemptAt)',
    );
    await db.execute('CREATE INDEX idx_items_folder ON vault_items(folderId)');
    await db.execute('CREATE INDEX idx_items_sync ON vault_items(syncStatus)');
    await db.execute(
      'CREATE INDEX idx_items_lastAccessed ON vault_items(lastAccessedAt)',
    );
    await db.execute(
      'CREATE INDEX idx_items_drive ON vault_items(driveFileId)',
    );
    await db.execute('CREATE INDEX idx_folders_parent ON folders(parentId)');
    await db.execute(
      'CREATE INDEX idx_items_deleted ON vault_items(deletedAt)',
    );
    await createMigrationTables(db);
    await createTagTables(db);
    await addRotationSchema(db);
    await addAccountTagSchema(db);
    await addImportQueueSchema(db);
  }

  /// v12 (D86, v2.2): cola reanudable de importación por bóveda y huella del
  /// original. Idempotente y estrictamente incremental:
  /// * `vault_items.sourceHash` (SHA-256 del ORIGINAL tal como estaba en la
  ///   galería; difiere de `contentHash` solo si el video se comprimió). Filas
  ///   existentes: `NULL` (para ellas `contentHash` sirve como huella).
  /// * índice `idx_items_source` (dedupe por `sourceAssetId`).
  /// * `import_batches` (un lote: estado, carpeta destino, calidad) e
  ///   `import_queue` (un asset por fila, con su estado). Vacías al crear.
  static Future<void> addImportQueueSchema(DatabaseExecutor db) async {
    final cols = (await db.rawQuery(
      'PRAGMA table_info(vault_items)',
    )).map((r) => r['name']).toSet();
    if (!cols.contains('sourceHash')) {
      await db.execute('ALTER TABLE vault_items ADD COLUMN sourceHash TEXT');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_items_source ON vault_items(sourceAssetId)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS import_batches (
        id TEXT PRIMARY KEY,
        state TEXT NOT NULL,
        folderId TEXT,
        videoQuality TEXT NOT NULL,
        total INTEGER NOT NULL DEFAULT 0,
        estimatedBytes INTEGER NOT NULL DEFAULT 0,
        pauseReason TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS import_queue (
        batchId TEXT NOT NULL,
        seq INTEGER NOT NULL,
        assetId TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        itemId TEXT,
        error TEXT,
        name TEXT,
        attempts INTEGER NOT NULL DEFAULT 0,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (batchId, seq),
        UNIQUE (batchId, assetId)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_import_queue_state '
      'ON import_queue(batchId, state, seq)',
    );
  }

  /// v11 (D75): tags de cuenta por item, `vault_meta` (sal del tag, se crea
  /// al primer uso, no aquí) y `diag_events` (diagnóstico persistente, parte
  /// B). Idempotente y estrictamente incremental: solo `ADD COLUMN` (con
  /// comprobación por `PRAGMA table_info`) y `CREATE TABLE IF NOT EXISTS`.
  /// Las filas existentes quedan con los tags a `NULL` (= «sin comprobar»):
  /// la primera apertura con sesión verifica todo en la cuenta actual.
  static Future<void> addAccountTagSchema(DatabaseExecutor db) async {
    final cols = (await db.rawQuery(
      'PRAGMA table_info(vault_items)',
    )).map((r) => r['name']).toSet();
    if (!cols.contains('cloudAccountTag')) {
      await db.execute(
        'ALTER TABLE vault_items ADD COLUMN cloudAccountTag TEXT',
      );
    }
    if (!cols.contains('thumbAccountTag')) {
      await db.execute(
        'ALTER TABLE vault_items ADD COLUMN thumbAccountTag TEXT',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vault_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS diag_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        level TEXT NOT NULL,
        category TEXT NOT NULL,
        message TEXT NOT NULL
      )
    ''');
  }

  /// v10 (D60/D62): generación de llave por item y tablas de la rotación de
  /// la DEK. Idempotente: no falla si ya existe nada de ello. NO toca datos
  /// (las filas existentes quedan en `keyGen = 1`, la bóveda actual).
  static Future<void> addRotationSchema(DatabaseExecutor db) async {
    final cols = (await db.rawQuery(
      'PRAGMA table_info(vault_items)',
    )).map((r) => r['name']).toSet();
    if (!cols.contains('keyGen')) {
      await db.execute(
        'ALTER TABLE vault_items ADD COLUMN keyGen INTEGER NOT NULL DEFAULT 1',
      );
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_items_keygen ON vault_items(keyGen)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rotation_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        rotationId TEXT NOT NULL,
        fromGen INTEGER NOT NULL,
        toGen INTEGER NOT NULL,
        frozenAt INTEGER NOT NULL,
        frozenItems INTEGER NOT NULL,
        frozenFolders INTEGER NOT NULL,
        itemsInserted INTEGER NOT NULL DEFAULT 0,
        itemsDeleted INTEGER NOT NULL DEFAULT 0,
        foldersInserted INTEGER NOT NULL DEFAULT 0,
        foldersDeleted INTEGER NOT NULL DEFAULT 0,
        oldBackupDriveId TEXT,
        oldBackupMd5 TEXT,
        oldSnapshotDriveId TEXT,
        oldSnapshotMd5 TEXT,
        bridgeDriveId TEXT
      )
    ''');
    // A5: lista exacta del conjunto viejo de Drive (lo único que se borra).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rotation_old_files (
        driveId TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        md5 TEXT,
        itemId TEXT,
        kind TEXT NOT NULL,
        quarantine INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  /// Cambio de cuenta de Google (v7). Una sola fila de estado (`id = 1`) y,
  /// por item, las referencias a la nube de la cuenta ANTERIOR (para poder
  /// cancelar sin perder nada tras el reinicio de referencias).
  static Future<void> createMigrationTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS migration_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        phase TEXT NOT NULL,
        oldEmail TEXT,
        newEmail TEXT,
        startedAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        neededBytes INTEGER NOT NULL DEFAULT 0,
        downloadTotal INTEGER NOT NULL DEFAULT 0,
        downloadDone INTEGER NOT NULL DEFAULT 0,
        lastError TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS migration_items (
        itemId TEXT PRIMARY KEY,
        oldStatus TEXT NOT NULL,
        oldDriveFileId TEXT,
        oldCloudMd5 TEXT,
        oldCloudSize INTEGER,
        oldThumbDriveFileId TEXT
      )
    ''');
  }

  /// Actualiza una BD existente. Desde [minUpgradableVersion] es incremental
  /// (no borra nada); anteriores se recrean (sin datos reales entonces).
  static Future<void> upgrade(Database db, int from, int to) async {
    if (from < minUpgradableVersion) {
      await recreate(db);
      return;
    }
    // v6 -> v7: tablas del cambio de cuenta.
    if (from < 7) await createMigrationTables(db);
    // v7 -> v8: papelera.
    if (from < 8) await addTrashColumns(db);
    // v8 -> v9: etiquetas.
    if (from < 9) await createTagTables(db);
    // v9 -> v10: generación de llave por item y tablas de la rotación.
    if (from < 10 && to >= 10) await addRotationSchema(db);
    // v10 -> v11: tags de cuenta, `vault_meta` y `diag_events` (D75).
    if (from < 11 && to >= 11) await addAccountTagSchema(db);
    // v11 -> v12: cola de importación y `sourceHash` (D86).
    if (from < 12 && to >= 12) await addImportQueueSchema(db);
  }

  /// v9: etiquetas. `tags.name` es único sin distinguir mayúsculas. Idempotente.
  static Future<void> createTagTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tags (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS item_tags (
        itemId TEXT NOT NULL,
        tagId TEXT NOT NULL,
        PRIMARY KEY (itemId, tagId)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_item_tags_tag ON item_tags(tagId)',
    );
  }

  /// v8: `deletedAt` (epoch ms en que entró a la papelera) y `trashRoot` (id
  /// del elemento que se borró: una carpeta arrastra a sus hijos con su id).
  /// Idempotente: no falla si las columnas ya existen. NO toca datos.
  static Future<void> addTrashColumns(DatabaseExecutor db) async {
    for (final table in const ['vault_items', 'folders']) {
      final cols = (await db.rawQuery(
        'PRAGMA table_info($table)',
      )).map((r) => r['name']).toSet();
      if (!cols.contains('deletedAt')) {
        await db.execute('ALTER TABLE $table ADD COLUMN deletedAt INTEGER');
      }
      if (!cols.contains('trashRoot')) {
        await db.execute('ALTER TABLE $table ADD COLUMN trashRoot TEXT');
      }
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_items_deleted ON vault_items(deletedAt)',
    );
  }

  /// Borra todo y recrea (sustituye a una migración).
  static Future<void> recreate(Database db) async {
    for (final t in rotationTriggerNames) {
      await db.execute('DROP TRIGGER IF EXISTS $t');
    }
    await db.execute('DROP TABLE IF EXISTS import_queue');
    await db.execute('DROP TABLE IF EXISTS import_batches');
    await db.execute('DROP TABLE IF EXISTS diag_events');
    await db.execute('DROP TABLE IF EXISTS vault_meta');
    await db.execute('DROP TABLE IF EXISTS rotation_old_files');
    await db.execute('DROP TABLE IF EXISTS rotation_state');
    await db.execute('DROP TABLE IF EXISTS item_tags');
    await db.execute('DROP TABLE IF EXISTS tags');
    await db.execute('DROP TABLE IF EXISTS migration_items');
    await db.execute('DROP TABLE IF EXISTS migration_state');
    await db.execute('DROP TABLE IF EXISTS sync_queue');
    await db.execute('DROP TABLE IF EXISTS vault_items');
    await db.execute('DROP TABLE IF EXISTS folders');
    await create(db);
  }
}

/// Abre una BD. Inyectable: en la app usa SQLCipher; en pruebas de escritorio
/// usa sqlite normal (sqflite_common_ffi) con `password == null`.
typedef DatabaseOpener =
    Future<Database> Function(
      String absolutePath, {
      String? password,
      required OpenDatabaseOptions options,
    });

/// Abre con SQLCipher real (móvil). Es el `opener` de la app.
Future<Database> openSqlCipherDatabase(
  String absolutePath, {
  String? password,
  required OpenDatabaseOptions options,
}) => openDatabase(
  absolutePath,
  password: password,
  version: options.version,
  onConfigure: options.onConfigure,
  onCreate: options.onCreate,
  onUpgrade: options.onUpgrade,
  onDowngrade: options.onDowngrade,
);

/// Conexión a la BD SQLCipher de la bóveda.
///
/// * La contraseña es el hex (64 caracteres) de la subllave HKDF "sqlcipher"
///   de la sesión; sin sesión desbloqueada no se abre ([StateError]).
/// * Al bloquear la bóveda (`VaultSession.clear`) la conexión se cierra.
/// * Si hay una conexión abierta con otra llave, se cierra y se reabre.
/// * El archivo vive en `AppPaths.dbDir` (documents/db/vault_secure.db).
///
/// C1 (D62): con la marca [AuthController.dbCreatedKey] escrita, la BD de
/// esta bóveda ya existió; si el archivo falta, [database] lanza
/// [VaultDatabaseMissingException] y NUNCA crea una BD vacía (que después se
/// tomaría como la verdad y se subiría a Drive). Solo se crea con la marca
/// ausente (primer uso tras `createVault`).
///
/// D67 (fase 8, `docs/DISENO_SENUELO.md` §2.3/§4.1): hay UNA instancia por
/// bóveda ([instance] = la principal, la de siempre; [secondaryInstance] = la
/// secundaria). Cada una tiene fijas su bóveda ([slot]), su ruta (la de su
/// `VaultPaths`) y su marca C1. [database] exige que la sesión abierta sea de
/// SU bóveda ([WrongVaultSlotError] si no) y liga la conexión a la época de
/// la sesión; una apertura que cruza un bloqueo no publica la conexión ni
/// crea nada.
class VaultDatabase {
  static final VaultDatabase _instance = VaultDatabase._(
    session: VaultSession(),
    opener: openSqlCipherDatabase,
    useSqlCipher: true,
    markerStore: FlutterSecureKeyValueStore(),
    rekeyer: const SqlCipherExportRekeyer(),
  );

  factory VaultDatabase() => _instance;

  /// Instancia única de la bóveda PRINCIPAL (equivalente a `VaultDatabase()`).
  static VaultDatabase get instance => _instance;

  /// Instancia de la bóveda SECUNDARIA (`Documents/alt/db/vault_secure.db`).
  /// Se crea al primer uso (sin secundaria nunca se construye).
  static final VaultDatabase secondaryInstance = VaultDatabase._(
    session: VaultSession(),
    opener: openSqlCipherDatabase,
    useSqlCipher: true,
    markerStore: FlutterSecureKeyValueStore(),
    rekeyer: const SqlCipherExportRekeyer(),
    slot: VaultSlot.secondary,
  );

  /// Instancia independiente para pruebas: [opener] (p. ej. sqflite_common_ffi,
  /// sin SQLCipher) y [dbPath] absoluta explícita (si no, usa la ruta de la
  /// bóveda [slot]). Sin [markerStore] no se aplica la guarda de "BD ausente"
  /// (pruebas históricas).
  @visibleForTesting
  VaultDatabase.forTesting({
    required VaultSession session,
    required DatabaseOpener opener,
    String? dbPath,
    bool useSqlCipher = false,
    SecureKeyValueStore? markerStore,
    DbRekeyer? rekeyer,
    VaultSlot slot = VaultSlot.primary,
  }) : this._(
         session: session,
         opener: opener,
         dbPath: dbPath,
         useSqlCipher: useSqlCipher,
         markerStore: markerStore,
         rekeyer: rekeyer ?? const SqlCipherExportRekeyer(),
         slot: slot,
       );

  VaultDatabase._({
    required VaultSession session,
    required DatabaseOpener opener,
    String? dbPath,
    required bool useSqlCipher,
    SecureKeyValueStore? markerStore,
    required DbRekeyer rekeyer,
    this.slot = VaultSlot.primary,
  }) : _session = session,
       _opener = opener,
       _dbPathOverride = dbPath,
       _useSqlCipher = useSqlCipher,
       _markerStore = markerStore,
       _rekeyer = rekeyer {
    // Al bloquear la bóveda se cierra la conexión.
    _session.addOnClear(() => unawaited(close()));
  }

  /// Bóveda a la que pertenece esta instancia (fija).
  final VaultSlot slot;

  final VaultSession _session;
  final DatabaseOpener _opener;
  final String? _dbPathOverride;
  final bool _useSqlCipher;
  final SecureKeyValueStore? _markerStore;
  final DbRekeyer _rekeyer;

  Database? _db;
  String? _openPassword;
  int? _openedGen;

  /// Época de la sesión con la que se abrió la conexión actual (D67).
  int? _openedEpoch;
  Future<Database>? _opening;

  /// Puerta exclusiva del re-cifrado (§6.1): mientras exista, [database]
  /// espera (la BD mide pocos MiB: < 1 s).
  Completer<void>? _rekeying;

  /// `true` mientras [rekeyTo] trabaja.
  bool get isRekeying => _rekeying != null;

  bool get isOpen => _db != null;

  /// Generación de la llave con la que se abrió la conexión actual (D60), o
  /// `null` si está cerrada. Durante una rotación la BD puede seguir con la
  /// llave anterior hasta re-cifrarla.
  int? get openedGen => _db == null ? null : _openedGen;

  /// Ruta de la BD de ESTA bóveda (la principal: `db/vault_secure.db`, la de
  /// siempre). Las operaciones la capturan una vez al empezar.
  String get _dbPath => _dbPathOverride ?? VaultPaths.of(slot).dbFilePath;

  /// Clave de la marca C1 de esta bóveda.
  String get _markerKey => AuthController.dbCreatedKeyFor(slot);

  /// D67: lanza [WrongVaultSlotError] si la sesión está abierta en OTRA
  /// bóveda (nunca se lee ni se escribe la BD de una bóveda con la otra
  /// abierta). Bloqueada: lo decide [_candidatesFromSession].
  void _requireOwnSlot() {
    final open = _session.slot;
    if (open != null && open != slot) throw WrongVaultSlotError(slot, open);
  }

  /// Llaves SQLCipher candidatas de la sesión (generación, llave cruda
  /// `x'<64 hex>'`), en el orden en que se prueban: SQLCipher usa la llave
  /// cruda tal cual y se salta su PBKDF2 interno (256 000 iteraciones), que es
  /// innecesario porque la subllave HKDF ya es de 256 bits de alta entropía.
  List<(int, String)> _candidatesFromSession() {
    _requireOwnSlot();
    final candidates = _session.dbCandidatesFor(slot);
    if (candidates.isEmpty || candidates.any((c) => c.$2.isDestroyed)) {
      throw StateError('La bóveda está bloqueada: no se puede abrir la BD');
    }
    return [for (final (gen, keys) in candidates) (gen, passwordFor(keys))];
  }

  /// Llave SQLCipher cruda `x'<64 hex>'` de unas llaves ya derivadas (F9: se
  /// usa para abrir el snapshot descargado ANTES de abrir la sesión).
  static String passwordFor(KeyHierarchy keys) {
    final sb = StringBuffer();
    for (final b in keys.sqlcipher.bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return "x'${sb.toString()}'";
  }

  /// Ruta absoluta de la BD de la app (`db/vault_secure.db`).
  static String get defaultDbPath =>
      p.join(AppPaths.dbDir.path, VaultSchema.dbFileName);

  /// Conexión abierta; la abre (o reabre si cambió la llave). Lanza
  /// [StateError] si la bóveda está bloqueada.
  Future<Database> get database async {
    // Durante un re-cifrado (§6.1) se espera a que termine.
    while (_rekeying != null) {
      await _rekeying!.future;
    }
    final candidates = _candidatesFromSession();
    // D67: bóveda y época de la sesión al pedir la BD.
    final ticket = _session.ticket();
    // Espera una apertura en curso antes de decidir.
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    ticket.check();
    final current = _db;
    if (current != null &&
        current.isOpen &&
        _openedEpoch == ticket.epoch &&
        candidates.any((c) => c.$1 == _openedGen && c.$2 == _openPassword)) {
      return current;
    }
    if (current != null) await close();
    final future = _open(candidates, ticket);
    _opening = future;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  Future<Database> _open(
    List<(int, String)> candidates,
    SessionTicket ticket,
  ) async {
    if (_dbPathOverride == null) await AppPaths.init();
    // D67: ruta y marca capturadas UNA vez (son fijas por instancia).
    final path = _dbPath;
    final markerKey = _markerKey;
    final file = File(path);
    final markers = _markerStore;
    var existed = file.existsSync();
    // C1: la BD ya existió y falta el archivo -> nunca se crea una vacía. Si
    // quedan restos de un re-cifrado (§6.2), se intenta repararla con ellos.
    if (!existed &&
        markers != null &&
        await markers.read(markerKey) == 'true') {
      ticket.check();
      if (!await _repairFromRekeyLeftovers(candidates)) {
        throw const VaultDatabaseMissingException();
      }
      existed = true;
    }
    // D67: nada se crea (carpeta ni BD) si la sesión cambió entretanto.
    ticket.check();
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    // Una BD NUEVA se crea con la llave actual (la última candidata). Con una
    // existente se prueban en orden; sin SQLCipher (pruebas) no hay llave que
    // probar y vale la primera.
    final tries = !existed
        ? [candidates.last]
        : (_useSqlCipher ? candidates : [candidates.first]);
    Database? db;
    late (int, String) used;
    Object? lastError;
    StackTrace? lastStack;
    for (final c in tries) {
      try {
        db = await _openWith(c.$2, path: path);
        used = c;
        break;
      } on VaultSchemaTooNewException {
        rethrow; // no es un problema de llave
      } catch (e, st) {
        lastError = e;
        lastStack = st;
      }
    }
    if (db == null) {
      Error.throwWithStackTrace(lastError!, lastStack!);
    }
    // D67: si la sesión cambió (bloqueo, otra bóveda) mientras se abría, la
    // conexión no se publica ni se escribe la marca.
    await _closeIfStale(db, ticket);
    // Creada ahora, o ya existente de una versión sin la marca (bóvedas
    // anteriores a C1): desde aquí la BD de esta bóveda "existe".
    if (markers != null && await markers.read(markerKey) != 'true') {
      await _closeIfStale(db, ticket);
      try {
        await markers.write(markerKey, 'true');
      } catch (_) {
        // Almacén seguro no disponible: la marca se escribe en la próxima
        // apertura (hasta entonces la guarda no está activa, como antes).
      }
    }
    await _closeIfStale(db, ticket);
    _db = db;
    _openPassword = used.$2;
    _openedGen = used.$1;
    _openedEpoch = ticket.epoch;
    return db;
  }

  /// Cierra [db] y lanza [SessionChangedException] si [ticket] ya no vale.
  static Future<void> _closeIfStale(Database db, SessionTicket ticket) async {
    if (ticket.isValid) return;
    try {
      await db.close();
    } catch (_) {}
    throw SessionChangedException();
  }

  /// Abre con [password] y, con SQLCipher, comprueba que la llave abre el
  /// archivo (una llave equivocada falla al leer el esquema).
  Future<Database> _openWith(String password, {String? path}) async {
    final db = await _opener(
      path ?? _dbPath,
      password: _useSqlCipher ? password : null,
      options: OpenDatabaseOptions(
        version: VaultSchema.version,
        onCreate: (db, v) => VaultSchema.create(db),
        // Desde v6: actualización incremental (conserva los datos).
        onUpgrade: (db, o, n) => VaultSchema.upgrade(db, o, n),
        // BD más NUEVA que la app (se instaló una versión anterior): NUNCA se
        // recrea (antes se borraba todo). Se niega a abrir sin tocar nada.
        onDowngrade: (db, o, n) => throw VaultSchemaTooNewException(o, n),
      ),
    );
    if (_useSqlCipher) {
      try {
        await db.rawQuery('SELECT count(*) FROM sqlite_master');
      } catch (_) {
        try {
          await db.close();
        } catch (_) {}
        rethrow;
      }
    }
    return db;
  }

  // ------------------------------------------------------------ re-cifrado

  /// Copia de trabajo de un re-cifrado hacia la generación [gen].
  String rekeyTmpPath(int gen) => '$_dbPath.k$gen.tmp';

  /// Copia de seguridad (cifrada con la llave vieja) de la generación [gen]
  /// mientras dura el re-cifrado; se borra en `switchingLocal`.
  String rekeyBackupPath(int gen) => '$_dbPath.k$gen';

  /// Tablas cuyas filas deben ser idénticas en la copia re-cifrada.
  static const List<String> _rekeyTables = [
    'vault_items',
    'folders',
    'sync_queue',
    'migration_state',
    'migration_items',
    'tags',
    'item_tags',
    'rotation_state',
    'rotation_old_files',
    // v11 (D75): la sal del tag de cuenta debe sobrevivir a la rotación (si
    // no, todos los tags dejarían de coincidir) y el diagnóstico persistente.
    'vault_meta',
    'diag_events',
    // v12 (D86): un lote de importación a medias debe seguir tras rotar.
    'import_batches',
    'import_queue',
  ];

  /// Re-cifra la BD de la llave de la generación [fromGen] ([from]) a la de
  /// [toGen] ([to]) POR COPIA (§6.1, C1, D62):
  ///
  /// 1. Puerta exclusiva: [database] espera; la conexión se cierra.
  /// 2. Cuentas de todas las tablas, triggers y `user_version`; checkpoint.
  /// 3. `sqlcipher_export` a `db.kN.tmp` con la llave nueva ([DbRekeyer]).
  /// 4. Verificación de la copia: abre con la nueva, `integrity_check`,
  ///    `cipher_integrity_check`, mismas cuentas, triggers y versión; con la
  ///    llave vieja NO abre ([VaultRekeyVerificationException]).
  /// 5. COPIA (no mueve) la BD original a `db.k<fromGen>`.
  /// 6. `rename(tmp → db)`: reemplazo atómico. NUNCA hay un instante sin BD.
  ///
  /// Las llaves se copian al empezar (L6): un bloqueo a mitad no las pone a
  /// cero bajo el código. Si se bloquea antes del paso 6, aborta sin tocar la
  /// BD ([StateError]); el `rename` ya no se interrumpe. Idempotente: si la BD
  /// ya abre con la llave nueva, no hace nada.
  Future<void> rekeyTo({
    required int fromGen,
    required KeyHierarchy from,
    required int toGen,
    required KeyHierarchy to,
  }) async {
    if (!_useSqlCipher) {
      throw StateError('El re-cifrado exige SQLCipher');
    }
    // D67: la rotación es solo de la principal.
    if (slot != VaultSlot.primary) {
      throw StateError('Solo la bóveda principal se re-cifra');
    }
    _requireOwnSlot();
    if (_rekeying != null) throw StateError('Ya hay un re-cifrado en curso');
    // D67: bóveda y época al empezar; cada punto de aborto las comprueba (un
    // bloqueo, aunque se vuelva a abrir la misma bóveda, aborta).
    final ticket = _session.ticket();
    final gate = Completer<void>();
    _rekeying = gate;
    // L6: copias propias (String inmutables) de las dos llaves.
    final oldPw = passwordFor(from);
    final newPw = passwordFor(to);
    // D67: rutas capturadas UNA vez (fijas por instancia).
    final dbPath = _dbPath;
    final dbFile = File(dbPath);
    final tmp = File(rekeyTmpPath(toGen));
    final backup = File(rekeyBackupPath(fromGen));
    var renamed = false;
    void requireSession() {
      if (!ticket.isValid) {
        throw SessionChangedException(
          'La bóveda se bloqueó durante el re-cifrado de la BD',
        );
      }
    }

    try {
      await _closeConnection();
      if (await tmp.exists()) await tmp.delete();
      if (!dbFile.existsSync()) throw const VaultDatabaseMissingException();
      // ¿Ya re-cifrada (corte tras el rename)?
      if (await _opensWith(dbPath, newPw)) return;

      requireSession();
      final src = await _openWith(oldPw, path: dbPath);
      final int version;
      final Map<String, int> counts;
      final Set<String> triggers;
      try {
        version = await _userVersion(src);
        counts = await _tableCounts(src);
        triggers = await _triggerNames(src);
        try {
          await src.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
        } catch (_) {
          // Modo journal normal: no hay WAL que vaciar.
        }
        await _rekeyer.exportTo(src, tmp.path, newPw, userVersion: version);
      } finally {
        await src.close();
      }
      requireSession();

      await _verifyRekeyed(
        tmp.path,
        newPw: newPw,
        oldPw: oldPw,
        version: version,
        counts: counts,
        triggers: triggers,
      );
      requireSession();

      if (await backup.exists()) await backup.delete();
      await dbFile.copy(backup.path);
      final raf = await backup.open(mode: FileMode.append);
      try {
        await raf.flush();
      } finally {
        await raf.close();
      }
      requireSession(); // último punto de aborto

      // Restos de diario de la BD vieja: no deben aplicarse a la nueva. Desde
      // aquí el `rename` ya no se interrumpe (como antes); la ruta es la
      // capturada al empezar, fija por instancia (D67): nunca otra bóveda.
      for (final suffix in const ['-wal', '-shm', '-journal']) {
        final f = File('$dbPath$suffix');
        if (f.existsSync()) await f.delete();
      }
      await tmp.rename(dbPath);
      renamed = true;
    } catch (_) {
      if (!renamed) {
        try {
          if (await tmp.exists()) await tmp.delete();
          if (await backup.exists()) await backup.delete();
        } on FileSystemException {
          // se barren al reintentar
        }
      }
      rethrow;
    } finally {
      _rekeying = null;
      gate.complete();
    }
  }

  /// Borra la copia de seguridad cifrada con la llave vieja (`db.k<gen>`) y
  /// cualquier copia de trabajo (`db.kN.tmp`).
  Future<void> deleteRekeyLeftovers(int fromGen) async {
    final dir = File(_dbPath).parent;
    final base = p.basename(_dbPath);
    final pattern = RegExp('^${RegExp.escape(base)}\\.k[0-9]+\\.tmp\$');
    final backup = File(rekeyBackupPath(fromGen));
    if (await backup.exists()) await backup.delete();
    if (!dir.existsSync()) return;
    for (final e in dir.listSync()) {
      if (e is File && pattern.hasMatch(p.basename(e.path))) await e.delete();
    }
  }

  Future<void> _closeConnection() async {
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final db = _db;
    _db = null;
    _openPassword = null;
    _openedGen = null;
    _openedEpoch = null;
    if (db != null && db.isOpen) await db.close();
  }

  Future<bool> _opensWith(String path, String password) async {
    if (!File(path).existsSync()) return false;
    try {
      final db = await _openWith(password, path: path);
      await db.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<int> _userVersion(Database db) async =>
      (await db.rawQuery('PRAGMA user_version')).first.values.first as int;

  static Future<Map<String, int>> _tableCounts(Database db) async {
    final existing = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((r) => r['name']).toSet();
    return {
      for (final t in _rekeyTables)
        if (existing.contains(t))
          t:
              (await db.rawQuery('SELECT COUNT(*) AS n FROM $t')).first['n']
                  as int,
    };
  }

  static Future<Set<String>> _triggerNames(Database db) async =>
      (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger'",
      )).map((r) => r['name'] as String).toSet();

  Future<void> _verifyRekeyed(
    String path, {
    required String newPw,
    required String oldPw,
    required int version,
    required Map<String, int> counts,
    required Set<String> triggers,
  }) async {
    Database copy;
    try {
      copy = await _openWith(newPw, path: path);
    } catch (_) {
      throw const VaultRekeyVerificationException('no abre con la llave nueva');
    }
    try {
      final integrity = await copy.rawQuery('PRAGMA integrity_check');
      if (integrity.length != 1 || integrity.first.values.first != 'ok') {
        throw const VaultRekeyVerificationException('integrity_check');
      }
      List<Map<String, Object?>> cipher;
      try {
        cipher = await copy.rawQuery('PRAGMA cipher_integrity_check');
      } catch (_) {
        cipher = const [];
      }
      if (cipher.isNotEmpty) {
        throw const VaultRekeyVerificationException('cipher_integrity_check');
      }
      if (await _userVersion(copy) != version) {
        throw const VaultRekeyVerificationException('user_version');
      }
      final got = await _tableCounts(copy);
      if (got.length != counts.length ||
          counts.entries.any((e) => got[e.key] != e.value)) {
        throw const VaultRekeyVerificationException('cantidad de filas');
      }
      final gotTriggers = await _triggerNames(copy);
      if (gotTriggers.length != triggers.length ||
          !gotTriggers.containsAll(triggers)) {
        throw const VaultRekeyVerificationException('triggers');
      }
    } finally {
      await copy.close();
    }
    if (await _opensWith(path, oldPw)) {
      throw const VaultRekeyVerificationException('abre con la llave vieja');
    }
  }

  /// §6.2: falta la BD pero quedan restos de un re-cifrado. Se usa la copia
  /// de trabajo si abre con una llave de la sesión y verifica; si no, la
  /// copia de seguridad (`db.kN`) si abre. `true` si la BD quedó en su sitio.
  Future<bool> _repairFromRekeyLeftovers(List<(int, String)> candidates) async {
    final dir = File(_dbPath).parent;
    if (!dir.existsSync()) return false;
    final base = p.basename(_dbPath);
    final tmpRe = RegExp('^${RegExp.escape(base)}\\.k[0-9]+\\.tmp\$');
    final bakRe = RegExp('^${RegExp.escape(base)}\\.k[0-9]+\$');
    final files = dir.listSync().whereType<File>().toList();
    Future<bool> usable(File f) async {
      for (final (_, pw) in candidates) {
        try {
          final db = await _openWith(pw, path: f.path);
          try {
            final r = await db.rawQuery('PRAGMA integrity_check');
            if (r.length == 1 && r.first.values.first == 'ok') return true;
          } finally {
            await db.close();
          }
        } catch (_) {
          // otra llave
        }
      }
      return false;
    }

    for (final f in files.where((f) => tmpRe.hasMatch(p.basename(f.path)))) {
      if (await usable(f)) {
        await f.rename(_dbPath);
        return true;
      }
    }
    for (final f in files.where((f) => bakRe.hasMatch(p.basename(f.path)))) {
      if (await usable(f)) {
        await f.copy(_dbPath);
        return true;
      }
    }
    return false;
  }

  /// Cierra la conexión (idempotente). Se llama al bloquear la bóveda.
  Future<void> close() async {
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final db = _db;
    _db = null;
    _openPassword = null;
    _openedGen = null;
    _openedEpoch = null;
    if (db != null && db.isOpen) await db.close();
  }

  /// Checkpoint + cierre limpio y copia del archivo .db (ya cifrado por
  /// SQLCipher) para respaldarlo. Devuelve la copia con la generación de la
  /// llave que la cifra y el rango de `keyGen` de sus filas (C2, D61); el
  /// llamador la borra tras usarla. La conexión se reabre sola en el
  /// siguiente acceso.
  ///
  /// F5: `SyncService` la sube a appDataFolder como `vault_db[.kN].snapshot`.
  ///
  /// D67: solo la bóveda PRINCIPAL tiene snapshot (la secundaria no sale del
  /// teléfono): en otra instancia lanza [WrongVaultSlotError].
  Future<SnapshotCopy> exportEncryptedSnapshot() async {
    if (slot != VaultSlot.primary) {
      throw WrongVaultSlotError(VaultSlot.primary, slot);
    }
    final db = await database; // exige sesión desbloqueada (de la principal)
    final dbGen = openedGen!;
    final password = _openPassword!;
    _exporting++;
    try {
      final range = await db.rawQuery(
        'SELECT MIN(keyGen) AS lo, MAX(keyGen) AS hi FROM vault_items',
      );
      try {
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (_) {
        // Modo journal normal: no hay WAL que vaciar.
      }
      await close();
      final source = File(_dbPath);
      final snapshot = File('$_dbPath.snapshot');
      if (await snapshot.exists()) await snapshot.delete();
      final copy = await source.copy(snapshot.path);
      // D78: el diagnóstico persistente NO sale del teléfono: se vacía en la
      // COPIA (la tabla de este teléfono queda intacta).
      await _scrubSnapshotCopy(copy.path, password);
      return SnapshotCopy(
        copy,
        dbGen: dbGen,
        minKeyGen: range.first['lo'] as int?,
        maxKeyGen: range.first['hi'] as int?,
      );
    } finally {
      _exporting--;
    }
  }

  /// D78: copias del snapshot en curso (el diagnóstico persistente no
  /// escribe mientras tanto: una escritura a mitad de la copia la rompería).
  int _exporting = 0;

  /// `true` mientras la BD se re-cifra o se copia para el snapshot.
  bool get isBusyForCopy => _rekeying != null || _exporting > 0;

  /// D78: vacía `diag_events` en la copia [path] (misma llave). `VACUUM`
  /// reescribe el archivo para que no queden páginas libres con eventos. Si
  /// la copia no se puede abrir o limpiar, se borra y se lanza (el snapshot
  /// no se sube con el diagnóstico dentro).
  Future<void> _scrubSnapshotCopy(String path, String password) async {
    Database? copy;
    try {
      copy = await _openWith(password, path: path);
      // D78 + D86: diagnóstico y cola de importación (ids de la fototeca de
      // ESTE teléfono) no viajan.
      var removed = 0;
      for (final table in VaultSchema.localOnlyTables) {
        final has = await copy.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [table],
        );
        if (has.isEmpty) continue;
        final n =
            (await copy.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n']
                as int;
        if (n > 0) {
          await copy.delete(table);
          removed += n;
        }
      }
      if (removed > 0) await copy.execute('VACUUM');
    } catch (_) {
      try {
        await copy?.close();
      } catch (_) {}
      copy = null;
      final f = File(path);
      if (await f.exists()) await f.delete();
      rethrow;
    } finally {
      try {
        await copy?.close();
      } catch (_) {}
      for (final suffix in const ['-wal', '-shm', '-journal']) {
        final f = File('$path$suffix');
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } on FileSystemException {
            // se limpiará en el próximo snapshot
          }
        }
      }
    }
  }
}

/// Copia cifrada de la BD para subirla (C2, D61). Su nombre en Drive sale de
/// [dbGen] (la generación de la llave que la cifra), nunca de una constante.
class SnapshotCopy {
  const SnapshotCopy(
    this.file, {
    required this.dbGen,
    this.minKeyGen,
    this.maxKeyGen,
  });

  final File file;

  /// Generación de la llave SQLCipher de la copia.
  final int dbGen;

  /// Menor y mayor `keyGen` de sus filas (`null` = sin items).
  final int? minKeyGen;
  final int? maxKeyGen;

  /// `true` si todas sus filas son de la generación de su llave (o no hay
  /// filas): es un índice coherente que se puede publicar con su nombre.
  bool get isCoherent =>
      (minKeyGen == null || minKeyGen == dbGen) &&
      (maxKeyGen == null || maxKeyGen == dbGen);
}
