import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/messaging/models.dart';
import '../core/protocol/node_id.dart';
import '../state/providers.dart';
import 'format.dart';
import 'widgets/connection_chip.dart';
import 'widgets/contact_dialogs.dart';
import 'widgets/status_strip.dart';

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaries = ref.watch(contactSummariesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LEAR Chat'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(48),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(alignment: Alignment.centerLeft, child: ConnectionChip()),
          ),
        ),
      ),
      body: Column(
        children: [
          const StatusStrip(),
          Expanded(
            child: summaries.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text("Couldn't load your contacts. Restart the app to try again.\n\n$e"),
                ),
              ),
              data: (list) => list.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                      itemBuilder: (context, i) => _ContactTile(summary: list[i]),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final id = await showAddContactDialog(context, ref);
          if (id != null && context.mounted) context.push('/chat/$id');
        },
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add contact'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('No contacts yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              "Add someone with their node ID, or wait for a message. People who write to you appear here automatically.",
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactTile extends ConsumerWidget {
  const _ContactTile({required this.summary});

  final ContactSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = summary.contact;
    final last = summary.lastMessage;
    final preview = last == null
        ? 'Node ${formatNodeId(c.id)}'
        : '${last.isOutgoing ? 'You: ' : ''}${last.text}';
    final hasUnread = summary.unread > 0;

    return ListTile(
      leading: CircleAvatar(child: Text(_initials(c.name))),
      title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: hasUnread ? const TextStyle(fontWeight: FontWeight.w600) : null,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (last != null) Text(formatListTime(last.ts), style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          if (hasUnread)
            Badge(
              label: Text(summary.unread > 99 ? '99+' : '${summary.unread}'),
              backgroundColor: theme.colorScheme.primary,
              textColor: theme.colorScheme.onPrimary,
            ),
        ],
      ),
      onTap: () => context.push('/chat/${c.id}'),
      onLongPress: () => _showActions(context, ref, c),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref, Contact c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: const Text('Delete contact and chat'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'rename') {
      await showRenameContactDialog(context, ref, c.id, c.name);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete ${c.name}?'),
          content: const Text(
            'This removes the contact and every message with them from this phone.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok == true) await ref.read(storeProvider).deleteContact(c.id);
    }
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
    return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
  }
}
