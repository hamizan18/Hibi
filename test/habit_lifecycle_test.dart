import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/habit_schedule_store.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'test_schema_downgrade.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 1, 12);
}

void main() {
  test(
    'applicability combines version, weekday schedule and lifecycle history',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v1', 'h', 'Read', '2026-11-05', '2026-11-11', 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v2', 'h', 'Read', '2026-11-11', NULL, 2, 2)",
      );
      final schedule = HabitScheduleStore(db);
      await schedule.insert('v1', DailySchedule(start: LocalDate(2026, 11, 5)));
      final reader = HabitApplicabilityReader(db);
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 4)),
        HabitApplicability.notApplicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 5)),
        HabitApplicability.unknown,
      );
      final store = HabitLifecycleStore(db, FixedClock());
      Future<void> append(String id, int day, HabitLifecycleState state) =>
          store.append(
            id: id,
            habitId: 'h',
            effectiveDate: LocalDate(2026, 11, day),
            state: state,
          );
      await append('s', 1, HabitLifecycleState.scheduled);
      await append('a', 5, HabitLifecycleState.active);
      await append('p', 7, HabitLifecycleState.paused);
      await append('r', 10, HabitLifecycleState.active);
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 6)),
        HabitApplicability.applicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 7)),
        HabitApplicability.notApplicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 10)),
        HabitApplicability.applicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 11)),
        HabitApplicability.unknown,
      );
      await schedule.insert(
        'v2',
        WeekdaySchedule(start: LocalDate(2026, 11, 5), weekdays: {1, 3, 4, 6}),
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 11)),
        HabitApplicability.applicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 12)),
        HabitApplicability.applicable,
      );
      await append('ar', 12, HabitLifecycleState.archived);
      await append('d', 14, HabitLifecycleState.deleted);
      await append('restore', 16, HabitLifecycleState.active);
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 12)),
        HabitApplicability.notApplicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 14)),
        HabitApplicability.notApplicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 16)),
        HabitApplicability.applicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 18)),
        HabitApplicability.applicable,
      );
      final event = await db
          .customSelect(
            "SELECT previous_state, state FROM habit_lifecycle_events WHERE id = 'restore'",
          )
          .getSingle();
      expect(event.read<String>('previous_state'), 'deleted');
      expect(event.read<String>('state'), 'active');
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  test(
    'invalid, backdated and history-reinterpreting changes do not write',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-01', NULL, 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_counter_targets VALUES ('v', 5, 'pages')",
      );
      final store = HabitLifecycleStore(db, FixedClock());
      await expectLater(
        store.append(
          id: 'bad',
          habitId: 'h',
          effectiveDate: LocalDate(2026, 11, 1),
          state: HabitLifecycleState.paused,
        ),
        throwsStateError,
      );
      await expectLater(
        store.append(
          id: 'past',
          habitId: 'h',
          effectiveDate: LocalDate(2026, 10, 31),
          state: HabitLifecycleState.active,
        ),
        throwsStateError,
      );
      await store.append(
        id: 'a',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 1),
        state: HabitLifecycleState.active,
        reason: 'start',
      );
      await expectLater(
        store.append(
          id: 'duplicate',
          habitId: 'h',
          effectiveDate: LocalDate(2026, 11, 1),
          state: HabitLifecycleState.paused,
        ),
        throwsStateError,
      );
      await db.customStatement(
        "INSERT INTO habit_occurrences VALUES ('o', 'h', 'v', '2026-11-10', 5, 'pages')",
      );
      await expectLater(
        store.append(
          id: 'p',
          habitId: 'h',
          effectiveDate: LocalDate(2026, 11, 5),
          state: HabitLifecycleState.paused,
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        db.customStatement(
          "UPDATE habit_lifecycle_events SET state = 'paused' WHERE id = 'a'",
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        db.customStatement("DELETE FROM habit_lifecycle_events WHERE id = 'a'"),
        throwsA(isA<Exception>()),
      );
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_lifecycle_events',
                )
                .getSingle())
            .read<int>('n'),
        1,
      );
      expect(
        (await db
                .customSelect(
                  "SELECT reason FROM habit_lifecycle_events WHERE id = 'a'",
                )
                .getSingle())
            .read<String>('reason'),
        'start',
      );
    },
  );

  test(
    'version gaps and missing schedule remain unknown, not failed',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-01', '2026-11-05', 1, 1)",
      );
      await HabitLifecycleStore(db, FixedClock()).append(
        id: 'a',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 1),
        state: HabitLifecycleState.active,
      );
      final reader = HabitApplicabilityReader(db);
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 2)),
        HabitApplicability.unknown,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 5)),
        HabitApplicability.unknown,
      );
      await expectLater(
        reader.evaluate('missing', LocalDate(2026, 11, 2)),
        throwsStateError,
      );
    },
  );

  test(
    'version 6 migration preserves data and does not invent lifecycle events',
    () async {
      final dir = await Directory.systemTemp.createTemp('hibi_lifecycle_v6_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(path.join(dir.path, 'test.sqlite'));
      final original = AppDatabase(NativeDatabase(file));
      await original.setSetting('theme', 'dark');
      await original.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await original.customStatement(
        "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-01', NULL, 1, 1)",
      );
      await HabitScheduleStore(original)
          .insert('v', DailySchedule(start: LocalDate(2026, 11, 1)));
      await original.close();
      final legacy = sqlite3.open(file.path);
      dropV11Tables(legacy);
      legacy.execute('DROP TABLE habit_counter_recoveries');
      legacy.execute('DROP TABLE habit_counter_resolutions');
      legacy.execute('DROP TABLE habit_counter_event_audit');
      legacy.execute('DROP TABLE habit_lifecycle_events');
      legacy.execute('PRAGMA user_version = 6');
      legacy.close();
      final migrated = AppDatabase(NativeDatabase(file));
      expect(await migrated.getSetting('theme'), 'dark');
      expect(
        await HabitApplicabilityReader(migrated)
            .evaluate('h', LocalDate(2026, 11, 2)),
        HabitApplicability.unknown,
      );
      expect(
        (await migrated.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        17,
      );
      await HabitLifecycleStore(migrated, FixedClock()).append(
        id: 'a',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 1),
        state: HabitLifecycleState.active,
      );
      await migrated.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(
        await HabitApplicabilityReader(reopened)
            .evaluate('h', LocalDate(2026, 11, 2)),
        HabitApplicability.applicable,
      );
    },
  );

  test('failed version 6 migration rolls back partial schema and preserves data', () async {
    final dir = await Directory.systemTemp.createTemp(
      'hibi_lifecycle_failure_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'test.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await original.setSetting('theme', 'dark');
    await original.close();
    final legacy = sqlite3.open(file.path);
    legacy.execute('DROP TABLE habit_lifecycle_events');
    legacy.execute(
      'CREATE TRIGGER habit_lifecycle_no_update BEFORE UPDATE ON app_settings BEGIN SELECT 1; END',
    );
    legacy.execute('PRAGMA user_version = 6');
    legacy.close();
    final migrated = AppDatabase(NativeDatabase(file));
    await expectLater(migrated.getSetting('theme'), throwsA(isA<Exception>()));
    await migrated.close();
    final unchanged = sqlite3.open(file.path);
    addTearDown(unchanged.close);
    expect(unchanged.select('PRAGMA user_version').first['user_version'], 6);
    expect(
      unchanged
          .select("SELECT value FROM app_settings WHERE key = 'theme'")
          .first['value'],
      'dark',
    );
    expect(
      unchanged.select(
        "SELECT name FROM sqlite_master WHERE name = 'habit_lifecycle_events'",
      ),
      isEmpty,
    );
  });
}
