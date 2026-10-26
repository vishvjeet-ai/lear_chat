import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../core/protocol/constants.dart';

enum ThemePreference { system, light, dark }

class AppSettings {
  const AppSettings({
    this.ble = const BleConfig(),
    this.demoMode = false,
    this.demoNodeId = 0x0001,
    this.theme = ThemePreference.system,
    this.permissionRationaleShown = false,
  });

  final BleConfig ble;
  final bool demoMode;

  /// Node ID this phone uses in demo mode. Random per install so several
  /// phones in demo mode show different nodes.
  final int demoNodeId;
  final ThemePreference theme;
  final bool permissionRationaleShown;

  AppSettings copyWith({
    BleConfig? ble,
    bool? demoMode,
    ThemePreference? theme,
    bool? permissionRationaleShown,
  }) => AppSettings(
    ble: ble ?? this.ble,
    demoMode: demoMode ?? this.demoMode,
    demoNodeId: demoNodeId,
    theme: theme ?? this.theme,
    permissionRationaleShown: permissionRationaleShown ?? this.permissionRationaleShown,
  );
}

/// Reads and writes [AppSettings] in the app's SQLite `settings` table.
///
/// Values are cached in memory so [load] is synchronous; [save] writes
/// through. With no database (tests), values live only in memory.
class SettingsRepo {
  SettingsRepo._(this._db, this._values);

  /// In-memory settings for tests.
  SettingsRepo.inMemory([Map<String, String>? values]) : this._(null, {...?values});

  static Future<SettingsRepo> open(Database db) async {
    final rows = await db.query('settings');
    final values = {for (final r in rows) r['key'] as String: r['value'] as String};
    if (int.tryParse(values[_demoNodeId] ?? '') == null) {
      // 0x0100..0xFFFE: clear of the default 0x0001 and the 0xFFFF broadcast.
      final id = 0x0100 + Random.secure().nextInt(0xFFFF - 0x0100);
      values[_demoNodeId] = '$id';
      await db.insert('settings', {
        'key': _demoNodeId,
        'value': '$id',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return SettingsRepo._(db, values);
  }

  final Database? _db;
  final Map<String, String> _values;

  static const _service = 'ble.service';
  static const _tx = 'ble.tx';
  static const _rx = 'ble.rx';
  static const _status = 'ble.status';
  static const _version = 'ble.version';
  static const _prefix = 'ble.namePrefix';
  static const demoKey = 'demoMode';
  static const _demoNodeId = 'demoNodeId';
  static const _theme = 'theme';
  static const _rationale = 'permissionRationaleShown';

  bool _bool(String key) => _values[key] == 'true';

  AppSettings load() {
    const d = BleConfig();
    return AppSettings(
      ble: BleConfig(
        serviceUuid: _values[_service] ?? d.serviceUuid,
        txUuid: _values[_tx] ?? d.txUuid,
        rxUuid: _values[_rx] ?? d.rxUuid,
        statusUuid: _values[_status] ?? d.statusUuid,
        versionUuid: _values[_version] ?? d.versionUuid,
        namePrefix: _values[_prefix] ?? d.namePrefix,
      ),
      demoMode: _bool(demoKey),
      demoNodeId: int.tryParse(_values[_demoNodeId] ?? '') ?? 0x0001,
      theme: ThemePreference.values.asNameMap()[_values[_theme]] ?? ThemePreference.system,
      permissionRationaleShown: _bool(_rationale),
    );
  }

  Future<void> save(AppSettings s) async {
    final values = {
      _service: s.ble.serviceUuid,
      _tx: s.ble.txUuid,
      _rx: s.ble.rxUuid,
      _status: s.ble.statusUuid,
      _version: s.ble.versionUuid,
      _prefix: s.ble.namePrefix,
      demoKey: '${s.demoMode}',
      _demoNodeId: '${s.demoNodeId}',
      _theme: s.theme.name,
      _rationale: '${s.permissionRationaleShown}',
    };
    _values.addAll(values);
    final db = _db;
    if (db == null) return;
    final batch = db.batch();
    values.forEach((key, value) {
      batch.insert('settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
  }
}
