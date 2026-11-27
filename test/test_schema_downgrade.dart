import 'package:sqlite3/sqlite3.dart';

/// Drops schema versions 11 and 12 for legacy migration fixtures.
void dropV11Tables(Database db) {
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
