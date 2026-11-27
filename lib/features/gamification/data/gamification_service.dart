import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../../habits/data/habit_metadata_store.dart';
import '../../habits/data/unified_habit_history_reader.dart';
import '../../habits/domain/habit_analytics.dart';
import '../../habits/domain/habit_schedule.dart';
import '../domain/gamification_models.dart';

const _gamificationEnabledSettingKey = 'gamification_enabled';

/// Complete, consistent snapshot of the user's Gamification state.
class GamificationSnapshot {
  const GamificationSnapshot({
    required this.isEnabled,
    required this.levelProgress,
    required this.ledgerEntries,
    required this.achievements,
    required this.attributes,
  });

  final bool isEnabled;
  final LevelProgress levelProgress;
  final List<XpLedgerEntry> ledgerEntries;
  final List<AchievementStatus> achievements;
  final List<AttributeActivitySummary> attributes;
}

/// Transactional Gamification store managing the versioned immutable XP ledger,
/// deterministic achievements with preserved unlock history, custom activity
/// attributes, global opt-out, and atomic correction reconciliation.
class GamificationService {
  const GamificationService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<bool> isGamificationEnabled() async {
    final raw = await _db.getSetting(_gamificationEnabledSettingKey);
    return raw != 'false';
  }

  Future<void> setGamificationEnabled(bool enabled) async {
    await _db.setSetting(
      _gamificationEnabledSettingKey,
      enabled ? 'true' : 'false',
    );
  }

  Future<GamificationAttribute> createAttribute({
    required String id,
    required String name,
    String? description,
  }) => _db.transaction(() async {
    final nowUtc = _clock.now().toUtc();
    final attr = GamificationAttribute(
      id: id,
      name: name,
      description: description,
      createdAtUtc: nowUtc,
    );
    await _db.customStatement(
      '''
      INSERT INTO gamification_attributes (
        id, name, description, is_archived, created_at_utc_us
      )
      VALUES (?, ?, ?, 0, ?)
      ''',
      [attr.id, attr.name, attr.description, nowUtc.microsecondsSinceEpoch],
    );
    return attr;
  });

