import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('settings can be inserted, updated and deleted in memory', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    expect(await database.getSetting('theme'), isNull);
    await database.setSetting('theme', 'light');
    expect(await database.getSetting('theme'), 'light');
    await database.setSetting('theme', 'dark');
    expect(await database.getSetting('theme'), 'dark');
    await database.deleteSetting('theme');
    expect(await database.getSetting('theme'), isNull);
  });

  test('schema version and foreign key enforcement are enabled', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(version.read<int>('user_version'), 12);
    final foreignKeys = await database
        .customSelect('PRAGMA foreign_keys')
        .getSingle();
    expect(foreignKeys.read<int>('foreign_keys'), 1);

    await database.customStatement(
      'CREATE TABLE parent (id INTEGER PRIMARY KEY)',
    );
    await database.customStatement(
      'CREATE TABLE child (parent_id INTEGER REFERENCES parent(id))',
    );
    await expectLater(
      database.customStatement('INSERT INTO child (parent_id) VALUES (1)'),
      throwsA(isA<Exception>()),
    );
  });

  test('settings survive closing and reopening a disk database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hibi_database_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'test.sqlite'));

    final first = AppDatabase(NativeDatabase(file));
    try {
      await first.setSetting('language', 'en');
    } finally {
      await first.close();
    }

    final reopened = AppDatabase(NativeDatabase(file));
    try {
      expect(await reopened.getSetting('language'), 'en');
      final foreignKeys = await reopened
          .customSelect('PRAGMA foreign_keys')
          .getSingle();
      expect(foreignKeys.read<int>('foreign_keys'), 1);
    } finally {
      await reopened.close();
    }
  });
  test('version 11 migration preserves lifecycle data and survives reopen', () async {
    final directory = await Directory.systemTemp.createTemp('hibi_v12_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'test.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await original.setSetting('theme', 'dark');
    await original.customStatement("INSERT INTO habits VALUES ('h', 1)");
    await original.customStatement(
      "INSERT INTO habit_lifecycle_events "
      "(id, habit_id, effective_date, state, created_at_utc_us) "
      "VALUES ('e', 'h', '2030-01-01', 'active', 1)",
    );
    await original.close();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute('DROP TABLE habit_lifecycle_start_pauses');
    legacy.execute('PRAGMA user_version = 11');
    legacy.close();

    final migrated = AppDatabase(NativeDatabase(file));
    expect(await migrated.getSetting('theme'), 'dark');
    expect(
      (await migrated
              .customSelect('SELECT id FROM habit_lifecycle_events')
              .getSingle())
          .read<String>('id'),
      'e',
    );
    await migrated.customStatement(
      "INSERT INTO habit_lifecycle_start_pauses VALUES ('p', 'e', 2, NULL)",
    );
    await expectLater(
      migrated.customStatement(
        "UPDATE habit_lifecycle_start_pauses SET reason = 'x'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      migrated.customStatement('DELETE FROM habit_lifecycle_start_pauses'),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      migrated.customStatement(
        "INSERT INTO habit_lifecycle_start_pauses VALUES ('p2', 'e', 3, NULL)",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      migrated.customStatement(
        "INSERT INTO habit_lifecycle_start_pauses VALUES ('p2', 'missing', 3, NULL)",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      migrated.customStatement(
        "INSERT INTO habit_lifecycle_start_pauses VALUES (' ', 'e', 3, NULL)",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      migrated.customStatement(
        "INSERT INTO habit_lifecycle_start_pauses VALUES ('p2', 'missing', 'bad', NULL)",
      ),
      throwsA(isA<Exception>()),
    );
    await migrated.close();

    final reopened = AppDatabase(NativeDatabase(file));
    expect(
      (await reopened.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      12,
    );
    expect(
      (await reopened
              .customSelect(
                'SELECT initial_event_id FROM habit_lifecycle_start_pauses',
              )
              .getSingle())
          .read<String>('initial_event_id'),
      'e',
    );
    await reopened.close();
  });

  test('failed version 11 migration rolls back and preserves data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hibi_v12_failure_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'test.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await original.setSetting('theme', 'dark');
    await original.close();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute('DROP TABLE habit_lifecycle_start_pauses');
    legacy.execute(
      'CREATE TRIGGER habit_lifecycle_start_pauses_no_update '
      'BEFORE UPDATE ON app_settings BEGIN SELECT 1; END',
    );
    legacy.execute('PRAGMA user_version = 11');
    legacy.close();

    final migrated = AppDatabase(NativeDatabase(file));
    await expectLater(migrated.getSetting('theme'), throwsA(isA<Exception>()));
    await migrated.close();
    final unchanged = sqlite.sqlite3.open(file.path);
    expect(unchanged.select('PRAGMA user_version').first['user_version'], 11);
    expect(
      unchanged
          .select("SELECT value FROM app_settings WHERE key = 'theme'")
          .first['value'],
      'dark',
    );
    expect(
      unchanged.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'habit_lifecycle_start_pauses'",
      ),
      isEmpty,
    );
    unchanged.close();
  });
}
