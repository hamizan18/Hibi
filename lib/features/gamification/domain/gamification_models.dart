import '../../habits/domain/habit_analytics.dart';
import '../../habits/domain/habit_schedule.dart';

/// Versioned XP reward rules.
///
/// Rule version 1 (per BUSINESS_RULES.md):
/// - 10 XP for completed eligible habit occurrences
/// - 5 XP for recovered eligible habit occurrences
/// - 0 XP for failed, pending, partial, excused, not applicable, unknown, conflict
/// - 0 XP for private, unclassified, or reward-opted-out habits
/// - Never awards XP for finance spending, income, or repeated edits
/// - Never derives XP from dynamic normalized numeric scores
class GamificationRules {
  const GamificationRules._();

  static const int currentRuleVersion = 1;
  static const int completedXpV1 = 10;
  static const int recoveredXpV1 = 5;

  /// Canonical non-moralizing notice required by BUSINESS_RULES.md.
  static const String nonMoralizingNotice =
      'XP, levels, achievements and custom attributes reflect recorded activity only — '
      'never competence, human worth or faith. Private and opted-out habits are excluded.';

  static int expectedXpForOccurrence({
    required HabitAnalyticsStatus status,
    required bool includeInRewards,
    required bool isPrivate,
    required bool hasMetadata,
    int ruleVersion = currentRuleVersion,
  }) {
    if (ruleVersion != 1) {
      throw ArgumentError.value(
        ruleVersion,
        'ruleVersion',
        'Unsupported gamification rule version',
      );
    }
    if (!hasMetadata || isPrivate || !includeInRewards) {
      return 0;
    }
    switch (status) {
      case HabitAnalyticsStatus.completed:
        return completedXpV1;
      case HabitAnalyticsStatus.recovered:
        return recoveredXpV1;
      case HabitAnalyticsStatus.failed:
      case HabitAnalyticsStatus.pending:
      case HabitAnalyticsStatus.partial:
      case HabitAnalyticsStatus.excused:
      case HabitAnalyticsStatus.notApplicable:
      case HabitAnalyticsStatus.unknown:
      case HabitAnalyticsStatus.conflict:
        return 0;
    }
  }
}

/// Deterministic level progress where Level 1 starts at 0 XP and advancing from
/// level L to L + 1 requires `100 × L` XP.
class LevelProgress {
  const LevelProgress({
    required this.level,
    required this.totalXp,
    required this.cumulativeXpForCurrentLevel,
    required this.xpIntoCurrentLevel,
    required this.xpRequiredForNextLevel,
    required this.xpRemainingToNextLevel,
    required this.progressRatio,
  });

  final int level;
  final int totalXp;
  final int cumulativeXpForCurrentLevel;
  final int xpIntoCurrentLevel;
  final int xpRequiredForNextLevel;
  final int xpRemainingToNextLevel;
  final double progressRatio;
}

class LevelCalculator {
  const LevelCalculator._();

  /// Minimum cumulative XP required to reach [level] (Level 1 = 0, Level 2 = 100, Level 3 = 300...).
  static int cumulativeXpForLevel(int level) {
    if (level < 1) {
      throw ArgumentError.value(level, 'level', 'Level must be >= 1');
    }
    return 100 * level * (level - 1) ~/ 2;
  }

  static LevelProgress fromTotalXp(int rawTotalXp) {
    final totalXp = rawTotalXp < 0 ? 0 : rawTotalXp;
    var level = 1;
    var remaining = totalXp;
    while (remaining >= 100 * level) {
      remaining -= 100 * level;
      level++;
    }
    final requiredForNext = 100 * level;
    final cumulative = cumulativeXpForLevel(level);
    return LevelProgress(
      level: level,
      totalXp: totalXp,
      cumulativeXpForCurrentLevel: cumulative,
      xpIntoCurrentLevel: remaining,
      xpRequiredForNextLevel: requiredForNext,
      xpRemainingToNextLevel: requiredForNext - remaining,
      progressRatio: (remaining / requiredForNext).clamp(0.0, 1.0),
    );
  }
}

