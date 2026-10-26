import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../core/messaging/message_store.dart';
import '../core/messaging/models.dart';
import '../core/protocol/node_id.dart';
import 'app_database.dart';

/// SQLite-backed [MessageStore]. All data stays on the phone.
class SqliteMessageStore implements MessageStore {
  SqliteMessageStore(this._db);

  final Database _db;
  final _changes = StreamController<void>.broadcast();

  /// Opens the app database and wraps it. See [openAppDatabase].
  static Future<SqliteMessageStore> open({DatabaseFactory? factory, String? path}) async =>
      SqliteMessageStore(await openAppDatabase(factory: factory, path: path));

  void _notify() => _changes.add(null);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<ContactSummary>> contactSummaries() async {
    final rows = await _db.rawQuery('''
      SELECT c.id, c.name, c.last_read_ts,
             m.rowid AS m_rowid, m.peer AS m_peer, m.dir AS m_dir, m.text AS m_text,
             m.state AS m_state, m.msg_id AS m_msg_id, m.ts AS m_ts,
             (SELECT COUNT(*) FROM messages u
               WHERE u.peer = c.id AND u.dir = 'in' AND u.ts > c.last_read_ts) AS unread
      FROM contacts c
      LEFT JOIN messages m ON m.rowid = (
        SELECT rowid FROM messages WHERE peer = c.id ORDER BY ts DESC, rowid DESC LIMIT 1)
      ORDER BY COALESCE(m.ts, 0) DESC, c.name COLLATE NOCASE
    ''');
    return [
      for (final r in rows)
        ContactSummary(
          contact: _contact(r),
          unread: r['unread'] as int,
          lastMessage: r['m_rowid'] == null
              ? null
              : _message({
                  'rowid': r['m_rowid'],
                  'peer': r['m_peer'],
                  'dir': r['m_dir'],
                  'text': r['m_text'],
                  'state': r['m_state'],
                  'msg_id': r['m_msg_id'],
                  'ts': r['m_ts'],
                }),
        ),
    ];
  }

  @override
  Future<Contact?> contact(int id) async {
    final rows = await _db.query('contacts', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _contact(rows.first);
  }

  @override
  Future<void> addContact(int id, String name) async {
    final inserted = await _db.insert('contacts', {
      'id': id,
      'name': name.trim(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (inserted == 0) throw DuplicateContactException(id);
    _notify();
  }

  @override
  Future<void> renameContact(int id, String name) async {
    await _db.update('contacts', {'name': name.trim()}, where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  @override
  Future<void> deleteContact(int id) async {
    await _db.transaction((txn) async {
      await txn.delete('messages', where: 'peer = ?', whereArgs: [id]);
      await txn.delete('contacts', where: 'id = ?', whereArgs: [id]);
    });
    _notify();
  }

  @override
  Future<bool> ensureContact(int id) async {
    final inserted = await _db.insert('contacts', {
      'id': id,
      'name': defaultContactName(id),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (inserted != 0) _notify();
    return inserted != 0;
  }

  @override
  Future<int> insertMessage({
    required int peer,
    required MessageDirection direction,
    required String text,
    required MessageState state,
    required int ts,
    int? msgId,
  }) async {
    final rowid = await _db.insert('messages', {
      'peer': peer,
      'dir': direction == MessageDirection.incoming ? 'in' : 'out',
      'text': text,
      'state': state.name,
      'msg_id': msgId,
      'ts': ts,
    });
    _notify();
    return rowid;
  }

  @override
  Future<void> updateMessage(int rowid, MessageState state, {int? msgId}) async {
    await _db.update(
      'messages',
      {'state': state.name, 'msg_id': ?msgId},
      where: 'rowid = ?',
      whereArgs: [rowid],
    );
    _notify();
  }

  @override
  Future<Message?> message(int rowid) async {
    final rows = await _db.query('messages', where: 'rowid = ?', whereArgs: [rowid]);
    return rows.isEmpty ? null : _message(rows.first);
  }

  @override
  Future<List<Message>> messagesFor(int peer) async {
    final rows = await _db.query(
      'messages',
      where: 'peer = ?',
      whereArgs: [peer],
      orderBy: 'ts ASC, rowid ASC',
    );
    return rows.map(_message).toList();
  }

  @override
  Future<List<Message>> openOutgoing() async {
    final rows = await _db.query(
      'messages',
      where: "dir = 'out' AND state IN ('queued', 'sent') AND msg_id IS NOT NULL",
    );
    return rows.map(_message).toList();
  }

  @override
  Future<void> failStaleOutgoing() async {
    final n = await _db.update(
      'messages',
      {'state': MessageState.failed.name},
      where: "dir = 'out' AND (state = 'sending' OR (state = 'queued' AND msg_id IS NULL))",
    );
    if (n > 0) _notify();
  }

  @override
  Future<void> markRead(int peer, int ts) async {
    final n = await _db.update(
      'contacts',
      {'last_read_ts': ts},
      where: 'id = ? AND last_read_ts < ?',
      whereArgs: [peer, ts],
    );
    if (n > 0) _notify();
  }

  @override
  Future<void> clearAllChats() async {
    await _db.transaction((txn) async {
      await txn.delete('messages');
      await txn.update('contacts', {'last_read_ts': 0});
    });
    _notify();
  }

  Future<void> close() async {
    await _changes.close();
    await _db.close();
  }

  static Contact _contact(Map<String, Object?> r) =>
      Contact(id: r['id'] as int, name: r['name'] as String, lastReadTs: r['last_read_ts'] as int);

  static Message _message(Map<String, Object?> r) => Message(
    rowid: r['rowid'] as int,
    peer: r['peer'] as int,
    direction: r['dir'] == 'in' ? MessageDirection.incoming : MessageDirection.outgoing,
    text: r['text'] as String,
    state: MessageState.parse(r['state'] as String),
    msgId: r['msg_id'] as int?,
    ts: r['ts'] as int,
  );
}
