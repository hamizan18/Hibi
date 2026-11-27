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

/// An audited target transition and the records present before it. Null
/// recovery IDs denote a legacy audit without record-level preimages.
typedef CounterCorrectionStage = ({
  int previous,
  int updated,
  List<String>? recoveryIds,
  String? resolutionId,
});

/// Combines schedule/lifecycle applicability, configured version target and
/// existing occurrence records without fabricating occurrences or hiding data.
CounterDayEvaluation interpretCounterDay({
  required CounterDay day,
  CounterTarget? configuredTarget,
  LocalDate? date,
  List<CounterCorrectionStage> corrections = const [],
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
    // The immutable resolution and recovery snapshots reflect the target in
    // force when they were written, not necessarily today's corrected target.
    final targets = <int>[];
    var validHistory = true;
    for (final correction in corrections) {
      if (targets.isEmpty) {
        targets.add(correction.previous);
      } else if (targets.last != correction.previous) {
        validHistory = false;
      }
      targets.add(correction.updated);
    }
    if (targets.isEmpty) targets.add(recorded.progress.target);
    if (targets.last != recorded.progress.target) validHistory = false;
    var checkedRecoveries = 0;
    var needsLegacyAnchor = false;
    int? auditedResolutionTarget;
    for (final correction in corrections) {
      final ids = correction.recoveryIds;
      if (ids == null) {
        needsLegacyAnchor = true;
        continue;
      }
      if (correction.resolutionId != null) {
        if (correction.resolutionId != resolution.id) validHistory = false;
        auditedResolutionTarget ??= correction.previous;
      } else if (auditedResolutionTarget != null) {
        validHistory = false;
      }
      if (ids.length < checkedRecoveries ||
          ids.length > day.recoveries.length) {
        validHistory = false;
        continue;
      }
      for (var i = 0; i < ids.length; i++) {
        if (ids[i] != day.recoveries[i].id) validHistory = false;
        if (!needsLegacyAnchor &&
            i >= checkedRecoveries &&
            day.recoveries[i].originalTarget != correction.previous) {
          validHistory = false;
        }
      }
      checkedRecoveries = ids.length;
      needsLegacyAnchor = false;
    }
    if (corrections.isNotEmpty &&
        corrections.every((correction) => correction.recoveryIds != null)) {
      if (resolution.target !=
          (auditedResolutionTarget ?? recorded.progress.target)) {
        validHistory = false;
      }
      for (var i = checkedRecoveries; i < day.recoveries.length; i++) {
        if (day.recoveries[i].originalTarget != recorded.progress.target) {
          validHistory = false;
        }
      }
    }
    var targetIndex = targets.indexOf(resolution.target);
    final snapshotMatches =
        validHistory &&
        targetIndex >= 0 &&
        resolution.progress == recorded.progress.total &&
        resolution.progress < resolution.target;
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
      final entryTargetIndex = targets.indexOf(
        entry.originalTarget,
        targetIndex,
      );
      if (entryTargetIndex < 0 ||
          entry.originalProgress != recorded.progress.total ||
          entry.quantity <= 0 ||
          entry.quantity >
              entry.originalTarget - recorded.progress.total - recoveredSoFar ||
          entry.quantity > initialDeficit - recoveredSoFar ||
          (date != null && entry.recoveryDate.compareTo(date) <= 0)) {
        return CounterDayEvaluation(
          effectiveStatus: CounterDayEffectiveStatus.conflict,
          day: day,
          configuredTarget: configuredTarget,
        );
      }
      targetIndex = entryTargetIndex;
      recoveredSoFar += entry.quantity;
      if (entry.remainingDeficit !=
          entry.originalTarget - recorded.progress.total - recoveredSoFar) {
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