  Future<void> linkHabitToAttribute({
    required String habitId,
    required String attributeId,
  }) => _db.transaction(() async {
    final habit = await _db
        .customSelect(
          'SELECT id FROM habits WHERE id = ?',
          variables: [Variable<String>(habitId.trim())],
        )
        .getSingleOrNull();
    if (habit == null) {
      throw StateError('Habit not found: $habitId');
    }
    final attr = await _db
        .customSelect(
          'SELECT id FROM gamification_attributes WHERE id = ?',
          variables: [Variable<String>(attributeId.trim())],
        )
        .getSingleOrNull();
    if (attr == null) {
      throw StateError('Attribute not found: $attributeId');
    }
    final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      INSERT OR IGNORE INTO gamification_habit_attributes (
        habit_id, attribute_id, created_at_utc_us
      )
      VALUES (?, ?, ?)
      ''',
      [habitId.trim(), attributeId.trim(), nowUs],
    );
  });

  Future<void> unlinkHabitFromAttribute({
    required String habitId,
    required String attributeId,
  }) => _db.transaction(() async {
    await _db.customStatement(
      'DELETE FROM gamification_habit_attributes WHERE habit_id = ? AND attribute_id = ?',
      [habitId.trim(), attributeId.trim()],
    );
  });

  /// Reconciles all recorded habit occurrences against the versioned XP ledger
  /// and deterministic achievements inside one atomic transaction.
  ///
  /// Strictly idempotent: repeated calls produce zero duplicate XP rows or
  /// duplicate achievement history events. Private, unclassified, and
  /// reward-opted-out habits earn 0 XP and are excluded from achievements.
  Future<GamificationSnapshot> reconcileAll({String? reason}) =>
      _db.transaction(() => reconcileInCurrentTransaction(reason: reason));

  /// Reconciles XP and achievements inside an already-open SQLite transaction
  /// (used by [CounterCorrectionWriter.commit] for atomic reconciliation).
  Future<GamificationSnapshot> reconcileInCurrentTransaction({
    String? reason,
  }) async {
    final enabled = await isGamificationEnabled();
    final nowUtc = _clock.now().toUtc();
    final nowUs = nowUtc.microsecondsSinceEpoch;

    if (enabled) {
      final candidateRows = await _db.customSelect('''
            SELECT DISTINCT habit_id, local_date FROM (
              SELECT habit_id, local_date FROM habit_occurrences
              UNION
              SELECT habit_id, local_date FROM habit_checklist_occurrences
              UNION
              SELECT habit_id, local_date FROM habit_avoidance_occurrences
              UNION
              SELECT habit_id, local_date FROM habit_typed_occurrences
              UNION
              SELECT habit_id, local_date FROM gamification_xp_ledger
            )
            ORDER BY local_date ASC, habit_id ASC
          ''').get();

      final historyReader = UnifiedHabitHistoryReader(_db);
      final metadataStore = HabitMetadataStore(_db);

      var eligibleCompletedCount = 0;
      final eligibleCompletedDates = <LocalDate>{};
      var eligibleRecoveredCount = 0;

      for (final row in candidateRows) {
        final habitId = row.read<String>('habit_id');
        final date = _parseDateKey(row.read<String>('local_date'));
        final evals = await historyReader.readHabitRange(
          habitId: habitId,
          startInclusive: date,
          endInclusive: date,
        );
        if (evals.isEmpty) continue;
        final eval = evals.single;
        final metadata = eval.versionId == null
            ? null
            : await metadataStore.findForVersion(eval.versionId!);
        final includeInRewards = metadata?.includeInRewards ?? false;

        final expectedXp = GamificationRules.expectedXpForOccurrence(
          status: eval.status,
          includeInRewards: includeInRewards,
          isPrivate: eval.isPrivate,
          hasMetadata: eval.hasMetadata,
        );

        if (expectedXp == GamificationRules.completedXpV1 &&
            eval.status == HabitAnalyticsStatus.completed) {
          eligibleCompletedCount++;
          eligibleCompletedDates.add(date);
        } else if (expectedXp == GamificationRules.recoveredXpV1 &&
            eval.status == HabitAnalyticsStatus.recovered) {
          eligibleRecoveredCount++;
        }

        await _reconcileSingleOccurrenceInTx(
          habitId: habitId,
          date: date,
          status: eval.status,
          expectedXp: expectedXp,
          reason: reason,
          nowUs: nowUs,
        );
      }

      final netXpRow = await _db
          .customSelect(
            'SELECT COALESCE(SUM(xp_delta), 0) AS total_xp FROM gamification_xp_ledger',
          )
          .getSingle();
      final totalNetXp = netXpRow.read<int>('total_xp');

      final focusRow = await _db
          .customSelect(
            "SELECT COUNT(*) AS c FROM focus_sessions WHERE kind = 'focus' AND state = 'completed'",
          )
          .getSingle();
      final milestoneRow = await _db.customSelect('''
            SELECT COUNT(*) AS c
            FROM goal_milestones m
            JOIN goals g ON g.id = m.goal_id
            WHERE g.is_private = 0 AND m.is_completed = 1
          ''').getSingle();

      final facts = AchievementEvaluationFacts(
        eligibleCompletedCount: eligibleCompletedCount,
        eligibleCompletedDistinctDates: eligibleCompletedDates.length,
        eligibleRecoveredCount: eligibleRecoveredCount,
        totalNetXp: totalNetXp < 0 ? 0 : totalNetXp,
        completedFocusSessions: focusRow.read<int>('c'),
        completedPublicGoalMilestones: milestoneRow.read<int>('c'),
      );

      await _reconcileAchievementsInTx(
        facts: facts,
        reason: reason,
        nowUs: nowUs,
      );
    }

    return _readSnapshotInTx(isEnabled: enabled);
  }

  /// Read-only snapshot without mutating the ledger or achievements.
  Future<GamificationSnapshot> readSnapshot() => _db.transaction(() async {
    final enabled = await isGamificationEnabled();
    return _readSnapshotInTx(isEnabled: enabled);
  });

  Future<void> _reconcileSingleOccurrenceInTx({
    required String habitId,
    required LocalDate date,
    required HabitAnalyticsStatus status,
    required int expectedXp,
    required String? reason,
    required int nowUs,
  }) async {
    final sourceKey = buildHabitRewardSourceKey(habitId, date);
    final existingRows = await _db
        .customSelect(
          '''
          SELECT id, entry_kind, xp_delta
          FROM gamification_xp_ledger
          WHERE source_type = 'habit_occurrence'
            AND source_key = ?
            AND rule_version = ?
          ORDER BY occurred_at_utc_us ASC, id ASC
          ''',
          variables: [
            Variable<String>(sourceKey),
            Variable<int>(GamificationRules.currentRuleVersion),
          ],
        )
        .get();

    var currentNet = 0;
    var hasBaseAward = false;
    for (final row in existingRows) {
      currentNet += row.read<int>('xp_delta');
      if (row.read<String>('entry_kind') == XpEntryKind.award.storageKey) {
        hasBaseAward = true;
      }
    }

    final delta = expectedXp - currentNet;
    if (delta == 0) return;

    final entryKind = (!hasBaseAward && delta > 0)
        ? XpEntryKind.award
        : XpEntryKind.reconciliation;
    final statusSnapshot = expectedXp == 0
        ? XpStatusSnapshot.revoked
        : (status == HabitAnalyticsStatus.recovered
              ? XpStatusSnapshot.recovered
              : XpStatusSnapshot.completed);

    final seq = existingRows.length + 1;
    final entryId =
        'xp_${GamificationRules.currentRuleVersion}_${sourceKey}_${seq}_$nowUs';
    final effectiveReason =
        _cleanOptional(reason) ??
        (entryKind == XpEntryKind.award
            ? 'Eligible habit ${statusSnapshot.storageKey}'
            : 'Reconciled reward to $expectedXp XP');

    await _db.customStatement(
      '''
      INSERT INTO gamification_xp_ledger (
        id, rule_version, source_type, source_key, habit_id, local_date,
        entry_kind, status_snapshot, xp_delta, reason, occurred_at_utc_us
      )
      VALUES (?, ?, 'habit_occurrence', ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        entryId,
        GamificationRules.currentRuleVersion,
        sourceKey,
        habitId,
        _dateKey(date),
        entryKind.storageKey,
        statusSnapshot.storageKey,
        delta,
        effectiveReason,
        nowUs,
      ],
    );
  }

