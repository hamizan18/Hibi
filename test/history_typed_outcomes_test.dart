import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/data/unified_habit_history_reader.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';

class _Clock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test('history reads recorded typed outcomes without writing', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock();
    final date = LocalDate(2026, 11, 26);
    final schedule = DailySchedule(start: date);
    final metadata = HabitMetadata(category: 'Test', isPrivate: false);
    final typed = BooleanDurationHabitService(db, clock);
    final numeric = MeasurementTimeRangeHabitService(db, clock);
    await typed.createBoolean(
      habitId: 'b',
      versionId: 'vb',
      lifecycleEventId: 'lb',
      name: 'Boolean',
      effectiveDate: clock.now(),
      schedule: schedule,
      metadata: metadata,
    );
    await typed.logBooleanToday(
      habitId: 'b',
      occurrenceId: 'ob',
      logId: 'eb',
      state: BooleanLogState.completed,
    );
    await typed.createDuration(
      habitId: 'd',
      versionId: 'vd',
      lifecycleEventId: 'ld',
      name: 'Duration',
      effectiveDate: clock.now(),
      target: DurationTarget(targetSeconds: 100),
      schedule: schedule,
      metadata: metadata,
    );
    await typed.recordDurationEntryToday(
      habitId: 'd',
      occurrenceId: 'od',
      eventId: 'ed',
      entry: DurationEntryInput.manual(durationSeconds: 50),
    );
    await numeric.createMeasurement(
      habitId: 'm',
      versionId: 'vm',
      lifecycleEventId: 'lm',
      name: 'Measure',
      effectiveDate: clock.now(),
      target: MeasurementTarget(
        scaledTarget: 20,
        decimalPlaces: 1,
        unit: 'L',
        rule: MeasurementComparisonRule.atLeast,
      ),
      schedule: schedule,
      metadata: metadata,
    );
    await numeric.logMeasurementToday(
      habitId: 'm',
      occurrenceId: 'om',
      logId: 'em',
      scaledValue: 20,
    );
    await numeric.createTimeOfDay(
      habitId: 't',
      versionId: 'vt',
      lifecycleEventId: 'lt',
      name: 'Time',
      effectiveDate: clock.now(),
      target: TimeOfDayTarget(
        targetMinutesSinceMidnight: 480,
        rule: TimeComparisonRule.atOrBefore,
      ),
      schedule: schedule,
      metadata: metadata,
    );
    await numeric.logTimeOfDayToday(
      habitId: 't',
      occurrenceId: 'ot',
      logId: 'et',
      minutesSinceMidnight: 470,
    );
    await numeric.createRange(
      habitId: 'r',
      versionId: 'vr',
      lifecycleEventId: 'lr',
      name: 'Range',
      effectiveDate: clock.now(),
      target: RangeTarget(
        minScaled: 10,
        maxScaled: 20,
        decimalPlaces: 0,
        unit: 'units',
      ),
      schedule: schedule,
      metadata: metadata,
    );
    await numeric.logRangeToday(
      habitId: 'r',
      occurrenceId: 'or',
      logId: 'er',
      scaledValue: 15,
    );
    final before =
        (await db.customSelect('SELECT total_changes() AS n').getSingle())
            .read<int>('n');
    final evaluations = await UnifiedHabitHistoryReader(db).readDay(date: date);
    final byHabit = {for (final item in evaluations) item.habitId: item};
    expect(byHabit['b']!.status, HabitAnalyticsStatus.completed);
    expect(byHabit['d']!.status, HabitAnalyticsStatus.partial);
    expect(byHabit['d']!.partialRatio, 0.5);
    expect(byHabit['m']!.status, HabitAnalyticsStatus.completed);
    expect(byHabit['t']!.status, HabitAnalyticsStatus.completed);
    expect(byHabit['r']!.status, HabitAnalyticsStatus.completed);
    expect(
      (await db.customSelect('SELECT total_changes() AS n').getSingle())
          .read<int>('n'),
      before,
    );
  });
}
