import 'package:flutter/material.dart';

import '../../core/messaging/models.dart';
import '../format.dart';
import '../theme.dart';

/// One message with its time and, for outgoing messages, delivery ticks.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, this.onRetry});

  final Message message;

  /// Called when a failed outgoing message is tapped.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final out = message.isOutgoing;
    final failed = message.state == MessageState.failed;
    final bg = failed
        ? scheme.errorContainer
        : out
        ? scheme.outgoingBubble
        : scheme.incomingBubble;
    final fg = failed
        ? scheme.onErrorContainer
        : out
        ? scheme.onOutgoingBubble
        : scheme.onIncomingBubble;

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(out ? 16 : 4),
          bottomRight: Radius.circular(out ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(message.text, style: textTheme.bodyLarge?.copyWith(color: fg)),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed) ...[
                Text(
                  'Not sent. Tap to retry.',
                  style: textTheme.labelSmall?.copyWith(color: scheme.error),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                formatMessageTime(message.ts),
                style: textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7)),
              ),
              if (out) ...[
                const SizedBox(width: 4),
                DeliveryIcon(state: message.state, color: fg.withValues(alpha: 0.8)),
              ],
            ],
          ),
        ],
      ),
    );

    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: failed && onRetry != null
          ? InkWell(borderRadius: BorderRadius.circular(16), onTap: onRetry, child: bubble)
          : bubble,
    );
  }
}

/// Clock while sending, one tick when queued or sent, two when delivered,
/// red mark when failed.
class DeliveryIcon extends StatelessWidget {
  const DeliveryIcon({super.key, required this.state, this.color});

  final MessageState state;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, iconColor) = switch (state) {
      MessageState.sending => (Icons.schedule, 'Sending', color),
      MessageState.queued => (Icons.check, 'Queued on handheld', color?.withValues(alpha: 0.6)),
      MessageState.sent => (Icons.check, 'Sent into the mesh', color),
      MessageState.delivered => (Icons.done_all, 'Delivered', scheme.primary),
      MessageState.failed => (Icons.error, 'Failed', scheme.error),
      MessageState.received => (Icons.check, 'Received', color),
    };
    return Semantics(
      label: label,
      child: Icon(icon, size: 16, color: iconColor),
    );
  }
}
