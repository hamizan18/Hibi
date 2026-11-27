import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'version 1 migrates without losing settings and survives reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hibi_migration_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(path.join(directory.path, 'database.sqlite'));
      final legacy = sqlite3.open(file.path);
      legacy.execute(
        'CREATE TABLE app_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
      );
      legacy.execute("INSERT INTO app_settings VALUES ('theme', 'dark')");
      legacy.execute('PRAGMA user_version = 1');
      legacy.close();

      final migrated = AppDatabase(NativeDatabase(file));
      expect(await migrated.getSetting('theme'), 'dark');
      await migrated.customStatement(
        "INSERT INTO habits VALUES ('habit-1', 100)",
      );
      await migrated.customStatement(
        "INSERT INTO habit_versions VALUES ('v1', 'habit-1', 'Original', '2026-11-18', '2026-12-01', 100, 1)",
      );
      await migrated.close();

      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(await reopened.getSetting('theme'), 'dark');
      expect(
        (await reopened.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        13,
      );
      expect(
        (await reopened
                .customSelect("SELECT name FROM habit_versions WHERE id = 'v1'")
                .getSingle())
            .read<String>('name'),
        'Original',
      );
    },
  );

  test(
    'failed version 1 migration rolls back and preserves the original data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hibi_migration_failure_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(path.join(directory.path, 'database.sqlite'));
      final legacy = sqlite3.open(file.path);
      legacy.execute(
        'CREATE TABLE app_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
      );
      legacy.execute("INSERT INTO app_settings VALUES ('theme', 'dark')");
      legacy.execute('CREATE TABLE habit_versions (id TEXT)');
      legacy.execute('PRAGMA user_version = 1');
      legacy.close();

      final database = AppDatabase(NativeDatabase(file));
      await expectLater(
        database.getSetting('theme'),
        throwsA(isA<Exception>()),
      );
      await database.close();
      final unchanged = sqlite3.open(file.path);
      addTearDown(unchanged.close);
      expect(unchanged.select('PRAGMA user_version').first['user_version'], 1);
      expect(
        unchanged
            .select("SELECT value FROM app_settings WHERE key = 'theme'")
            .first['value'],
        'dark',
      );
      expect(
        unchanged.select(
          "SELECT name FROM sqlite_master WHERE name = 'habits'",
        ),
        isEmpty,
      );
    },
  );

  test('version intervals preserve history and reject invalid changes', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customStatement(
      "INSERT INTO habits VALUES ('habit-1', 100), ('habit-2', 101)",
    );
    await database.customStatement(
      "INSERT INTO habit_versions VALUES ('v1', 'habit-1', 'Original', '2026-11-18', '2026-12-01', 100, 1)",
    );
    await database.customStatement(
      "INSERT INTO habit_versions VALUES ('v2', 'habit-1', 'Updated', '2026-12-01', NULL, 200, 2)",
    );
    await database.customStatement(
      "INSERT INTO habit_versions VALUES ('other', 'habit-2', 'Other', '2026-11-18', NULL, 100, 1)",
    );
    final historical = await database
        .customSelect(
          "SELECT name FROM habit_versions WHERE habit_id = 'habit-1' AND effective_start <= '2026-11-19' AND (effective_end IS NULL OR '2026-11-19' < effective_end)",
        )
        .getSingle();
    expect(historical.read<String>('name'), 'Original');
    final future = await database
        .customSelect(
          "SELECT name FROM habit_versions WHERE habit_id = 'habit-1' AND effective_start <= '2026-12-01' AND (effective_end IS NULL OR '2026-12-01' < effective_end)",
        )
        .getSingle();
    expect(future.read<String>('name'), 'Updated');
    final invalid = [
      "INSERT INTO habit_versions VALUES ('overlap', 'habit-1', 'Bad', '2026-11-30', '2026-12-02', 100, 3)",
      "INSERT INTO habit_versions VALUES ('open', 'habit-1', 'Bad', '2027-01-01', NULL, 100, 3)",
      "INSERT INTO habit_versions VALUES ('invalid', 'habit-1', 'Bad', '2026-02-30', NULL, 100, 3)",
      "INSERT INTO habit_versions VALUES ('invalid2', 'habit-1', 'Bad', '2026-01-01', '2026-01-01', 100, 3)",
      "INSERT INTO habit_versions VALUES ('orphan', 'missing', 'Bad', '2026-01-01', NULL, 100, 1)",
      "INSERT INTO habit_versions VALUES ('revision', 'habit-1', 'Bad', '2025-01-01', '2025-02-01', 100, 1)",
      "UPDATE habit_versions SET effective_end = '2026-12-02' WHERE id = 'v1'",
      "UPDATE habit_versions SET habit_id = 'habit-2' WHERE id = 'v1'",
    ];
    for (final statement in invalid) {
      await expectLater(
        database.customStatement(statement),
        throwsA(isA<Exception>()),
        reason: statement,
      );
    }
    expect(
      (await database
              .customSelect('SELECT COUNT(*) AS total FROM habit_versions')
              .getSingle())
          .read<int>('total'),
      3,
    );
  });
}
