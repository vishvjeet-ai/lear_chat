import 'models.dart';

/// Thrown when adding a contact whose node ID is already saved.
class DuplicateContactException implements Exception {
  const DuplicateContactException(this.id);

  final int id;

  @override
  String toString() => 'DuplicateContactException($id)';
}

/// Persistence the messaging logic needs. Implemented by SQLite in the app and
/// in memory in tests.
abstract class MessageStore {
  /// Emits after any write, so screens can reload.
  Stream<void> get changes;

  Future<List<ContactSummary>> contactSummaries();
  Future<Contact?> contact(int id);

  /// Throws [DuplicateContactException] if [id] exists.
  Future<void> addContact(int id, String name);
  Future<void> renameContact(int id, String name);
  Future<void> deleteContact(int id);

  /// Creates `Node XXXX` for an unknown sender. Returns true if created.
  Future<bool> ensureContact(int id);

  Future<int> insertMessage({
    required int peer,
    required MessageDirection direction,
    required String text,
    required MessageState state,
    required int ts,
    int? msgId,
  });
  Future<void> updateMessage(int rowid, MessageState state, {int? msgId});
  Future<Message?> message(int rowid);
  Future<List<Message>> messagesFor(int peer);

  /// Outgoing messages that are queued or sent and have an ID.
  Future<List<Message>> openOutgoing();

  /// At startup: messages left SENDING, or v1 QUEUED without an ID, can't be
  /// tracked any more, so they become FAILED.
  Future<void> failStaleOutgoing();

  Future<void> markRead(int peer, int ts);
  Future<void> clearAllChats();
}
