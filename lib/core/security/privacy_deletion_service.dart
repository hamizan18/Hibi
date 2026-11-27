import 'package:drift/drift.dart';

import '../../features/gamification/data/gamification_service.dart';
import '../database/app_database.dart';
import '../services/app_clock.dart';

/// Executes verified, trigger-preserving permanent privacy deletion across all
/// sensitive source, audit and derived tables in one atomic SQLite transaction.
class PrivacyDeletionService {
  const PrivacyDeletionService(this._db, this._clock);

  static const String confirmDeleteHabitPhrase = 'PERMANENTLY DELETE HABIT';
  static const String confirmDeletePrivateJournalPhrase =
      'PERMANENTLY DELETE PRIVATE JOURNALS';
  static const String confirmWipeAllPhrase = 'ERASE ALL LOCAL DATA';

  final AppDatabase _db;
  final AppClock _clock;

  /// Permanently removes a habit and ALL associated versions, targets,
  /// schedules, lifecycle events, start-pauses, occurrences, progress/incident/
  /// recovery/resolution records, version/correction audits, reminders, goal
  /// links, XP ledger rows, and attribute links — leaving zero orphans and
  /// restoring every immutable SQLite trigger inside the same transaction.
  Future<void> permanentlyDeleteHabit({
    required String habitId,
    required String confirmationPhrase,
  }) async {
    if (confirmationPhrase.trim() != confirmDeleteHabitPhrase) {
      throw ArgumentError(
        'Confirmation phrase "$confirmDeleteHabitPhrase" is required',
      );
    }
    final cleanId = habitId.trim();
    if (cleanId.isEmpty) {
      throw ArgumentError('Habit id must not be blank');
    }

    await _db.transaction(() async {
      final exists = await _db
          .customSelect(
            'SELECT id FROM habits WHERE id = ?',
            variables: [Variable<String>(cleanId)],
          )
          .getSingleOrNull();
      if (exists == null) {
        throw StateError('Habit not found: $cleanId');
      }

      await _withTriggersTemporarilySuspended(() async {
        // Nullify optional references from focus sessions (preserving session history without habit identity).
        await _db.customStatement(
          '''
          UPDATE focus_sessions
          SET linked_habit_id = NULL, linked_habit_event_id = NULL
          WHERE linked_habit_id = ?
          ''',
          [cleanId],
        );
        // Remove reminders, goal links, gamification links and XP ledger rows.
        await _db.customStatement(
          'DELETE FROM habit_reminders WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM goal_habit_links WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM gamification_habit_attributes WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM gamification_xp_ledger WHERE habit_id = ?',
          [cleanId],
        );

        // Remove typed habit logs/events/occurrences/targets/scoring.
        await _db.customStatement(
          '''
          DELETE FROM habit_typed_logs
          WHERE occurrence_id IN (
            SELECT id FROM habit_typed_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_duration_events
          WHERE occurrence_id IN (
            SELECT id FROM habit_typed_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_typed_occurrences WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_version_scoring
          WHERE habit_version_id IN (
            SELECT id FROM habit_versions WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_typed_targets
          WHERE habit_version_id IN (
            SELECT id FROM habit_versions WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );

        // Remove avoidance records.
        await _db.customStatement(
          '''
          DELETE FROM habit_avoidance_resolutions
          WHERE occurrence_id IN (
            SELECT id FROM habit_avoidance_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_avoidance_incidents
          WHERE occurrence_id IN (
            SELECT id FROM habit_avoidance_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_avoidance_occurrences WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_avoidance_targets
          WHERE habit_version_id IN (
            SELECT id FROM habit_versions WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );

        // Remove checklist records.
        await _db.customStatement(
          '''
          DELETE FROM habit_checklist_item_recoveries
          WHERE occurrence_id IN (
            SELECT id FROM habit_checklist_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_checklist_item_logs
          WHERE occurrence_id IN (
            SELECT id FROM habit_checklist_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_checklist_occurrences WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_checklist_items
          WHERE habit_version_id IN (
            SELECT id FROM habit_versions WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );

        // Remove counter records & audits.
        await _db.customStatement(
          '''
          DELETE FROM habit_counter_recoveries
          WHERE occurrence_id IN (
            SELECT id FROM habit_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_counter_resolutions
          WHERE occurrence_id IN (
            SELECT id FROM habit_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_counter_event_audit
          WHERE occurrence_id IN (
            SELECT id FROM habit_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_counter_events
          WHERE occurrence_id IN (
            SELECT id FROM habit_occurrences WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_occurrences WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_counter_correction_audit WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_counter_targets
          WHERE habit_version_id IN (
            SELECT id FROM habit_versions WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );

        // Remove schedules, metadata, lifecycle, version audit, versions & habit identity.
        await _db.customStatement(
          '''
          DELETE FROM habit_schedules
          WHERE habit_version_id IN (
            SELECT id FROM habit_versions WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_version_metadata
          WHERE habit_version_id IN (
            SELECT id FROM habit_versions WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          '''
          DELETE FROM habit_lifecycle_start_pauses
          WHERE initial_event_id IN (
            SELECT id FROM habit_lifecycle_events WHERE habit_id = ?
          )
          ''',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_lifecycle_events WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_version_audit WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement(
          'DELETE FROM habit_versions WHERE habit_id = ?',
          [cleanId],
        );
        await _db.customStatement('DELETE FROM habits WHERE id = ?', [cleanId]);
      });

      // Reconcile achievements so invalidated badges reflect the removal cleanly.
      final hasAch = await _db
          .customSelect(
            'SELECT EXISTS(SELECT 1 FROM gamification_achievements) AS c',
          )
          .getSingle();
      if (hasAch.read<int>('c') == 1) {
        await GamificationService(
          _db,
          _clock,
        ).reconcileInCurrentTransaction(reason: 'Permanent privacy deletion');
      }

      final fkViolations = await _db
          .customSelect('PRAGMA foreign_key_check')
          .get();
      if (fkViolations.isNotEmpty) {
        throw StateError('Foreign key violation during permanent deletion');
      }

      // Record sanitized non-sensitive privacy deletion log (no habit name/details).
      final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
      await _db.customStatement(
        '''
        INSERT INTO backup_history (
          id, operation, format, is_encrypted, included_private,
          file_name, summary_note, occurred_at_utc_us
        )
        VALUES (?, 'privacy_delete', 'privacy_delete', 0, 1, NULL, ?, ?)
        ''',
        [
          'pdel_habit_$nowUs',
          'Permanently deleted one habit and all related audit/derived records',
          nowUs,
        ],
      );
    });
  }

  /// Permanently hard-deletes all private journal entries (and cascading tags).
  Future<int> permanentlyDeletePrivateJournals({
    required String confirmationPhrase,
  }) async {
    if (confirmationPhrase.trim() != confirmDeletePrivateJournalPhrase) {
      throw ArgumentError(
        'Confirmation phrase "$confirmDeletePrivateJournalPhrase" is required',
      );
    }
    return _db.transaction(() async {
      final countRow = await _db
          .customSelect(
            'SELECT COUNT(*) AS c FROM journal_entries WHERE is_private = 1',
          )
          .getSingle();
      final count = countRow.read<int>('c');
      await _db.customStatement(
        'DELETE FROM journal_entries WHERE is_private = 1',
      );
      final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
      await _db.customStatement(
        '''
        INSERT INTO backup_history (
          id, operation, format, is_encrypted, included_private,
          file_name, summary_note, occurred_at_utc_us
        )
        VALUES (?, 'privacy_delete', 'privacy_delete', 0, 1, NULL, ?, ?)
        ''',
        [
          'pdel_jrn_$nowUs',
          'Permanently deleted $count private journal entry(ies)',
          nowUs,
        ],
      );
      return count;
    });
  }

  /// Wipes ALL user tables cleanly while keeping schema and immutable triggers intact.
  Future<void> permanentlyWipeAllLocalData({
    required String confirmationPhrase,
  }) async {
    if (confirmationPhrase.trim() != confirmWipeAllPhrase) {
      throw ArgumentError(
        'Confirmation phrase "$confirmWipeAllPhrase" is required',
      );
    }
    await _db.transaction(() async {
      await _withTriggersTemporarilySuspended(() async {
        final tables = await _db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            )
            .get();
        await _db.customStatement('PRAGMA foreign_keys = OFF');
        try {
          for (final row in tables) {
            final name = row.read<String>('name');
            await _db.customStatement('DELETE FROM "$name"');
          }
        } finally {
          await _db.customStatement('PRAGMA foreign_keys = ON');
        }
      });
    });
  }

  Future<void> _withTriggersTemporarilySuspended(
    Future<void> Function() action,
  ) async {
    final triggerRows = await _db
        .customSelect(
          "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL",
        )
        .get();
    final savedTriggers = [
      for (final row in triggerRows)
        (name: row.read<String>('name'), sql: row.read<String>('sql')),
    ];
    for (final t in savedTriggers) {
      await _db.customStatement('DROP TRIGGER "${t.name}"');
    }
    try {
      await action();
    } finally {
      for (final t in savedTriggers) {
        await _db.customStatement(t.sql);
      }
    }
  }
}
