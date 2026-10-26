# LEAR Chat

The phone client for a LoRa mesh messenger that needs no network infrastructure. The phone talks over Bluetooth Low Energy to a handheld node (ESP32-S3 + SX1262), and the handheld carries messages across a gateway-free LoRa mesh.

- **No internet.** The app never uses cellular, Wi-Fi or the internet for messaging. The release build doesn't even request the INTERNET permission.
- **No backend.** There's no login and no cloud. Contacts, messages and settings stay on the phone (SQLite and SharedPreferences).
- **Android first.** The code is iOS-compatible.

Built with Flutter 3.44 / Dart 3.12, [universal_ble](https://pub.dev/packages/universal_ble) (BSD-3), Riverpod, go_router and sqflite.

## Quick start (demo mode, no hardware)

Demo mode simulates a handheld. A sent message shows QUEUED after 0.3 s and DELIVERED after 2 s, then an echo reply `Got it: <text>` arrives at 3.5 s. The simulated node reports 0001, 87 % battery, queue 0, link good.

```bash
flutter pub get
flutter run            # emulator or phone; then Settings → Demo mode
```

Demo mode runs on an emulator without Bluetooth, and the unit tests use the same fake transport. (Flutter has no Expo Go equivalent. `flutter run` builds a debug app with hot reload, and Bluetooth works in it on a real phone.)

## Build an installable APK

Requirements: the Flutter SDK, the Android SDK, and **JDK 17 or 21**. Gradle doesn't support JDK 25 yet.

```bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64   # or: flutter config --jdk-dir <path>
flutter build apk --release                           # build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

For smaller per-device files, use `flutter build apk --release --split-per-abi`.

The release build is currently signed with the debug key, which is fine for side-loading. Before publishing, create an upload keystore and set `signingConfig` in [android/app/build.gradle.kts](android/app/build.gradle.kts) (see the [Flutter Android release guide](https://docs.flutter.dev/deployment/android)).

To confirm the APK has no network permission:

```bash
$ANDROID_HOME/build-tools/<version>/aapt dump permissions build/app/outputs/flutter-apk/app-release.apk
```

## Tests

```bash
flutter analyze
flutter test
```

| Area | File |
|---|---|
| Packet encode/decode (v1 + v2, malformed input) | [test/protocol/codec_test.dart](test/protocol/codec_test.dart) |
| 144-byte UTF-8 counter (é, CJK, emoji, ZWJ, boundaries), node IDs | [test/protocol/utf8_limit_test.dart](test/protocol/utf8_limit_test.dart) |
| Delivery state machine: CIDs, v1 FIFO, write/status races, disconnect | [test/messaging/delivery_tracker_test.dart](test/messaging/delivery_tracker_test.dart) |
| Send/receive end to end on the fake transport, on fake time | [test/messaging/messaging_service_test.dart](test/messaging/messaging_service_test.dart) |
| SQLite store (runs on the desktop through sqflite ffi) | [test/data/sqlite_store_test.dart](test/data/sqlite_store_test.dart) |
| Connect errors, auto-reconnect (3 tries, 1.5 s apart), demo auto-connect | [test/state/link_controller_test.dart](test/state/link_controller_test.dart) |
| UI: add contact, byte counter, ticks, echo, unread badge | [test/widget/demo_flow_test.dart](test/widget/demo_flow_test.dart) |

Flutter handles BLE values as raw bytes (`Uint8List`), so the base64 helper that react-native-ble-plx would need doesn't exist here.

## BLE contract

The full contract, with the reasons for each change and firmware notes, is in **[docs/ble-contract.md](docs/ble-contract.md)**. All 16-bit values are big-endian.

| Characteristic | UUID | Properties | Payload |
|---|---|---|---|
| Service | `4c454152-4d45-5348-0001-000000000000` | | |
| TX | `4c454152-4d45-5348-0002-000000000000` | Write with response | v2: `CID_hi CID_lo DST_hi DST_lo text` · v1: `DST_hi DST_lo text` (text ≤ 144 B) |
| RX | `4c454152-4d45-5348-0003-000000000000` | Notify | `0x01 SRC_hi SRC_lo text` incoming · `0x02 ID_hi ID_lo state` status |
| STATUS | `4c454152-4d45-5348-0004-000000000000` | Read, Notify | `NODE_hi NODE_lo SoC% queueLen link(0 none, 1 weak, 2 good)` |
| VERSION | `4c454152-4d45-5348-0005-000000000000` | Read | `[2]`. If missing, the node is treated as v1 |

Delivery states: 1 QUEUED, 4 SENT (first hop acknowledged), 2 DELIVERED (end-to-end), 3 FAILED. The device name prefix is `LEAR`. You can change the UUIDs and the prefix in Settings.

**What changed from the original contract, and why.** In v1 the node assigns message IDs and the phone matches QUEUED statuses to messages in FIFO order, so one lost notification shifts every later match onto the wrong message. In v2 the phone sends its own client ID (CID), which every status echoes, so matching is exact and queued messages can still finish after a reconnect. v2 also adds SENT, which keeps DELIVERED for end-to-end delivery: the mesh's ACKs are hop-by-hop, so a hop ACK doesn't prove the message arrived. Nodes without a VERSION characteristic fall back to v1 automatically.

## Test the handheld with nRF Connect first

Check the firmware with [nRF Connect for Mobile](https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-for-mobile) before using the app:

1. Scan and connect to `LEAR-xxxx`. Enter the 6-digit passkey from the handheld's OLED.
2. Enable notifications on **RX** and **STATUS**.
3. Read **VERSION**: expect `02`. Read **STATUS**: expect 5 bytes, such as `00 01 57 00 02`.
4. Write `00 01 00 02 48 69` to **TX**, *with response*. That's CID 1, to node 0002, text "Hi".
5. Expect RX `02 00 01 01` (QUEUED), then `02 00 01 04` (SENT), then `02 00 01 02` (DELIVERED).
6. Message this handheld from another one and expect `01 <src> <text>` on RX.

Then forget the pairing in nRF Connect (or Android Bluetooth settings) and connect from LEAR Chat.

## Using the app with a handheld

1. Turn off **Demo mode** in Settings.
2. Tap **Connect**. The first time, the app explains why it needs Bluetooth, then Android asks for *Nearby devices* (on Android 11 and below, *Location*, which those versions require for BLE scanning).
3. Pick your handheld and enter the passkey from its screen in the Android dialog.
4. The status strip shows the relay node, battery, queue and link quality.

If the link drops, the app retries 3 times, 1.5 s apart. Messages still being written are marked failed (tap to retry). Queued messages keep their client ID and still get their final status after a reconnect.

Errors say what went wrong and how to fix it, for example "Bluetooth is off. Turn it on to connect." When the fix is in system settings, the message includes a button that opens them.

## Project layout

```
lib/
  core/protocol/    constants, codec (TX/RX/STATUS bytes), UTF-8 limit, node IDs   ← pure Dart
  core/messaging/   models, DeliveryTracker (state machine), MessagingService       ← pure Dart
  core/ble_failure  user-facing error kinds and messages
  transport/        BleTransport interface, UniversalBleTransport, FakeTransport (demo)
  data/             SQLite message store, settings
  state/            Riverpod providers, LinkController (connect / reconnect)
  ui/               contacts, chat, settings screens and widgets
docs/ble-contract.md   the firmware contract
```

The UI and the messaging logic depend only on `BleTransport`. Protocol and state-machine code has no Flutter imports.

## Known limits and next steps

- **Background receiving** (phase 2): messages arrive only while the app is open. A foreground service and local notifications are planned.
- Messages that stay QUEUED (for example after the handheld reboots and forgets its CIDs) don't time out yet.
- BLE pairing secures only the phone ↔ handheld hop. The LoRa mesh is unencrypted, as in the reference design.
