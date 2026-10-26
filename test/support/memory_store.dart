import 'dart:async';

import 'package:lear_chat/core/messaging/message_store.dart';
import 'package:lear_chat/core/messaging/models.dart';
import 'package:lear_chat/core/protocol/node_id.dart';

/// Synchronous-in-spirit [MessageStore] for tests that run on fake time.
class MemoryMessageStore implements MessageStore {
  final Map<int, Contact> contacts = {};
  final Map<int, Message> messages = {};
  final _changes = StreamController<void>.broadcast(sync: true);
  int _nextRowid = 1;

  void _notify() => _changes.add(null);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<ContactSummary>> contactSummaries() async {
    final out = <ContactSummary>[];
    for (final c in contacts.values) {
      final msgs = messages.values.where((m) => m.peer == c.id).toList()
        ..sort((a, b) => a.ts != b.ts ? a.ts.compareTo(b.ts) : a.rowid.compareTo(b.rowid));
      final unread = msgs.where((m) => !m.isOutgoing && m.ts > c.lastReadTs).length;
      out.add(ContactSummary(contact: c, unread: unread, lastMessage: msgs.lastOrNull));
    }
    out.sort((a, b) => (b.lastMessage?.ts ?? 0).compareTo(a.lastMessage?.ts ?? 0));
    return out;
  }

  @override
  Future<Contact?> contact(int id) async => contacts[id];

  @override
  Future<void> addContact(int id, String name) async {
    if (contacts.containsKey(id)) throw DuplicateContactException(id);
    contacts[id] = Contact(id: id, name: name);
    _notify();
  }

  @override
  Future<void> renameContact(int id, String name) async {
    final c = contacts[id];
    if (c == null) return;
    contacts[id] = Contact(id: id, name: name, lastReadTs: c.lastReadTs);
    _notify();
  }

  @override
  Future<void> deleteContact(int id) async {
    contacts.remove(id);
    messages.removeWhere((_, m) => m.peer == id);
    _notify();
  }

  @override
  Future<bool> ensureContact(int id) async {
    if (contacts.containsKey(id)) return false;
    contacts[id] = Contact(id: id, name: defaultContactName(id));
    _notify();
    return true;
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
    final rowid = _nextRowid++;
    messages[rowid] = Message(
      rowid: rowid,
      peer: peer,
      direction: direction,
      text: text,
      state: state,
      ts: ts,
      msgId: msgId,
    );
    _notify();
    return rowid;
  }

  @override
  Future<void> updateMessage(int rowid, MessageState state, {int? msgId}) async {
    final m = messages[rowid];
    if (m == null) return;
    messages[rowid] = m.copyWith(state: state, msgId: msgId);
    _notify();
  }

  @override
  Future<Message?> message(int rowid) async => messages[rowid];

  @override
  Future<List<Message>> messagesFor(int peer) async =>
      messages.values.where((m) => m.peer == peer).toList()
        ..sort((a, b) => a.ts != b.ts ? a.ts.compareTo(b.ts) : a.rowid.compareTo(b.rowid));

  @override
  Future<List<Message>> openOutgoing() async => messages.values
      .where(
        (m) =>
            m.isOutgoing &&
            (m.state == MessageState.queued || m.state == MessageState.sent) &&
            m.msgId != null,
      )
      .toList();

  @override
  Future<void> failStaleOutgoing() async {
    for (final m in messages.values.toList()) {
      if (m.isOutgoing &&
          (m.state == MessageState.sending ||
              (m.state == MessageState.queued && m.msgId == null))) {
        messages[m.rowid] = m.copyWith(state: MessageState.failed);
      }
    }
    _notify();
  }

  @override
  Future<void> markRead(int peer, int ts) async {
    final c = contacts[peer];
    if (c == null || c.lastReadTs >= ts) return;
    contacts[peer] = Contact(id: c.id, name: c.name, lastReadTs: ts);
    _notify();
  }

  @override
  Future<void> clearAllChats() async {
    messages.clear();
    for (final c in contacts.values.toList()) {
      contacts[c.id] = Contact(id: c.id, name: c.name);
    }
    _notify();
  }
}
