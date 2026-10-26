import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/ble_failure.dart';
import 'data/settings_repo.dart';
import 'state/providers.dart';
import 'transport/universal_ble_transport.dart';
import 'ui/chat_screen.dart';
import 'ui/contacts_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

GoRouter buildRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const ContactsScreen(),
      routes: [
        GoRoute(
          path: 'chat/:peer',
          builder: (context, state) => ChatScreen(peer: int.parse(state.pathParameters['peer']!)),
        ),
        GoRoute(path: 'settings', builder: (context, state) => const SettingsScreen()),
      ],
    ),
  ],
);

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class LearChatApp extends ConsumerStatefulWidget {
  const LearChatApp({super.key});

  @override
  ConsumerState<LearChatApp> createState() => _LearChatAppState();
}

class _LearChatAppState extends ConsumerState<LearChatApp> {
  // One router per app instance, so a fresh app always starts at '/'.
  late final GoRouter _router = buildRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(settingsProvider.select((s) => s.theme));

    ref.listen<BleFailure?>(linkProvider.select((s) => s.error), (_, error) {
      if (error == null) return;
      ref.read(linkProvider.notifier).clearError();
      showFailure(error);
    });

    return MaterialApp.router(
      title: 'LEAR Chat',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: switch (theme) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      },
      routerConfig: _router,
    );
  }
}

/// Shows [failure] with the action that fixes it, when there is one.
void showFailure(BleFailure failure) {
  SnackBarAction? action;
  if (failure.opensSettings) {
    action = SnackBarAction(
      label: 'Open settings',
      onPressed: UniversalBleTransport.openSystemSettings,
    );
  } else if (failure.canEnableBluetooth) {
    action = SnackBarAction(
      label: 'Turn on',
      onPressed: UniversalBleTransport.requestEnableBluetooth,
    );
  }
  scaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(failure.message),
        action: action,
        duration: const Duration(seconds: 6),
      ),
    );
}

/// Shows a short informational message.
void showInfo(String message) {
  scaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
