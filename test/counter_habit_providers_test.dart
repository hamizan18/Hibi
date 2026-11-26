import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/application/counter_habit_providers.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_starter_template.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('Riverpod providers inject isolated database and clock across creation, logging, resolution, recovery and roster/history queries', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(clock),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(counterTodayRosterProvider.future), isEmpty);

    final writer = container.read(counterHabitWriterProvider);
    await writer.createFromStarterTemplate(
      template: CounterStarterTemplate.quranReading,
      habitId: 'h_quran',
      versionId: 'v_quran',
      auditId: 'a_quran',
      lifecycleEventId: 'l_quran',
      effectiveDate: DateTime(2026, 11, 26),
    );

    final detail = await container
        .read(habitApplicabilityReaderProvider)
        .describe('h_quran', LocalDate(2026, 11, 26));
    expect(detail.reason, HabitApplicabilityReason.applicable);

    final actions = container.read(counterTodayActionServiceProvider);
    await actions.recordTodayProgress(
      habitId: 'h_quran',
      occurrenceId: 'o_26',
      eventId: 'e_26',
      quantity: 2,
    );
    await actions.resolveToday(
      habitId: 'h_quran',
      occurrenceId: 'o_26',
      resolutionId: 'r_26',
      state: CounterResolutionState.failed,
      reason: 'Incomplete',
    );

    container.invalidate(counterTodayRosterProvider);
    final nov26Roster = await container.read(counterTodayRosterProvider.future);
    expect(
      nov26Roster.single.evaluation.effectiveStatus,
      CounterDayEffectiveStatus.failed,
    );

    // Advance clock to Nov 27 and recover remaining 3 pages
    clock.current = DateTime(2026, 11, 27, 10);
    final historyReader = container.read(counterHistoryReaderProvider);
    final deficits = await historyReader.findRecoverableDeficits(
      habitId: 'h_quran',
      asOfDate: LocalDate(2026, 11, 27),
    );
    expect(deficits.single.remainingDeficit, 3);

    await actions.recoverPriorDeficit(
      recoveryId: 'rec_27',
      occurrenceId: 'o_26',
      quantity: 3,
    );

    final nov26Evaluation = await container.read(
      counterDayRosterProvider(LocalDate(2026, 11, 26)).future,
    );
    expect(
      nov26Evaluation.single.evaluation.effectiveStatus,
      CounterDayEffectiveStatus.recovered,
    );

    container.invalidate(counterTodayRosterProvider);
    final nov27Roster = await container.read(counterTodayRosterProvider.future);
    expect(
      nov27Roster.single.evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(nov27Roster.single.evaluation.hasOccurrence, isFalse);
  });
}
