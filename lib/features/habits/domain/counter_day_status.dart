import '../data/counter_day_reader.dart';
import '../data/counter_resolution.dart';
import '../data/habit_lifecycle.dart';
import 'counter_progress.dart';
import 'counter_recovery.dart';
import 'counter_target.dart';
import 'habit_schedule.dart';

/// Effective day status derived from applicability, progress, resolution and recovery.
enum CounterDayEffectiveStatus {
  notApplicable,
  unknown,
  pending,
  partial,
  completed,
  failed,
  recovered,
  excused,
  conflict,
}

/// Complete read-only interpretation of a counter habit on a local date.
/// Underlying records remain accessible even when effectiveStatus is conflict.
class CounterDayEvaluation {
  const CounterDayEvaluation({
    required this.effectiveStatus,
    required this.day,
    required this.configuredTarget,
    this.recovery,
  });

  final CounterDayEffectiveStatus effectiveStatus;
  final CounterDay day;
  final CounterTarget? configuredTarget;
  final CounterRecovery? recovery;

  bool get hasOccurrence => day.occurrenceId != null;
}

/// Combines schedule/lifecycle applicability, configured version target and
/// existing occurrence records without fabricating occurrences or hiding data.
CounterDayEvaluation interpretCounterDay({
  required CounterDay day,
  CounterTarget? configuredTarget,
  LocalDate? date,
}) {
  final hasRecord =
      day.occurrenceId != null ||
      day.recorded != null ||
      day.resolution != null ||
      day.recoveries.isNotEmpty;

  if (day.applicability == HabitApplicability.notApplicable) {
    return CounterDayEvaluation(
      effectiveStatus: hasRecord
          ? CounterDayEffectiveStatus.conflict
          : CounterDayEffectiveStatus.notApplicable,
      day: day,
      configuredTarget: configuredTarget,
    );
  }

  if (day.applicability == HabitApplicability.unknown) {
    return CounterDayEvaluation(
      effectiveStatus: hasRecord
          ? CounterDayEffectiveStatus.conflict
          : CounterDayEffectiveStatus.unknown,
      day: day,
      configuredTarget: configuredTarget,
    );
  }

  final recorded = day.recorded;
  final resolution = day.resolution;

  if (day.occurrenceId == null) {
    if (recorded != null || resolution != null || day.recoveries.isNotEmpty) {
      return CounterDayEvaluation(
        effectiveStatus: CounterDayEffectiveStatus.conflict,
        day: day,
        configuredTarget: configuredTarget,
      );
    }
    return CounterDayEvaluation(
      effectiveStatus: configuredTarget == null
          ? CounterDayEffectiveStatus.unknown
          : CounterDayEffectiveStatus.pending,
      day: day,
      configuredTarget: configuredTarget,
    );
  }

  if (recorded == null) {
    return CounterDayEvaluation(
      effectiveStatus: CounterDayEffectiveStatus.conflict,
      day: day,
      configuredTarget: configuredTarget,
    );
  }

  if (resolution != null) {
    final snapshotMatches =
        resolution.target == recorded.progress.target &&
        resolution.progress == recorded.progress.total;
    final incomplete =
        recorded.progress.status != CounterProgressStatus.completed &&
        recorded.progress.total < recorded.progress.target;
    if (!snapshotMatches || !incomplete) {
      return CounterDayEvaluation(
        effectiveStatus: CounterDayEffectiveStatus.conflict,
        day: day,
        configuredTarget: configuredTarget,
      );
    }

    if (resolution.state == CounterResolutionState.excused) {
      if (day.recoveries.isNotEmpty) {
        return CounterDayEvaluation(
          effectiveStatus: CounterDayEffectiveStatus.conflict,
          day: day,
          configuredTarget: configuredTarget,
        );
      }
      return CounterDayEvaluation(
        effectiveStatus: CounterDayEffectiveStatus.excused,
        day: day,
        configuredTarget: configuredTarget,
      );
    }

    final initialDeficit = recorded.progress.target - recorded.progress.total;
    var recoveredSoFar = 0;
    for (final entry in day.recoveries) {
      if (entry.originalTarget != recorded.progress.target ||
          entry.originalProgress != recorded.progress.total ||
          entry.quantity <= 0 ||
          entry.quantity > initialDeficit - recoveredSoFar ||
          (date != null && entry.recoveryDate.compareTo(date) <= 0)) {
        return CounterDayEvaluation(
          effectiveStatus: CounterDayEffectiveStatus.conflict,
          day: day,
          configuredTarget: configuredTarget,
        );
      }
      recoveredSoFar += entry.quantity;
      if (entry.remainingDeficit != initialDeficit - recoveredSoFar) {
        return CounterDayEvaluation(
          effectiveStatus: CounterDayEffectiveStatus.conflict,
          day: day,
          configuredTarget: configuredTarget,
        );
      }
    }

    final recovery = CounterRecovery.fromEvents(
      progress: recorded.progress,
      resolution: resolution.state,
      quantities: day.recoveries.map((entry) => entry.quantity),
    );
    return CounterDayEvaluation(
      effectiveStatus: recovery.status == CounterRecoveryStatus.recovered
          ? CounterDayEffectiveStatus.recovered
          : CounterDayEffectiveStatus.failed,
      day: day,
      configuredTarget: configuredTarget,
      recovery: recovery,
    );
  }

  if (day.recoveries.isNotEmpty) {
    return CounterDayEvaluation(
      effectiveStatus: CounterDayEffectiveStatus.conflict,
      day: day,
      configuredTarget: configuredTarget,
    );
  }

  return CounterDayEvaluation(
    effectiveStatus: switch (recorded.progress.status) {
      CounterProgressStatus.pending => CounterDayEffectiveStatus.pending,
      CounterProgressStatus.partial => CounterDayEffectiveStatus.partial,
      CounterProgressStatus.completed => CounterDayEffectiveStatus.completed,
    },
    day: day,
    configuredTarget: configuredTarget,
  );
}
