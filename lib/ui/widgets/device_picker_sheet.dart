import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble_failure.dart';
import '../../state/providers.dart';
import '../../transport/ble_transport.dart';
import '../../transport/universal_ble_transport.dart';

/// Scans for handhelds and returns the one the person picks.
class DevicePickerSheet extends ConsumerStatefulWidget {
  const DevicePickerSheet({super.key});

  static Future<DiscoveredDevice?> show(BuildContext context) =>
      showModalBottomSheet<DiscoveredDevice>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const DevicePickerSheet(),
      );

  @override
  ConsumerState<DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends ConsumerState<DevicePickerSheet> {
  final Map<String, DiscoveredDevice> _devices = {};
  StreamSubscription<DiscoveredDevice>? _sub;
  BleFailure? _failure;
  bool _scanning = false;

  /// Lists every advertising device, to diagnose a handheld that isn't found.
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _failure = null;
      _devices.clear();
      _scanning = true;
    });
    final link = ref.read(linkProvider.notifier);
    final failure = await link.prepare();
    if (!mounted) return;
    if (failure != null) {
      setState(() {
        _failure = failure;
        _scanning = false;
      });
      return;
    }
    await _sub?.cancel();
    _sub = link.transport
        .scan(ref.read(settingsProvider).ble, showAll: _showAll)
        .listen(
          (d) {
            if (mounted) setState(() => _devices[d.id] = d);
          },
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              _failure = e is BleFailure ? e : BleFailure(BleFailureKind.unknown, cause: e);
              _scanning = false;
            });
          },
          onDone: () {
            if (mounted) setState(() => _scanning = false);
          },
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devices = _devices.values.toList()
      ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Connect to a handheld', style: theme.textTheme.titleLarge)),
                if (_scanning)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(onPressed: _start, child: const Text('Scan again')),
              ],
            ),
            const SizedBox(height: 8),
            if (_failure != null)
              _FailurePanel(failure: _failure!, onRetry: _start)
            else if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _scanning
                      ? (_showAll
                            ? 'Looking for Bluetooth devices nearby…'
                            : 'Looking for LEAR handhelds nearby…')
                      : _showAll
                      ? 'No Bluetooth devices found. Check that the handheld is on and advertising.'
                      : 'No handhelds found. Make sure yours is on and within a few metres. '
                            'If it still doesn\'t appear, turn on "Show all Bluetooth devices" '
                            'to check what it advertises.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final d in devices)
                      ListTile(
                        leading: Icon(
                          d.isLear ? Icons.settings_input_antenna : Icons.bluetooth,
                          color: d.isLear ? null : theme.colorScheme.outline,
                        ),
                        title: Text(d.name),
                        subtitle: Text(
                          d.isLear
                              ? d.id
                              : '${d.id}\nNot a LEAR handheld: no LEAR service UUID '
                                    'and the name doesn\'t start with '
                                    '"${ref.read(settingsProvider).ble.namePrefix}".',
                        ),
                        isThreeLine: !d.isLear,
                        trailing: d.rssi == null ? null : Text('${d.rssi} dBm'),
                        onTap: () => Navigator.of(context).pop(d),
                      ),
                  ],
                ),
              ),
            SwitchListTile(
              key: const Key('show-all-devices'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Show all Bluetooth devices'),
              subtitle: const Text('Use this if your handheld doesn\'t appear'),
              value: _showAll,
              onChanged: (v) {
                setState(() => _showAll = v);
                _start();
              },
            ),
            Text(
              'When asked, enter the passkey shown on the handheld\'s screen.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({required this.failure, required this.onRetry});

  final BleFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(failure.message, style: TextStyle(color: scheme.onErrorContainer)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                if (failure.opensSettings)
                  FilledButton(
                    onPressed: UniversalBleTransport.openSystemSettings,
                    child: const Text('Open settings'),
                  ),
                if (failure.canEnableBluetooth)
                  FilledButton(
                    onPressed: () async {
                      await UniversalBleTransport.requestEnableBluetooth();
                      onRetry();
                    },
                    child: const Text('Turn on Bluetooth'),
                  ),
                OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
