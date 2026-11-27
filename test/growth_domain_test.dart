import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/growth/domain/focus_models.dart';
import 'package:hibi/features/growth/domain/goal_models.dart';
import 'package:hibi/features/growth/domain/journal_models.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

void main() {
  group('Journal domain models', () {
    test('normalizes tags and requires at least one content field or mood', () {
      final t0 = DateTime.utc(2026, 11, 27, 8);
      final entry = JournalEntry(
        id: 'j1',
        localDate: LocalDate(2026, 11, 27),
        reflectionText: '  Quiet morning walk.  ',
        gratitudeText: 'Good health',
        mood: JournalMood.good,
        tags: const ['  Morning ', 'morning', 'Focus', '  '],
        createdAtUtc: t0,
        updatedAtUtc: t0,
      );
      expect(entry.reflectionText, 'Quiet morning walk.');
      expect(entry.tags, ['morning', 'focus']);

      expect(
        () => JournalEntry(
          id: 'j2',
          localDate: LocalDate(2026, 11, 27),
          createdAtUtc: t0,
          updatedAtUtc: t0,
        ),
        throwsArgumentError,
      );
    });

    test(
      'summarizes multiple entries per day descriptively without penalties',
      () {
        final t0 = DateTime.utc(2026, 11, 27, 8);
        final summary = JournalSummary.summarize([
          JournalEntry(
            id: 'j1',
            localDate: LocalDate(2026, 11, 27),
            mood: JournalMood.good,
            tags: const ['calm', 'work'],
            createdAtUtc: t0,
            updatedAtUtc: t0,
          ),
          JournalEntry(
            id: 'j2',
            localDate: LocalDate(2026, 11, 27),
            gratitudeText: 'Finished a milestone',
            tags: const ['calm'],
            createdAtUtc: t0,
            updatedAtUtc: t0,
          ),
          JournalEntry(
            id: 'j3',
            localDate: LocalDate(2026, 11, 27),
            mood: JournalMood.low,
            isDeleted: true,
            createdAtUtc: t0,
            updatedAtUtc: t0,
          ),
        ]);
        expect(summary.entryCount, 2);
        expect(summary.distinctDaysCount, 1);
        expect(summary.moodCounts, {JournalMood.good: 1});
        expect(summary.tagCounts, {'calm': 2, 'work': 1});
      },
    );
  });

  group('Goal domain models', () {
    test('deduplicates linked progress references and separates sources', () {
      final t0 = DateTime.utc(2026, 11, 27, 9);
      final goal = Goal(
        id: 'g1',
        title: 'Read 10 chapters',
        status: GoalStatus.inProgress,
        targetUnits: 10,
        unitLabel: 'chapters',
        createdAtUtc: t0,
        updatedAtUtc: t0,
      );
      final milestones = [
        GoalMilestone(
          id: 'm1',
          goalId: 'g1',
          title: 'Part 1',
          isCompleted: true,
          completedAtUtc: t0,
          createdAtUtc: t0,
        ),
        GoalMilestone(
          id: 'm2',
          goalId: 'g1',
          title: 'Part 2',
          isCompleted: false,
          createdAtUtc: t0,
        ),
      ];
      final refHabit = buildLinkedHabitProgressRef(
        'h1',
        LocalDate(2026, 11, 27),
      );
      final summary = GoalProgressCalculator.summarize(
        goal: goal,
        milestones: milestones,
        linkedHabitIds: const ['h1'],
        progressEntries: [
          GoalProgressEntry(
            id: 'p1',
            goalId: 'g1',
            localDate: LocalDate(2026, 11, 27),
            units: 2,
            source: GoalProgressSource.manual,
            occurredAtUtc: t0,
          ),
          GoalProgressEntry(
            id: 'p2',
            goalId: 'g1',
            localDate: LocalDate(2026, 11, 27),
            units: 1,
            source: GoalProgressSource.linkedHabit,
            sourceRefId: refHabit,
            occurredAtUtc: t0,
          ),
          // Defensive duplicate with same (source, sourceRefId)
          GoalProgressEntry(
            id: 'p3',
            goalId: 'g1',
            localDate: LocalDate(2026, 11, 27),
            units: 1,
            source: GoalProgressSource.linkedHabit,
            sourceRefId: refHabit,
            occurredAtUtc: t0,
          ),
          GoalProgressEntry(
            id: 'p4',
            goalId: 'g1',
            localDate: LocalDate(2026, 11, 27),
            units: 25,
            source: GoalProgressSource.linkedFocus,
            sourceRefId: buildLinkedFocusProgressRef('foc1'),
            occurredAtUtc: t0,
          ),
        ],
        statusHistory: [
          GoalStatusEvent(
            id: 's1',
            goalId: 'g1',
            newStatus: GoalStatus.inProgress,
            occurredAtUtc: t0,
          ),
        ],
      );

      expect(summary.totalUnits, 28);
      expect(summary.manualUnits, 2);
      expect(summary.linkedHabitUnits, 1);
      expect(summary.linkedFocusUnits, 25);
      expect(summary.completedMilestones, 1);
      expect(summary.totalMilestones, 2);
      expect(summary.milestoneCompletionRatio, 0.5);
      expect(summary.unitCompletionRatio, 1.0);
    });
  });

  group('Focus / Pomodoro domain models', () {
    test(
      'uses 25/5/15 defaults and long break after 4 completed focus sessions',
      () {
        final t0 = DateTime.utc(2026, 11, 27, 9);
        final preset = FocusPreset.defaultPomodoro(t0);
        expect(preset.focusMinutes, 25);
        expect(preset.shortBreakMinutes, 5);
        expect(preset.longBreakMinutes, 15);
        expect(preset.sessionsBeforeLongBreak, 4);

        FocusSession completed(String id, FocusSessionKind kind, int idx) =>
            FocusSession(
              id: id,
              kind: kind,
              localDate: LocalDate(2026, 11, 27),
              plannedDurationSeconds: preset.plannedSecondsFor(kind),
              state: FocusSessionState.completed,
              cycleIndex: idx,
              startedAtUtc: t0,
              accumulatedElapsedSeconds: preset.plannedSecondsFor(kind),
              endedAtUtc: t0.add(const Duration(minutes: 25)),
            );

        final interrupted = FocusSession(
          id: 'int1',
          kind: FocusSessionKind.focus,
          localDate: LocalDate(2026, 11, 27),
          plannedDurationSeconds: 1500,
          state: FocusSessionState.interrupted,
          cycleIndex: 2,
          startedAtUtc: t0,
          accumulatedElapsedSeconds: 600,
          endedAtUtc: t0.add(const Duration(minutes: 10)),
          interruptionReason: 'Phone call',
        );

        // 1 completed focus -> short break
        final after1 = FocusCyclePlanner.recommendNext(
          chronologicalSessions: [completed('f1', FocusSessionKind.focus, 1)],
        );
        expect(after1.nextKind, FocusSessionKind.shortBreak);
        expect(after1.completedFocusInCurrentCycle, 1);

        // Interrupted focus does NOT count toward the 4-session cycle.
        final after3PlusInterrupted = FocusCyclePlanner.recommendNext(
          chronologicalSessions: [
            completed('f1', FocusSessionKind.focus, 1),
            completed('b1', FocusSessionKind.shortBreak, 1),
            completed('f2', FocusSessionKind.focus, 2),
            interrupted,
            completed('b2', FocusSessionKind.shortBreak, 2),
            completed('f3', FocusSessionKind.focus, 3),
          ],
        );
        expect(after3PlusInterrupted.nextKind, FocusSessionKind.shortBreak);
        expect(after3PlusInterrupted.completedFocusInCurrentCycle, 3);

        // 4th completed focus -> long break
        final after4 = FocusCyclePlanner.recommendNext(
          chronologicalSessions: [
            completed('f1', FocusSessionKind.focus, 1),
            completed('b1', FocusSessionKind.shortBreak, 1),
            completed('f2', FocusSessionKind.focus, 2),
            completed('b2', FocusSessionKind.shortBreak, 2),
            completed('f3', FocusSessionKind.focus, 3),
            completed('b3', FocusSessionKind.shortBreak, 3),
            completed('f4', FocusSessionKind.focus, 4),
          ],
        );
        expect(after4.nextKind, FocusSessionKind.longBreak);
        expect(after4.completedFocusInCurrentCycle, 4);

        // After long break -> resets to focus #1
        final afterLongBreak = FocusCyclePlanner.recommendNext(
          chronologicalSessions: [
            completed('f1', FocusSessionKind.focus, 1),
            completed('f2', FocusSessionKind.focus, 2),
            completed('f3', FocusSessionKind.focus, 3),
            completed('f4', FocusSessionKind.focus, 4),
            completed('lb1', FocusSessionKind.longBreak, 4),
          ],
        );
        expect(afterLongBreak.nextKind, FocusSessionKind.focus);
        expect(afterLongBreak.nextCycleIndex, 1);
        expect(afterLongBreak.completedFocusInCurrentCycle, 0);
      },
    );

    test(
      'computes elapsed, remaining and deadline deterministically across time',
      () {
        final start = DateTime.utc(2026, 11, 27, 10, 0, 0);
        final resumed = start.add(const Duration(minutes: 15));
        final session = FocusSession(
          id: 'foc1',
          kind: FocusSessionKind.focus,
          localDate: LocalDate(2026, 11, 27),
          plannedDurationSeconds: 1500,
          state: FocusSessionState.running,
          startedAtUtc: start,
          lastResumedAtUtc: resumed,
          deadlineUtc: resumed.add(const Duration(seconds: 900)),
          accumulatedElapsedSeconds: 600,
        );

        final checkMid = resumed.add(const Duration(seconds: 300));
        expect(session.elapsedSecondsAt(checkMid), 900);
        expect(session.remainingSecondsAt(checkMid), 600);
        expect(session.isDeadlineReachedAt(checkMid), isFalse);
        expect(formatFocusClock(session.remainingSecondsAt(checkMid)), '10:00');

        final checkPast = resumed.add(const Duration(seconds: 950));
        expect(session.elapsedSecondsAt(checkPast), 1500);
        expect(session.remainingSecondsAt(checkPast), 0);
        expect(session.isDeadlineReachedAt(checkPast), isTrue);
      },
    );
  });
}
