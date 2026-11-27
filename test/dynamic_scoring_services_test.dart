import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/data/non_counter_version_service.dart';
import 'package:hibi/features/habits/domain/dynamic_normalized_scoring.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';

class _Clock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test(
    'time scoring is versioned and audited, and offsets are persisted',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock();
      final service = MeasurementTimeRangeHabitService(db, clock);
      final before = TimeOfDayTarget(
        targetMinutesSinceMidnight: 60,
        rule: TimeComparisonRule.atOrBefore,
      );
      final after = TimeOfDayTarget(
        targetMinutesSinceMidnight: 60,
        rule: TimeComparisonRule.atOrAfter,
      );
      expect(before.evaluate(61, dayOffset: -1), TypedValueStatus.completed);
      expect(before.evaluate(59, dayOffset: 1), TypedValueStatus.failed);
      expect(after.evaluate(59, dayOffset: 1), TypedValueStatus.completed);
      expect(after.evaluate(61, dayOffset: -1), TypedValueStatus.failed);
      final target = TimeOfDayTarget(
        targetMinutesSinceMidnight: 60,
        rule: TimeComparisonRule.atOrNear,
      );
      await service.createTimeOfDay(
        habitId: 'h',
        versionId: 'v1',
        lifecycleEventId: 'l',
        name: 'Time',
        effectiveDate: DateTime(2026, 11, 26),
        target: target,
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
        scoring: const HabitScoringConfig.timeOfDay(toleranceMinutes: 30),
      );
      expect(target.evaluate(60), TypedValueStatus.completed);
      expect(target.evaluate(61), TypedValueStatus.partial);
      expect(
        await service.logTimeOfDayToday(
          habitId: 'h',
          occurrenceId: 'o',
          logId: 'log',
          minutesSinceMidnight: 61,
          dayOffset: -1,
        ),
        TypedValueStatus.partial,
      );
      final log = await db
          .customSelect('SELECT state, day_offset FROM habit_typed_logs')
          .getSingle();
      expect(log.read<String>('state'), 'partial');
      expect(log.read<int>('day_offset'), -1);

      await NonCounterVersionService(db, clock).scheduleTimeOfDayVersion(
        habitId: 'h',
        versionId: 'v2',
        auditId: 'a',
        name: 'Time',
        effectiveDate: DateTime(2026, 11, 27),
        target: target,
        schedule: DailySchedule(start: LocalDate(2026, 11, 27)),
        scoring: const HabitScoringConfig.timeOfDay(toleranceMinutes: 45),
      );
      final history = await NonCounterVersionService(db, clock)
          .readConfigurationAndAudit(
            habitId: 'h',
            asOfDate: LocalDate(2026, 11, 26),
          );
      expect(history.effectiveVersion!.scoring!.tolerance, 30);
      expect(history.futureVersions.single.scoring!.tolerance, 45);
      expect(
        history.futureVersions.single.timeOfDayTarget!.rule,
        TimeComparisonRule.atOrNear,
      );
      final audits = await db
          .customSelect(
            'SELECT operation, updated_values FROM habit_version_audit',
          )
          .get();
      final creation = jsonDecode(
        audits
            .singleWhere((r) => r.read<String>('operation') == 'create')
            .read<String>('updated_values'),
      ) as Map<String, dynamic>;
      expect(creation['scoring']['tolerance'], 30);
      final scheduled = jsonDecode(
        audits
            .singleWhere(
              (r) => r.read<String>('operation') == 'schedule_version',
            )
            .read<String>('updated_values'),
      ) as Map<String, dynamic>;
      expect(scheduled['new_version']['scoring']['tolerance'], 45);
      expect(scheduled['closed_previous_version']['scoring']['tolerance'], 30);
    },
  );

  test(
    'legacy null config remains unavailable and invalid writes roll back',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock();
      final service = MeasurementTimeRangeHabitService(db, clock);
      final target = MeasurementTarget(
        scaledTarget: 10,
        decimalPlaces: 0,
        unit: 'x',
        rule: MeasurementComparisonRule.atLeast,
      );
      await service.createMeasurement(
        habitId: 'h',
        versionId: 'v',
        lifecycleEventId: 'l',
        name: 'Measure',
        effectiveDate: DateTime(2026, 11, 26),
        target: target,
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      final versions = NonCounterVersionService(db, clock);
      final history = await versions.readConfigurationAndAudit(
        habitId: 'h',
        asOfDate: LocalDate(2026, 11, 26),
      );
      expect(history.effectiveVersion!.scoring, isNull);
      await expectLater(
        versions.scheduleMeasurementVersion(
          habitId: 'h',
          versionId: 'bad',
          auditId: 'audit',
          name: 'Measure',
          effectiveDate: DateTime(2026, 11, 27),
          target: target,
          schedule: DailySchedule(start: LocalDate(2026, 11, 27)),
          scoring: const HabitScoringConfig.range(toleranceScaled: 2),
        ),
        throwsArgumentError,
      );
      final rows = await db
          .customSelect(
            "SELECT id, effective_end FROM habit_versions WHERE habit_id = 'h'",
          )
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.readNullable<String>('effective_end'), isNull);
    },
  );

  test(
    'time offset validation does not create an occurrence and default is zero',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final service = MeasurementTimeRangeHabitService(db, _Clock());
      await service.createTimeOfDay(
        habitId: 'h',
        versionId: 'v',
        lifecycleEventId: 'l',
        name: 'Time',
        effectiveDate: DateTime(2026, 11, 26),
        target: TimeOfDayTarget(
          targetMinutesSinceMidnight: 100,
          rule: TimeComparisonRule.atOrBefore,
        ),
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      await expectLater(
        service.logTimeOfDayToday(
          habitId: 'h',
          occurrenceId: 'bad',
          logId: 'bad',
          minutesSinceMidnight: 100,
          dayOffset: 2,
        ),
        throwsRangeError,
      );
      expect(
        await db.customSelect('SELECT id FROM habit_typed_occurrences').get(),
        isEmpty,
      );
      expect(
        await service.logTimeOfDayToday(
          habitId: 'h',
          occurrenceId: 'o',
          logId: 'log',
          minutesSinceMidnight: 101,
        ),
        TypedValueStatus.failed,
      );
      final log = await db
          .customSelect('SELECT day_offset FROM habit_typed_logs')
          .getSingle();
      expect(log.read<int>('day_offset'), 0);
      await service.createTimeOfDay(
        habitId: 'h2',
        versionId: 'v2',
        lifecycleEventId: 'l2',
        name: 'Time',
        effectiveDate: DateTime(2026, 11, 26),
        target: TimeOfDayTarget(
          targetMinutesSinceMidnight: 100,
          rule: TimeComparisonRule.atOrBefore,
        ),
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      expect(
        await service.logTimeOfDayToday(
          habitId: 'h2',
          occurrenceId: 'o2',
          logId: 'log2',
          minutesSinceMidnight: 101,
          dayOffset: -1,
        ),
        TypedValueStatus.completed,
      );
    },
  );
  test(
    'scoring configuration validates atomically for numeric creation',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final service = MeasurementTimeRangeHabitService(db, _Clock());
      final range = RangeTarget(
        minScaled: 10,
        maxScaled: 20,
        decimalPlaces: 0,
        unit: 'x',
      );
      await expectLater(
        service.createRange(
          habitId: 'bad',
          versionId: 'bad-v',
          lifecycleEventId: 'bad-l',
          name: 'Range',
          effectiveDate: DateTime(2026, 11, 26),
          target: range,
          schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
          scoring: const HabitScoringConfig.range(toleranceScaled: 0),
        ),
        throwsArgumentError,
      );
      expect(await db.customSelect('SELECT id FROM habits').get(), isEmpty);
      await service.createRange(
        habitId: 'r',
        versionId: 'rv',
        lifecycleEventId: 'rl',
        name: 'Range',
        effectiveDate: DateTime(2026, 11, 26),
        target: range,
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
        scoring: const HabitScoringConfig.range(toleranceScaled: 5),
      );
      final snapshot = await NonCounterVersionService(db, _Clock())
          .readConfigurationAndAudit(
            habitId: 'r',
            asOfDate: LocalDate(2026, 11, 26),
          );
      expect(snapshot.effectiveVersion!.scoring!.tolerance, 5);
    },
  );
}
