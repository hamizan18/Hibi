import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('occurrences enforce applicable versions and preserve multiple counter events', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO habits VALUES ('h1', 1), ('h2', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v1', 'h1', 'Read', '2026-11-18', '2026-12-01', 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v2', 'h1', 'Read', '2026-12-01', NULL, 2, 2)",
    );
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('other', 'h2', 'Other', '2026-11-18', NULL, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_targets VALUES ('v1', 5, 'pages'), ('v2', 20, 'pages'), ('other', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('o1', 'h1', 'v1', '2026-11-26', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_events VALUES ('e1', 'o1', 2, 100), ('e2', 'o1', 3, 101)",
    );
    final progress = await db
        .customSelect(
          "SELECT COUNT(*) AS n, SUM(quantity) AS total FROM habit_counter_events WHERE occurrence_id = 'o1'",
        )
        .getSingle();
    expect(progress.read<int>('n'), 2);
    expect(progress.read<int>('total'), 5);
    final invalid = [
      "INSERT INTO habit_occurrences VALUES ('duplicate', 'h1', 'v1', '2026-11-26', 5, 'pages')",
      "INSERT INTO habit_occurrences VALUES ('wrong-habit', 'h1', 'other', '2026-11-27', 5, 'pages')",
      "INSERT INTO habit_occurrences VALUES ('before', 'h1', 'v1', '2026-11-17', 5, 'pages')",
      "INSERT INTO habit_occurrences VALUES ('end', 'h1', 'v1', '2026-12-01', 5, 'pages')",
      "INSERT INTO habit_occurrences VALUES ('invalid-date', 'h1', 'v1', '2026-11-31', 5, 'pages')",
      "INSERT INTO habit_occurrences VALUES ('target', 'h1', 'v1', '2026-11-27', 20, 'pages')",
      "INSERT INTO habit_occurrences VALUES ('unit', 'h1', 'v1', '2026-11-27', 5, 'reps')",
      "INSERT INTO habit_counter_events VALUES ('orphan', 'missing', 1, 1)",
      "INSERT INTO habit_counter_events VALUES ('bad', 'o1', 0, 1)",
      "INSERT INTO habit_counter_events VALUES ('fraction', 'o1', 1.5, 1)",
      "INSERT INTO habit_counter_events VALUES ('e1', 'o1', 1, 1)",
      "UPDATE habit_occurrences SET local_date = '2026-11-27' WHERE id = 'o1'",
      "UPDATE habit_versions SET effective_end = '2026-11-26' WHERE id = 'v1'",
      "UPDATE habit_versions SET name = 'Changed' WHERE id = 'v1'",
      "UPDATE habit_counter_targets SET target_count = 10 WHERE habit_version_id = 'v1'",
      "DELETE FROM habit_counter_targets WHERE habit_version_id = 'v1'",
    ];
    for (final statement in invalid) {
      await expectLater(
        db.customStatement(statement),
        throwsA(isA<Exception>()),
        reason: statement,
      );
    }
    await db.customStatement(
      "UPDATE habit_versions SET effective_end = '2026-11-30' WHERE id = 'v1'",
    );
    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('o2', 'h1', 'v2', '2026-12-01', 20, 'pages')",
    );
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      2,
    );
  });

  test('version 4 migration retains existing records without inventing occurrences', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hibi_v4_occurrences_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'test.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await original.setSetting('theme', 'dark');
    await original.customStatement("INSERT INTO habits VALUES ('h', 1)");
    await original.customStatement(
      "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-26', NULL, 1, 1)",
    );
    await original.customStatement(
      "INSERT INTO habit_counter_targets VALUES ('v', 5, 'pages')",
    );
    await original.customStatement(
      "INSERT INTO habit_version_audit VALUES ('a', 'h', 'create', NULL, '{}', 1)",
    );
    await original.close();
    final legacy = sqlite3.open(file.path);
    legacy.execute('DROP TABLE habit_counter_resolutions');
    legacy.execute('DROP TABLE habit_counter_event_audit');
    legacy.execute('DROP TABLE habit_lifecycle_events');
    legacy.execute('DROP TABLE habit_schedules');
    _removeV5Schema(legacy);
    legacy.execute('PRAGMA user_version = 4');
    legacy.close();
    final migrated = AppDatabase(NativeDatabase(file));
    expect(await migrated.getSetting('theme'), 'dark');
    expect(
      (await migrated
              .customSelect(
                "SELECT target_count FROM habit_counter_targets WHERE habit_version_id = 'v'",
              )
              .getSingle())
          .read<int>('target_count'),
      5,
    );
    expect(
      (await migrated
              .customSelect('SELECT COUNT(*) AS n FROM habit_version_audit')
              .getSingle())
          .read<int>('n'),
      1,
    );
    expect(
      (await migrated
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      0,
    );
    expect(
      (await migrated.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      9,
    );
    await migrated.customStatement(
      "INSERT INTO habit_occurrences VALUES ('o', 'h', 'v', '2026-11-26', 5, 'pages')",
    );
    await migrated.customStatement(
      "INSERT INTO habit_counter_events VALUES ('e', 'o', 2, 1)",
    );
    await migrated.close();
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      (await reopened
              .customSelect(
                "SELECT quantity FROM habit_counter_events WHERE id = 'e'",
              )
              .getSingle())
          .read<int>('quantity'),
      2,
    );
  });

  test(
    'failed version 4 migration is rolled back with existing data intact',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hibi_v4_failure_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(path.join(directory.path, 'test.sqlite'));
      final original = AppDatabase(NativeDatabase(file));
      await original.setSetting('theme', 'dark');
      await original.close();
      final legacy = sqlite3.open(file.path);
      _removeV5Schema(legacy);
      legacy.execute('CREATE TABLE habit_counter_events (id TEXT)');
      legacy.execute('PRAGMA user_version = 4');
      legacy.close();
      final migrated = AppDatabase(NativeDatabase(file));
      await expectLater(
        migrated.getSetting('theme'),
        throwsA(isA<Exception>()),
      );
      await migrated.close();
      final unchanged = sqlite3.open(file.path);
      addTearDown(unchanged.close);
      expect(unchanged.select('PRAGMA user_version').first['user_version'], 4);
      expect(
        unchanged
            .select("SELECT value FROM app_settings WHERE key = 'theme'")
            .first['value'],
        'dark',
      );
      expect(
        unchanged.select(
          "SELECT name FROM sqlite_master WHERE name = 'habit_occurrences'",
        ),
        isEmpty,
      );
    },
  );
}

void _removeV5Schema(Database db) {
  db.execute('DROP TABLE habit_counter_events');
  db.execute('DROP TRIGGER habit_versions_protect_occurrences');
  db.execute('DROP TRIGGER habit_counter_targets_protect_update');
  db.execute('DROP TRIGGER habit_counter_targets_protect_delete');
  db.execute('DROP TABLE habit_occurrences');
}
