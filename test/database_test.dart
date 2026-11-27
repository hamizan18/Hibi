import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/features/habits/data/habit_scoring_store.dart';
import 'package:hibi/features/habits/domain/dynamic_normalized_scoring.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'test_schema_downgrade.dart';

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
    expect(version.read<int>('user_version'), 16);
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
    dropV13Schema(legacy);
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
      16,
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
    dropV13Schema(legacy);
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
  test('scoring configurations are versioned and validated', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customStatement("INSERT INTO habits VALUES ('h', 1)");
    for (final entry in [
      ('v1', '2030-01-01', '2030-01-02', 1),
      ('v2', '2030-01-02', '2030-01-03', 2),
      ('v3', '2030-01-03', null, 3),
    ]) {
      await database.customStatement(
        'INSERT INTO habit_versions VALUES (?, ?, ?, ?, ?, ?, ?)',
        [entry.$1, 'h', 'Habit', entry.$2, entry.$3, 1, entry.$4],
      );
    }
    await database.customStatement(
      "INSERT INTO habit_typed_targets (habit_version_id, tracking_type, scaled_target, decimal_places, unit, comparison_rule) VALUES ('v1', 'measurement', 1, 0, 'unit', 'at_least')",
    );
    await database.customStatement(
      "INSERT INTO habit_typed_targets (habit_version_id, tracking_type, target_minutes_since_midnight, comparison_rule) VALUES ('v2', 'time_of_day', 600, 'at_or_before')",
    );
    await database.customStatement(
      "INSERT INTO habit_typed_targets (habit_version_id, tracking_type, min_scaled, max_scaled, decimal_places, unit) VALUES ('v3', 'range', 1, 2, 0, 'unit')",
    );
    await expectLater(
      database.customStatement(
        "INSERT INTO habit_version_scoring VALUES ('v1', 'range', 1, 10)",
      ),
      throwsA(isA<Exception>()),
    );
    final store = HabitScoringStore(database);
    expect(await store.findForVersion('v1'), isNull);
    await store.insert('v1', const HabitScoringConfig.measurement());
    await store.insert(
      'v2',
      const HabitScoringConfig.timeOfDay(toleranceMinutes: 30),
    );
    expect(
      (await store.findForVersion('v1'))?.type,
      DynamicScoreType.measurement,
    );
    expect((await store.findForVersion('v2'))?.tolerance, 30);
    expect(
      () => store.insert(
        'v3',
        const HabitScoringConfig.range(toleranceScaled: 0),
      ),
      throwsArgumentError,
    );
    await database.customStatement(
      "INSERT INTO habit_version_scoring VALUES ('v3', 'range', 2, 10)",
    );
    expect(await store.findForVersion('v3'), isNull);
    await database.customStatement(
      "INSERT INTO habit_typed_occurrences VALUES ('o', 'h', 'v1', 'measurement', '2030-01-01')",
    );
    await expectLater(
      database.customStatement(
        "UPDATE habit_version_scoring SET rule_version = 2 WHERE habit_version_id = 'v1'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database.customStatement(
        "DELETE FROM habit_version_scoring WHERE habit_version_id = 'v1'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database.customStatement(
        "DELETE FROM habit_typed_targets WHERE habit_version_id = 'v1'",
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('v12 migration preserves typed data and survives reopen', () async {
    final directory = await Directory.systemTemp.createTemp('hibi_v13_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'test.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await original.setSetting('theme', 'dark');
    await original.close();
    final legacy = sqlite.sqlite3.open(file.path);
    dropV13Schema(legacy);
    legacy.execute("INSERT INTO habits VALUES ('h', 1)");
    legacy.execute(
      "INSERT INTO habit_versions VALUES ('v', 'h', 'Time', '2030-01-01', NULL, 1, 1)",
    );
    legacy.execute(
      "INSERT INTO habit_typed_targets (habit_version_id, tracking_type, comparison_rule, target_minutes_since_midnight) VALUES ('v', 'time_of_day', 'at_or_before', 600)",
    );
    legacy.execute(
      "INSERT INTO habit_typed_occurrences VALUES ('o', 'h', 'v', 'time_of_day', '2030-01-01')",
    );
    legacy.execute(
      "INSERT INTO habit_typed_logs (id, occurrence_id, state, minutes_since_midnight, occurred_at_utc_us) VALUES ('l', 'o', 'completed', 605, 1)",
    );
    legacy.execute('PRAGMA user_version = 12');
    legacy.close();

    final migrated = AppDatabase(NativeDatabase(file));
    final log = await migrated
        .customSelect(
          'SELECT state, minutes_since_midnight, day_offset FROM habit_typed_logs',
        )
        .getSingle();
    expect(log.read<String>('state'), 'completed');
    expect(log.read<int>('minutes_since_midnight'), 605);
    expect(log.readNullable<int>('day_offset'), isNull);
    expect(
      await migrated.customSelect('SELECT * FROM habit_version_scoring').get(),
      isEmpty,
    );
    expect(
      (await migrated
              .customSelect('SELECT comparison_rule FROM habit_typed_targets')
              .getSingle())
          .read<String>('comparison_rule'),
      'at_or_before',
    );
    await migrated.customStatement(
      "UPDATE habit_typed_targets SET comparison_rule = 'at_or_near' WHERE habit_version_id = 'v'",
    );
    await migrated.close();

    final reopened = AppDatabase(NativeDatabase(file));
    expect(await reopened.getSetting('theme'), 'dark');
    expect(
      (await reopened
              .customSelect('SELECT comparison_rule FROM habit_typed_targets')
              .getSingle())
          .read<String>('comparison_rule'),
      'at_or_near',
    );
    expect(
      (await reopened.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      16,
    );
    await reopened.close();
  });

  test(
    'failed v13 migration rolls back target rebuild and log alteration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hibi_v13_failure_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(path.join(directory.path, 'test.sqlite'));
      final original = AppDatabase(NativeDatabase(file));
      await original.setSetting('theme', 'dark');
      await original.close();
      final legacy = sqlite.sqlite3.open(file.path);
      dropV13Schema(legacy);
      legacy.execute('CREATE TABLE habit_version_scoring (sentinel TEXT)');
      legacy.execute("INSERT INTO habit_version_scoring VALUES ('preserved')");
      legacy.execute('PRAGMA user_version = 12');
      legacy.close();
      final migrated = AppDatabase(NativeDatabase(file));
      await expectLater(
        migrated.getSetting('theme'),
        throwsA(isA<Exception>()),
      );
      await migrated.close();
      final unchanged = sqlite.sqlite3.open(file.path);
      expect(
        unchanged.select('PRAGMA user_version').single['user_version'],
        12,
      );
      expect(
        unchanged
            .select('SELECT sentinel FROM habit_version_scoring')
            .single['sentinel'],
        'preserved',
      );
      expect(
        unchanged
            .select('PRAGMA table_info(habit_typed_logs)')
            .any((row) => row['name'] == 'day_offset'),
        isFalse,
      );
      final targetSql =
          unchanged
                  .select(
                    "SELECT sql FROM sqlite_master WHERE name = 'habit_typed_targets'",
                  )
                  .single['sql']
              as String;
      expect(targetSql, isNot(contains('at_or_near')));
      expect(
        unchanged
            .select("SELECT value FROM app_settings WHERE key = 'theme'")
            .single['value'],
        'dark',
      );
      unchanged.close();
    },
  );
}
