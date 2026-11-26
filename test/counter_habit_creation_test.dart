import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/habit_schedule_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;

class ChangingClock implements AppClock {
  int reads = 0;
  @override
  DateTime now() {
    reads++;
    return reads == 1 ? DateTime(2026, 11, 26, 23, 59) : DateTime(2026, 11, 27);
  }
}

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test(
    'explicit schedule and lifecycle are committed and audited together',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = ChangingClock();
      final writer = CounterHabitWriter(db, clock);
      await writer.create(
        habitId: 'h',
        versionId: 'v',
        auditId: 'a',
        lifecycleEventId: 'l',
        name: 'Read',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: WeekdaySchedule(
          start: LocalDate(2026, 11, 26),
          weekdays: {7, 4, 1},
        ),
      );
      expect(clock.reads, 1);
      final schedule = await HabitScheduleStore(db).findForVersion('v');
      expect(schedule, isA<WeekdaySchedule>());
      expect((schedule! as WeekdaySchedule).weekdays, {1, 4, 7});
      final reader = HabitApplicabilityReader(db);
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 25)),
        HabitApplicability.notApplicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 26)),
        HabitApplicability.applicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 27)),
        HabitApplicability.notApplicable,
      );
      final lifecycle = await db
          .customSelect(
            "SELECT state, effective_date, created_at_utc_us FROM habit_lifecycle_events WHERE id = 'l'",
          )
          .getSingle();
      expect(lifecycle.read<String>('state'), 'active');
      expect(lifecycle.read<String>('effective_date'), '2026-11-26');
      final audit = await db
          .customSelect(
            "SELECT updated_values, occurred_at_utc_us FROM habit_version_audit WHERE id = 'a'",
          )
          .getSingle();
      final snapshot = jsonDecode(
        audit.read<String>('updated_values'),
      ) as Map<String, dynamic>;
      expect(snapshot['schedule']['recurrence'], 'weekdays');
      expect(snapshot['schedule']['weekdays'], [1, 4, 7]);
      expect(snapshot['lifecycle']['event_id'], 'l');
      expect(
        lifecycle.read<int>('created_at_utc_us'),
        audit.read<int>('occurred_at_utc_us'),
      );
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
    'future start remains not applicable until its selected start date',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await CounterHabitWriter(db, FixedClock()).create(
        habitId: 'h',
        versionId: 'v',
        auditId: 'a',
        lifecycleEventId: 'l',
        name: 'Read',
        effectiveDate: DateTime(2026, 12, 1),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
      );
      final reader = HabitApplicabilityReader(db);
      expect(
        await reader.evaluate('h', LocalDate(2026, 11, 30)),
        HabitApplicability.notApplicable,
      );
      expect(
        await reader.evaluate('h', LocalDate(2026, 12, 1)),
        HabitApplicability.applicable,
      );
      expect(
        (await db
                .customSelect(
                  "SELECT effective_date FROM habit_lifecycle_events WHERE id = 'l'",
                )
                .getSingle())
            .read<String>('effective_date'),
        '2026-12-01',
      );
    },
  );

  test(
    'schedule, lifecycle and audit failures roll back every newly created row',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final writer = CounterHabitWriter(db, FixedClock());
      final target = CounterTarget(count: 5, unit: 'pages');
      final schedule = DailySchedule(start: LocalDate(2026, 11, 26));
      await writer.create(
        habitId: 'existing',
        versionId: 'ev',
        auditId: 'ea',
        lifecycleEventId: 'el',
        name: 'Existing',
        effectiveDate: DateTime(2026, 11, 26),
        target: target,
        schedule: schedule,
      );
      await expectLater(
        writer.create(
          habitId: 'h1',
          versionId: 'v1',
          auditId: 'a1',
          lifecycleEventId: 'el',
          name: 'Read',
          effectiveDate: DateTime(2026, 11, 26),
          target: target,
          schedule: schedule,
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        writer.create(
          habitId: 'h2',
          versionId: 'v2',
          auditId: 'ea',
          lifecycleEventId: 'l2',
          name: 'Read',
          effectiveDate: DateTime(2026, 11, 26),
          target: target,
          schedule: schedule,
        ),
        throwsA(isA<Exception>()),
      );
      await db.customStatement(
        "CREATE TRIGGER reject_test_schedule BEFORE INSERT ON habit_schedules WHEN NEW.habit_version_id = 'v3' BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      );
      await expectLater(
        writer.create(
          habitId: 'h3',
          versionId: 'v3',
          auditId: 'a3',
          lifecycleEventId: 'l3',
          name: 'Read',
          effectiveDate: DateTime(2026, 11, 26),
          target: target,
          schedule: schedule,
        ),
        throwsA(isA<Exception>()),
      );
      for (final table in [
        'habits',
        'habit_versions',
        'habit_counter_targets',
        'habit_schedules',
        'habit_lifecycle_events',
        'habit_version_audit',
      ]) {
        expect(
          (await db
                  .customSelect('SELECT COUNT(*) AS n FROM $table')
                  .getSingle())
              .read<int>('n'),
          1,
          reason: table,
        );
      }
      expect(
        (await HabitScheduleStore(db).findForVersion('ev'))!
            .appliesOn(LocalDate(2026, 11, 26)),
        isTrue,
      );
    },
  );

  test(
    'expired schedules are rejected and legacy data is not guessed',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final writer = CounterHabitWriter(db, FixedClock());
      await expectLater(
        writer.create(
          habitId: 'h',
          versionId: 'v',
          auditId: 'a',
          lifecycleEventId: 'l',
          name: 'Read',
          effectiveDate: DateTime(2026, 11, 26),
          target: CounterTarget(count: 5, unit: 'pages'),
          schedule: DailySchedule(
            start: LocalDate(2026, 11, 20),
            endExclusive: LocalDate(2026, 11, 26),
          ),
        ),
        throwsArgumentError,
      );
      expect(
        (await db.customSelect('SELECT COUNT(*) AS n FROM habits').getSingle())
            .read<int>('n'),
        0,
      );
      await db.customStatement("INSERT INTO habits VALUES ('legacy', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('old', 'legacy', 'Old', '2026-11-20', NULL, 1, 1)",
      );
      expect(await HabitScheduleStore(db).findForVersion('old'), isNull);
      expect(
        await HabitApplicabilityReader(db)
            .evaluate('legacy', LocalDate(2026, 11, 26)),
        HabitApplicability.unknown,
      );
    },
  );

  test('created configuration remains applicable after database reopen', () async {
    final directory = await Directory.systemTemp.createTemp('hibi_creation_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'test.sqlite'));
    final first = AppDatabase(NativeDatabase(file));
    await CounterHabitWriter(first, FixedClock()).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await first.close();
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      await HabitApplicabilityReader(reopened)
          .evaluate('h', LocalDate(2026, 11, 26)),
      HabitApplicability.applicable,
    );
    expect(
      (await reopened
              .customSelect(
                "SELECT COUNT(*) AS n FROM habit_version_audit WHERE id = 'a'",
              )
              .getSingle())
          .read<int>('n'),
      1,
    );
  });
}
