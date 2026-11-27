import '../../habits/domain/habit_schedule.dart';

/// Kinds of Focus / Pomodoro sessions.
enum FocusSessionKind {
  focus('focus', 'Focus'),
  shortBreak('short_break', 'Short break'),
  longBreak('long_break', 'Long break');

  const FocusSessionKind(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static FocusSessionKind fromStorageKey(String raw) {
    for (final kind in values) {
      if (kind.storageKey == raw) return kind;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown focus session kind');
  }
}

/// Lifecycle states of a persisted focus session.
enum FocusSessionState {
  running('running', 'Running'),
  paused('paused', 'Paused'),
  completed('completed', 'Completed'),
  interrupted('interrupted', 'Interrupted'),
  cancelled('cancelled', 'Cancelled');

  const FocusSessionState(this.storageKey, this.label);

  final String storageKey;
  final String label;

  bool get isActive => this == running || this == paused;
  bool get isTerminal => !isActive;

  static FocusSessionState fromStorageKey(String raw) {
    for (final state in values) {
      if (state.storageKey == raw) return state;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown focus session state');
  }
}

/// Focus / Pomodoro preset configuration.
/// Default Pomodoro timings are 25 / 5 / 15 minutes with a long break after 4
/// completed focus sessions.
class FocusPreset {
  FocusPreset({
    required String id,
    required String name,
    this.focusMinutes = 25,
    this.shortBreakMinutes = 5,
    this.longBreakMinutes = 15,
    this.sessionsBeforeLongBreak = 4,
    required this.createdAtUtc,
  }) : id = id.trim(),
       name = name.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError('Focus preset id must not be blank');
    }
    if (this.name.isEmpty) {
      throw ArgumentError('Focus preset name must not be blank');
    }
    if (focusMinutes <= 0 ||
        shortBreakMinutes <= 0 ||
        longBreakMinutes <= 0 ||
        sessionsBeforeLongBreak <= 0) {
      throw ArgumentError('Focus preset durations and cycle must be positive');
    }
  }

  static const int defaultFocusMinutes = 25;
  static const int defaultShortBreakMinutes = 5;
  static const int defaultLongBreakMinutes = 15;
  static const int defaultSessionsBeforeLongBreak = 4;

  static FocusPreset defaultPomodoro(DateTime createdAtUtc) => FocusPreset(
    id: 'default-pomodoro',
    name: 'Classic Pomodoro (25 / 5 / 15)',
    focusMinutes: defaultFocusMinutes,
    shortBreakMinutes: defaultShortBreakMinutes,
    longBreakMinutes: defaultLongBreakMinutes,
    sessionsBeforeLongBreak: defaultSessionsBeforeLongBreak,
    createdAtUtc: createdAtUtc.toUtc(),
  );

  final String id;
  final String name;
  final int focusMinutes;
  final int shortBreakMinutes;
  final int longBreakMinutes;
  final int sessionsBeforeLongBreak;
  final DateTime createdAtUtc;

  int plannedSecondsFor(FocusSessionKind kind) {
    switch (kind) {
      case FocusSessionKind.focus:
        return focusMinutes * 60;
      case FocusSessionKind.shortBreak:
        return shortBreakMinutes * 60;
      case FocusSessionKind.longBreak:
        return longBreakMinutes * 60;
    }
  }
}

/// Restart-safe Focus / Pomodoro session model.
class FocusSession {
  FocusSession({
    required String id,
    this.presetId,
    required this.kind,
    required this.localDate,
    required this.plannedDurationSeconds,
    required this.state,
    this.cycleIndex = 1,
    required this.startedAtUtc,
    this.lastResumedAtUtc,
    this.deadlineUtc,
    required this.accumulatedElapsedSeconds,
    this.endedAtUtc,
    String? interruptionReason,
    this.linkedHabitId,
    this.linkedGoalId,
    this.linkedHabitEventId,
    this.linkedGoalProgressId,
    String? note,
  }) : id = id.trim(),
       interruptionReason = _cleanOptional(interruptionReason),
       note = _cleanOptional(note) {
    if (this.id.isEmpty) {
      throw ArgumentError('Focus session id must not be blank');
    }
    if (plannedDurationSeconds <= 0) {
      throw ArgumentError.value(
        plannedDurationSeconds,
        'plannedDurationSeconds',
        'Planned duration must be positive',
      );
    }
    if (cycleIndex <= 0) {
      throw ArgumentError.value(
        cycleIndex,
        'cycleIndex',
        'Cycle index must be positive',
      );
    }
    if (accumulatedElapsedSeconds < 0 ||
        accumulatedElapsedSeconds > plannedDurationSeconds) {
      throw ArgumentError.value(
        accumulatedElapsedSeconds,
        'accumulatedElapsedSeconds',
        'Accumulated elapsed seconds must be within [0, plannedDurationSeconds]',
      );
    }
    if (state == FocusSessionState.running) {
      if (lastResumedAtUtc == null || deadlineUtc == null) {
        throw ArgumentError(
          'Running focus session requires lastResumedAtUtc and deadlineUtc',
        );
      }
      if (endedAtUtc != null) {
        throw ArgumentError('Running focus session must not have endedAtUtc');
      }
    } else if (state == FocusSessionState.paused) {
      if (lastResumedAtUtc != null || deadlineUtc != null) {
        throw ArgumentError(
          'Paused focus session must not have active deadline timestamps',
        );
      }
      if (endedAtUtc != null) {
        throw ArgumentError('Paused focus session must not have endedAtUtc');
      }
    } else {
      if (lastResumedAtUtc != null || deadlineUtc != null) {
        throw ArgumentError(
          'Terminal focus session must not have active deadline timestamps',
        );
      }
      if (endedAtUtc == null) {
        throw ArgumentError('Terminal focus session requires endedAtUtc');
      }
    }
    if (state != FocusSessionState.interrupted &&
        this.interruptionReason != null) {
      throw ArgumentError(
        'Only interrupted focus sessions may carry an interruptionReason',
      );
    }
  }

