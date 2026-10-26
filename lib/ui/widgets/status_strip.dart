import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/protocol/codec.dart';
import '../../core/protocol/node_id.dart';
import '../../state/providers.dart';

/// Relay node, battery, queue and link quality. Shown only while connected.
class StatusStrip extends ConsumerWidget {
  const StatusStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkProvider);
    final status = link.nodeStatus;
    if (!link.isConnected || status == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelMedium;
    final (linkIcon, linkLabel, linkColor) = switch (status.link) {
      LinkQuality.good => (Icons.signal_cellular_alt, 'Link good', scheme.primary),
      LinkQuality.weak => (Icons.signal_cellular_alt_1_bar, 'Link weak', scheme.tertiary),
      LinkQuality.none => (Icons.signal_cellular_off, 'No mesh link', scheme.error),
    };

    Widget item(IconData icon, String label, {Color? color}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label, style: text),
      ],
    );

    return Semantics(
      container: true,
      label: 'Handheld status',
      child: Container(
        width: double.infinity,
        color: scheme.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            item(Icons.router_outlined, 'Node ${formatNodeId(status.nodeId)}'),
            item(
              _batteryIcon(status.batteryPercent),
              '${status.batteryPercent}%',
              color: status.batteryPercent <= 15 ? scheme.error : null,
            ),
            item(Icons.outbox_outlined, 'Queue ${status.queueLength}'),
            item(linkIcon, linkLabel, color: linkColor),
          ],
        ),
      ),
    );
  }

  static IconData _batteryIcon(int percent) {
    if (percent >= 90) return Icons.battery_full;
    if (percent >= 60) return Icons.battery_5_bar;
    if (percent >= 35) return Icons.battery_3_bar;
    if (percent >= 15) return Icons.battery_2_bar;
    return Icons.battery_alert;
  }
}
