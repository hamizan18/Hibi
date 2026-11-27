import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/data/non_counter_version_service.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';

class MutableClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 9);
  @override
  DateTime now() => current;
}

void main() {
  test('schedules future versions and records before/after audits for all 7 non-counter tracking types while preserving historical occurrences', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock();
    final nov26 = LocalDate(2026, 11, 26);
    final nov28 = LocalDate(2026, 11, 28);
    final nov28Dt = DateTime(2026, 11, 28);

    final checklist = ChecklistHabitService(db, clock);
    final avoidance = AvoidanceHabitService(db, clock);
    final boolDur = BooleanDurationHabitService(db, clock);
    final numTimeRange = MeasurementTimeRangeHabitService(db, clock);
    final scheduler = NonCounterVersionService(db, clock);

    // 1. Checklist
    await checklist.create(
      habitId: 'h_chk',
      versionId: 'v_chk_1',
      lifecycleEventId: 'l_chk_1',
      name: 'Morning Checklist',
      effectiveDate: DateTime(2026, 11, 26),
      items: [
        ChecklistItemDefinition(
          id: 'i1',
          label: 'Fajr',
          displayOrder: 0,
          recoveryEnabled: true,
        ),
      ],
      schedule: DailySchedule(start: nov26),
    );
    await checklist.logItemToday(
      habitId: 'h_chk',
      occurrenceId: 'occ_chk_26',
      logId: 'log_chk_1',
      itemId: 'i1',
      state: ChecklistItemLogState.completed,
    );
    await scheduler.scheduleChecklistVersion(
      habitId: 'h_chk',
      versionId: 'v_chk_2',
      auditId: 'aud_chk_2',
      name: 'Morning Checklist v2',
      effectiveDate: nov28Dt,
      items: [
        ChecklistItemDefinition(
          id: 'i2_1',
          label: 'Fajr',
          displayOrder: 0,
          recoveryEnabled: true,
        ),
        ChecklistItemDefinition(
          id: 'i2_2',
          label: 'Duha',
          displayOrder: 1,
          recoveryEnabled: true,
        ),
      ],
      schedule: DailySchedule(start: nov28),
      metadata: HabitMetadata(category: 'Spiritual', recoveryEnabled: true),
    );

    final chkDay26 = await checklist.readDay(habitId: 'h_chk', date: nov26);
    expect(chkDay26.progress!.items.length, 1);
    expect(chkDay26.progress!.completedCount, 1);
    final chkConfig = await scheduler.readConfigurationAndAudit(
      habitId: 'h_chk',
      asOfDate: nov26,
    );
    expect(chkConfig.effectiveVersion!.checklistItems!.length, 1);
    expect(chkConfig.futureVersions.single.checklistItems!.length, 2);
    expect(chkConfig.versionAudits.length, 2);
    expect(chkConfig.versionAudits.last.operation, 'schedule_version');
    expect(
      chkConfig.versionAudits.last.updatedValues.containsKey('new_version'),
      isTrue,
    );

    // 2. Avoidance
    await avoidance.create(
      habitId: 'h_av',
      versionId: 'v_av_1',
      lifecycleEventId: 'l_av_1',
      name: 'No Late Sugar',
      effectiveDate: DateTime(2026, 11, 26),
      target: AvoidanceTarget(maxIncidents: 1),
      schedule: DailySchedule(start: nov26),
    );
    await scheduler.scheduleAvoidanceVersion(
      habitId: 'h_av',
      versionId: 'v_av_2',
      auditId: 'aud_av_2',
      name: 'Zero Late Sugar',
      effectiveDate: nov28Dt,
      target: AvoidanceTarget(maxIncidents: 0),
      schedule: DailySchedule(start: nov28),
    );
    final avConfig = await scheduler.readConfigurationAndAudit(
      habitId: 'h_av',
      asOfDate: nov26,
    );
    expect(avConfig.effectiveVersion!.avoidanceTarget!.maxIncidents, 1);
    expect(avConfig.futureVersions.single.avoidanceTarget!.maxIncidents, 0);

    // Avoidance rejects recoveryEnabled metadata
    await expectLater(
      () => scheduler.scheduleAvoidanceVersion(
        habitId: 'h_av',
        versionId: 'v_av_3',
        auditId: 'aud_av_3',
        name: 'Invalid',
        effectiveDate: DateTime(2026, 11, 29),
        target: AvoidanceTarget(maxIncidents: 0),
        schedule: DailySchedule(start: LocalDate(2026, 11, 29)),
        metadata: HabitMetadata(category: 'Health', recoveryEnabled: true),
      ),
      throwsArgumentError,
    );

    // 3. Boolean
    await boolDur.createBoolean(
      habitId: 'h_bool',
      versionId: 'v_bool_1',
      lifecycleEventId: 'l_bool_1',
      name: 'Journal Entry',
      effectiveDate: DateTime(2026, 11, 26),
      schedule: DailySchedule(start: nov26),
    );
    await scheduler.scheduleBooleanVersion(
      habitId: 'h_bool',
      versionId: 'v_bool_2',
      auditId: 'aud_bool_2',
      name: 'Evening Journal',
      effectiveDate: nov28Dt,
      schedule: WeekdaySchedule(start: nov28, weekdays: const {1, 3, 5}),
    );

    // 4. Duration
    await boolDur.createDuration(
      habitId: 'h_dur',
      versionId: 'v_dur_1',
      lifecycleEventId: 'l_dur_1',
      name: 'Deep Focus',
      effectiveDate: DateTime(2026, 11, 26),
      target: DurationTarget(targetSeconds: 1800),
      schedule: DailySchedule(start: nov26),
    );
    await scheduler.scheduleDurationVersion(
      habitId: 'h_dur',
      versionId: 'v_dur_2',
      auditId: 'aud_dur_2',
      name: 'Deep Focus 45m',
      effectiveDate: nov28Dt,
      target: DurationTarget(targetSeconds: 2700),
      schedule: DailySchedule(start: nov28),
    );

    // 5. Measurement
    await numTimeRange.createMeasurement(
      habitId: 'h_meas',
      versionId: 'v_meas_1',
      lifecycleEventId: 'l_meas_1',
      name: 'Hydration',
      effectiveDate: DateTime(2026, 11, 26),
      target: MeasurementTarget(
        scaledTarget: 20,
        decimalPlaces: 1,
        unit: 'L',
        rule: MeasurementComparisonRule.atLeast,
      ),
      schedule: DailySchedule(start: nov26),
    );
    await scheduler.scheduleMeasurementVersion(
      habitId: 'h_meas',
      versionId: 'v_meas_2',
      auditId: 'aud_meas_2',
      name: 'Hydration 2.5L',
      effectiveDate: nov28Dt,
      target: MeasurementTarget(
        scaledTarget: 25,
        decimalPlaces: 1,
        unit: 'L',
        rule: MeasurementComparisonRule.atLeast,
      ),
      schedule: DailySchedule(start: nov28),
    );

    // 6. Time of day
    await numTimeRange.createTimeOfDay(
      habitId: 'h_tod',
      versionId: 'v_tod_1',
      lifecycleEventId: 'l_tod_1',
      name: 'Wake Up',
      effectiveDate: DateTime(2026, 11, 26),
      target: TimeOfDayTarget(
        targetMinutesSinceMidnight: 360,
        rule: TimeComparisonRule.atOrBefore,
      ),
      schedule: DailySchedule(start: nov26),
    );
    await scheduler.scheduleTimeOfDayVersion(
      habitId: 'h_tod',
      versionId: 'v_tod_2',
      auditId: 'aud_tod_2',
      name: 'Wake Up 05:30',
      effectiveDate: nov28Dt,
      target: TimeOfDayTarget(
        targetMinutesSinceMidnight: 330,
        rule: TimeComparisonRule.atOrBefore,
      ),
      schedule: DailySchedule(start: nov28),
    );

    // 7. Range
    await numTimeRange.createRange(
      habitId: 'h_rng',
      versionId: 'v_rng_1',
      lifecycleEventId: 'l_rng_1',
      name: 'Sleep Hours',
      effectiveDate: DateTime(2026, 11, 26),
      target: RangeTarget(
        minScaled: 70,
        maxScaled: 80,
        decimalPlaces: 1,
        unit: 'h',
      ),
      schedule: DailySchedule(start: nov26),
    );
    await scheduler.scheduleRangeVersion(
      habitId: 'h_rng',
      versionId: 'v_rng_2',
      auditId: 'aud_rng_2',
      name: 'Sleep Hours 7.5-8.5',
      effectiveDate: nov28Dt,
      target: RangeTarget(
        minScaled: 75,
        maxScaled: 85,
        decimalPlaces: 1,
        unit: 'h',
      ),
      schedule: DailySchedule(start: nov28),
    );

    // Rejects same-day version scheduling and mismatched tracking type
    await expectLater(
      () => scheduler.scheduleBooleanVersion(
        habitId: 'h_bool',
        versionId: 'v_bool_bad',
        auditId: 'aud_bad',
        name: 'Same Day',
        effectiveDate: DateTime(2026, 11, 26),
        schedule: DailySchedule(start: nov26),
      ),
      throwsStateError,
    );
    await expectLater(
      () => scheduler.scheduleBooleanVersion(
        habitId: 'h_dur',
        versionId: 'v_dur_mismatch',
        auditId: 'aud_mismatch',
        name: 'Mismatched Type',
        effectiveDate: DateTime(2026, 11, 29),
        schedule: DailySchedule(start: LocalDate(2026, 11, 29)),
      ),
      throwsStateError,
    );
  });
}
