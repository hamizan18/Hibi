import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/gamification/domain/gamification_models.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

void main() {
  group('GamificationRules (v1)', () {
    test(
      'awards 10 XP completed, 5 XP recovered and 0 XP for other statuses',
      () {
        expect(
          GamificationRules.expectedXpForOccurrence(
            status: HabitAnalyticsStatus.completed,
            includeInRewards: true,
            isPrivate: false,
            hasMetadata: true,
          ),
          10,
        );
        expect(
          GamificationRules.expectedXpForOccurrence(
            status: HabitAnalyticsStatus.recovered,
            includeInRewards: true,
            isPrivate: false,
            hasMetadata: true,
          ),
          5,
        );
        for (final zeroStatus in [
          HabitAnalyticsStatus.failed,
          HabitAnalyticsStatus.pending,
          HabitAnalyticsStatus.partial,
          HabitAnalyticsStatus.excused,
          HabitAnalyticsStatus.notApplicable,
          HabitAnalyticsStatus.unknown,
          HabitAnalyticsStatus.conflict,
        ]) {
          expect(
            GamificationRules.expectedXpForOccurrence(
              status: zeroStatus,
              includeInRewards: true,
              isPrivate: false,
              hasMetadata: true,
            ),
            0,
          );
        }
      },
    );

    test('excludes private, unclassified and reward-opted-out habits', () {
      expect(
        GamificationRules.expectedXpForOccurrence(
          status: HabitAnalyticsStatus.completed,
          includeInRewards: false,
          isPrivate: false,
          hasMetadata: true,
        ),
        0,
      );
      expect(
        GamificationRules.expectedXpForOccurrence(
          status: HabitAnalyticsStatus.completed,
          includeInRewards: true,
          isPrivate: true,
          hasMetadata: true,
        ),
        0,
      );
      expect(
        GamificationRules.expectedXpForOccurrence(
          status: HabitAnalyticsStatus.completed,
          includeInRewards: true,
          isPrivate: false,
          hasMetadata: false,
        ),
        0,
      );
    });
  });

  group('LevelCalculator (100 * L)', () {
    test('verifies exact level boundaries', () {
      final l1Start = LevelCalculator.fromTotalXp(0);
      expect(l1Start.level, 1);
      expect(l1Start.xpIntoCurrentLevel, 0);
      expect(l1Start.xpRequiredForNextLevel, 100);

      final l1End = LevelCalculator.fromTotalXp(99);
      expect(l1End.level, 1);
      expect(l1End.xpIntoCurrentLevel, 99);
      expect(l1End.xpRemainingToNextLevel, 1);

      final l2Start = LevelCalculator.fromTotalXp(100);
      expect(l2Start.level, 2);
      expect(l2Start.xpIntoCurrentLevel, 0);
      expect(l2Start.xpRequiredForNextLevel, 200);

      final l3Start = LevelCalculator.fromTotalXp(300);
      expect(l3Start.level, 3);
      expect(l3Start.xpIntoCurrentLevel, 0);
      expect(l3Start.xpRequiredForNextLevel, 300);

      final l4Start = LevelCalculator.fromTotalXp(600);
      expect(l4Start.level, 4);
      expect(l4Start.xpRequiredForNextLevel, 400);

      // Defensive clamp: negative XP never drops below Level 1 / 0 XP.
      final clamped = LevelCalculator.fromTotalXp(-50);
      expect(clamped.level, 1);
      expect(clamped.totalXp, 0);
    });
  });

  group('AchievementCatalog & Attribute calculator', () {
    test('evaluates achievements deterministically from facts', () {
      final results = AchievementCatalog.evaluate(
        const AchievementEvaluationFacts(
          eligibleCompletedCount: 1,
          eligibleCompletedDistinctDates: 1,
          eligibleRecoveredCount: 0,
          totalNetXp: 10,
          completedFocusSessions: 1,
          completedPublicGoalMilestones: 0,
        ),
      );
      expect(results[AchievementCatalog.firstStep], isTrue);
      expect(results[AchievementCatalog.focusFinisher], isTrue);
      expect(results[AchievementCatalog.steadyFive], isFalse);
      expect(results[AchievementCatalog.recoveryComeback], isFalse);
      expect(results[AchievementCatalog.xpCentury], isFalse);
      expect(results[AchievementCatalog.goalMilestone], isFalse);
    });

    test('sums reconciled attribute XP per linked habit', () {
      final t0 = DateTime.utc(2026, 11, 27, 9);
      final attr = GamificationAttribute(
        id: 'attr1',
        name: 'Consistency',
        createdAtUtc: t0,
      );
      final summaries = GamificationAttributeCalculator.summarize(
        attributes: [attr],
        linkedHabitIdsByAttribute: {
          'attr1': ['h1', 'h2'],
        },
        ledgerEntries: [
          XpLedgerEntry(
            id: 'e1',
            ruleVersion: 1,
            sourceType: 'habit_occurrence',
            sourceKey: buildHabitRewardSourceKey('h1', LocalDate(2026, 11, 26)),
            habitId: 'h1',
            localDate: LocalDate(2026, 11, 26),
            entryKind: XpEntryKind.award,
            statusSnapshot: XpStatusSnapshot.completed,
            xpDelta: 10,
            occurredAtUtc: t0,
          ),
          XpLedgerEntry(
            id: 'e2',
            ruleVersion: 1,
            sourceType: 'habit_occurrence',
            sourceKey: buildHabitRewardSourceKey('h1', LocalDate(2026, 11, 26)),
            habitId: 'h1',
            localDate: LocalDate(2026, 11, 26),
            entryKind: XpEntryKind.reconciliation,
            statusSnapshot: XpStatusSnapshot.revoked,
            xpDelta: -10,
            occurredAtUtc: t0,
          ),
          XpLedgerEntry(
            id: 'e3',
            ruleVersion: 1,
            sourceType: 'habit_occurrence',
            sourceKey: buildHabitRewardSourceKey('h2', LocalDate(2026, 11, 27)),
            habitId: 'h2',
            localDate: LocalDate(2026, 11, 27),
            entryKind: XpEntryKind.award,
            statusSnapshot: XpStatusSnapshot.recovered,
            xpDelta: 5,
            occurredAtUtc: t0,
          ),
        ],
      );
      expect(summaries.single.totalActivityXp, 5);
      expect(summaries.single.levelProgress.level, 1);
    });
  });
}
