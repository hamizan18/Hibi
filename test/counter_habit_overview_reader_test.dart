import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/application/counter_habit_providers.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_starter_template.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('CounterHabitOverviewReader and Riverpod providers compose configuration, range summary, audit and deficits without writing rows', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 25, 9));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(clock),
      ],
    );
    addTearDown(container.dispose);

    final writer = container.read(counterHabitWriterProvider);
    await writer.createFromStarterTemplate(
      template: CounterStarterTemplate.quranReading,
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      effectiveDate: DateTime(2026, 11, 25),
    );
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v2',
      auditId: 'a2',
      name: 'Quran Reading 10',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
    );

    final actions = container.read(counterTodayActionServiceProvider);
    // Nov 25: completed (5/5)
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_25',
      eventId: 'e_25',
      quantity: 5,
    );

    // Nov 26: failed (2/5 -> deficit 3)
    clock.current = DateTime(2026, 11, 26, 9);
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e_26',
      quantity: 2,
    );
    await actions.resolveToday(
      habitId: 'h',
      occurrenceId: 'o_26',
      resolutionId: 'r_26',
      state: CounterResolutionState.failed,
    );

    // Nov 27: recover 1 page of Nov 26 (remaining deficit 2), leave Nov 27 pending
    clock.current = DateTime(2026, 11, 27, 9);
    await actions.recoverPriorDeficit(
      recoveryId: 'rec_27',
      occurrenceId: 'o_26',
      quantity: 1,
    );

    final overviewReader = container.read(counterHabitOverviewReaderProvider);
    expect(
      () => overviewReader.read(
        habitId: 'h',
        asOfDate: LocalDate(2026, 11, 27),
        rangeStartInclusive: LocalDate(2026, 11, 27),
        rangeEndInclusive: LocalDate(2026, 11, 24),
      ),
      throwsArgumentError,
    );

    final overview = await overviewReader.read(
      habitId: 'h',
      asOfDate: LocalDate(2026, 11, 27),
      rangeStartInclusive: LocalDate(2026, 11, 24),
      rangeEndInclusive: LocalDate(2026, 11, 27),
    );
    expect(overview.configuration.effectiveVersion!.versionId, 'v1');
    expect(overview.configuration.futureVersions.map((v) => v.versionId), [
      'v2',
    ]);
    expect(
      overview.asOfEvaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(overview.asOfEvaluation.hasOccurrence, isFalse);

    // Range: Nov 24 (notApplicable), Nov 25 (completed 5), Nov 26 (failed 2, recovered 1, deficit 2), Nov 27 (pending)
    expect(overview.rangeHistory.length, 4);
    expect(overview.rangeSummary.totalDays, 4);
    expect(overview.rangeSummary.notApplicableDays, 1);
    expect(overview.rangeSummary.applicableDays, 3);
    expect(overview.rangeSummary.completedDays, 1);
    expect(overview.rangeSummary.failedDays, 1);
    expect(overview.rangeSummary.pendingDays, 1);
    expect(overview.rangeSummary.missingOccurrencePendingDays, 1);
    expect(overview.rangeSummary.recordedQuantityTotal, 7);
    expect(overview.rangeSummary.recoveredQuantityTotal, 1);
    expect(overview.rangeSummary.remainingDeficitTotal, 2);

    expect(overview.recoverableDeficits.length, 1);
    expect(overview.recoverableDeficits.single.occurrenceId, 'o_26');
    expect(overview.recoverableDeficits.single.remainingDeficit, 2);

    final auditTrail = await container
        .read(counterAuditReaderProvider)
        .readForHabit('h');
    expect(auditTrail.versionAudits.length, 2);
    expect(auditTrail.eventAudits.length, 2);
    expect(auditTrail.resolutionAudits.length, 1);
    expect(auditTrail.recoveryAudits.length, 1);
  });
}
