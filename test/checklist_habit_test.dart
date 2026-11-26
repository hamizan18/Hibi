import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('Daily Prayers / S starter template creates independent checklist items, logs partial/failed statuses and recovers prior failed items', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 6));
    final service = ChecklistHabitService(db, clock);

    await service.createFromStarterTemplate(
      template: ChecklistStarterTemplate.dailyPrayers,
      habitId: 'h_prayers',
      versionId: 'v_prayers',
      lifecycleEventId: 'l_prayers',
      itemIds: const ['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'],
      effectiveDate: DateTime(2026, 11, 26),
    );

    // Before any log, occurrence is absent
    final initial = await service.readDay(
      habitId: 'h_prayers',
      date: LocalDate(2026, 11, 26),
    );
    expect(initial.occurrenceId, isNull);
    expect(initial.progress, isNull);

    // Log 4 completed and 1 failed (Isha)
    for (final item in ['fajr', 'dhuhr', 'asr', 'maghrib']) {
      await service.logItemToday(
        habitId: 'h_prayers',
        occurrenceId: 'o_26',
        logId: 'log_$item',
        itemId: item,
        state: ChecklistItemLogState.completed,
      );
    }
    final partial = await service.logItemToday(
      habitId: 'h_prayers',
      occurrenceId: 'o_26',
      logId: 'log_isha',
      itemId: 'isha',
      state: ChecklistItemLogState.failed,
      reason: 'Slept early',
    );
    expect(partial.progress!.status, ChecklistOccurrenceStatus.partial);
    expect(partial.progress!.completedCount, 4);
    expect(partial.progress!.failedCount, 1);

    // Same-day recovery is rejected
    await expectLater(
      service.recoverFailedItem(
        recoveryId: 'rec_same_day',
        occurrenceId: 'o_26',
        itemId: 'isha',
      ),
      throwsStateError,
    );

    // Next day (Nov 27): recover Isha from Nov 26
    clock.current = DateTime(2026, 11, 27, 7);
    final recoveredView = await service.recoverFailedItem(
      recoveryId: 'rec_isha',
      occurrenceId: 'o_26',
      itemId: 'isha',
      note: 'Made up in the morning',
    );
    expect(recoveredView.progress!.status, ChecklistOccurrenceStatus.recovered);
    expect(recoveredView.progress!.completedCount, 4);
    expect(recoveredView.progress!.recoveredCount, 1);
    expect(recoveredView.progress!.failedCount, 0);

    // Today (Nov 27) still has no fabricated checklist occurrence
    final nov27 = await service.readDay(
      habitId: 'h_prayers',
      date: LocalDate(2026, 11, 27),
    );
    expect(nov27.occurrenceId, isNull);
  });
}