  Future<void> _reconcileAchievementsInTx({
    required AchievementEvaluationFacts facts,
    required String? reason,
    required int nowUs,
  }) async {
    final evaluated = AchievementCatalog.evaluate(facts);
    for (final definition in AchievementCatalog.all) {
      final isMet = evaluated[definition.key] ?? false;
      final existing = await _db
          .customSelect(
            '''
            SELECT achievement_key, is_currently_valid
            FROM gamification_achievements
            WHERE achievement_key = ?
            ''',
            variables: [Variable<String>(definition.key)],
          )
          .getSingleOrNull();

      if (existing == null) {
        if (!isMet) continue;
        await _db.customStatement(
          '''
          INSERT INTO gamification_achievements (
            achievement_key, rule_version, unlocked_at_utc_us,
            is_currently_valid, invalidated_at_utc_us, last_evaluated_at_utc_us,
            status_note
          )
          VALUES (?, ?, ?, 1, NULL, ?, ?)
          ''',
          [
            definition.key,
            definition.ruleVersion,
            nowUs,
            nowUs,
            'Unlocked under rule v${definition.ruleVersion}',
          ],
        );
        await _appendAchievementHistoryInTx(
          achievementKey: definition.key,
          ruleVersion: definition.ruleVersion,
          eventType: AchievementHistoryEventType.unlocked,
          reason: _cleanOptional(reason) ?? 'Criteria met',
          nowUs: nowUs,
        );
      } else {
        final wasValid = existing.read<int>('is_currently_valid') == 1;
        if (wasValid && !isMet) {
          await _db.customStatement(
            '''
            UPDATE gamification_achievements
            SET is_currently_valid = 0,
                invalidated_at_utc_us = ?,
                last_evaluated_at_utc_us = ?,
                status_note = ?
            WHERE achievement_key = ?
            ''',
            [
              nowUs,
              nowUs,
              'Criteria no longer met after reconciliation (unlock history preserved)',
              definition.key,
            ],
          );
          await _appendAchievementHistoryInTx(
            achievementKey: definition.key,
            ruleVersion: definition.ruleVersion,
            eventType: AchievementHistoryEventType.invalidated,
            reason:
                _cleanOptional(reason) ??
                'Criteria no longer met after reconciliation',
            nowUs: nowUs,
          );
        } else if (!wasValid && isMet) {
          await _db.customStatement(
            '''
            UPDATE gamification_achievements
            SET is_currently_valid = 1,
                invalidated_at_utc_us = NULL,
                last_evaluated_at_utc_us = ?,
                status_note = ?
            WHERE achievement_key = ?
            ''',
            [
              nowUs,
              'Revalidated under rule v${definition.ruleVersion}',
              definition.key,
            ],
          );
          await _appendAchievementHistoryInTx(
            achievementKey: definition.key,
            ruleVersion: definition.ruleVersion,
            eventType: AchievementHistoryEventType.revalidated,
            reason: _cleanOptional(reason) ?? 'Criteria met again',
            nowUs: nowUs,
          );
        } else {
          await _db.customStatement(
            '''
            UPDATE gamification_achievements
            SET last_evaluated_at_utc_us = ?
            WHERE achievement_key = ?
            ''',
            [nowUs, definition.key],
          );
        }
      }
    }
  }

