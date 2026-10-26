import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../core/messaging/models.dart';
import '../core/protocol/node_id.dart';
import '../state/link_controller.dart';
import '../state/providers.dart';
import 'widgets/composer.dart';
import 'widgets/message_bubble.dart';
import 'widgets/status_strip.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.peer});

  final int peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = ref.watch(contactProvider(peer)).value;
    final messages = ref.watch(messagesProvider(peer));
    final link = ref.watch(linkProvider);

    // Opening the chat, or a message arriving while it's open, marks it read.
    ref.listen<AsyncValue<List<Message>>>(messagesProvider(peer), (_, next) {
      _markRead(ref, next.value);
    });
    _markRead(ref, messages.value);

    final disabledHint = switch (link.phase) {
      LinkPhase.connected => null,
      LinkPhase.connecting => 'Connecting to your handheld…',
      LinkPhase.reconnecting => 'Reconnecting to your handheld…',
      LinkPhase.disconnected => 'Connect to your handheld to send messages.',
    };

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(contact?.name ?? defaultContactName(peer)),
            Text('Node ${formatNodeId(peer)}', style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
      body: Column(
        children: [
          const StatusStrip(),
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text("Couldn't load messages.\n\n$e")),
              data: (list) => list.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'No messages yet. Messages travel through the LoRa mesh, so delivery can take a minute.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final m = list[list.length - 1 - i];
                        return MessageBubble(
                          key: ValueKey(m.rowid),
                          message: m,
                          onRetry: () => _retry(ref, m),
                        );
                      },
                    ),
            ),
          ),
          Composer(
            enabled: link.isConnected,
            disabledHint: disabledHint,
            onSend: (text) => ref.read(messagingProvider).send(peer, text),
          ),
        ],
      ),
    );
  }

  void _markRead(WidgetRef ref, List<Message>? list) {
    if (list == null) return;
    final lastIncoming = list.lastWhere(
      (m) => !m.isOutgoing,
      orElse: () => const Message(
        rowid: 0,
        peer: 0,
        direction: MessageDirection.incoming,
        text: '',
        state: MessageState.received,
        ts: 0,
      ),
    );
    if (lastIncoming.ts > 0) {
      ref.read(storeProvider).markRead(peer, lastIncoming.ts);
    }
  }

  Future<void> _retry(WidgetRef ref, Message m) async {
    if (!ref.read(linkProvider).isConnected) {
      showInfo('Connect to your handheld first, then tap the message again.');
      return;
    }
    await ref.read(messagingProvider).retry(m.rowid);
  }
}
