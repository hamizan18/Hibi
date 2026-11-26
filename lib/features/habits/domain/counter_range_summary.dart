import 'counter_day_status.dart';

/// Deterministic summary of counter-day evaluations across a date range.
/// Keeps pending, unknown, notApplicable and conflict distinct from failed,
/// and separates same-day recorded quantities from recovered quantities.
class CounterRangeSummary {
  const CounterRangeSummary._({
    required this.totalDays,
    required this.applicableDays,
    required this.notApplicableDays,
    required this.unknownDays,
    required this.conflictDays,
    required this.pendingDays,
    required this.missingOccurrencePendingDays,
    required this.recordedZeroPendingDays,
    required this.partialDays,
    required this.completedDays,
    required this.failedDays,
    required this.recoveredDays,
    required this.excusedDays,
    required this.recordedQuantityTotal,
    required this.recoveredQuantityTotal,
    required this.remainingDeficitTotal,
  });

  factory CounterRangeSummary.fromEvaluations(
    Iterable<CounterDayEvaluation> evaluations,
  ) {
    const maximum = 9223372036854775807;
    var totalDays = 0;
    var notApplicableDays = 0;
    var unknownDays = 0;
    var conflictDays = 0;
    var missingOccurrencePendingDays = 0;
    var recordedZeroPendingDays = 0;
    var partialDays = 0;
    var completedDays = 0;
    var failedDays = 0;
    var recoveredDays = 0;
    var excusedDays = 0;
    var recordedQuantityTotal = 0;
    var recoveredQuantityTotal = 0;
    var remainingDeficitTotal = 0;

    for (final evaluation in evaluations) {
      totalDays += 1;
      switch (evaluation.effectiveStatus) {
        case CounterDayEffectiveStatus.notApplicable:
          notApplicableDays += 1;
        case CounterDayEffectiveStatus.unknown:
          unknownDays += 1;
        case CounterDayEffectiveStatus.conflict:
          conflictDays += 1;
        case CounterDayEffectiveStatus.pending:
          if (evaluation.hasOccurrence) {
            recordedZeroPendingDays += 1;
          } else {
            missingOccurrencePendingDays += 1;
          }
        case CounterDayEffectiveStatus.partial:
          partialDays += 1;
        case CounterDayEffectiveStatus.completed:
          completedDays += 1;
        case CounterDayEffectiveStatus.failed:
          failedDays += 1;
        case CounterDayEffectiveStatus.recovered:
          recoveredDays += 1;
        case CounterDayEffectiveStatus.excused:
          excusedDays += 1;
      }

      if (evaluation.effectiveStatus != CounterDayEffectiveStatus.conflict) {
        final recorded = evaluation.day.recorded?.progress.total ?? 0;
        if (recorded > maximum - recordedQuantityTotal) {
          throw RangeError(
            'Recorded quantity total exceeds signed 64-bit range',
          );
        }
        recordedQuantityTotal += recorded;

        final recovered = evaluation.recovery?.recoveredTotal ?? 0;
        if (recovered > maximum - recoveredQuantityTotal) {
          throw RangeError(
            'Recovered quantity total exceeds signed 64-bit range',
          );
        }
        recoveredQuantityTotal += recovered;

        final deficit = evaluation.recovery?.remainingDeficit ?? 0;
        if (deficit > maximum - remainingDeficitTotal) {
          throw RangeError(
            'Remaining deficit total exceeds signed 64-bit range',
          );
        }
        remainingDeficitTotal += deficit;
      }
    }

    final pendingDays = missingOccurrencePendingDays + recordedZeroPendingDays;
    final applicableDays =
        pendingDays +
        partialDays +
        completedDays +
        failedDays +
        recoveredDays +
        excusedDays;

    return CounterRangeSummary._(
      totalDays: totalDays,
      applicableDays: applicableDays,
      notApplicableDays: notApplicableDays,
      unknownDays: unknownDays,
      conflictDays: conflictDays,
      pendingDays: pendingDays,
      missingOccurrencePendingDays: missingOccurrencePendingDays,
      recordedZeroPendingDays: recordedZeroPendingDays,
      partialDays: partialDays,
      completedDays: completedDays,
      failedDays: failedDays,
      recoveredDays: recoveredDays,
      excusedDays: excusedDays,
      recordedQuantityTotal: recordedQuantityTotal,
      recoveredQuantityTotal: recoveredQuantityTotal,
      remainingDeficitTotal: remainingDeficitTotal,
    );
  }

  final int totalDays;
  final int applicableDays;
  final int notApplicableDays;
  final int unknownDays;
  final int conflictDays;
  final int pendingDays;
  final int missingOccurrencePendingDays;
  final int recordedZeroPendingDays;
  final int partialDays;
  final int completedDays;
  final int failedDays;
  final int recoveredDays;
  final int excusedDays;
  final int recordedQuantityTotal;
  final int recoveredQuantityTotal;
  final int remainingDeficitTotal;

  bool get hasApplicableDays => applicableDays > 0;

  bool get hasRecordedOutcomeDays =>
      (partialDays + completedDays + failedDays + recoveredDays) > 0;

  bool get hasUnresolvedApplicableDays => pendingDays > 0;

  bool get hasUnknownOrConflictDays => (unknownDays + conflictDays) > 0;
}
