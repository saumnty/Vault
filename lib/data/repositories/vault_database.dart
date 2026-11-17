import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/crypto/key_hierarchy.dart';
import '../../core/services/app_paths.dart';
import '../../core/session/vault_session.dart';

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
class VaultSchema {
  VaultSchema._();

  static const int version = 9;

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
        trashRoot TEXT
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
class VaultDatabase {
  static final VaultDatabase _instance = VaultDatabase._(
    session: VaultSession(),
    opener: openSqlCipherDatabase,
    useSqlCipher: true,
  );

  factory VaultDatabase() => _instance;

  /// Instancia única (equivalente a `VaultDatabase()`).
  static VaultDatabase get instance => _instance;

  /// Instancia independiente para pruebas: [opener] (p. ej. sqflite_common_ffi,
  /// sin SQLCipher) y [dbPath] absoluta explícita (si no, usa `AppPaths`).
  @visibleForTesting
  VaultDatabase.forTesting({
    required VaultSession session,
    required DatabaseOpener opener,
    String? dbPath,
    bool useSqlCipher = false,
  }) : this._(
         session: session,
         opener: opener,
         dbPath: dbPath,
         useSqlCipher: useSqlCipher,
       );

  VaultDatabase._({
    required VaultSession session,
    required DatabaseOpener opener,
    String? dbPath,
    required bool useSqlCipher,
  }) : _session = session,
       _opener = opener,
       _dbPathOverride = dbPath,
       _useSqlCipher = useSqlCipher {
    // Al bloquear la bóveda se cierra la conexión.
    _session.addOnClear(() => unawaited(close()));
  }

  final VaultSession _session;
  final DatabaseOpener _opener;
  final String? _dbPathOverride;
  final bool _useSqlCipher;

  Database? _db;
  String? _openPassword;
  Future<Database>? _opening;

  bool get isOpen => _db != null;

  String get _dbPath =>
      _dbPathOverride ?? p.join(AppPaths.dbDir.path, VaultSchema.dbFileName);

  /// Llave SQLCipher derivada de la sesión, en formato de llave CRUDA
  /// `x'<64 hex>'`: SQLCipher la usa tal cual y se salta su PBKDF2 interno
  /// (256 000 iteraciones), que es innecesario porque la subllave HKDF ya es
  /// de 256 bits de alta entropía.
  String _passwordFromSession() {
    final keys = _session.keysOrNull;
    if (keys == null || keys.isDestroyed) {
      throw StateError('La bóveda está bloqueada: no se puede abrir la BD');
    }
    return passwordFor(keys);
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
    final password = _passwordFromSession();
    // Espera una apertura en curso antes de decidir.
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final current = _db;
    if (current != null && current.isOpen && _openPassword == password) {
      return current;
    }
    if (current != null) await close();
    final future = _open(password);
    _opening = future;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  Future<Database> _open(String password) async {
    if (_dbPathOverride == null) await AppPaths.init();
    final file = File(_dbPath);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    final db = await _opener(
      _dbPath,
      password: _useSqlCipher ? password : null,
      options: OpenDatabaseOptions(
        version: VaultSchema.version,
        onCreate: (db, v) => VaultSchema.create(db),
        // Sin datos reales: cualquier cambio de versión recrea el esquema.
        onUpgrade: (db, o, n) => VaultSchema.upgrade(db, o, n),
        onDowngrade: (db, o, n) => VaultSchema.recreate(db),
      ),
    );
    _db = db;
    _openPassword = password;
    return db;
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
    if (db != null && db.isOpen) await db.close();
  }

  /// Checkpoint + cierre limpio y copia del archivo .db (ya cifrado por
  /// SQLCipher) para respaldarlo. Devuelve la copia; el llamador la borra
  /// tras usarla. La conexión se reabre sola en el siguiente acceso.
  ///
  /// F5: `SyncService` lo sube a appDataFolder como `vault_db.snapshot`.
  Future<File> exportEncryptedSnapshot() async {
    final db = await database; // exige sesión desbloqueada
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {
      // Modo journal normal: no hay WAL que vaciar.
    }
    await close();
    final source = File(_dbPath);
    final snapshot = File('$_dbPath.snapshot');
    if (await snapshot.exists()) await snapshot.delete();
    return source.copy(snapshot.path);
  }
}
