import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// A single app-scoped database, closed when its provider is disposed.
final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase.open();
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

/// The schema is managed using explicit SQL migrations without codegen.
class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);

  factory AppDatabase.open() => AppDatabase(_openConnection());

  @override
  int get schemaVersion => 7;

  // Tables are managed explicitly in the migration until generated Drift
  // tables are needed. Custom queries below do not rely on table notifications.
  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await customStatement('''
        CREATE TABLE app_settings (
          key TEXT NOT NULL PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      await _createHabitSchema();
      await _createCounterTargetSchema();
      await _createHabitAuditSchema();
      await _createOccurrenceSchema();
      await _createScheduleSchema();
      await _createLifecycleSchema();
    },
    // Unknown upgrades and downgrades must never silently discard data.
    onUpgrade: (migrator, from, to) async {
      if (from < 1 || from > 6 || to != 7) {
        throw StateError('No database migration from version $from to $to');
      }
      await transaction(() async {
        if (from == 1) await _createHabitSchema();
        if (from <= 2) await _createCounterTargetSchema();
        if (from <= 3) await _createHabitAuditSchema();
        if (from <= 4) await _createOccurrenceSchema();
        if (from <= 5) await _createScheduleSchema();
        await _createLifecycleSchema();
      });
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _createHabitSchema() async {
    await customStatement('''
      CREATE TABLE habits (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        created_at_utc_us INTEGER NOT NULL
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_versions (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        effective_start TEXT NOT NULL CHECK (
          effective_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(effective_start, 1, 4) >= '0001'
          AND date(effective_start, '+0 days') IS effective_start
        ),
        effective_end TEXT CHECK (
          effective_end IS NULL OR (
            effective_end GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
            AND substr(effective_end, 1, 4) >= '0001'
            AND date(effective_end, '+0 days') IS effective_end
            AND effective_end > effective_start
          )
        ),
        created_at_utc_us INTEGER NOT NULL,
        revision INTEGER NOT NULL CHECK (revision > 0),
        UNIQUE (habit_id, revision)
      )
    ''');
    await customStatement('''
      CREATE INDEX habit_versions_by_habit_start
      ON habit_versions (habit_id, effective_start)
    ''');
    for (final operation in ['INSERT', 'UPDATE']) {
      final exclusion = operation == 'UPDATE' ? 'AND id != OLD.id' : '';
      await customStatement('''
        CREATE TRIGGER habit_versions_no_overlap_${operation.toLowerCase()}
        BEFORE $operation ON habit_versions
        WHEN EXISTS (
          SELECT 1 FROM habit_versions
          WHERE habit_id = NEW.habit_id $exclusion
            AND (NEW.effective_end IS NULL OR effective_start < NEW.effective_end)
            AND (effective_end IS NULL OR NEW.effective_start < effective_end)
        )
        BEGIN
          SELECT RAISE(ABORT, 'habit version intervals overlap');
        END
      ''');
    }
  }

  Future<void> _createCounterTargetSchema() => customStatement('''
    CREATE TABLE habit_counter_targets (
      habit_version_id TEXT NOT NULL PRIMARY KEY
        REFERENCES habit_versions(id) ON DELETE RESTRICT,
      target_count INTEGER NOT NULL
        CHECK (typeof(target_count) = 'integer' AND target_count > 0),
      unit TEXT NOT NULL CHECK (length(trim(unit)) > 0)
    )
  ''');

  Future<void> _createHabitAuditSchema() async {
    await customStatement('''
      CREATE TABLE habit_version_audit (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        operation TEXT NOT NULL CHECK (operation IN ('create', 'schedule_version')),
        previous_values TEXT,
        updated_values TEXT NOT NULL,
        occurred_at_utc_us INTEGER NOT NULL
      )
    ''');
    await customStatement('''
      CREATE INDEX habit_version_audit_by_habit_time
      ON habit_version_audit (habit_id, occurred_at_utc_us)
    ''');
  }

  Future<void> _createOccurrenceSchema() async {
    await customStatement('''
      CREATE TABLE habit_occurrences (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        habit_version_id TEXT NOT NULL REFERENCES habit_versions(id) ON DELETE RESTRICT,
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        target_count INTEGER NOT NULL
          CHECK (typeof(target_count) = 'integer' AND target_count > 0),
        unit TEXT NOT NULL CHECK (length(trim(unit)) > 0),
        UNIQUE (habit_id, local_date)
      )
    ''');
    await customStatement('''
      CREATE INDEX habit_occurrences_by_version_date
      ON habit_occurrences (habit_version_id, local_date)
    ''');
    await customStatement('''
      CREATE TRIGGER habit_occurrences_validate_insert
      BEFORE INSERT ON habit_occurrences
      WHEN NOT EXISTS (
        SELECT 1 FROM habit_versions v
        JOIN habit_counter_targets t ON t.habit_version_id = v.id
        WHERE v.id = NEW.habit_version_id AND v.habit_id = NEW.habit_id
          AND v.effective_start <= NEW.local_date
          AND (v.effective_end IS NULL OR NEW.local_date < v.effective_end)
          AND t.target_count = NEW.target_count AND t.unit = NEW.unit
      )
      BEGIN
        SELECT RAISE(ABORT, 'occurrence does not match an applicable counter version');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER habit_occurrences_protect_interpretation
      BEFORE UPDATE OF id, habit_id, habit_version_id, local_date, target_count, unit
      ON habit_occurrences
      WHEN NEW.id IS NOT OLD.id OR NEW.habit_id IS NOT OLD.habit_id
        OR NEW.habit_version_id IS NOT OLD.habit_version_id
        OR NEW.local_date IS NOT OLD.local_date
        OR NEW.target_count IS NOT OLD.target_count OR NEW.unit IS NOT OLD.unit
      BEGIN
        SELECT RAISE(ABORT, 'occurrence correction workflow required');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER habit_versions_protect_occurrences
      BEFORE UPDATE OF id, habit_id, name, effective_start, effective_end ON habit_versions
      WHEN EXISTS (
        SELECT 1 FROM habit_occurrences o WHERE o.habit_version_id = OLD.id
          AND (NEW.id IS NOT OLD.id OR NEW.habit_id IS NOT OLD.habit_id
            OR NEW.name IS NOT OLD.name OR o.local_date < NEW.effective_start
            OR (NEW.effective_end IS NOT NULL AND o.local_date >= NEW.effective_end))
      )
      BEGIN
        SELECT RAISE(ABORT, 'version change would alter existing occurrences');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER habit_counter_targets_protect_update
      BEFORE UPDATE ON habit_counter_targets
      WHEN EXISTS (SELECT 1 FROM habit_occurrences WHERE habit_version_id = OLD.habit_version_id)
        AND (NEW.habit_version_id IS NOT OLD.habit_version_id
          OR NEW.target_count IS NOT OLD.target_count OR NEW.unit IS NOT OLD.unit)
      BEGIN
        SELECT RAISE(ABORT, 'target correction workflow required');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER habit_counter_targets_protect_delete
      BEFORE DELETE ON habit_counter_targets
      WHEN EXISTS (SELECT 1 FROM habit_occurrences WHERE habit_version_id = OLD.habit_version_id)
      BEGIN
        SELECT RAISE(ABORT, 'target is used by existing occurrences');
      END
    ''');
    await customStatement('''
      CREATE TABLE habit_counter_events (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL REFERENCES habit_occurrences(id) ON DELETE RESTRICT,
        quantity INTEGER NOT NULL CHECK (typeof(quantity) = 'integer' AND quantity > 0),
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX habit_counter_events_by_occurrence_time
      ON habit_counter_events (occurrence_id, occurred_at_utc_us)
    ''');
  }

  Future<void> _createScheduleSchema() async {
    await customStatement('''
      CREATE TABLE habit_schedules (
        habit_version_id TEXT NOT NULL PRIMARY KEY
          REFERENCES habit_versions(id) ON DELETE RESTRICT,
        recurrence TEXT NOT NULL CHECK (recurrence IN ('daily', 'weekdays')),
        start_date TEXT NOT NULL CHECK (
          start_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(start_date, 1, 4) >= '0001'
          AND date(start_date, '+0 days') IS start_date
        ),
        end_exclusive TEXT CHECK (
          end_exclusive IS NULL OR (
            end_exclusive GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
            AND substr(end_exclusive, 1, 4) >= '0001'
            AND date(end_exclusive, '+0 days') IS end_exclusive
            AND end_exclusive > start_date
          )
        ),
        weekday_mask INTEGER,
        CHECK (
          (recurrence = 'daily' AND weekday_mask IS NULL)
          OR (recurrence = 'weekdays' AND typeof(weekday_mask) = 'integer'
              AND weekday_mask BETWEEN 1 AND 127)
        )
      )
    ''');
    await customStatement('''
      CREATE TRIGGER habit_schedules_protect_insert
      BEFORE INSERT ON habit_schedules
      WHEN EXISTS (
        SELECT 1 FROM habit_occurrences WHERE habit_version_id = NEW.habit_version_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'schedule correction workflow required');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER habit_schedules_protect_update
      BEFORE UPDATE ON habit_schedules
      WHEN EXISTS (
        SELECT 1 FROM habit_occurrences
        WHERE habit_version_id = OLD.habit_version_id
           OR habit_version_id = NEW.habit_version_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'schedule correction workflow required');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER habit_schedules_protect_delete
      BEFORE DELETE ON habit_schedules
      WHEN EXISTS (
        SELECT 1 FROM habit_occurrences WHERE habit_version_id = OLD.habit_version_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'schedule correction workflow required');
      END
    ''');
  }

  Future<void> _createLifecycleSchema() async {
    await customStatement('''
      CREATE TABLE habit_lifecycle_events (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        effective_date TEXT NOT NULL CHECK (
          effective_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(effective_date, 1, 4) >= '0001'
          AND date(effective_date, '+0 days') IS effective_date
        ),
        previous_state TEXT CHECK (previous_state IS NULL OR previous_state IN
          ('scheduled', 'active', 'paused', 'archived', 'deleted')),
        state TEXT NOT NULL CHECK (state IN
          ('scheduled', 'active', 'paused', 'archived', 'deleted')),
        reason TEXT,
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        UNIQUE (habit_id, effective_date)
      )
    ''');
    await customStatement('''
      CREATE TRIGGER habit_lifecycle_no_retroactive_occurrences
      BEFORE INSERT ON habit_lifecycle_events
      WHEN EXISTS (
        SELECT 1 FROM habit_occurrences
        WHERE habit_id = NEW.habit_id AND local_date >= NEW.effective_date
      )
      BEGIN
        SELECT RAISE(ABORT, 'lifecycle correction workflow required');
      END
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_lifecycle_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_lifecycle_events
        BEGIN
          SELECT RAISE(ABORT, 'lifecycle correction workflow required');
        END
      ''');
    }
  }

  Future<String?> getSetting(String key) async {
    final row = await customSelect(
      'SELECT value FROM app_settings WHERE key = ?',
      variables: [Variable<String>(key)],
    ).getSingleOrNull();
    return row?.read<String>('value');
  }

  Future<void> setSetting(String key, String value) => customStatement(
    'INSERT INTO app_settings (key, value) VALUES (?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  Future<void> deleteSetting(String key) =>
      customStatement('DELETE FROM app_settings WHERE key = ?', [key]);
}

QueryExecutor _openConnection() => LazyDatabase(() async {
  final directory = await getApplicationSupportDirectory();
  final file = File(path.join(directory.path, 'hibi.sqlite'));
  return NativeDatabase.createInBackground(file);
});
