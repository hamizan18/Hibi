import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/data/non_counter_version_service.dart';
import 'package:hibi/features/habits/data/unified_habit_history_reader.dart';
import 'package:hibi/features/habits/domain/dynamic_normalized_scoring.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';

class _Clock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  test('version scores, unavailable coverage and privacy remain independent of status', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock();
    final service = MeasurementTimeRangeHabitService(db, clock);
    final first = LocalDate(2026, 11, 26);
    final second = LocalDate(2026, 11, 27);
    final target = MeasurementTarget(
      scaledTarget: 10,
      decimalPlaces: 0,
      unit: 'units',
      rule: MeasurementComparisonRule.atLeast,
    );
    await service.createMeasurement(
      habitId: 'public',
      versionId: 'old',
      lifecycleEventId: 'l1',
      name: 'Public',
      effectiveDate: clock.now(),
      target: target,
      schedule: DailySchedule(start: first),
      metadata: HabitMetadata(category: 'Health'),
    );
    await service.logMeasurementToday(
      habitId: 'public',
      occurrenceId: 'o1',
      logId: 'log1',
      scaledValue: 10,
    );
    await NonCounterVersionService(db, clock).scheduleMeasurementVersion(
      habitId: 'public',
      versionId: 'new',
      auditId: 'a2',
      name: 'Public',
      effectiveDate: DateTime(2026, 11, 27),
      target: target,
      schedule: DailySchedule(start: second),
      metadata: HabitMetadata(category: 'Health'),
      scoring: const HabitScoringConfig.measurement(),
    );
    await service.createMeasurement(
      habitId: 'private',
      versionId: 'private-v',
      lifecycleEventId: 'lp',
      name: 'Private',
      effectiveDate: clock.now(),
      target: target,
      schedule: DailySchedule(start: first),
      metadata: HabitMetadata(category: 'Health', isPrivate: true),
      scoring: const HabitScoringConfig.measurement(),
    );
    await service.logMeasurementToday(
      habitId: 'private',
      occurrenceId: 'op',
      logId: 'logp',
      scaledValue: 5,
    );
    clock.current = DateTime(2026, 11, 27, 12);
    await service.logMeasurementToday(
      habitId: 'public',
      occurrenceId: 'o2',
      logId: 'log2',
      scaledValue: 5,
    );
    final reader = UnifiedHabitHistoryReader(db);
    final days = await reader.readRange(
      startInclusive: first,
      endInclusive: second,
      filter: const HabitAnalyticsFilter(),
    );
    final old = days[first]!.single;
    final recent = days[second]!.single;
    expect(old.status, HabitAnalyticsStatus.completed);
    expect(old.scoreMultiplier, isNull);
    expect(old.scoringUnavailable, isTrue);
    expect(recent.scoreMultiplier, 0.5);
    final report = AnalyticsPeriodReportCalculator.buildReport(
      startInclusive: first,
      endInclusive: second,
      evaluationsByDate: days,
    );
    expect(report.validScoreCount, 1);
    expect(report.unavailableRecordedScoreCount, 1);
    expect(report.scoreCoveragePercent, 50);
    expect(report.overallWeightedScorePercent, 50);
    expect(report.dailyCells.first.scoreSummary.weightedScorePercent, isNull);
    final revealed = await reader.readDay(
      date: first,
      filter: const HabitAnalyticsFilter(includePrivate: true),
    );
    final summary = DailyWeightedScoreCalculator.calculate(
      date: first,
      evaluations: revealed,
    );
    expect(summary.validScoreCount, 1);
    expect(summary.unavailableRecordedScoreCount, 1);
    expect(summary.weightedScorePercent, 50);
  });

  test('time and range use version rules and reject mismatched occurrence bindings', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock();
    final day = LocalDate(2026, 11, 26);
    final service = MeasurementTimeRangeHabitService(db, clock);
    final metadata = HabitMetadata(category: 'Health');
    await service.createTimeOfDay(
      habitId: 'time',
      versionId: 'vt',
      lifecycleEventId: 'lt',
      name: 'Time',
      effectiveDate: clock.now(),
      schedule: DailySchedule(start: day),
      metadata: metadata,
      target: TimeOfDayTarget(
        targetMinutesSinceMidnight: 10,
        rule: TimeComparisonRule.atOrBefore,
      ),
      scoring: const HabitScoringConfig.timeOfDay(toleranceMinutes: 20),
    );
    await service.logTimeOfDayToday(
      habitId: 'time',
      occurrenceId: 'ot',
      logId: 'et',
      minutesSinceMidnight: 20,
      dayOffset: 0,
    );
    await service.createRange(
      habitId: 'range',
      versionId: 'vr',
      lifecycleEventId: 'lr',
      name: 'Range',
      effectiveDate: clock.now(),
      schedule: DailySchedule(start: day),
      metadata: metadata,
      target: RangeTarget(
        minScaled: 10,
        maxScaled: 20,
        decimalPlaces: 0,
        unit: 'u',
      ),
      scoring: const HabitScoringConfig.range(toleranceScaled: 10),
    );
    await service.logRangeToday(
      habitId: 'range',
      occurrenceId: 'or',
      logId: 'er',
      scaledValue: 25,
    );
    final reader = UnifiedHabitHistoryReader(db);
    var values = {
      for (final e in await reader.readDay(date: day)) e.habitId: e,
    };
    expect(values['time']!.scoreMultiplier, 0.5);
    expect(values['range']!.scoreMultiplier, 0.5);
    await db.customStatement(
      "UPDATE habit_typed_occurrences SET tracking_type = 'measurement' WHERE id = 'or'",
    );
    values = {for (final e in await reader.readDay(date: day)) e.habitId: e};
    expect(values['range']!.status, HabitAnalyticsStatus.conflict);
    expect(values['range']!.scoreMultiplier, isNull);
    await db.customStatement(
      "INSERT INTO habit_typed_occurrences (id, habit_id, habit_version_id, tracking_type, local_date) VALUES ('ot2', 'time', 'vt', 'time_of_day', '2026-11-27')",
    );
    await db.customStatement(
      "INSERT INTO habit_typed_logs (id, occurrence_id, state, minutes_since_midnight, day_offset, occurred_at_utc_us) VALUES ('et2', 'ot2', 'failed', 20, 0, 1)",
    );
    final failed = (await reader.readDay(date: LocalDate(2026, 11, 27)))
        .singleWhere((e) => e.habitId == 'time');
    expect(failed.status, HabitAnalyticsStatus.failed);
    expect(failed.scoreMultiplier, 0.5);
  });
}
