import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test('Measurement, Time-of-Day and Range-based habits validate fixed-scale integer targets and evaluate logged values', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final service = MeasurementTimeRangeHabitService(db, FixedClock());

    // 1. Measurement: at least 2.50 L (scaled 250, decimalPlaces 2)
    await service.createMeasurement(
      habitId: 'h_meas',
      versionId: 'v_meas',
      lifecycleEventId: 'l_meas',
      name: 'Water Intake',
      effectiveDate: DateTime(2026, 11, 26),
      target: MeasurementTarget(
        scaledTarget: 250,
        decimalPlaces: 2,
        unit: 'L',
        rule: MeasurementComparisonRule.atLeast,
      ),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    final measStatus = await service.logMeasurementToday(
      habitId: 'h_meas',
      occurrenceId: 'o_meas',
      logId: 'log_meas',
      scaledValue: 275,
    );
    expect(measStatus, TypedValueStatus.completed);

    // 2. Time-of-Day: wake up at or before 05:30 (330 minutes since midnight)
    await service.createTimeOfDay(
      habitId: 'h_time',
      versionId: 'v_time',
      lifecycleEventId: 'l_time',
      name: 'Early Wake',
      effectiveDate: DateTime(2026, 11, 26),
      target: TimeOfDayTarget(
        targetMinutesSinceMidnight: 330,
        rule: TimeComparisonRule.atOrBefore,
      ),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    final timeStatus = await service.logTimeOfDayToday(
      habitId: 'h_time',
      occurrenceId: 'o_time',
      logId: 'log_time',
      minutesSinceMidnight: 345, // 05:45 -> failed
    );
    expect(timeStatus, TypedValueStatus.failed);

    // 3. Range: sleep 7.0 to 8.5 hours (scaled 70..85, decimalPlaces 1)
    await service.createRange(
      habitId: 'h_range',
      versionId: 'v_range',
      lifecycleEventId: 'l_range',
      name: 'Sleep Duration',
      effectiveDate: DateTime(2026, 11, 26),
      target: RangeTarget(
        minScaled: 70,
        maxScaled: 85,
        decimalPlaces: 1,
        unit: 'hours',
      ),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    final rangeStatus = await service.logRangeToday(
      habitId: 'h_range',
      occurrenceId: 'o_range',
      logId: 'log_range',
      scaledValue: 75,
    );
    expect(rangeStatus, TypedValueStatus.completed);
  });
}
