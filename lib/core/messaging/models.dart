/// Plain data types for contacts and messages. No Flutter imports.
library;

enum MessageDirection { incoming, outgoing }

/// Lifecycle of a message as the app shows it.
///
/// Outgoing: sending → queued → sent → delivered, or failed at any point
/// before delivered. Incoming messages are always [received].
enum MessageState {
  sending,
  queued,
  sent,
  delivered,
  failed,
  received;

  static MessageState parse(String value) =>
      MessageState.values.firstWhere((s) => s.name == value, orElse: () => failed);
}

class Contact {
  const Contact({required this.id, required this.name, this.lastReadTs = 0});

  /// Mesh node ID, 0 to 0xFFFF.
  final int id;
  final String name;
  final int lastReadTs;
}

class Message {
  const Message({
    required this.rowid,
    required this.peer,
    required this.direction,
    required this.text,
    required this.state,
    required this.ts,
    this.msgId,
  });

  final int rowid;
  final int peer;
  final MessageDirection direction;
  final String text;
  final MessageState state;

  /// Client ID (protocol v2) or the node's message ID (v1).
  final int? msgId;

  /// Milliseconds since epoch, phone clock.
  final int ts;

  bool get isOutgoing => direction == MessageDirection.outgoing;

  Message copyWith({MessageState? state, int? msgId}) => Message(
    rowid: rowid,
    peer: peer,
    direction: direction,
    text: text,
    state: state ?? this.state,
    ts: ts,
    msgId: msgId ?? this.msgId,
  );
}

/// A row of the contact list.
class ContactSummary {
  const ContactSummary({required this.contact, required this.unread, this.lastMessage});

  final Contact contact;
  final int unread;
  final Message? lastMessage;
}
