import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/app.dart';
import 'package:lear_chat/core/messaging/messaging_service.dart';
import 'package:lear_chat/core/protocol/codec.dart';
import 'package:lear_chat/data/settings_repo.dart';
import 'package:lear_chat/state/providers.dart';
import 'package:lear_chat/transport/fake_transport.dart';

import '../support/memory_store.dart';

void main() {
  late MemoryMessageStore store;

  Future<void> pumpApp(WidgetTester tester, {required bool demo}) async {
    store = MemoryMessageStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepoProvider.overrideWithValue(
            SettingsRepo.inMemory({SettingsRepo.demoKey: '$demo'}),
          ),
          storeProvider.overrideWithValue(store),
          messagingProvider.overrideWithValue(MessagingService(store: store)),
          transportFactoryProvider.overrideWithValue((d) => FakeTransport(isDemo: d)),
        ],
        child: const LearChatApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('demo mode: add contact, send, see ticks and the echo reply', (tester) async {
    await pumpApp(tester, demo: true);
    expect(find.text('Demo mode'), findsOneWidget);
    expect(find.text('Node 0001'), findsOneWidget, reason: 'status strip');
    expect(find.text('87%'), findsOneWidget);

    // Add a contact; a bad ID is rejected first.
    await tester.tap(find.text('Add contact'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('contact-name')), 'Ana');
    await tester.enterText(find.byKey(const Key('contact-id')), 'XYZ1');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a hex ID from 0000 to FFFF.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('contact-id')), '00a2');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // Now in the chat with Ana.
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Node 00A2'), findsOneWidget);

    // Byte counter counts UTF-8 bytes.
    await tester.enterText(find.byKey(const Key('composer-field')), 'Hola 😀');
    await tester.pump();
    expect(find.text('9 / 144 bytes'), findsOneWidget);

    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Hola 😀'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byIcon(Icons.done_all), findsOneWidget, reason: 'delivered');

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('Got it: Hola 😀'), findsOneWidget);
  });

  testWidgets('send is disabled over 144 bytes', (tester) async {
    await pumpApp(tester, demo: true);
    await store.addContact(1, 'Bo');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bo'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('composer-field')), '😀' * 37);
    await tester.pump();
    expect(find.textContaining('148 / 144 bytes'), findsOneWidget);
    final button = tester.widget<IconButton>(find.byKey(const Key('send-button')));
    expect(button.onPressed, isNull);
  });

  testWidgets('without a connection the chip offers Connect and Send is disabled', (tester) async {
    await pumpApp(tester, demo: false);
    expect(find.text('Connect'), findsOneWidget);
    await store.addContact(2, 'Cy');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cy'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to your handheld to send messages.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer-field')), 'hi');
    await tester.pump();
    final button = tester.widget<IconButton>(find.byKey(const Key('send-button')));
    expect(button.onPressed, isNull);
  });

  testWidgets('unread badge appears for incoming and clears when opened', (tester) async {
    await pumpApp(tester, demo: true);
    final messaging = MessagingService(store: store);
    await store.addContact(3, 'Dee');
    await messaging.handleRx(encodeRxMessage(3, 'one'));
    await messaging.handleRx(encodeRxMessage(3, 'two'));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.text('Dee'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('2'), findsNothing);
  });
}
