import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/habit_schedule_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

Future<void> createHabit(CounterHabitWriter writer) => writer.create(
  habitId: 'h',
  versionId: 'v1',
  auditId: 'a1',
  lifecycleEventId: 'l1',
  name: 'Read',
  effectiveDate: DateTime(2026, 11, 26),
  target: CounterTarget(count: 5, unit: 'pages'),
  schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
);

Future<void> appendVersion(
  CounterHabitWriter writer, {
  String auditId = 'a2',
  HabitSchedule? schedule,
}) => writer.scheduleVersion(
  habitId: 'h',
  versionId: 'v2',
  auditId: auditId,
  name: 'Read more',
  effectiveDate: DateTime(2026, 12, 1),
  target: CounterTarget(count: 20, unit: 'pages'),
  schedule:
      schedule ??
      WeekdaySchedule(start: LocalDate(2026, 11, 26), weekdays: {5, 2}),
);

void main() {
  test('future version preserves historical schedule and audits both configurations', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final writer = CounterHabitWriter(db, FixedClock());
    await createHabit(writer);
    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('o', 'h', 'v1', '2026-11-30', 5, 'pages')",
    );
    await appendVersion(writer);
    final reader = HabitApplicabilityReader(db);
    expect(
      await reader.evaluate('h', LocalDate(2026, 11, 30)),
      HabitApplicability.applicable,
    );
    expect(
      await reader.evaluate('h', LocalDate(2026, 12, 1)),
      HabitApplicability.applicable,
    );
    expect(
      await reader.evaluate('h', LocalDate(2026, 12, 2)),
      HabitApplicability.notApplicable,
    );
    expect(
      await HabitScheduleStore(db).findForVersion('v1'),
      isA<DailySchedule>(),
    );
    expect(
      (await HabitScheduleStore(
        db,
      ).findForVersion('v2') as WeekdaySchedule).weekdays,
      {2, 5},
    );
    final occurrence = await db
        .customSelect(
          "SELECT habit_version_id, target_count FROM habit_occurrences WHERE id = 'o'",
        )
        .getSingle();
    expect(occurrence.read<String>('habit_version_id'), 'v1');
    expect(occurrence.read<int>('target_count'), 5);
    final audit = await db
        .customSelect(
          "SELECT previous_values, updated_values FROM habit_version_audit WHERE id = 'a2'",
        )
        .getSingle();
    final before = jsonDecode(
      audit.read<String>('previous_values'),
    ) as Map<String, dynamic>;
    final after = jsonDecode(
      audit.read<String>('updated_values'),
    ) as Map<String, dynamic>;
    expect(before['schedule']['recurrence'], 'daily');
    expect(after['closed_version']['schedule'], before['schedule']);
    expect(after['new_version']['schedule'], {
      'recurrence': 'weekdays',
      'start_date': '2026-11-26',
      'end_exclusive': null,
      'weekdays': [2, 5],
    });
  });

  test(
    'legacy missing schedule stays missing and is audited as unknown',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v1', 'h', 'Read', '2026-11-26', NULL, 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_counter_targets VALUES ('v1', 5, 'pages')",
      );
      await appendVersion(CounterHabitWriter(db, FixedClock()));
      expect(await HabitScheduleStore(db).findForVersion('v1'), isNull);
      final row = await db
          .customSelect(
            "SELECT previous_values FROM habit_version_audit WHERE id = 'a2'",
          )
          .getSingle();
      expect(
        (jsonDecode(row.read<String>('previous_values'))
            as Map<String, dynamic>)['schedule'],
        isNull,
      );
    },
  );

  test(
    'schedule and audit failures roll back version, target and old boundary',
    () async {
      for (final failSchedule in [true, false]) {
        final db = AppDatabase(NativeDatabase.memory());
        try {
          final writer = CounterHabitWriter(db, FixedClock());
          await createHabit(writer);
          if (failSchedule) {
            await db.customStatement(
              "CREATE TRIGGER reject_new_schedule BEFORE INSERT ON habit_schedules WHEN NEW.habit_version_id = 'v2' BEGIN SELECT RAISE(ABORT, 'injected'); END",
            );
          }
          await expectLater(
            appendVersion(writer, auditId: failSchedule ? 'a2' : 'a1'),
            throwsA(isA<Exception>()),
          );
          final versions = await db
              .customSelect('SELECT id, effective_end FROM habit_versions')
              .get();
          expect(versions.length, 1);
          expect(versions.single.readNullable<String>('effective_end'), isNull);
          for (final table in [
            'habit_counter_targets',
            'habit_schedules',
            'habit_version_audit',
          ]) {
            final row = await db
                .customSelect('SELECT COUNT(*) AS n FROM $table')
                .getSingle();
            expect(row.read<int>('n'), 1, reason: table);
          }
        } finally {
          await db.close();
        }
      }
    },
  );

  test(
    'expired schedule and existing later occurrence cannot alter history',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final writer = CounterHabitWriter(db, FixedClock());
      await createHabit(writer);
      await expectLater(
        appendVersion(
          writer,
          schedule: DailySchedule(
            start: LocalDate(2026, 11, 26),
            endExclusive: LocalDate(2026, 12, 1),
          ),
        ),
        throwsArgumentError,
      );
      await db.customStatement(
        "INSERT INTO habit_occurrences VALUES ('o', 'h', 'v1', '2026-12-01', 5, 'pages')",
      );
      await expectLater(appendVersion(writer), throwsA(isA<Exception>()));
      final version = await db
          .customSelect(
            "SELECT effective_end FROM habit_versions WHERE id = 'v1'",
          )
          .getSingle();
      expect(version.readNullable<String>('effective_end'), isNull);
      expect(await HabitScheduleStore(db).findForVersion('v2'), isNull);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_version_audit')
                .getSingle())
            .read<int>('n'),
        1,
      );
    },
  );
}
