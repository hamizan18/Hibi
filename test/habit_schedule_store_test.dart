import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/features/habits/data/habit_schedule_store.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'test_schema_downgrade.dart';

void main() {
  test(
    'versioned schedules round-trip without altering earlier versions',
    () async {
      final directory = await Directory.systemTemp.createTemp('hibi_schedule_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File(path.join(directory.path, 'test.sqlite'));
      final db = AppDatabase(NativeDatabase(file));
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v1', 'h', 'Read', '2026-11-26', '2026-12-01', 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v2', 'h', 'Read', '2026-12-01', NULL, 2, 2)",
      );
      final store = HabitScheduleStore(db);
      await store.insert(
        'v1',
        DailySchedule(
          start: LocalDate(2026, 11, 26),
          endExclusive: LocalDate(2026, 12, 1),
        ),
      );
      await store.insert(
        'v2',
        WeekdaySchedule(
          start: LocalDate(2026, 11, 26),
          endExclusive: LocalDate(2026, 12, 11),
          weekdays: {1, 4, 7},
        ),
      );
      await db.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      final earlier = await HabitScheduleStore(reopened).findForVersion('v1');
      final later = await HabitScheduleStore(reopened).findForVersion('v2');
      expect(earlier, isA<DailySchedule>());
      expect(earlier!.appliesOn(LocalDate(2026, 11, 30)), isTrue);
      expect(earlier.appliesOn(LocalDate(2026, 12, 1)), isFalse);
      expect(later, isA<WeekdaySchedule>());
      expect((later! as WeekdaySchedule).weekdays, {1, 4, 7});
      expect(later.appliesOn(LocalDate(2026, 12, 3)), isTrue);
      expect(later.appliesOn(LocalDate(2026, 12, 4)), isFalse);
      expect(later.appliesOn(LocalDate(2026, 12, 13)), isFalse);
      expect(
        await HabitScheduleStore(reopened).findForVersion('unknown'),
        isNull,
      );
    },
  );

  test(
    'interval, monthly and one-time schedules round-trip through SQLite',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v_int', 'h', 'Interval', '2026-11-01', '2026-11-10', 1, 1), ('v_m_skip', 'h', 'MonthlySkip', '2026-11-10', '2026-11-20', 1, 2), ('v_m_last', 'h', 'MonthlyLast', '2026-11-20', '2026-11-25', 1, 3), ('v_one', 'h', 'OneTime', '2026-11-26', NULL, 1, 4)",
      );
      final store = HabitScheduleStore(db);
      await store.insert(
        'v_int',
        IntervalSchedule(start: LocalDate(2026, 11, 1), everyDays: 4),
      );
      await store.insert(
        'v_m_skip',
        MonthlyDaySchedule(start: LocalDate(2024, 1, 1), dayOfMonth: 31),
      );
      await store.insert(
        'v_m_last',
        MonthlyDaySchedule(
          start: LocalDate(2024, 1, 1),
          dayOfMonth: 31,
          lastDayFallback: true,
        ),
      );
      await store.insert(
        'v_one',
        OneTimeSchedule(date: LocalDate(2026, 11, 26)),
      );

      final loadedInt =
          (await store.findForVersion('v_int'))! as IntervalSchedule;
      expect(loadedInt.everyDays, 4);
      expect(loadedInt.appliesOn(LocalDate(2026, 11, 5)), isTrue);

      final loadedSkip =
          (await store.findForVersion('v_m_skip'))! as MonthlyDaySchedule;
      expect(loadedSkip.dayOfMonth, 31);
      expect(loadedSkip.lastDayFallback, isFalse);

      final loadedLast =
          (await store.findForVersion('v_m_last'))! as MonthlyDaySchedule;
      expect(loadedLast.dayOfMonth, 31);
      expect(loadedLast.lastDayFallback, isTrue);

      final loadedOne =
          (await store.findForVersion('v_one'))! as OneTimeSchedule;
      expect(loadedOne.date.compareTo(LocalDate(2026, 11, 26)), 0);
    },
  );

  test(
    'database rejects invalid schedules and protects occurrence history',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v1', 'h', 'Read', '2026-11-26', '2026-12-01', 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v2', 'h', 'Read', '2026-12-01', NULL, 2, 2)",
      );
      await db.customStatement(
        "INSERT INTO habit_counter_targets VALUES ('v1', 5, 'pages'), ('v2', 5, 'pages')",
      );
      await HabitScheduleStore(db)
          .insert('v1', DailySchedule(start: LocalDate(2026, 11, 26)));
      final invalid = [
        "INSERT INTO habit_schedules VALUES ('missing', 'daily', '2026-11-26', NULL, NULL)",
        "INSERT INTO habit_schedules VALUES ('v1', 'daily', '2026-11-26', NULL, NULL)",
        "INSERT INTO habit_schedules VALUES ('v2', 'weekdays', '2026-11-26', NULL, 0)",
        "INSERT INTO habit_schedules VALUES ('v2', 'weekdays', '2026-11-26', NULL, 128)",
        "INSERT INTO habit_schedules VALUES ('v2', 'weekdays', '2026-11-26', NULL, 1.5)",
        "INSERT INTO habit_schedules VALUES ('v2', 'daily', '2026-11-26', NULL, 1)",
        "INSERT INTO habit_schedules VALUES ('v2', 'weekdays', '2026-02-30', NULL, 1)",
        "INSERT INTO habit_schedules VALUES ('v2', 'daily', '2026-11-26', '2026-11-26', NULL)",
      ];
      for (final statement in invalid) {
        await expectLater(
          db.customStatement(statement),
          throwsA(isA<Exception>()),
          reason: statement,
        );
      }
      await db.customStatement(
        "INSERT INTO habit_occurrences VALUES ('o1', 'h', 'v1', '2026-11-26', 5, 'pages')",
      );
      await db.customStatement(
        "INSERT INTO habit_occurrences VALUES ('o2', 'h', 'v2', '2026-12-01', 5, 'pages')",
      );
      for (final statement in [
        "UPDATE habit_schedules SET start_date = '2026-11-27' WHERE habit_version_id = 'v1'",
        "DELETE FROM habit_schedules WHERE habit_version_id = 'v1'",
        "INSERT INTO habit_schedules VALUES ('v2', 'daily', '2026-12-01', NULL, NULL)",
      ]) {
        await expectLater(
          db.customStatement(statement),
          throwsA(isA<Exception>()),
          reason: statement,
        );
      }
      expect(
        (await HabitScheduleStore(db).findForVersion('v1'))!
            .appliesOn(LocalDate(2026, 11, 26)),
        isTrue,
      );
      expect(await HabitScheduleStore(db).findForVersion('v2'), isNull);
    },
  );

  test(
    'version 5 migration keeps records and leaves schedules unknown',
    () async {
      final dir = await Directory.systemTemp.createTemp('hibi_schedule_v5_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(path.join(dir.path, 'test.sqlite'));
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
        "INSERT INTO habit_occurrences VALUES ('o', 'h', 'v', '2026-11-26', 5, 'pages')",
      );
      await original.customStatement(
        "INSERT INTO habit_counter_events VALUES ('e', 'o', 2, 1)",
      );
      await original.customStatement(
        "INSERT INTO habit_version_audit VALUES ('a', 'h', 'create', NULL, '{}', 1)",
      );
      await original.close();
      final legacy = sqlite3.open(file.path);
      dropV11Tables(legacy);
      legacy.execute('DROP TABLE habit_counter_recoveries');
      legacy.execute('DROP TABLE habit_counter_resolutions');
      legacy.execute('DROP TABLE habit_counter_event_audit');
      legacy.execute('DROP TABLE habit_lifecycle_events');
      legacy.execute('DROP TABLE habit_schedules');
      legacy.execute('PRAGMA user_version = 5');
      legacy.close();
      final migrated = AppDatabase(NativeDatabase(file));
      addTearDown(migrated.close);
      expect(await migrated.getSetting('theme'), 'dark');
      expect(
        (await migrated
                .customSelect(
                  "SELECT quantity FROM habit_counter_events WHERE id = 'e'",
                )
                .getSingle())
            .read<int>('quantity'),
        2,
      );
      expect(
        (await migrated
                .customSelect(
                  "SELECT operation FROM habit_version_audit WHERE id = 'a'",
                )
                .getSingle())
            .read<String>('operation'),
        'create',
      );
      expect(await HabitScheduleStore(migrated).findForVersion('v'), isNull);
      expect(
        (await migrated.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        17,
      );
    },
  );

  test('failed version 5 migration retains old version and data', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_schedule_failure_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'test.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await original.setSetting('theme', 'dark');
    await original.close();
    final legacy = sqlite3.open(file.path);
    legacy.execute('PRAGMA user_version = 5');
    legacy.close();
    final migrated = AppDatabase(NativeDatabase(file));
    await expectLater(migrated.getSetting('theme'), throwsA(isA<Exception>()));
    await migrated.close();
    final unchanged = sqlite3.open(file.path);
    addTearDown(unchanged.close);
    expect(unchanged.select('PRAGMA user_version').first['user_version'], 5);
    expect(
      unchanged
          .select("SELECT value FROM app_settings WHERE key = 'theme'")
          .first['value'],
      'dark',
    );
  });
}
