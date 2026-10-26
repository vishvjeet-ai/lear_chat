import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/core/messaging/message_store.dart';
import 'package:lear_chat/core/messaging/models.dart';
import 'package:lear_chat/core/protocol/constants.dart';
import 'package:lear_chat/data/app_database.dart';
import 'package:lear_chat/data/settings_repo.dart';
import 'package:lear_chat/data/sqlite_message_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late SqliteMessageStore store;

  setUp(() async {
    store = await SqliteMessageStore.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });

  tearDown(() => store.close());

  Future<int> msg(
    int peer,
    MessageDirection dir,
    int ts, {
    MessageState? state,
    String text = 't',
    int? msgId,
  }) => store.insertMessage(
    peer: peer,
    direction: dir,
    text: text,
    state:
        state ?? (dir == MessageDirection.incoming ? MessageState.received : MessageState.sending),
    ts: ts,
    msgId: msgId,
  );

  test('contacts: add, duplicate rejected, rename, ensure', () async {
    await store.addContact(0x0A, 'Ana');
    await expectLater(store.addContact(0x0A, 'Other'), throwsA(isA<DuplicateContactException>()));
    await store.renameContact(0x0A, '  Ana B  ');
    expect((await store.contact(0x0A))!.name, 'Ana B');
    expect(await store.ensureContact(0x0A), isFalse);
    expect(await store.ensureContact(0xBEEF), isTrue);
    expect((await store.contact(0xBEEF))!.name, 'Node BEEF');
  });

  test('summaries: sorted by last message, preview and unread count', () async {
    await store.addContact(1, 'One');
    await store.addContact(2, 'Two');
    await store.addContact(3, 'Quiet');
    await msg(1, MessageDirection.incoming, 100, text: 'old');
    await msg(2, MessageDirection.incoming, 200);
    await msg(2, MessageDirection.incoming, 300);
    await msg(2, MessageDirection.outgoing, 400, text: 'latest');

    final list = await store.contactSummaries();
    expect(list.map((s) => s.contact.id), [2, 1, 3]);
    expect(list[0].lastMessage!.text, 'latest');
    expect(list[0].unread, 2);
    expect(list[1].unread, 1);
    expect(list[2].lastMessage, isNull);

    await store.markRead(2, 300);
    expect((await store.contactSummaries()).first.unread, 0);
    await store.markRead(2, 100); // never moves back
    expect((await store.contact(2))!.lastReadTs, 300);
  });

  test('messages: update keeps msg_id unless a new one is given', () async {
    final id = await msg(1, MessageDirection.outgoing, 1);
    await store.updateMessage(id, MessageState.queued, msgId: 0x10);
    await store.updateMessage(id, MessageState.delivered);
    final m = (await store.message(id))!;
    expect(m.state, MessageState.delivered);
    expect(m.msgId, 0x10);
  });

  test('messagesFor is in time order', () async {
    await msg(1, MessageDirection.incoming, 30, text: 'c');
    await msg(1, MessageDirection.incoming, 10, text: 'a');
    await msg(1, MessageDirection.outgoing, 20, text: 'b');
    await msg(2, MessageDirection.incoming, 15, text: 'other');
    expect((await store.messagesFor(1)).map((m) => m.text), ['a', 'b', 'c']);
  });

  test('startup cleanup and open outgoing', () async {
    final sending = await msg(1, MessageDirection.outgoing, 1);
    final queuedNoId = await msg(1, MessageDirection.outgoing, 2, state: MessageState.queued);
    final queuedId = await msg(
      1,
      MessageDirection.outgoing,
      3,
      state: MessageState.queued,
      msgId: 7,
    );
    final sent = await msg(1, MessageDirection.outgoing, 4, state: MessageState.sent, msgId: 8);
    await store.failStaleOutgoing();
    expect((await store.message(sending))!.state, MessageState.failed);
    expect((await store.message(queuedNoId))!.state, MessageState.failed);
    expect((await store.openOutgoing()).map((m) => m.rowid), unorderedEquals([queuedId, sent]));
  });

  test('clear all chats keeps contacts and resets unread', () async {
    await store.addContact(1, 'One');
    await msg(1, MessageDirection.incoming, 5);
    await store.markRead(1, 5);
    await store.clearAllChats();
    final list = await store.contactSummaries();
    expect(list.single.contact.name, 'One');
    expect(list.single.lastMessage, isNull);
    expect(list.single.contact.lastReadTs, 0);
  });

  test('delete contact removes their messages', () async {
    await store.addContact(1, 'One');
    await msg(1, MessageDirection.incoming, 5);
    await store.deleteContact(1);
    expect(await store.contact(1), isNull);
    expect(await store.messagesFor(1), isEmpty);
  });

  test('every write notifies listeners', () async {
    var count = 0;
    final sub = store.changes.listen((_) => count++);
    await store.addContact(1, 'One');
    await msg(1, MessageDirection.incoming, 1);
    await Future<void>.delayed(Duration.zero);
    expect(count, 2);
    await sub.cancel();
  });

  test('settings persist in the database and default when absent', () async {
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = await SettingsRepo.open(db);
    final defaults = repo.load();
    expect(defaults.demoMode, isFalse);
    expect(defaults.ble, const BleConfig());
    expect(defaults.theme, ThemePreference.system);

    await repo.save(
      defaults.copyWith(
        demoMode: true,
        theme: ThemePreference.dark,
        ble: const BleConfig(namePrefix: 'MESH'),
      ),
    );
    final reloaded = (await SettingsRepo.open(db)).load();
    expect(reloaded.demoMode, isTrue);
    expect(reloaded.theme, ThemePreference.dark);
    expect(reloaded.ble.namePrefix, 'MESH');
    expect(reloaded.ble.serviceUuid, kDefaultServiceUuid);
    await db.close();
  });

  test('upgrades a v1 database (no settings table) and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('lear_db');
    final path = '${dir.path}/lear_chat.db';
    // A database as the first build created it.
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE contacts(id INTEGER PRIMARY KEY, name TEXT NOT NULL, '
            'last_read_ts INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE messages(rowid INTEGER PRIMARY KEY AUTOINCREMENT, peer INTEGER NOT NULL, '
            'dir TEXT NOT NULL, text TEXT NOT NULL, state TEXT NOT NULL, msg_id INTEGER NULL, '
            'ts INTEGER NOT NULL)',
          );
          await db.insert('contacts', {'id': 7, 'name': 'Kept'});
        },
      ),
    );
    await old.close();

    final db = await openAppDatabase(factory: databaseFactoryFfi, path: path);
    expect(await db.getVersion(), dbVersion);
    final settings = await SettingsRepo.open(db);
    await settings.save(settings.load().copyWith(demoMode: true));
    expect((await SettingsRepo.open(db)).load().demoMode, isTrue);
    expect((await SqliteMessageStore(db).contact(7))!.name, 'Kept');
    await db.close();
    await dir.delete(recursive: true);
  });
}
