import '../../habits/domain/habit_schedule.dart';

/// Supported lifecycle states for personal goals.
enum GoalStatus {
  planned('planned', 'Planned'),
  inProgress('in_progress', 'In progress'),
  completed('completed', 'Completed'),
  paused('paused', 'Paused'),
  abandoned('abandoned', 'Abandoned');

  const GoalStatus(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static GoalStatus fromStorageKey(String raw) {
    for (final status in values) {
      if (status.storageKey == raw) return status;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown goal status');
  }
}

/// Source attribution for goal progress entries so linked and manual progress
/// remain distinguishable and deduplicated.
enum GoalProgressSource {
  manual('manual', 'Manual'),
  linkedHabit('linked_habit', 'Linked habit'),
  linkedFocus('linked_focus', 'Focus session'),
  milestone('milestone', 'Milestone');

  const GoalProgressSource(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static GoalProgressSource fromStorageKey(String raw) {
    for (final source in values) {
      if (source.storageKey == raw) return source;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown goal progress source');
  }
}

class Goal {
  Goal({
    required String id,
    required String title,
    String? description,
    required this.status,
    this.targetDate,
    this.targetUnits,
    String? unitLabel,
    this.isPrivate = false,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : id = id.trim(),
       title = title.trim(),
       description = _cleanOptional(description),
       unitLabel = _cleanOptional(unitLabel) {
    if (this.id.isEmpty) {
      throw ArgumentError('Goal id must not be blank');
    }
    if (this.title.isEmpty) {
      throw ArgumentError('Goal title must not be blank');
    }
    if (targetUnits != null && targetUnits! <= 0) {
      throw ArgumentError.value(
        targetUnits,
        'targetUnits',
        'Goal target units must be positive when configured',
      );
    }
  }

  final String id;
  final String title;
  final String? description;
  final GoalStatus status;
  final LocalDate? targetDate;
  final int? targetUnits;
  final String? unitLabel;
  final bool isPrivate;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

class GoalStatusEvent {
  GoalStatusEvent({
    required String id,
    required String goalId,
    this.previousStatus,
    required this.newStatus,
    String? reason,
    required this.occurredAtUtc,
  }) : id = id.trim(),
       goalId = goalId.trim(),
       reason = _cleanOptional(reason) {
    if (this.id.isEmpty) {
      throw ArgumentError('Goal status event id must not be blank');
    }
    if (this.goalId.isEmpty) {
      throw ArgumentError('Goal id must not be blank');
    }
  }

  final String id;
  final String goalId;
  final GoalStatus? previousStatus;
  final GoalStatus newStatus;
  final String? reason;
  final DateTime occurredAtUtc;
}

class GoalMilestone {
  GoalMilestone({
    required String id,
    required String goalId,
    required String title,
    this.sortOrder = 0,
    this.isCompleted = false,
    this.completedAtUtc,
    required this.createdAtUtc,
  }) : id = id.trim(),
       goalId = goalId.trim(),
       title = title.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError('Milestone id must not be blank');
    }
    if (this.goalId.isEmpty) {
      throw ArgumentError('Goal id must not be blank');
    }
    if (this.title.isEmpty) {
      throw ArgumentError('Milestone title must not be blank');
    }
    if (isCompleted && completedAtUtc == null) {
      throw ArgumentError(
        'Completed milestone must include a completion timestamp',
      );
    }
    if (!isCompleted && completedAtUtc != null) {
      throw ArgumentError(
        'Incomplete milestone must not carry a completion timestamp',
      );
    }
  }

  final String id;
  final String goalId;
  final String title;
  final int sortOrder;
  final bool isCompleted;
  final DateTime? completedAtUtc;
  final DateTime createdAtUtc;
}

class GoalProgressEntry {
  GoalProgressEntry({
    required String id,
    required String goalId,
    required this.localDate,
    required this.units,
    required this.source,
    String? sourceRefId,
    String? note,
    required this.occurredAtUtc,
  }) : id = id.trim(),
       goalId = goalId.trim(),
       sourceRefId = _cleanOptional(sourceRefId),
       note = _cleanOptional(note) {
    if (this.id.isEmpty) {
      throw ArgumentError('Progress entry id must not be blank');
    }
    if (this.goalId.isEmpty) {
      throw ArgumentError('Goal id must not be blank');
    }
    if (units <= 0) {
      throw ArgumentError.value(
        units,
        'units',
        'Progress units must be positive',
      );
    }
    if (source != GoalProgressSource.manual && this.sourceRefId == null) {
      throw ArgumentError(
        'Linked or milestone goal progress must include a sourceRefId for deduplication',
      );
    }
  }

  final String id;
  final String goalId;
  final LocalDate localDate;
  final int units;
  final GoalProgressSource source;
  final String? sourceRefId;
  final String? note;
  final DateTime occurredAtUtc;
}

/// Deterministic progress summary for a single goal, derived from milestones
/// and deduplicated progress entries.
class GoalProgressSummary {
  const GoalProgressSummary({
    required this.goal,
    required this.milestones,
    required this.linkedHabitIds,
    required this.progressEntries,
    required this.statusHistory,
    required this.totalUnits,
    required this.manualUnits,
    required this.linkedHabitUnits,
    required this.linkedFocusUnits,
    required this.milestoneUnits,
    required this.completedMilestones,
    required this.totalMilestones,
    required this.unitCompletionRatio,
    required this.milestoneCompletionRatio,
  });

  final Goal goal;
  final List<GoalMilestone> milestones;
  final List<String> linkedHabitIds;
  final List<GoalProgressEntry> progressEntries;
  final List<GoalStatusEvent> statusHistory;
  final int totalUnits;
  final int manualUnits;
  final int linkedHabitUnits;
  final int linkedFocusUnits;
  final int milestoneUnits;
  final int completedMilestones;
  final int totalMilestones;
  final double? unitCompletionRatio;
  final double? milestoneCompletionRatio;
}

class GoalProgressCalculator {
  const GoalProgressCalculator._();

  /// Computes a deterministic goal summary while guarding against duplicate
  /// `(source, sourceRefId)` linked entries.
  static GoalProgressSummary summarize({
    required Goal goal,
    required List<GoalMilestone> milestones,
    required List<String> linkedHabitIds,
    required List<GoalProgressEntry> progressEntries,
    required List<GoalStatusEvent> statusHistory,
  }) {
    final seenRefs = <(GoalProgressSource, String)>{};
    final dedupedEntries = <GoalProgressEntry>[];
    var totalUnits = 0;
    var manualUnits = 0;
    var linkedHabitUnits = 0;
    var linkedFocusUnits = 0;
    var milestoneUnits = 0;

    for (final entry in progressEntries) {
      if (entry.goalId != goal.id) continue;
      if (entry.sourceRefId != null) {
        final key = (entry.source, entry.sourceRefId!);
        if (!seenRefs.add(key)) {
          continue;
        }
      }
      dedupedEntries.add(entry);
      totalUnits += entry.units;
      switch (entry.source) {
        case GoalProgressSource.manual:
          manualUnits += entry.units;
        case GoalProgressSource.linkedHabit:
          linkedHabitUnits += entry.units;
        case GoalProgressSource.linkedFocus:
          linkedFocusUnits += entry.units;
        case GoalProgressSource.milestone:
          milestoneUnits += entry.units;
      }
    }

    final completedMilestones = milestones.where((m) => m.isCompleted).length;
    final totalMilestones = milestones.length;
    final unitRatio = goal.targetUnits == null
        ? null
        : (totalUnits / goal.targetUnits!).clamp(0.0, 1.0);
    final milestoneRatio = totalMilestones == 0
        ? null
        : (completedMilestones / totalMilestones).clamp(0.0, 1.0);

    return GoalProgressSummary(
      goal: goal,
      milestones: List<GoalMilestone>.unmodifiable(milestones),
      linkedHabitIds: List<String>.unmodifiable(linkedHabitIds),
      progressEntries: List<GoalProgressEntry>.unmodifiable(dedupedEntries),
      statusHistory: List<GoalStatusEvent>.unmodifiable(statusHistory),
      totalUnits: totalUnits,
      manualUnits: manualUnits,
      linkedHabitUnits: linkedHabitUnits,
      linkedFocusUnits: linkedFocusUnits,
      milestoneUnits: milestoneUnits,
      completedMilestones: completedMilestones,
      totalMilestones: totalMilestones,
      unitCompletionRatio: unitRatio,
      milestoneCompletionRatio: milestoneRatio,
    );
  }
}

/// Canonical deduplication reference key for a linked habit occurrence on a date.
String buildLinkedHabitProgressRef(String habitId, LocalDate date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return 'habit:${habitId.trim()}:$y-$m-$d';
}

/// Canonical deduplication reference key for a completed focus session.
String buildLinkedFocusProgressRef(String focusSessionId) =>
    'focus:${focusSessionId.trim()}';

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
