import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_dashboard_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
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
  test('combines daily roster, applicability reasons and prior recoverable deficits without writing occurrences', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 8));
    final writer = CounterHabitWriter(db, clock);

    await writer.createFromStarterTemplate(
      template: CounterStarterTemplate.quranReading,
      habitId: 'h1_quran',
      versionId: 'v1_quran',
      auditId: 'a1_quran',
      lifecycleEventId: 'l1_quran',
      effectiveDate: DateTime(2026, 11, 26),
    );
    clock.current = DateTime(2026, 11, 26, 9);
    await writer.createFromStarterTemplate(
      template: CounterStarterTemplate.pushUp,
      habitId: 'h2_pushup',
      versionId: 'v1_pushup',
      auditId: 'a1_pushup',
      lifecycleEventId: 'l1_pushup',
      effectiveDate: DateTime(2026, 11, 26),
    );

    final actions = CounterTodayActionService(db, clock);
    // Nov 26: Quran failed (2/5 -> deficit 3), Push Up failed (4/10 -> deficit 6)
    await actions.recordTodayProgress(
      habitId: 'h1_quran',
      occurrenceId: 'o_quran_26',
      eventId: 'e_quran_26',
      quantity: 2,
    );
    await actions.resolveToday(
      habitId: 'h1_quran',
      occurrenceId: 'o_quran_26',
      resolutionId: 'r_quran_26',
      state: CounterResolutionState.failed,
    );
    await actions.recordTodayProgress(
      habitId: 'h2_pushup',
      occurrenceId: 'o_pushup_26',
      eventId: 'e_pushup_26',
      quantity: 4,
    );
    await actions.resolveToday(
      habitId: 'h2_pushup',
      occurrenceId: 'o_pushup_26',
      resolutionId: 'r_pushup_26',
      state: CounterResolutionState.failed,
    );

    // Nov 27: pause Push Up, keep Quran active
    clock.current = DateTime(2026, 11, 27, 9);
    await CounterLifecycleActionService(db, clock).pause(
      eventId: 'pause_pushup',
      habitId: 'h2_pushup',
      effectiveDate: LocalDate(2026, 11, 27),
      reason: 'Soreness',
    );

    final dashboard = await CounterDashboardReader(db)
        .readForDate(LocalDate(2026, 11, 27));
    expect(dashboard.items.length, 2);

    // h1_quran is active & pending on Nov 27, with 1 recoverable deficit of 3 pages from Nov 26
    expect(dashboard.items[0].rosterItem.habitId, 'h1_quran');
    expect(
      dashboard.items[0].rosterItem.evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(
      dashboard.items[0].applicabilityDetail.reason,
      HabitApplicabilityReason.applicable,
    );
    expect(dashboard.items[0].recoverableDeficits.length, 1);
    expect(dashboard.items[0].recoverableDeficits.single.remainingDeficit, 3);

    // h2_pushup is paused on Nov 27, so its recoverable deficits are suppressed while paused
    expect(dashboard.items[1].rosterItem.habitId, 'h2_pushup');
    expect(
      dashboard.items[1].rosterItem.evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );
    expect(
      dashboard.items[1].applicabilityDetail.reason,
      HabitApplicabilityReason.paused,
    );
    expect(dashboard.items[1].recoverableDeficits, isEmpty);

    expect(dashboard.daySummary.totalDays, 2);
    expect(dashboard.daySummary.applicableDays, 1);
    expect(dashboard.daySummary.notApplicableDays, 1);
    expect(dashboard.daySummary.pendingDays, 1);
    expect(dashboard.totalRecoverableDeficitCount, 1);
    expect(dashboard.totalRecoverableDeficitQuantity, 3);

    // No occurrences were created for Nov 27
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      2,
    );
  });
}