enum XpEntryKind {
  award('award', 'Award'),
  reconciliation('reconciliation', 'Reconciliation');

  const XpEntryKind(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static XpEntryKind fromStorageKey(String raw) {
    for (final v in values) {
      if (v.storageKey == raw) return v;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown XP entry kind');
  }
}

enum XpStatusSnapshot {
  completed('completed', 'Completed'),
  recovered('recovered', 'Recovered'),
  revoked('revoked', 'Revoked');

  const XpStatusSnapshot(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static XpStatusSnapshot fromStorageKey(String raw) {
    for (final v in values) {
      if (v.storageKey == raw) return v;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown XP status snapshot');
  }
}

/// Canonical idempotency source key for a habit occurrence on a local date.
String buildHabitRewardSourceKey(String habitId, LocalDate date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return 'habit:${habitId.trim()}:$y-$m-$d';
}

/// One immutable entry in the versioned XP ledger.
class XpLedgerEntry {
  const XpLedgerEntry({
    required this.id,
    required this.ruleVersion,
    required this.sourceType,
    required this.sourceKey,
    required this.habitId,
    required this.localDate,
    required this.entryKind,
    required this.statusSnapshot,
    required this.xpDelta,
    this.reason,
    required this.occurredAtUtc,
  });

  final String id;
  final int ruleVersion;
  final String sourceType;
  final String sourceKey;
  final String habitId;
  final LocalDate localDate;
  final XpEntryKind entryKind;
  final XpStatusSnapshot statusSnapshot;
  final int xpDelta;
  final String? reason;
  final DateTime occurredAtUtc;
}

class AchievementDefinition {
  const AchievementDefinition({
    required this.key,
    required this.title,
    required this.description,
    required this.ruleVersion,
  });

  final String key;
  final String title;
  final String description;
  final int ruleVersion;
}

/// Deterministic, non-private facts used to evaluate achievements reproducibly.
class AchievementEvaluationFacts {
  const AchievementEvaluationFacts({
    required this.eligibleCompletedCount,
    required this.eligibleCompletedDistinctDates,
    required this.eligibleRecoveredCount,
    required this.totalNetXp,
    required this.completedFocusSessions,
    required this.completedPublicGoalMilestones,
  });

  final int eligibleCompletedCount;
  final int eligibleCompletedDistinctDates;
  final int eligibleRecoveredCount;
  final int totalNetXp;
  final int completedFocusSessions;
  final int completedPublicGoalMilestones;
}

class AchievementCatalog {
  const AchievementCatalog._();

  static const String firstStep = 'first_step';
  static const String steadyFive = 'steady_five';
  static const String recoveryComeback = 'recovery_comeback';
  static const String xpCentury = 'xp_century';
  static const String focusFinisher = 'focus_finisher';
  static const String goalMilestone = 'goal_milestone';

  static const List<AchievementDefinition> all = [
    AchievementDefinition(
      key: firstStep,
      title: 'First Step',
      description:
          'Complete at least 1 reward-eligible public habit occurrence.',
      ruleVersion: GamificationRules.currentRuleVersion,
    ),
    AchievementDefinition(
      key: steadyFive,
      title: 'Steady Rhythm',
      description: 'Complete reward-eligible public habits across at least 5 distinct dates.',
      ruleVersion: GamificationRules.currentRuleVersion,
    ),
    AchievementDefinition(
      key: recoveryComeback,
      title: 'Steady Recovery',
      description: 'Recover at least 1 reward-eligible public prior deficit.',
      ruleVersion: GamificationRules.currentRuleVersion,
    ),
    AchievementDefinition(
      key: xpCentury,
      title: 'First 100 XP',
      description: 'Reach at least 100 net XP from eligible habit activity.',
      ruleVersion: GamificationRules.currentRuleVersion,
    ),
    AchievementDefinition(
      key: focusFinisher,
      title: 'Focus Finisher',
      description: 'Complete at least 1 Focus session.',
      ruleVersion: GamificationRules.currentRuleVersion,
    ),
    AchievementDefinition(
      key: goalMilestone,
      title: 'Milestone Reached',
      description: 'Complete at least 1 non-private goal milestone.',
      ruleVersion: GamificationRules.currentRuleVersion,
    ),
  ];

  static Map<String, bool> evaluate(AchievementEvaluationFacts facts) => {
    firstStep: facts.eligibleCompletedCount >= 1,
    steadyFive: facts.eligibleCompletedDistinctDates >= 5,
    recoveryComeback: facts.eligibleRecoveredCount >= 1,
    xpCentury: facts.totalNetXp >= 100,
    focusFinisher: facts.completedFocusSessions >= 1,
    goalMilestone: facts.completedPublicGoalMilestones >= 1,
  };
}

enum AchievementHistoryEventType {
  unlocked('unlocked', 'Unlocked'),
  invalidated('invalidated', 'Invalidated'),
  revalidated('revalidated', 'Revalidated');

  const AchievementHistoryEventType(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static AchievementHistoryEventType fromStorageKey(String raw) {
    for (final v in values) {
      if (v.storageKey == raw) return v;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown achievement event type');
  }
}

class AchievementHistoryEvent {
  const AchievementHistoryEvent({
    required this.id,
    required this.achievementKey,
    required this.ruleVersion,
    required this.eventType,
    this.reason,
    required this.occurredAtUtc,
  });

  final String id;
  final String achievementKey;
  final int ruleVersion;
  final AchievementHistoryEventType eventType;
  final String? reason;
  final DateTime occurredAtUtc;
}

/// Combined catalog + persisted unlock/validity status for one achievement.
class AchievementStatus {
  const AchievementStatus({
    required this.definition,
    required this.isUnlockedEver,
    required this.isCurrentlyValid,
    this.unlockedAtUtc,
    this.invalidatedAtUtc,
    this.statusNote,
    this.history = const [],
  });

  final AchievementDefinition definition;
  final bool isUnlockedEver;
  final bool isCurrentlyValid;
  final DateTime? unlockedAtUtc;
  final DateTime? invalidatedAtUtc;
  final String? statusNote;
  final List<AchievementHistoryEvent> history;
}

class GamificationAttribute {
  GamificationAttribute({
    required String id,
    required String name,
    String? description,
    this.isArchived = false,
    required this.createdAtUtc,
  }) : id = id.trim(),
       name = name.trim(),
       description = _cleanOptional(description) {
    if (this.id.isEmpty) {
      throw ArgumentError('Attribute id must not be blank');
    }
    if (this.name.isEmpty) {
      throw ArgumentError('Attribute name must not be blank');
    }
  }

  final String id;
  final String name;
  final String? description;
  final bool isArchived;
  final DateTime createdAtUtc;
}

class AttributeActivitySummary {
  const AttributeActivitySummary({
    required this.attribute,
    required this.linkedHabitIds,
    required this.totalActivityXp,
    required this.levelProgress,
  });

  final GamificationAttribute attribute;
  final List<String> linkedHabitIds;
  final int totalActivityXp;
  final LevelProgress levelProgress;
}

class GamificationAttributeCalculator {
  const GamificationAttributeCalculator._();

  static List<AttributeActivitySummary> summarize({
    required List<GamificationAttribute> attributes,
    required Map<String, List<String>> linkedHabitIdsByAttribute,
    required List<XpLedgerEntry> ledgerEntries,
  }) {
    final xpByHabit = <String, int>{};
    for (final entry in ledgerEntries) {
      xpByHabit[entry.habitId] =
          (xpByHabit[entry.habitId] ?? 0) + entry.xpDelta;
    }

    return [
      for (final attr in attributes)
        () {
          final linked = linkedHabitIdsByAttribute[attr.id] ?? const <String>[];
          var total = 0;
          for (final habitId in linked) {
            final habitNet = xpByHabit[habitId] ?? 0;
            if (habitNet > 0) total += habitNet;
          }
          return AttributeActivitySummary(
            attribute: attr,
            linkedHabitIds: List<String>.unmodifiable(linked),
            totalActivityXp: total,
            levelProgress: LevelCalculator.fromTotalXp(total),
          );
        }(),
    ];
  }
}

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
