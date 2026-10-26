import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/core/ble_failure.dart';
import 'package:lear_chat/core/messaging/messaging_service.dart';
import 'package:lear_chat/core/messaging/models.dart';
import 'package:lear_chat/data/settings_repo.dart';
import 'package:lear_chat/state/link_controller.dart';
import 'package:lear_chat/state/providers.dart';
import 'package:lear_chat/transport/fake_transport.dart';

import '../support/memory_store.dart';

void main() {
  late FakeTransport transport;
  late ProviderContainer container;
  late MemoryMessageStore store;

  Future<void> setUpContainer({bool demo = false}) async {
    store = MemoryMessageStore();
    transport = FakeTransport(isDemo: demo);
    container = ProviderContainer(
      overrides: [
        settingsRepoProvider.overrideWithValue(
          SettingsRepo.inMemory({SettingsRepo.demoKey: '$demo'}),
        ),
        storeProvider.overrideWithValue(store),
        messagingProvider.overrideWithValue(MessagingService(store: store)),
        transportFactoryProvider.overrideWithValue((_) => transport),
      ],
    );
    // Keep the controller alive for the whole test.
    container.listen(linkProvider, (_, _) {});
  }

  tearDown(() => container.dispose());

  test('connect moves to connected and reports node status', () async {
    await setUpContainer();
    await container.read(linkProvider.notifier).connect(FakeTransport.demoDevice);
    final s = container.read(linkProvider);
    expect(s.phase, LinkPhase.connected);
    expect(s.protocolVersion, 2);
    expect(s.nodeStatus!.batteryPercent, 87);
  });

  test('a failed connect reports a readable error', () async {
    await setUpContainer();
    transport.failNextConnects = 1;
    await container.read(linkProvider.notifier).connect(FakeTransport.demoDevice);
    final s = container.read(linkProvider);
    expect(s.phase, LinkPhase.disconnected);
    expect(s.error!.kind, BleFailureKind.outOfRange);
    expect(s.error!.message, contains('LEAR-DEMO'));
  });

  test('auto-reconnect succeeds on a later attempt', () async {
    await setUpContainer();
    final link = container.read(linkProvider.notifier);
    await link.connect(FakeTransport.demoDevice);
    transport.failNextConnects = 2;
    transport.simulateLinkLoss();
    await pumpEventQueue();
    expect(container.read(linkProvider).phase, LinkPhase.reconnecting);
    expect(container.read(linkProvider).reconnectAttempt, 1);

    await Future<void>.delayed(
      LinkController.reconnectDelay * 3 + const Duration(milliseconds: 200),
    );
    await pumpEventQueue();
    expect(container.read(linkProvider).phase, LinkPhase.connected);
    expect(transport.connectCalls, 4); // first connect + 3 attempts
  });

  test('auto-reconnect gives up after 3 tries with a clear message', () async {
    await setUpContainer();
    final link = container.read(linkProvider.notifier);
    await link.connect(FakeTransport.demoDevice);
    transport.failNextConnects = 3;
    transport.simulateLinkLoss();
    await Future<void>.delayed(
      LinkController.reconnectDelay * 3 + const Duration(milliseconds: 200),
    );
    await pumpEventQueue();
    final s = container.read(linkProvider);
    expect(s.phase, LinkPhase.disconnected);
    expect(s.error!.kind, BleFailureKind.connectionLost);
  });

  test('link loss fails messages still sending', () async {
    await setUpContainer();
    await container.read(linkProvider.notifier).connect(FakeTransport.demoDevice);
    final messaging = container.read(messagingProvider);
    // Write the row directly in SENDING and register it with the tracker.
    final rowid = await store.insertMessage(
      peer: 1,
      direction: MessageDirection.outgoing,
      text: 'x',
      state: MessageState.sending,
      ts: 1,
    );
    messaging.tracker.beginSend(rowid);
    transport.failNextConnects = 3;
    transport.simulateLinkLoss();
    await pumpEventQueue();
    expect(store.messages[rowid]!.state, MessageState.failed);
  });

  test('disconnect on purpose does not reconnect', () async {
    await setUpContainer();
    final link = container.read(linkProvider.notifier);
    await link.connect(FakeTransport.demoDevice);
    await link.disconnect();
    await Future<void>.delayed(LinkController.reconnectDelay * 2);
    expect(container.read(linkProvider).phase, LinkPhase.disconnected);
    expect(transport.connectCalls, 1);
  });

  test('demo mode connects by itself', () async {
    await setUpContainer(demo: true);
    container.read(linkProvider);
    await pumpEventQueue();
    final s = container.read(linkProvider);
    expect(s.demo, isTrue);
    expect(s.phase, LinkPhase.connected);
  });
}
