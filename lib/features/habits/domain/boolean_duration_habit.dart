enum BooleanLogState { completed, failed, excused }

enum DurationEntrySource { manual, timer }

enum DurationEffectiveStatus { pending, partial, completed, failed, excused }

/// Positive integer duration target in seconds.
class DurationTarget {
  DurationTarget({required this.targetSeconds}) {
    if (targetSeconds <= 0) {
      throw RangeError.value(
        targetSeconds,
        'targetSeconds',
        'Must be a positive whole number of seconds',
      );
    }
  }

  final int targetSeconds;
}

/// Validated manual or timer duration entry.
class DurationEntryInput {
  DurationEntryInput.manual({required this.durationSeconds})
    : source = DurationEntrySource.manual,
      startedAtUtc = null,
      endedAtUtc = null {
    if (durationSeconds <= 0) {
      throw RangeError.value(
        durationSeconds,
        'durationSeconds',
        'Must be positive',
      );
    }
  }

  DurationEntryInput.timer({
    required DateTime startedAtUtc,
    required DateTime endedAtUtc,
  }) : source = DurationEntrySource.timer,
       startedAtUtc = startedAtUtc.toUtc(),
       endedAtUtc = endedAtUtc.toUtc(),
       durationSeconds = endedAtUtc
           .toUtc()
           .difference(startedAtUtc.toUtc())
           .inSeconds {
    if (!this.endedAtUtc!.isAfter(this.startedAtUtc!) || durationSeconds <= 0) {
      throw ArgumentError(
        'Timer end must be at least 1 second after timer start',
      );
    }
  }

  final DurationEntrySource source;
  final int durationSeconds;
  final DateTime? startedAtUtc;
  final DateTime? endedAtUtc;
}

/// Pure duration day calculation across manual and timer entries.
class DurationDayProgress {
  const DurationDayProgress._({
    required this.targetSeconds,
    required this.totalSeconds,
    required this.status,
  });

  factory DurationDayProgress.evaluate({
    required int targetSeconds,
    required Iterable<int> entrySeconds,
    BooleanLogState? explicitResolution,
  }) {
    if (targetSeconds <= 0) {
      throw RangeError.value(targetSeconds, 'targetSeconds', 'Must be > 0');
    }
    var total = 0;
    for (final seconds in entrySeconds) {
      if (seconds <= 0) {
        throw RangeError.value(seconds, 'seconds', 'Must be > 0');
      }
      total += seconds;
    }
    if (explicitResolution == BooleanLogState.failed) {
      if (total >= targetSeconds) {
        throw StateError('Completed duration cannot be resolved as failed');
      }
      return DurationDayProgress._(
        targetSeconds: targetSeconds,
        totalSeconds: total,
        status: DurationEffectiveStatus.failed,
      );
    }
    if (explicitResolution == BooleanLogState.excused) {
      if (total >= targetSeconds) {
        throw StateError('Completed duration cannot be resolved as excused');
      }
      return DurationDayProgress._(
        targetSeconds: targetSeconds,
        totalSeconds: total,
        status: DurationEffectiveStatus.excused,
      );
    }
    final status = total == 0
        ? DurationEffectiveStatus.pending
        : total < targetSeconds
        ? DurationEffectiveStatus.partial
        : DurationEffectiveStatus.completed;
    return DurationDayProgress._(
      targetSeconds: targetSeconds,
      totalSeconds: total,
      status: status,
    );
  }

  final int targetSeconds;
  final int totalSeconds;
  final DurationEffectiveStatus status;
}
