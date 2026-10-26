import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/link_controller.dart';
import '../../state/providers.dart';
import 'device_picker_sheet.dart';

/// Shows the link state and starts connecting or disconnecting.
class ConnectionChip extends ConsumerWidget {
  const ConnectionChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkProvider);
    final scheme = Theme.of(context).colorScheme;
    final name = link.device?.name ?? 'handheld';

    const spinner = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );

    if (link.demo) {
      return ActionChip(
        avatar: Icon(Icons.science_outlined, color: scheme.tertiary),
        label: Text(link.isConnected ? 'Demo mode' : 'Demo mode (starting…)'),
        onPressed: () => context.push('/settings'),
        tooltip: 'Demo mode simulates a handheld. Turn it off in Settings.',
      );
    }

    return switch (link.phase) {
      LinkPhase.disconnected => ActionChip(
        avatar: const Icon(Icons.bluetooth),
        label: const Text('Connect'),
        onPressed: () => connectFlow(context, ref),
      ),
      LinkPhase.connecting => Chip(avatar: spinner, label: Text('Connecting to $name…')),
      LinkPhase.reconnecting => ActionChip(
        avatar: spinner,
        label: Text(
          'Reconnecting (${link.reconnectAttempt} of ${LinkController.maxReconnectAttempts})…',
        ),
        onPressed: () => ref.read(linkProvider.notifier).disconnect(),
        tooltip: 'Tap to stop reconnecting',
      ),
      LinkPhase.connected => ActionChip(
        avatar: Icon(Icons.bluetooth_connected, color: scheme.primary),
        label: Text('Connected to $name'),
        onPressed: () => _confirmDisconnect(context, ref, name),
      ),
    };
  }

  Future<void> _confirmDisconnect(BuildContext context, WidgetRef ref, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect from $name?'),
        content: const Text("You won't receive messages until you connect again."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(linkProvider.notifier).disconnect();
  }
}

/// Explains the permission once, then lets the person pick a handheld.
Future<void> connectFlow(BuildContext context, WidgetRef ref) async {
  final settings = ref.read(settingsProvider);
  if (!settings.permissionRationaleShown) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.bluetooth_searching),
        title: const Text('Allow Bluetooth access'),
        content: const Text(
          'LEAR Chat uses Bluetooth only to find and talk to your handheld. '
          "It doesn't use your location or the internet.\n\n"
          'Next, Android will ask for the Nearby devices permission.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(permissionRationaleShown: true));
  }
  if (!context.mounted) return;
  final device = await DevicePickerSheet.show(context);
  if (device != null) await ref.read(linkProvider.notifier).connect(device);
}
