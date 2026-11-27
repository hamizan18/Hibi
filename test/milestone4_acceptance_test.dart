import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/growth/data/focus_service.dart';
import 'package:hibi/features/growth/data/goal_service.dart';
import 'package:hibi/features/growth/data/journal_service.dart';
import 'package:hibi/features/growth/domain/focus_models.dart';
import 'package:hibi/features/growth/domain/goal_models.dart';
import 'package:hibi/features/growth/domain/journal_models.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as p;

class _AcceptanceClock implements AppClock {
  _AcceptanceClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

/// T-008 acceptance test:
/// Journal and goal persistence across disk reopen; focus start/pause/resume/
/// completion, interruption and restart reconciliation, and duplicate linked
/// progress prevention.
void main() {
  test('T-008: journal, goals and restart-safe focus persist without duplicate linked progress', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_m4_t008_');
    addTearDown(() => dir.delete(recursive: true));
    final dbFile = File(p.join(dir.path, 'hibi.sqlite'));
    final clock = _AcceptanceClock(DateTime(2026, 11, 27, 8, 0, 0));
    final today = LocalDate(2026, 11, 27);

    // Phase 1: Create duration habit, journal entries, goal + milestone + link,
    // start focus session and pause it, then close DB (simulating process stop).
    final db1 = AppDatabase(NativeDatabase(dbFile));
    final habitService1 = BooleanDurationHabitService(db1, clock);
    final journal1 = JournalService(db1, clock);
    final goals1 = GoalService(db1, clock);
    final focus1 = FocusService(db1, clock);

    await habitService1.createDuration(
      habitId: 'h_deep',
      versionId: 'v_deep',
      lifecycleEventId: 'l_deep',
      name: 'Deep Focus',
      effectiveDate: DateTime(2026, 11, 27),
      target: DurationTarget(targetSeconds: 1500),
      schedule: DailySchedule(start: today),
    );

    await journal1.createEntry(
      id: 'j_am',
      localDate: today,
      title: 'Morning',
      reflectionText: 'Clear plan for the day.',
      mood: JournalMood.good,
      tags: const ['plan'],
    );
    await journal1.createEntry(
      id: 'j_priv',
      localDate: today,
      reflectionText: 'Private note stays hidden by default.',
      isPrivate: true,
    );

    await goals1.createGoal(
      id: 'g_m4',
      title: 'Complete Architecture Study',
      status: GoalStatus.planned,
      targetUnits: 50,
      unitLabel: 'min',
    );
    await goals1.updateGoalStatus(
      goalId: 'g_m4',
      newStatus: GoalStatus.inProgress,
    );
    await goals1.addMilestone(id: 'm1', goalId: 'g_m4', title: 'Read notes');
    await goals1.linkHabit(goalId: 'g_m4', habitId: 'h_deep');

    await focus1.startSession(
      id: 'foc_restart',
      kind: FocusSessionKind.focus,
      plannedDurationSeconds: 1500,
      linkedHabitId: 'h_deep',
      linkedGoalId: 'g_m4',
    );
    // Advance 10 minutes and pause before app closes.
    clock.current = DateTime(2026, 11, 27, 8, 10, 0);
    await focus1.pauseSession('foc_restart');
    await db1.close();

    // Phase 2: Reopen DB, verify paused session survived restart with exact 600s,
    // resume it, then close DB while running.
    clock.current = DateTime(2026, 11, 27, 8, 20, 0);
    final db2 = AppDatabase(NativeDatabase(dbFile));
    final focus2 = FocusService(db2, clock);
    final reconciledPaused = await focus2.reconcileActiveSession();
    expect(reconciledPaused.activeSession?.id, 'foc_restart');
    expect(reconciledPaused.activeSession?.state, FocusSessionState.paused);
    expect(reconciledPaused.activeSession?.accumulatedElapsedSeconds, 600);

    await focus2.resumeSession('foc_restart');
    await db2.close();

    // Phase 3: Advance clock past deadline (remaining 15m ends at 8:35),
    // reopen DB -> reconcileActiveSession auto-completes once and records
    // linked duration habit + linked goal progress once.
    clock.current = DateTime(2026, 11, 27, 8, 40, 0);
    final db3 = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db3.close);

    final focus3 = FocusService(db3, clock);
    final goals3 = GoalService(db3, clock);
    final journal3 = JournalService(db3, clock);
    final habitService3 = BooleanDurationHabitService(db3, clock);

    final reconciledDone = await focus3.reconcileActiveSession();
    expect(reconciledDone.activeSession, isNull);
    expect(reconciledDone.autoCompletedSession?.id, 'foc_restart');
    expect(
      reconciledDone.autoCompletedSession?.state,
      FocusSessionState.completed,
    );

    // Repeating completion or reconciliation must NOT duplicate linked progress.
    await focus3.completeSession('foc_restart');
    await focus3.reconcileActiveSession();

    final durationDay = (await habitService3.readDurationDay(
      habitId: 'h_deep',
      date: today,
    ))!;
    expect(durationDay.totalSeconds, 1500);
    expect(durationDay.status, DurationEffectiveStatus.completed);

    // Syncing linked habit for the completed habit records once, and repeating does not duplicate.
    final sync1 = await goals3.syncLinkedHabitProgress(
      entryId: 'gp_sync_1',
      goalId: 'g_m4',
      habitId: 'h_deep',
      date: today,
      units: 1,
    );
    final sync2 = await goals3.syncLinkedHabitProgress(
      entryId: 'gp_sync_2',
      goalId: 'g_m4',
      habitId: 'h_deep',
      date: today,
      units: 1,
    );
    expect(sync1.recorded, isTrue);
    expect(sync2.alreadyRecorded, isTrue);

    // Start another focus session and interrupt it -> clearly distinguished from completed.
    clock.current = DateTime(2026, 11, 27, 9, 0, 0);
    await focus3.startSession(
      id: 'foc_int',
      kind: FocusSessionKind.focus,
      plannedDurationSeconds: 1500,
      linkedHabitId: 'h_deep',
      linkedGoalId: 'g_m4',
    );
    clock.current = DateTime(2026, 11, 27, 9, 4, 0);
    final interrupted = await focus3.interruptSession(
      sessionId: 'foc_int',
      reason: 'Interruption test',
    );
    expect(interrupted.state, FocusSessionState.interrupted);
    expect(interrupted.accumulatedElapsedSeconds, 240);

    // Verify all persisted state after full restart flow.
    final visibleJournal = await journal3.readEntries();
    expect(visibleJournal.map((e) => e.id).toList(), ['j_am']);
    final allJournal = await journal3.readEntries(includePrivate: true);
    expect(allJournal.length, 2);

    final goalSummary = (await goals3.readGoalSummary('g_m4'))!;
    expect(goalSummary.linkedFocusUnits, 25);
    expect(goalSummary.linkedHabitUnits, 1);
    expect(goalSummary.totalUnits, 26);
    expect(goalSummary.statusHistory.length, 2);

    final focusSummary = FocusHistorySummary.summarize(
      await focus3.readHistory(),
    );
    expect(focusSummary.completedFocusCount, 1);
    expect(focusSummary.interruptedFocusCount, 1);
    expect(focusSummary.totalCompletedFocusSeconds, 1500);
    expect(focusSummary.totalInterruptedFocusSeconds, 240);
  });
}
