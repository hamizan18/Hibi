import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_recovery_store.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_progress.dart';
import 'package:hibi/features/habits/domain/counter_range_summary.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

CounterDay _day({
  required HabitApplicability applicability,
  String? occurrenceId,
  CounterProgress? progress,
  CounterResolution? resolution,
  List<CounterRecoveryRecord> recoveries = const [],
}) => (
  applicability: applicability,
  occurrenceId: occurrenceId,
  recorded: progress == null ? null : (progress: progress, unit: 'pages'),
  resolution: resolution,
  recoveries: recoveries,
);

void main() {
  test('empty range and no-applicable-data range report explicit flags without inferring failure', () {
    final empty = CounterRangeSummary.fromEvaluations(const []);
    expect(empty.totalDays, 0);
    expect(empty.applicableDays, 0);
    expect(empty.hasApplicableDays, isFalse);
    expect(empty.hasRecordedOutcomeDays, isFalse);
    expect(empty.hasUnresolvedApplicableDays, isFalse);
    expect(empty.hasUnknownOrConflictDays, isFalse);

    final notApplicableOnly = CounterRangeSummary.fromEvaluations([
      interpretCounterDay(
        day: _day(applicability: HabitApplicability.notApplicable),
      ),
    ]);
    expect(notApplicableOnly.totalDays, 1);
    expect(notApplicableOnly.notApplicableDays, 1);
    expect(notApplicableOnly.applicableDays, 0);
    expect(notApplicableOnly.failedDays, 0);
    expect(notApplicableOnly.hasApplicableDays, isFalse);
  });

  test('aggregates every day status accurately and keeps recorded, recovered and deficit totals separate', () {
    final target = CounterTarget(count: 5, unit: 'pages');
    final utc = DateTime.utc(2026, 11, 26, 12);

    final evaluations = [
      // 1. notApplicable
      interpretCounterDay(
        day: _day(applicability: HabitApplicability.notApplicable),
      ),
      // 2. unknown
      interpretCounterDay(day: _day(applicability: HabitApplicability.unknown)),
      // 3. pending without occurrence
      interpretCounterDay(
        day: _day(applicability: HabitApplicability.applicable),
        configuredTarget: target,
      ),
      // 4. pending with 0-event occurrence
      interpretCounterDay(
        day: _day(
          applicability: HabitApplicability.applicable,
          occurrenceId: 'o_pending',
          progress: CounterProgress.fromEvents(target: 5, quantities: const []),
        ),
        configuredTarget: target,
      ),
      // 5. partial (2/5)
      interpretCounterDay(
        day: _day(
          applicability: HabitApplicability.applicable,
          occurrenceId: 'o_partial',
          progress: CounterProgress.fromEvents(
            target: 5,
            quantities: const [2],
          ),
        ),
        configuredTarget: target,
      ),
      // 6. completed (6/5)
      interpretCounterDay(
        day: _day(
          applicability: HabitApplicability.applicable,
          occurrenceId: 'o_completed',
          progress: CounterProgress.fromEvents(
            target: 5,
            quantities: const [6],
          ),
        ),
        configuredTarget: target,
      ),
      // 7. failed with partial recovery (recorded 1/5, recovered 2 -> remaining 2)
      interpretCounterDay(
        day: _day(
          applicability: HabitApplicability.applicable,
          occurrenceId: 'o_failed',
          progress: CounterProgress.fromEvents(
            target: 5,
            quantities: const [1],
          ),
          resolution: CounterResolution(
            id: 'r_failed',
            state: CounterResolutionState.failed,
            reason: null,
            target: 5,
            progress: 1,
            occurredAtUtc: utc,
          ),
          recoveries: [
            CounterRecoveryRecord(
              id: 'rec_partial',
              occurrenceId: 'o_failed',
              recoveryDate: LocalDate(2026, 11, 27),
              quantity: 2,
              originalTarget: 5,
              originalProgress: 1,
              remainingDeficit: 2,
              note: null,
              occurredAtUtc: utc,
            ),
          ],
        ),
        configuredTarget: target,
        date: LocalDate(2026, 11, 26),
      ),
      // 8. recovered (recorded 2/5, recovered 3 -> remaining 0)
      interpretCounterDay(
        day: _day(
          applicability: HabitApplicability.applicable,
          occurrenceId: 'o_recovered',
          progress: CounterProgress.fromEvents(
            target: 5,
            quantities: const [2],
          ),
          resolution: CounterResolution(
            id: 'r_rec',
            state: CounterResolutionState.failed,
            reason: null,
            target: 5,
            progress: 2,
            occurredAtUtc: utc,
          ),
          recoveries: [
            CounterRecoveryRecord(
              id: 'rec_full',
              occurrenceId: 'o_recovered',
              recoveryDate: LocalDate(2026, 11, 27),
              quantity: 3,
              originalTarget: 5,
              originalProgress: 2,
              remainingDeficit: 0,
              note: null,
              occurredAtUtc: utc,
            ),
          ],
        ),
        configuredTarget: target,
        date: LocalDate(2026, 11, 26),
      ),
      // 9. excused (recorded 1/5)
      interpretCounterDay(
        day: _day(
          applicability: HabitApplicability.applicable,
          occurrenceId: 'o_excused',
          progress: CounterProgress.fromEvents(
            target: 5,
            quantities: const [1],
          ),
          resolution: CounterResolution(
            id: 'r_exc',
            state: CounterResolutionState.excused,
            reason: null,
            target: 5,
            progress: 1,
            occurredAtUtc: utc,
          ),
        ),
        configuredTarget: target,
      ),
      // 10. conflict (record on notApplicable day; its quantity 99 is excluded from valid totals)
      interpretCounterDay(
        day: _day(
          applicability: HabitApplicability.notApplicable,
          occurrenceId: 'o_conflict',
          progress: CounterProgress.fromEvents(
            target: 5,
            quantities: const [99],
          ),
        ),
      ),
    ];

    final summary = CounterRangeSummary.fromEvaluations(evaluations);
    expect(summary.totalDays, 10);
    expect(summary.applicableDays, 7);
    expect(summary.notApplicableDays, 1);
    expect(summary.unknownDays, 1);
    expect(summary.conflictDays, 1);
    expect(summary.pendingDays, 2);
    expect(summary.missingOccurrencePendingDays, 1);
    expect(summary.recordedZeroPendingDays, 1);
    expect(summary.partialDays, 1);
    expect(summary.completedDays, 1);
    expect(summary.failedDays, 1);
    expect(summary.recoveredDays, 1);
    expect(summary.excusedDays, 1);

    // Valid recorded quantities: 2 (partial) + 6 (completed) + 1 (failed) + 2 (recovered) + 1 (excused) = 12
    expect(summary.recordedQuantityTotal, 12);
    // Recovered quantities: 2 (failed partial) + 3 (recovered) = 5
    expect(summary.recoveredQuantityTotal, 5);
    // Remaining deficit: 2 (failed partial)
    expect(summary.remainingDeficitTotal, 2);

    expect(summary.hasApplicableDays, isTrue);
    expect(summary.hasRecordedOutcomeDays, isTrue);
    expect(summary.hasUnresolvedApplicableDays, isTrue);
    expect(summary.hasUnknownOrConflictDays, isTrue);
  });
}
