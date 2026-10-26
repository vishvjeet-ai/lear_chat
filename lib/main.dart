import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/messaging/messaging_service.dart';
import 'data/app_database.dart';
import 'data/settings_repo.dart';
import 'data/sqlite_message_store.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await openAppDatabase();
  final settings = await SettingsRepo.open(db);
  final store = SqliteMessageStore(db);
  final messaging = MessagingService(store: store);
  await messaging.init();

  runApp(
    ProviderScope(
      overrides: [
        settingsRepoProvider.overrideWithValue(settings),
        storeProvider.overrideWithValue(store),
        messagingProvider.overrideWithValue(messaging),
      ],
      child: const LearChatApp(),
    ),
  );
}
