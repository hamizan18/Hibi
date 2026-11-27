import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

LocalDate _date(int day) => LocalDate(2026, 11, day);

UnifiedHabitDayEvaluation _day(int day, HabitAnalyticsStatus status) =>
    UnifiedHabitDayEvaluation(
      habitId: 'h',
      versionId: 'v',
      name: 'Habit',
      date: _date(day),
      trackingType: HabitTrackingType.counter,
      status: status,
      applicabilityReason: status == HabitAnalyticsStatus.notApplicable
          ? HabitApplicabilityReason.unscheduled
          : HabitApplicabilityReason.applicable,
      priority: HabitPriority.normal,
      category: 'General',
      symbol: null,
      isPrivate: false,
      includeInScore: true,
      includeInStreak: true,
      hasMetadata: true,
      partialRatio: 0,
      summaryText: status.name,
      hasOccurrence:
          status != HabitAnalyticsStatus.pending &&
          status != HabitAnalyticsStatus.notApplicable,
    );

HabitStreakSummary _evaluate(List<UnifiedHabitDayEvaluation> days, int asOf) =>
    HabitStreakEvaluator.evaluate(
      habitId: 'h',
      habitName: 'Habit',
      asOfDate: _date(asOf),
      chronologicalEvaluations: days,
    );

void main() {
  for (final uncertain in [
    HabitAnalyticsStatus.unknown,
    HabitAnalyticsStatus.conflict,
  ]) {
    test('${uncertain.name} separates confirmed runs without a failure', () {
      final result = _evaluate([
        _day(20, HabitAnalyticsStatus.completed),
        _day(21, HabitAnalyticsStatus.completed),
        _day(22, uncertain),
        _day(23, HabitAnalyticsStatus.completed),
        _day(24, HabitAnalyticsStatus.notApplicable),
        _day(25, HabitAnalyticsStatus.excused),
        _day(26, HabitAnalyticsStatus.completed),
      ], 26);

      expect(result.state, StreakResolutionState.unresolved);
      expect(result.currentStreak, 2);
      expect(result.longestStreak, 2);
      expect(result.applicableDaysCount, 5);
      expect(result.completedDaysCount, 4);
      expect(result.recoveredDaysCount, 0);
      expect(result.failedDaysCount, 0);
      expect(result.excusedDaysCount, 1);
      expect(result.skippedNotApplicableCount, 1);
      expect(result.unresolvedPendingDates, isEmpty);
      expect(result.isPendingToday, isFalse);
    });

    test('${uncertain.name} alone is unresolved, including today', () {
      for (final asOf in [20, 21]) {
        final result = _evaluate([_day(20, uncertain)], asOf);
        expect(result.state, StreakResolutionState.unresolved);
        expect(result.currentStreak, 0);
        expect(result.longestStreak, 0);
        expect(result.applicableDaysCount, 0);
        expect(result.completedDaysCount, 0);
        expect(result.recoveredDaysCount, 0);
        expect(result.failedDaysCount, 0);
        expect(result.excusedDaysCount, 0);
        expect(result.skippedNotApplicableCount, 0);
        expect(result.unresolvedPendingDates, isEmpty);
        expect(result.isPendingToday, isFalse);
      }
    });

    test('${uncertain.name} today does not preserve earlier continuity', () {
      final result = _evaluate([
        _day(19, HabitAnalyticsStatus.completed),
        _day(20, uncertain),
      ], 20);
      expect(result.state, StreakResolutionState.unresolved);
      expect(result.currentStreak, 0);
      expect(result.longestStreak, 1);
      expect(result.failedDaysCount, 0);
      expect(result.isPendingToday, isFalse);
    });

    test(
      'confirmed failure after ${uncertain.name} resolves current state',
      () {
        final result = _evaluate([
          _day(19, HabitAnalyticsStatus.completed),
          _day(20, uncertain),
          _day(21, HabitAnalyticsStatus.failed),
          _day(22, HabitAnalyticsStatus.completed),
        ], 22);
        expect(result.state, StreakResolutionState.active);
        expect(result.currentStreak, 1);
        expect(result.longestStreak, 1);
        expect(result.applicableDaysCount, 3);
        expect(result.failedDaysCount, 1);
        expect(result.skippedNotApplicableCount, 0);
      },
    );
  }

  test('past and current pending keep their existing semantics', () {
    final result = _evaluate([
      _day(19, HabitAnalyticsStatus.completed),
      _day(20, HabitAnalyticsStatus.pending),
      _day(21, HabitAnalyticsStatus.completed),
      _day(22, HabitAnalyticsStatus.pending),
    ], 22);
    expect(result.state, StreakResolutionState.unresolved);
    expect(result.currentStreak, 1);
    expect(result.longestStreak, 1);
    expect(result.applicableDaysCount, 4);
    expect(result.failedDaysCount, 0);
    expect(result.unresolvedPendingDates.length, 1);
    expect(result.unresolvedPendingDates.single.compareTo(_date(20)), 0);
    expect(result.isPendingToday, isTrue);

    final todayOnly = _evaluate([
      _day(21, HabitAnalyticsStatus.completed),
      _day(22, HabitAnalyticsStatus.pending),
    ], 22);
    expect(todayOnly.state, StreakResolutionState.activePendingToday);
    expect(todayOnly.currentStreak, 1);
    expect(todayOnly.unresolvedPendingDates, isEmpty);
    expect(todayOnly.isPendingToday, isTrue);
  });
}
