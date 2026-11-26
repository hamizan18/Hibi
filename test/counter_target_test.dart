import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/features/habits/data/counter_target_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('counter targets reject nonpositive counts and blank units', () {
    expect(() => CounterTarget(count: 0, unit: 'pages'), throwsRangeError);
    expect(() => CounterTarget(count: -1, unit: 'pages'), throwsRangeError);
    expect(() => CounterTarget(count: 1, unit: '  '), throwsArgumentError);
    final target = CounterTarget(count: 5, unit: ' pages ');
    expect(target.count, 5);
    expect(target.unit, 'pages');
  });

  test(
    'separate versions retain their own exact target and reject invalid SQL',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customStatement("INSERT INTO habits VALUES ('h1', 1)");
      await database.customStatement(
        "INSERT INTO habit_versions VALUES ('v1', 'h1', 'Read', '2026-11-18', '2026-12-01', 1, 1)",
      );
      await database.customStatement(
        "INSERT INTO habit_versions VALUES ('v2', 'h1', 'Read', '2026-12-01', NULL, 2, 2)",
      );
      final store = CounterTargetStore(database);
      await store.insert('v1', CounterTarget(count: 5, unit: 'pages'));
      await store.insert('v2', CounterTarget(count: 20, unit: 'pages'));
      expect((await store.findForVersion('v1'))?.count, 5);
      expect((await store.findForVersion('v2'))?.count, 20);
      expect((await store.findForVersion('v1'))?.unit, 'pages');
      expect(await store.findForVersion('missing'), isNull);
      for (final statement in [
        "INSERT INTO habit_counter_targets VALUES ('missing', 1, 'pages')",
        "INSERT INTO habit_counter_targets VALUES ('v1', 1, 'pages')",
        "UPDATE habit_counter_targets SET target_count = 0 WHERE habit_version_id = 'v1'",
        "UPDATE habit_counter_targets SET target_count = 1.5 WHERE habit_version_id = 'v1'",
        "UPDATE habit_counter_targets SET unit = ' ' WHERE habit_version_id = 'v1'",
      ]) {
        await expectLater(
          database.customStatement(statement),
          throwsA(isA<Exception>()),
          reason: statement,
        );
      }
      expect((await store.findForVersion('v1'))?.count, 5);
    },
  );

  test(
    'version 2 migration preserves versions and never invents targets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hibi_v2_counter_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(path.join(directory.path, 'database.sqlite'));
      final original = AppDatabase(NativeDatabase(file));
      await original.setSetting('theme', 'dark');
      await original.customStatement("INSERT INTO habits VALUES ('h1', 1)");
      await original.customStatement(
        "INSERT INTO habit_versions VALUES ('v1', 'h1', 'Read', '2026-11-18', NULL, 1, 1)",
      );
      await original.close();
      final legacy = sqlite3.open(file.path);
      legacy.execute('DROP TABLE habit_counter_events');
      legacy.execute('DROP TRIGGER habit_versions_protect_occurrences');
      legacy.execute('DROP TABLE habit_occurrences');
      legacy.execute('DROP TABLE habit_counter_targets');
      legacy.execute('DROP TABLE habit_version_audit');
      legacy.execute('PRAGMA user_version = 2');
      legacy.close();

      final migrated = AppDatabase(NativeDatabase(file));
      expect(await migrated.getSetting('theme'), 'dark');
      expect(
        (await migrated
                .customSelect("SELECT name FROM habit_versions WHERE id = 'v1'")
                .getSingle())
            .read<String>('name'),
        'Read',
      );
      expect(await CounterTargetStore(migrated).findForVersion('v1'), isNull);
      expect(
        (await migrated.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        5,
      );
      await CounterTargetStore(migrated)
          .insert('v1', CounterTarget(count: 5, unit: 'pages'));
      await migrated.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(
        (await CounterTargetStore(reopened).findForVersion('v1'))?.count,
        5,
      );
    },
  );

  test('failed version 2 migration rolls back without losing data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hibi_v2_counter_failure_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'database.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await original.setSetting('theme', 'dark');
    await original.close();
    final legacy = sqlite3.open(file.path);
    legacy.execute('PRAGMA user_version = 2');
    legacy.close();

    final migrated = AppDatabase(NativeDatabase(file));
    await expectLater(migrated.getSetting('theme'), throwsA(isA<Exception>()));
    await migrated.close();
    final unchanged = sqlite3.open(file.path);
    addTearDown(unchanged.close);
    expect(unchanged.select('PRAGMA user_version').first['user_version'], 2);
    expect(
      unchanged
          .select("SELECT value FROM app_settings WHERE key = 'theme'")
          .first['value'],
      'dark',
    );
  });
}
