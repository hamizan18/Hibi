import 'package:sqlite3/sqlite3.dart';

/// Drops schema version 14 Finance tables for legacy migration fixtures.
void dropV14Schema(Database db) {
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
