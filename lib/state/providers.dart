import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/messaging/message_store.dart';
import '../core/messaging/messaging_service.dart';
import '../core/messaging/models.dart';
import '../core/protocol/codec.dart';
import '../data/settings_repo.dart';
import '../transport/ble_transport.dart';
import '../transport/demo_lan.dart';
import '../transport/fake_transport.dart';
import '../transport/universal_ble_transport.dart';
import 'link_controller.dart';

/// Overridden in main() with the opened database.
final storeProvider = Provider<MessageStore>(
  (ref) => throw UnimplementedError('storeProvider must be overridden'),
);

/// Overridden in main() after [MessagingService.init].
final messagingProvider = Provider<MessagingService>(
  (ref) => throw UnimplementedError('messagingProvider must be overridden'),
);

/// Overridden in main() with settings loaded from the database.
final settingsRepoProvider = Provider<SettingsRepo>(
  (ref) => throw UnimplementedError('settingsRepoProvider must be overridden'),
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(settingsRepoProvider).load();

  Future<void> update(AppSettings Function(AppSettings) change) async {
    state = change(state);
    await ref.read(settingsRepoProvider).save(state);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// Builds the transport for demo or real mode. Tests override this.
final transportFactoryProvider = Provider<BleTransport Function(bool demo)>(
  (ref) =>
      (demo) => demo
          ? FakeTransport(
              nodeStatus: NodeStatus(
                nodeId: ref.read(settingsProvider).demoNodeId,
                batteryPercent: 87,
                queueLength: 0,
                link: LinkQuality.good,
              ),
              lan: UdpDemoLan(),
            )
          : UniversalBleTransport(),
);

final transportProvider = Provider<BleTransport>((ref) {
  final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
  final transport = ref.watch(transportFactoryProvider)(demo);
  ref.onDispose(transport.dispose);
  return transport;
});

final linkProvider = NotifierProvider<LinkController, LinkState>(LinkController.new);

/// Runs [query] now and again after every store change.
Stream<T> _watch<T>(MessageStore store, Future<T> Function() query) {
  late final StreamController<T> controller;
  StreamSubscription<void>? sub;
  Future<void> run() async {
    final result = await query();
    if (!controller.isClosed) controller.add(result);
  }

  controller = StreamController<T>(
    onListen: () {
      sub = store.changes.listen((_) => run());
      run();
    },
    onCancel: () => sub?.cancel(),
  );
  return controller.stream;
}

final contactSummariesProvider = StreamProvider<List<ContactSummary>>((ref) {
  final store = ref.watch(storeProvider);
  return _watch(store, store.contactSummaries);
});

final contactProvider = StreamProvider.autoDispose.family<Contact?, int>((ref, id) {
  final store = ref.watch(storeProvider);
  return _watch(store, () => store.contact(id));
});

final messagesProvider = StreamProvider.autoDispose.family<List<Message>, int>((ref, peer) {
  final store = ref.watch(storeProvider);
  return _watch(store, () => store.messagesFor(peer));
});
