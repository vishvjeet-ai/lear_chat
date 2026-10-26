import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ble_failure.dart';
import '../core/protocol/codec.dart';
import '../core/protocol/node_id.dart';
import '../transport/ble_transport.dart';
import 'providers.dart';

enum LinkPhase { disconnected, connecting, connected, reconnecting }

class LinkState {
  const LinkState({
    this.phase = LinkPhase.disconnected,
    this.device,
    this.protocolVersion,
    this.nodeStatus,
    this.reconnectAttempt = 0,
    this.error,
    this.demo = false,
  });

  final LinkPhase phase;
  final DiscoveredDevice? device;
  final int? protocolVersion;
  final NodeStatus? nodeStatus;
  final int reconnectAttempt;

  /// Last failure, for the UI to show once. Cleared by [LinkController.clearError].
  final BleFailure? error;
  final bool demo;

  bool get isConnected => phase == LinkPhase.connected;

  LinkState copyWith({
    LinkPhase? phase,
    DiscoveredDevice? device,
    int? protocolVersion,
    NodeStatus? nodeStatus,
    int? reconnectAttempt,
    BleFailure? error,
    bool clearError = false,
  }) => LinkState(
    phase: phase ?? this.phase,
    device: device ?? this.device,
    protocolVersion: protocolVersion ?? this.protocolVersion,
    nodeStatus: nodeStatus ?? this.nodeStatus,
    reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
    error: clearError ? null : (error ?? this.error),
    demo: demo,
  );
}

/// Owns the link to the handheld: connect, disconnect and auto-reconnect.
class LinkController extends Notifier<LinkState> {
  static const maxReconnectAttempts = 3;
  static const reconnectDelay = Duration(milliseconds: 1500);

  late BleTransport _transport;

  /// Bumped whenever an operation should abandon its remaining steps.
  int _generation = 0;

  @override
  LinkState build() {
    _transport = ref.watch(transportProvider);
    final messaging = ref.read(messagingProvider);
    final gen = ++_generation;

    final subs = <StreamSubscription<Object?>>[
      _transport.status.listen((s) {
        if (ref.mounted && state.isConnected) state = state.copyWith(nodeStatus: s);
      }),
      _transport.disconnected.listen((_) => _onLinkLost()),
    ];
    ref.onDispose(() {
      _generation++;
      for (final s in subs) {
        s.cancel();
      }
      unawaited(messaging.detach());
    });

    if (_transport.isDemo) {
      scheduleMicrotask(() {
        if (ref.mounted && gen == _generation) connect(_demoDevice());
      });
    }
    return LinkState(demo: _transport.isDemo);
  }

  /// Named after this phone's demo node so several demo phones are told apart.
  DiscoveredDevice _demoDevice() => DiscoveredDevice(
    id: 'demo-handheld',
    name: 'LEAR-DEMO-${formatNodeId(ref.read(settingsProvider).demoNodeId)}',
  );

  BleTransport get transport => _transport;

  /// Checks permissions and Bluetooth before scanning. Returns the failure,
  /// or null when ready.
  Future<BleFailure?> prepare() async {
    try {
      await _transport.ensureReady();
      return null;
    } on BleFailure catch (f) {
      return f;
    } catch (e) {
      return BleFailure(BleFailureKind.unknown, cause: e);
    }
  }

  Future<void> connect(DiscoveredDevice device) async {
    final gen = ++_generation;
    state = state.copyWith(
      phase: LinkPhase.connecting,
      device: device,
      reconnectAttempt: 0,
      clearError: true,
    );
    try {
      await _transport.ensureReady();
      final info = await _transport.connect(device, ref.read(settingsProvider).ble);
      if (!ref.mounted || gen != _generation) return;
      _onConnected(info);
    } catch (e) {
      if (!ref.mounted || gen != _generation) return;
      state = LinkState(
        device: device,
        error: e is BleFailure ? e : BleFailure(BleFailureKind.unknown, cause: e),
        demo: state.demo,
      );
    }
  }

  void _onConnected(LinkInfo info) {
    ref.read(messagingProvider).attach(_transport, info.protocolVersion);
    state = LinkState(
      phase: LinkPhase.connected,
      device: info.device,
      protocolVersion: info.protocolVersion,
      nodeStatus: info.status ?? state.nodeStatus,
      demo: state.demo,
    );
  }

  Future<void> _onLinkLost() async {
    if (!ref.mounted || !state.isConnected) return;
    final device = state.device!;
    final gen = ++_generation;
    await ref.read(messagingProvider).detach();

    for (var attempt = 1; attempt <= maxReconnectAttempts; attempt++) {
      if (!ref.mounted || gen != _generation) return;
      state = state.copyWith(phase: LinkPhase.reconnecting, reconnectAttempt: attempt);
      await Future<void>.delayed(reconnectDelay);
      if (!ref.mounted || gen != _generation) return;
      try {
        final info = await _transport.connect(device, ref.read(settingsProvider).ble);
        if (!ref.mounted || gen != _generation) return;
        _onConnected(info);
        return;
      } catch (_) {
        // Try again until attempts run out.
      }
    }
    if (!ref.mounted || gen != _generation) return;
    state = LinkState(
      device: device,
      error: BleFailure(BleFailureKind.connectionLost, deviceName: device.name),
      demo: state.demo,
    );
  }

  Future<void> disconnect() async {
    _generation++;
    await _transport.disconnect();
    await ref.read(messagingProvider).detach();
    if (!ref.mounted) return;
    state = LinkState(device: state.device, demo: state.demo);
  }

  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }
}
