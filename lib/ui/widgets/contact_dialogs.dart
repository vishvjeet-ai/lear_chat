import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/messaging/message_store.dart';
import '../../core/protocol/node_id.dart';
import '../../state/providers.dart';

/// Asks for a name and node ID and saves the contact. Returns the new ID.
Future<int?> showAddContactDialog(BuildContext context, WidgetRef ref) =>
    showDialog<int>(context: context, builder: (_) => const _AddContactDialog());

class _AddContactDialog extends ConsumerStatefulWidget {
  const _AddContactDialog();

  @override
  ConsumerState<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends ConsumerState<_AddContactDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _id = TextEditingController();
  String? _duplicateError;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _duplicateError = null);
    if (!_form.currentState!.validate()) return;
    final id = parseNodeId(_id.text)!;
    setState(() => _saving = true);
    try {
      await ref.read(storeProvider).addContact(id, _name.text.trim());
      if (mounted) Navigator.pop(context, id);
    } on DuplicateContactException {
      final existing = await ref.read(storeProvider).contact(id);
      setState(() {
        _saving = false;
        _duplicateError =
            'Node ${formatNodeId(id)} is already saved as "${existing?.name ?? 'a contact'}".';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add contact'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('contact-name'),
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name.' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('contact-id'),
              controller: _id,
              decoration: InputDecoration(
                labelText: 'Node ID',
                hintText: 'e.g. 00A3',
                helperText: '4 hex digits, 0000 to FFFF',
                errorText: _duplicateError,
                errorMaxLines: 2,
              ),
              textCapitalization: TextCapitalization.characters,
              validator: (v) =>
                  parseNodeId(v ?? '') == null ? 'Enter a hex ID from 0000 to FFFF.' : null,
              onFieldSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Add')),
      ],
    );
  }
}

/// Asks for a new name for contact [id].
Future<void> showRenameContactDialog(
  BuildContext context,
  WidgetRef ref,
  int id,
  String currentName,
) async {
  final controller = TextEditingController(text: currentName);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename contact'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null && name.trim().isNotEmpty) {
    await ref.read(storeProvider).renameContact(id, name);
  }
}