  final String id;
  final String? presetId;
  final FocusSessionKind kind;
  final LocalDate localDate;
  final int plannedDurationSeconds;
  final FocusSessionState state;
  final int cycleIndex;
  final DateTime startedAtUtc;
  final DateTime? lastResumedAtUtc;
  final DateTime? deadlineUtc;
  final int accumulatedElapsedSeconds;
  final DateTime? endedAtUtc;
  final String? interruptionReason;
  final String? linkedHabitId;
  final String? linkedGoalId;
  final String? linkedHabitEventId;
  final String? linkedGoalProgressId;
  final String? note;

  /// Computes deterministic elapsed whole seconds as of [nowUtc], surviving
  /// app restart using persisted [accumulatedElapsedSeconds] + [lastResumedAtUtc].
  int elapsedSecondsAt(DateTime nowUtc) {
    if (state != FocusSessionState.running) {
      return accumulatedElapsedSeconds;
    }
    final deltaSeconds = nowUtc.toUtc().difference(lastResumedAtUtc!).inSeconds;
    final liveDelta = deltaSeconds < 0 ? 0 : deltaSeconds;
    final total = accumulatedElapsedSeconds + liveDelta;
    return total > plannedDurationSeconds ? plannedDurationSeconds : total;
  }

  /// Computes remaining whole seconds as of [nowUtc], clamped to `[0, plannedDurationSeconds]`.
  int remainingSecondsAt(DateTime nowUtc) {
    final remaining = plannedDurationSeconds - elapsedSecondsAt(nowUtc);
    return remaining < 0 ? 0 : remaining;
  }

  /// True when a currently running session has reached or passed its persisted deadline.
  bool isDeadlineReachedAt(DateTime nowUtc) {
    if (state != FocusSessionState.running || deadlineUtc == null) {
      return false;
    }
    return !nowUtc.toUtc().isBefore(deadlineUtc!);
  }
}

/// Deterministic Pomodoro cycle planner.
/// Defaults to 4 focus sessions before recommending a long break.
class FocusCycleRecommendation {
  const FocusCycleRecommendation({
    required this.nextKind,
    required this.nextCycleIndex,
    required this.completedFocusInCurrentCycle,
    required this.sessionsBeforeLongBreak,
  });

  final FocusSessionKind nextKind;
  final int nextCycleIndex;
  final int completedFocusInCurrentCycle;
  final int sessionsBeforeLongBreak;
}

class FocusCyclePlanner {
  const FocusCyclePlanner._();

