import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test('Boolean and Duration (manual + timer) habits persist and evaluate progress deterministically', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final service = BooleanDurationHabitService(db, FixedClock());

    await service.createBoolean(
      habitId: 'h_bool',
      versionId: 'v_bool',
      lifecycleEventId: 'l_bool',
      name: 'Morning Stretch',
      effectiveDate: DateTime(2026, 11, 26),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    expect(
      await service.readBooleanDay(
        habitId: 'h_bool',
        date: LocalDate(2026, 11, 26),
      ),
      isNull,
    );
    await service.logBooleanToday(
      habitId: 'h_bool',
      occurrenceId: 'o_bool',
      logId: 'log_bool',
      state: BooleanLogState.completed,
    );
    expect(
      await service.readBooleanDay(
        habitId: 'h_bool',
        date: LocalDate(2026, 11, 26),
      ),
      BooleanLogState.completed,
    );

    // Duration habit: target 1800 seconds (30 minutes)
    await service.createDuration(
      habitId: 'h_dur',
      versionId: 'v_dur',
      lifecycleEventId: 'l_dur',
      name: 'Deep Study',
      effectiveDate: DateTime(2026, 11, 26),
      target: DurationTarget(targetSeconds: 1800),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );

    // 600s manual entry -> partial
    final afterManual = await service.recordDurationEntryToday(
      habitId: 'h_dur',
      occurrenceId: 'o_dur',
      eventId: 'ev_manual',
      entry: DurationEntryInput.manual(durationSeconds: 600),
    );
    expect(afterManual.status, DurationEffectiveStatus.partial);
    expect(afterManual.totalSeconds, 600);

    // 1200s timer entry -> completed (1800s total)
    final afterTimer = await service.recordDurationEntryToday(
      habitId: 'h_dur',
      occurrenceId: 'o_dur',
      eventId: 'ev_timer',
      entry: DurationEntryInput.timer(
        startedAtUtc: DateTime.utc(2026, 11, 26, 10, 0),
        endedAtUtc: DateTime.utc(2026, 11, 26, 10, 20),
      ),
    );
    expect(afterTimer.status, DurationEffectiveStatus.completed);
    expect(afterTimer.totalSeconds, 1800);
  });
}
