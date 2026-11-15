import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../core/services/app_paths.dart';
import '../../core/session/vault_session.dart';

/// Esquema de la BD. SIN MIGRACIONES (aún no hay datos reales): al cambiar
/// [version] se borran todas las tablas y se recrean (ver [recreate]).
///
/// Historial: v2 = esquema anterior (rutas absolutas); v3 = F3 (rutas
/// relativas, syncStatus, driveFileId, thumbPath, lastAccessedAt,
/// contentHash, sourceAssetId, durationMs, folders.isOffline, índices).
class VaultSchema {
  VaultSchema._();

  static const int version = 3;
  static const String dbFileName = 'vault_secure.db';

  static const List<String> indexNames = [
    'idx_items_folder',
    'idx_items_sync',
    'idx_items_lastAccessed',
    'idx_items_drive',
    'idx_folders_parent',
  ];

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        parentId TEXT,
        createdAt TEXT NOT NULL,
        isOffline INTEGER NOT NULL DEFAULT 0
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
        durationMs INTEGER
      )
    ''');
    await db.execute('CREATE INDEX idx_items_folder ON vault_items(folderId)');
    await db.execute('CREATE INDEX idx_items_sync ON vault_items(syncStatus)');
    await db.execute(
      'CREATE INDEX idx_items_lastAccessed ON vault_items(lastAccessedAt)',
    );
    await db.execute(
      'CREATE INDEX idx_items_drive ON vault_items(driveFileId)',
    );
    await db.execute('CREATE INDEX idx_folders_parent ON folders(parentId)');
  }

  /// Borra todo y recrea (sustituye a una migración).
  static Future<void> recreate(Database db) async {
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

Future<Database> _openWithSqlCipher(
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
    opener: _openWithSqlCipher,
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
    final bytes = keys.sqlcipher.bytes;
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return "x'${sb.toString()}'";
  }

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
        onUpgrade: (db, o, n) => VaultSchema.recreate(db),
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
  /// TODO(F5): subir este archivo al appDataFolder de Drive periódicamente
  /// (no implementado en F3).
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
