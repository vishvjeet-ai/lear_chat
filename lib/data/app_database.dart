import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Schema migrations, oldest first. Migration `i` takes the database from
/// version `i` to `i + 1`. Never edit a shipped migration; append a new one.
const _migrations = <List<String>>[
  // v0 → v1: contacts and messages.
  [
    '''
    CREATE TABLE contacts(
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      last_read_ts INTEGER NOT NULL DEFAULT 0
    )''',
    '''
    CREATE TABLE messages(
      rowid INTEGER PRIMARY KEY AUTOINCREMENT,
      peer INTEGER NOT NULL,
      dir TEXT NOT NULL,
      text TEXT NOT NULL,
      state TEXT NOT NULL,
      msg_id INTEGER NULL,
      ts INTEGER NOT NULL
    )''',
    'CREATE INDEX messages_peer_ts ON messages(peer, ts)',
    'CREATE INDEX messages_msg_id ON messages(msg_id)',
  ],
  // v1 → v2: settings moved from SharedPreferences into the database.
  ['CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)'],
];

/// Current schema version.
final int dbVersion = _migrations.length;

Future<void> _migrate(Database db, int from, int to) async {
  for (var v = from; v < to; v++) {
    for (final sql in _migrations[v]) {
      await db.execute(sql);
    }
  }
}

/// Opens the single on-device database, creating or upgrading the schema.
/// Pass a [factory] (e.g. sqflite ffi) and [path] (e.g. `inMemoryDatabasePath`)
/// in tests.
Future<Database> openAppDatabase({DatabaseFactory? factory, String? path}) async {
  final f = factory ?? databaseFactory;
  final dbPath = path ?? p.join(await f.getDatabasesPath(), 'lear_chat.db');
  return f.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      version: dbVersion,
      onCreate: (db, version) => _migrate(db, 0, version),
      onUpgrade: _migrate,
    ),
  );
}