  Future<void> _appendAchievementHistoryInTx({
    required String achievementKey,
    required int ruleVersion,
    required AchievementHistoryEventType eventType,
    required String? reason,
    required int nowUs,
  }) async {
    final countRow = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM gamification_achievement_history WHERE achievement_key = ?',
          variables: [Variable<String>(achievementKey)],
        )
        .getSingle();
    final seq = countRow.read<int>('c') + 1;
    await _db.customStatement(
      '''
      INSERT INTO gamification_achievement_history (
        id, achievement_key, rule_version, event_type, reason, occurred_at_utc_us
      )
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        'ach_${achievementKey}_${seq}_$nowUs',
        achievementKey,
        ruleVersion,
        eventType.storageKey,
        reason,
        nowUs,
      ],
    );
  }

  Future<GamificationSnapshot> _readSnapshotInTx({
    required bool isEnabled,
  }) async {
    final ledgerRows = await _db.customSelect('''
          SELECT id, rule_version, source_type, source_key, habit_id,
                 local_date, entry_kind, status_snapshot, xp_delta, reason,
                 occurred_at_utc_us
          FROM gamification_xp_ledger
          ORDER BY occurred_at_utc_us DESC, id DESC
        ''').get();
    final ledger = [
      for (final row in ledgerRows)
        XpLedgerEntry(
          id: row.read<String>('id'),
          ruleVersion: row.read<int>('rule_version'),
          sourceType: row.read<String>('source_type'),
          sourceKey: row.read<String>('source_key'),
          habitId: row.read<String>('habit_id'),
          localDate: _parseDateKey(row.read<String>('local_date')),
          entryKind: XpEntryKind.fromStorageKey(row.read<String>('entry_kind')),
          statusSnapshot: XpStatusSnapshot.fromStorageKey(
            row.read<String>('status_snapshot'),
          ),
          xpDelta: row.read<int>('xp_delta'),
          reason: row.readNullable<String>('reason'),
          occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('occurred_at_utc_us'),
            isUtc: true,
          ),
        ),
    ];
    final totalXp = ledger.fold<int>(0, (sum, entry) => sum + entry.xpDelta);
    final levelProgress = LevelCalculator.fromTotalXp(totalXp);

    final achRows = await _db.customSelect('''
          SELECT achievement_key, unlocked_at_utc_us, is_currently_valid,
                 invalidated_at_utc_us, status_note
          FROM gamification_achievements
        ''').get();
    final achByKey = {
      for (final row in achRows) row.read<String>('achievement_key'): row,
    };

    final histRows = await _db.customSelect('''
          SELECT id, achievement_key, rule_version, event_type, reason, occurred_at_utc_us
          FROM gamification_achievement_history
          ORDER BY occurred_at_utc_us ASC, id ASC
        ''').get();
    final histByKey = <String, List<AchievementHistoryEvent>>{};
    for (final row in histRows) {
      final key = row.read<String>('achievement_key');
      histByKey
          .putIfAbsent(key, () => <AchievementHistoryEvent>[])
          .add(
            AchievementHistoryEvent(
              id: row.read<String>('id'),
              achievementKey: key,
              ruleVersion: row.read<int>('rule_version'),
              eventType: AchievementHistoryEventType.fromStorageKey(
                row.read<String>('event_type'),
              ),
              reason: row.readNullable<String>('reason'),
              occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.read<int>('occurred_at_utc_us'),
                isUtc: true,
              ),
            ),
          );
    }

    final achievements = [
      for (final def in AchievementCatalog.all)
        () {
          final row = achByKey[def.key];
          if (row == null) {
            return AchievementStatus(
              definition: def,
              isUnlockedEver: false,
              isCurrentlyValid: false,
            );
          }
          final invRaw = row.readNullable<int>('invalidated_at_utc_us');
          return AchievementStatus(
            definition: def,
            isUnlockedEver: true,
            isCurrentlyValid: row.read<int>('is_currently_valid') == 1,
            unlockedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
              row.read<int>('unlocked_at_utc_us'),
              isUtc: true,
            ),
            invalidatedAtUtc: invRaw == null
                ? null
                : DateTime.fromMicrosecondsSinceEpoch(invRaw, isUtc: true),
            statusNote: row.readNullable<String>('status_note'),
            history: List<AchievementHistoryEvent>.unmodifiable(
              histByKey[def.key] ?? const [],
            ),
          );
        }(),
    ];

    final attrRows = await _db.customSelect('''
          SELECT id, name, description, is_archived, created_at_utc_us
          FROM gamification_attributes
          WHERE is_archived = 0
          ORDER BY name ASC, id ASC
        ''').get();
    final attrs = [
      for (final row in attrRows)
        GamificationAttribute(
          id: row.read<String>('id'),
          name: row.read<String>('name'),
          description: row.readNullable<String>('description'),
          isArchived: row.read<int>('is_archived') == 1,
          createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('created_at_utc_us'),
            isUtc: true,
          ),
        ),
    ];

    final linkRows = await _db.customSelect('''
          SELECT habit_id, attribute_id
          FROM gamification_habit_attributes
          ORDER BY created_at_utc_us ASC, habit_id ASC
        ''').get();
    final linksByAttr = <String, List<String>>{};
    for (final row in linkRows) {
      linksByAttr
          .putIfAbsent(row.read<String>('attribute_id'), () => <String>[])
          .add(row.read<String>('habit_id'));
    }

    final attrSummaries = GamificationAttributeCalculator.summarize(
      attributes: attrs,
      linkedHabitIdsByAttribute: linksByAttr,
      ledgerEntries: ledger,
    );

    return GamificationSnapshot(
      isEnabled: isEnabled,
      levelProgress: levelProgress,
      ledgerEntries: List<XpLedgerEntry>.unmodifiable(ledger),
      achievements: List<AchievementStatus>.unmodifiable(achievements),
      attributes: List<AttributeActivitySummary>.unmodifiable(attrSummaries),
    );
  }
}

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDateKey(String raw) {
  final parts = raw.split('-');
  return LocalDate(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}
