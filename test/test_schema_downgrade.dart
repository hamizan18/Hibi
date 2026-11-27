import 'package:sqlite3/sqlite3.dart';

/// Drops schema version 17 Privacy, Reminders & Backup tables for legacy migration fixtures.
void dropV17Schema(Database db) {
  db.execute('DROP TABLE IF EXISTS backup_history');
  db.execute('DROP TABLE IF EXISTS habit_reminders');
}

/// Drops schema version 16 Gamification tables (and v17) for legacy migration fixtures.
void dropV16Schema(Database db) {
  dropV17Schema(db);
  db.execute('DROP TABLE IF EXISTS gamification_habit_attributes');
  db.execute('DROP TABLE IF EXISTS gamification_attributes');
  db.execute('DROP TABLE IF EXISTS gamification_achievement_history');
  db.execute('DROP TABLE IF EXISTS gamification_achievements');
  db.execute('DROP TABLE IF EXISTS gamification_xp_ledger');
}

/// Drops schema version 15 Growth (Journal, Goals, Focus) tables (and v16) for legacy migration fixtures.
void dropV15Schema(Database db) {
  dropV16Schema(db);
  db.execute('DROP TABLE IF EXISTS focus_sessions');
  db.execute('DROP TABLE IF EXISTS focus_presets');
  db.execute('DROP TABLE IF EXISTS goal_progress_entries');
  db.execute('DROP TABLE IF EXISTS goal_habit_links');
  db.execute('DROP TABLE IF EXISTS goal_milestones');
  db.execute('DROP TABLE IF EXISTS goal_status_history');
  db.execute('DROP TABLE IF EXISTS goals');
  db.execute('DROP TABLE IF EXISTS journal_entry_tags');
  db.execute('DROP TABLE IF EXISTS journal_entries');
}

/// Drops schema version 14 Finance tables (and v15 Growth tables) for legacy migration fixtures.
void dropV14Schema(Database db) {
  dropV15Schema(db);
  db.execute('DROP TABLE IF EXISTS finance_audit');
  db.execute('DROP TABLE IF EXISTS finance_budgets');
  db.execute('DROP TABLE IF EXISTS finance_transfers');
  db.execute('DROP TABLE IF EXISTS finance_transactions');
  db.execute('DROP TABLE IF EXISTS finance_categories');
  db.execute('DROP TABLE IF EXISTS finance_wallets');
}

/// Reconstructs the pre-scoring v12 schema for migration fixtures.
void dropV13Schema(Database db) {
  dropV14Schema(db);
  db.execute('DROP TRIGGER habit_typed_targets_protect_scoring_update');
  db.execute('DROP TRIGGER habit_typed_targets_protect_scoring_delete');
  db.execute('DROP TABLE habit_version_scoring');
  db.execute('ALTER TABLE habit_typed_logs DROP COLUMN day_offset');
  final sql =
      db
              .select(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'habit_typed_targets'",
              )
              .single['sql']
          as String;
  db.execute(
    'ALTER TABLE habit_typed_targets RENAME TO habit_typed_targets_v13',
  );
  db.execute(sql.replaceFirst(", 'at_or_near'", ''));
  db.execute(
    'INSERT INTO habit_typed_targets SELECT * FROM habit_typed_targets_v13',
  );
  db.execute('DROP TABLE habit_typed_targets_v13');
}

/// Drops schema versions 11 through 14 for legacy migration fixtures.
void dropV11Tables(Database db) {
  dropV14Schema(db);
  db.execute(
    'DROP TRIGGER IF EXISTS habit_typed_targets_protect_scoring_update',
  );
  db.execute(
    'DROP TRIGGER IF EXISTS habit_typed_targets_protect_scoring_delete',
  );
  db.execute('DROP TABLE IF EXISTS habit_version_scoring');
  db.execute('DROP TABLE IF EXISTS habit_lifecycle_start_pauses');
  db.execute('DROP TABLE IF EXISTS habit_typed_logs');
  db.execute('DROP TABLE IF EXISTS habit_duration_events');
  db.execute('DROP TABLE IF EXISTS habit_typed_occurrences');
  db.execute('DROP TABLE IF EXISTS habit_typed_targets');
  db.execute('DROP TABLE IF EXISTS habit_avoidance_resolutions');
  db.execute('DROP TABLE IF EXISTS habit_avoidance_incidents');
  db.execute('DROP TABLE IF EXISTS habit_avoidance_occurrences');
  db.execute('DROP TABLE IF EXISTS habit_avoidance_targets');
  db.execute('DROP TABLE IF EXISTS habit_checklist_item_recoveries');
  db.execute('DROP TABLE IF EXISTS habit_checklist_item_logs');
  db.execute('DROP TABLE IF EXISTS habit_checklist_occurrences');
  db.execute('DROP TABLE IF EXISTS habit_checklist_items');
  db.execute('DROP TABLE IF EXISTS habit_version_metadata');
  db.execute('DROP TABLE IF EXISTS habit_counter_correction_audit');
}