  /// Computes the next recommended Pomodoro session kind and cycle index from
  /// chronological session history. Interrupted and cancelled sessions do not
  /// advance the completed-focus count.
  static FocusCycleRecommendation recommendNext({
    required List<FocusSession> chronologicalSessions,
    int sessionsBeforeLongBreak = FocusPreset.defaultSessionsBeforeLongBreak,
  }) {
    if (sessionsBeforeLongBreak <= 0) {
      throw ArgumentError.value(
        sessionsBeforeLongBreak,
        'sessionsBeforeLongBreak',
        'Must be positive',
      );
    }

    var completedFocusSinceLongBreak = 0;
    FocusSession? lastCompleted;
    for (final session in chronologicalSessions) {
      if (session.state != FocusSessionState.completed) continue;
      lastCompleted = session;
      if (session.kind == FocusSessionKind.focus) {
        completedFocusSinceLongBreak++;
      } else if (session.kind == FocusSessionKind.longBreak) {
        completedFocusSinceLongBreak = 0;
      }
    }

    if (lastCompleted == null) {
      return FocusCycleRecommendation(
        nextKind: FocusSessionKind.focus,
        nextCycleIndex: 1,
        completedFocusInCurrentCycle: 0,
        sessionsBeforeLongBreak: sessionsBeforeLongBreak,
      );
    }

    if (lastCompleted.kind == FocusSessionKind.focus) {
      if (completedFocusSinceLongBreak >= sessionsBeforeLongBreak) {
        return FocusCycleRecommendation(
          nextKind: FocusSessionKind.longBreak,
          nextCycleIndex: sessionsBeforeLongBreak,
          completedFocusInCurrentCycle: sessionsBeforeLongBreak,
          sessionsBeforeLongBreak: sessionsBeforeLongBreak,
        );
      }
      return FocusCycleRecommendation(
        nextKind: FocusSessionKind.shortBreak,
        nextCycleIndex: completedFocusSinceLongBreak,
        completedFocusInCurrentCycle: completedFocusSinceLongBreak,
        sessionsBeforeLongBreak: sessionsBeforeLongBreak,
      );
    }

    final nextIndex = completedFocusSinceLongBreak >= sessionsBeforeLongBreak
        ? 1
        : completedFocusSinceLongBreak + 1;
    final cycleCount = completedFocusSinceLongBreak >= sessionsBeforeLongBreak
        ? 0
        : completedFocusSinceLongBreak;
    return FocusCycleRecommendation(
      nextKind: FocusSessionKind.focus,
      nextCycleIndex: nextIndex,
      completedFocusInCurrentCycle: cycleCount,
      sessionsBeforeLongBreak: sessionsBeforeLongBreak,
    );
  }
}

/// Summary of focus history distinguishing completed, interrupted and cancelled sessions.
class FocusHistorySummary {
  const FocusHistorySummary({
    required this.completedFocusCount,
    required this.interruptedFocusCount,
    required this.cancelledFocusCount,
    required this.completedBreakCount,
    required this.totalCompletedFocusSeconds,
    required this.totalInterruptedFocusSeconds,
  });

  final int completedFocusCount;
  final int interruptedFocusCount;
  final int cancelledFocusCount;
  final int completedBreakCount;
  final int totalCompletedFocusSeconds;
  final int totalInterruptedFocusSeconds;

  static FocusHistorySummary summarize(Iterable<FocusSession> sessions) {
    var completedFocus = 0;
    var interruptedFocus = 0;
    var cancelledFocus = 0;
    var completedBreaks = 0;
    var completedFocusSeconds = 0;
    var interruptedFocusSeconds = 0;

    for (final session in sessions) {
      if (session.kind == FocusSessionKind.focus) {
        switch (session.state) {
          case FocusSessionState.completed:
            completedFocus++;
            completedFocusSeconds += session.accumulatedElapsedSeconds;
          case FocusSessionState.interrupted:
            interruptedFocus++;
            interruptedFocusSeconds += session.accumulatedElapsedSeconds;
          case FocusSessionState.cancelled:
            cancelledFocus++;
          case FocusSessionState.running:
          case FocusSessionState.paused:
            break;
        }
      } else if (session.state == FocusSessionState.completed) {
        completedBreaks++;
      }
    }

    return FocusHistorySummary(
      completedFocusCount: completedFocus,
      interruptedFocusCount: interruptedFocus,
      cancelledFocusCount: cancelledFocus,
      completedBreakCount: completedBreaks,
      totalCompletedFocusSeconds: completedFocusSeconds,
      totalInterruptedFocusSeconds: interruptedFocusSeconds,
    );
  }
}

/// Formats whole seconds as `MM:SS` (or `H:MM:SS` for >= 1 hour).
String formatFocusClock(int totalSeconds) {
  final safe = totalSeconds < 0 ? 0 : totalSeconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final seconds = safe % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$mm:$ss';
  }
  return '$mm:$ss';
}

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
