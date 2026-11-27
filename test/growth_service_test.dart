import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/finance/data/finance_service.dart';
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
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'test_schema_downgrade.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  group('JournalService', () {
    test('supports multiple entries per day, tags, edits, soft-delete and private hiding', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = MutableClock(DateTime(2026, 11, 27, 8, 0));
      final service = JournalService(db, clock);
      final today = LocalDate(2026, 11, 27);

      await service.createEntry(
        id: 'j1',
        localDate: today,
        title: 'Morning check-in',
        reflectionText: 'Ready for deep work.',
        mood: JournalMood.good,
        tags: const ['morning', 'focus'],
      );
      clock.current = DateTime(2026, 11, 27, 21, 0);
      await service.createEntry(
        id: 'j2',
        localDate: today,
        gratitudeText: 'Grateful for steady progress.',
        mood: JournalMood.great,
        tags: const ['evening', 'gratitude'],
      );
      await service.createEntry(
        id: 'j3',
        localDate: today,
        reflectionText: 'Private thought',
        isPrivate: true,
        tags: const ['private'],
      );

      final defaultEntries = await service.readEntries();
      expect(defaultEntries.map((e) => e.id).toList(), ['j2', 'j1']);

      final allEntries = await service.readEntries(includePrivate: true);
      expect(allEntries.length, 3);

      final tagged = await service.readEntries(tagFilter: 'FOCUS');
      expect(tagged.map((e) => e.id).toList(), ['j1']);

      await service.updateEntry(
        id: 'j1',
        localDate: today,
        title: 'Morning check-in (edited)',
        reflectionText: 'Updated reflection.',
        mood: JournalMood.neutral,
        tags: const ['calm'],
      );
      final afterEdit = await service.readEntries(tagFilter: 'calm');
      expect(afterEdit.single.title, 'Morning check-in (edited)');
      expect(afterEdit.single.mood, JournalMood.neutral);

      await service.softDeleteEntry('j2');
      final afterDelete = await service.readEntries();
      expect(afterDelete.map((e) => e.id).toList(), ['j1']);
    });
  });

  group('GoalService', () {
    test('retains immutable status history and prevents duplicate linked/manual progress', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = MutableClock(DateTime(2026, 11, 27, 9, 0));
      final goalService = GoalService(db, clock);
      final habitService = BooleanDurationHabitService(db, clock);
      final today = LocalDate(2026, 11, 27);

      await habitService.createBoolean(
        habitId: 'h_study',
        versionId: 'v_study',
        lifecycleEventId: 'l_study',
        name: 'Daily Study',
        effectiveDate: DateTime(2026, 11, 27),
        schedule: DailySchedule(start: today),
      );
      await habitService.logBooleanToday(
        habitId: 'h_study',
        occurrenceId: 'o_study',
        logId: 'log_study',
        state: BooleanLogState.completed,
      );

      await goalService.createGoal(
        id: 'g1',
        title: 'Finish Flutter Course',
        status: GoalStatus.planned,
        targetUnits: 10,
        unitLabel: 'lessons',
      );
      clock.current = DateTime(2026, 11, 27, 9, 5);
      await goalService.updateGoalStatus(
        goalId: 'g1',
        newStatus: GoalStatus.inProgress,
        reason: 'Started chapter 1',
      );
      await goalService.addMilestone(id: 'm1', goalId: 'g1', title: 'Module 1');
      await goalService.setMilestoneCompleted(
        milestoneId: 'm1',
        completed: true,
      );
      await goalService.linkHabit(goalId: 'g1', habitId: 'h_study');

      // First sync records linked habit progress.
      final firstSync = await goalService.syncLinkedHabitProgress(
        entryId: 'gp_h1',
        goalId: 'g1',
        habitId: 'h_study',
        date: today,
        units: 1,
      );
      expect(firstSync.recorded, isTrue);
      expect(firstSync.alreadyRecorded, isFalse);

      // Second sync for the same habit + date is idempotent and does NOT duplicate.
      final secondSync = await goalService.syncLinkedHabitProgress(
        entryId: 'gp_h2',
        goalId: 'g1',
        habitId: 'h_study',
        date: today,
        units: 1,
      );
      expect(secondSync.recorded, isFalse);
      expect(secondSync.alreadyRecorded, isTrue);

      // Manual entry attempting to claim the same canonical habit ref is rejected.
      final canonicalRef = buildLinkedHabitProgressRef('h_study', today);
      await expectLater(
        () => goalService.recordManualProgress(
          id: 'gp_manual_dup',
          goalId: 'g1',
          localDate: today,
          units: 1,
          sourceRefId: canonicalRef,
        ),
        throwsStateError,
      );

      // Independent manual progress succeeds.
      await goalService.recordManualProgress(
        id: 'gp_manual_ok',
        goalId: 'g1',
        localDate: today,
        units: 2,
        note: 'Extra practice',
      );

      final summary = (await goalService.readGoalSummary('g1'))!;
      expect(summary.totalUnits, 3);
      expect(summary.linkedHabitUnits, 1);
      expect(summary.manualUnits, 2);
      expect(summary.completedMilestones, 1);
      expect(summary.statusHistory.map((e) => e.newStatus).toList(), [
        GoalStatus.planned,
        GoalStatus.inProgress,
      ]);

      // Immutable trigger prevents mutating or deleting status history.
      await expectLater(
        () => db.customStatement('DELETE FROM goal_status_history'),
        throwsException,
      );
    });
  });

  group('FocusService', () {
    test('handles start, pause, resume, interruption, restart deadline reconciliation and deduplicated linked progress', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = MutableClock(DateTime(2026, 11, 27, 10, 0, 0));
      final focusService = FocusService(db, clock);
      final goalService = GoalService(db, clock);
      final habitService = BooleanDurationHabitService(db, clock);
      final today = LocalDate(2026, 11, 27);

      await habitService.createDuration(
        habitId: 'h_focus',
        versionId: 'v_focus',
        lifecycleEventId: 'l_focus',
        name: 'Deep Work',
        effectiveDate: DateTime(2026, 11, 27),
        target: DurationTarget(targetSeconds: 1500),
        schedule: DailySchedule(start: today),
      );
      await goalService.createGoal(
        id: 'g_focus',
        title: 'Ship Milestone 4',
        status: GoalStatus.inProgress,
        targetUnits: 100,
        unitLabel: 'min',
      );

      // Start 25-minute focus session linked to both duration habit & goal.
      final started = await focusService.startSession(
        id: 'foc1',
        kind: FocusSessionKind.focus,
        plannedDurationSeconds: 1500,
        linkedHabitId: 'h_focus',
        linkedGoalId: 'g_focus',
      );
      expect(started.state, FocusSessionState.running);

      // Pause after 10 minutes (600 seconds).
      clock.current = DateTime(2026, 11, 27, 10, 10, 0);
      final paused = await focusService.pauseSession('foc1');
      expect(paused.state, FocusSessionState.paused);
      expect(paused.accumulatedElapsedSeconds, 600);
      expect(paused.deadlineUtc, isNull);

      // Wait 5 minutes paused, then resume -> remaining is still 900s (15 min).
      clock.current = DateTime(2026, 11, 27, 10, 15, 0);
      final resumed = await focusService.resumeSession('foc1');
      expect(resumed.state, FocusSessionState.running);
      expect(resumed.accumulatedElapsedSeconds, 600);
      expect(resumed.deadlineUtc, DateTime(2026, 11, 27, 10, 30, 0).toUtc());

      // Simulate app closed and reopened past deadline (10:35).
      clock.current = DateTime(2026, 11, 27, 10, 35, 0);
      final reconciled = await focusService.reconcileActiveSession();
      expect(reconciled.activeSession, isNull);
      expect(
        reconciled.autoCompletedSession?.state,
        FocusSessionState.completed,
      );
      expect(reconciled.autoCompletedSession?.linkedHabitEventId, isNotNull);
      expect(reconciled.autoCompletedSession?.linkedGoalProgressId, isNotNull);

      // Calling completeSession again must be strictly idempotent (zero duplicates!).
      await focusService.completeSession('foc1');

      final durationProgress = (await habitService.readDurationDay(
        habitId: 'h_focus',
        date: today,
      ))!;
      expect(durationProgress.totalSeconds, 1500);
      expect(durationProgress.status, DurationEffectiveStatus.completed);

      final goalSummary = (await goalService.readGoalSummary('g_focus'))!;
      expect(goalSummary.linkedFocusUnits, 25);
      expect(goalSummary.progressEntries.length, 1);

      // Start second focus session and interrupt after 5 minutes -> must NOT grant linked progress.
      clock.current = DateTime(2026, 11, 27, 11, 0, 0);
      await focusService.startSession(
        id: 'foc2',
        kind: FocusSessionKind.focus,
        plannedDurationSeconds: 1500,
        linkedHabitId: 'h_focus',
        linkedGoalId: 'g_focus',
      );
      clock.current = DateTime(2026, 11, 27, 11, 5, 0);
      final interrupted = await focusService.interruptSession(
        sessionId: 'foc2',
        reason: 'Urgent call',
      );
      expect(interrupted.state, FocusSessionState.interrupted);
      expect(interrupted.accumulatedElapsedSeconds, 300);
      expect(interrupted.interruptionReason, 'Urgent call');
      expect(interrupted.linkedHabitEventId, isNull);
      expect(interrupted.linkedGoalProgressId, isNull);

      final goalAfterInterrupt = (await goalService.readGoalSummary(
        'g_focus',
      ))!;
      expect(goalAfterInterrupt.linkedFocusUnits, 25);
    });
  });

  group('Schema v14 -> v15 migration', () {
    test(
      'preserves existing v14 Finance and settings data when upgrading to v15',
      () async {
        final dir = await Directory.systemTemp.createTemp('hibi_v14_to_v15_');
        addTearDown(() => dir.delete(recursive: true));
        final dbFile = File(p.join(dir.path, 'hibi.sqlite'));

        final clock = MutableClock(DateTime(2026, 11, 27, 9, 0));
        final initialDb = AppDatabase(NativeDatabase(dbFile));
        await initialDb.setSetting('theme', 'dark');
        final finance = FinanceService(initialDb, clock);
        await finance.createWallet(
          id: 'w1',
          auditId: 'a_w1',
          name: 'Cash',
          openingBalanceIdr: 500000,
          openingDate: LocalDate(2026, 11, 1),
        );
        await initialDb.close();

        // Downgrade DB file to schema v14 to simulate pre-Milestone-4 install.
        final raw = sqlite.sqlite3.open(dbFile.path);
        try {
          dropV15Schema(raw);
          raw.execute('PRAGMA user_version = 14');
        } finally {
          raw.close();
        }

        // Reopen via AppDatabase to trigger v14 -> v15 upgrade.
        final upgraded = AppDatabase(NativeDatabase(dbFile));
        addTearDown(upgraded.close);

        final versionRow = await upgraded
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(versionRow.read<int>('user_version'), 15);
        expect(await upgraded.getSetting('theme'), 'dark');

        final wallets = await FinanceService(upgraded, clock).readWallets();
        expect(wallets.single.name, 'Cash');
        expect(wallets.single.openingBalanceIdr, 500000);

        // New v15 tables work immediately.
        await JournalService(upgraded, clock).createEntry(
          id: 'j_post_mig',
          localDate: LocalDate(2026, 11, 27),
          reflectionText: 'Upgraded smoothly to v15.',
        );
        final entries = await JournalService(upgraded, clock).readEntries();
        expect(entries.single.id, 'j_post_mig');
      },
    );
  });
}
