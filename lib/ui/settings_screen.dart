import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../core/protocol/constants.dart';
import '../core/protocol/node_id.dart';
import '../data/settings_repo.dart';
import '../state/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;

  @override
  void initState() {
    super.initState();
    _fields = {};
    _load(ref.read(settingsProvider).ble);
  }

  void _load(BleConfig c) {
    final values = {
      'service': c.serviceUuid,
      'tx': c.txUuid,
      'rx': c.rxUuid,
      'status': c.statusUuid,
      'version': c.versionUuid,
      'prefix': c.namePrefix,
    };
    values.forEach((k, v) => (_fields[k] ??= TextEditingController()).text = v);
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveBle() async {
    if (!_form.currentState!.validate()) return;
    String v(String k) => _fields[k]!.text.trim().toLowerCase();
    final config = BleConfig(
      serviceUuid: v('service'),
      txUuid: v('tx'),
      rxUuid: v('rx'),
      statusUuid: v('status'),
      versionUuid: v('version'),
      namePrefix: _fields['prefix']!.text.trim(),
    );
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(ble: config));
    showInfo('Saved. The new values apply the next time you connect.');
  }

  Future<void> _resetBle() async {
    _load(const BleConfig());
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(ble: const BleConfig()));
    showInfo('Bluetooth settings reset to defaults.');
  }

  Future<void> _clearChats() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all chats?'),
        content: const Text(
          'This deletes every message on this phone. Your contacts are kept. This can\'t be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all chats'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(storeProvider).clearAllChats();
    showInfo('All chats cleared.');
  }

  String? _uuidValidator(String? v) =>
      isValidUuid(v ?? '') ? null : 'Enter a full UUID, like 4c454152-4d45-5348-0001-000000000000.';

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final link = ref.watch(linkProvider);
    final theme = Theme.of(context);

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
      ),
    );

    Widget uuidField(String key, String label) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextFormField(
        controller: _fields[key],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        validator: _uuidValidator,
        autocorrect: false,
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          section('Demo mode'),
          SwitchListTile(
            key: const Key('demo-switch'),
            title: const Text('Demo mode'),
            subtitle: Text(
              'Simulates a handheld so you can try the app without hardware. Phones on the same Wi-Fi '
              'with demo mode on can message each other by node ID. '
              'This phone is node ${formatNodeId(settings.demoNodeId)}.',
            ),
            value: settings.demoMode,
            onChanged: (on) =>
                ref.read(settingsProvider.notifier).update((s) => s.copyWith(demoMode: on)),
          ),
          section('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemePreference>(
              segments: const [
                ButtonSegment(value: ThemePreference.system, label: Text('System')),
                ButtonSegment(value: ThemePreference.light, label: Text('Light')),
                ButtonSegment(value: ThemePreference.dark, label: Text('Dark')),
              ],
              selected: {settings.theme},
              onSelectionChanged: (s) =>
                  ref.read(settingsProvider.notifier).update((x) => x.copyWith(theme: s.first)),
            ),
          ),
          section('Handheld Bluetooth'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Only change these if your handheld firmware uses different values.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Form(
            key: _form,
            child: Column(
              children: [
                uuidField('service', 'Service UUID'),
                uuidField('tx', 'TX characteristic (phone to node)'),
                uuidField('rx', 'RX characteristic (node to phone)'),
                uuidField('status', 'STATUS characteristic'),
                uuidField('version', 'VERSION characteristic'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: TextFormField(
                    controller: _fields['prefix'],
                    decoration: const InputDecoration(
                      labelText: 'Device name prefix',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Enter a prefix, like LEAR.' : null,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: _saveBle, child: const Text('Save')),
                OutlinedButton(onPressed: _resetBle, child: const Text('Reset to defaults')),
              ],
            ),
          ),
          section('Data'),
          ListTile(
            leading: Icon(Icons.delete_sweep_outlined, color: theme.colorScheme.error),
            title: const Text('Clear all chats'),
            subtitle: const Text('Deletes all messages stored on this phone'),
            onTap: _clearChats,
          ),
          section('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Works without internet'),
            subtitle: Text(
              'Messages go phone → Bluetooth → handheld → LoRa mesh. Everything is stored only on this phone.'
              '${link.protocolVersion == null ? '' : '\nConnected handheld speaks protocol v${link.protocolVersion}.'}',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
