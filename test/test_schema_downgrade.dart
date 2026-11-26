import 'package:sqlite3/sqlite3.dart';

/// Drops the tables added in schema version 11 so legacy migration tests can
/// downgrade an initialized database file to versions 2 through 10.
void dropV11Tables(Database db) {
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
