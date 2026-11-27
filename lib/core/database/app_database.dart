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
  int get schemaVersion => 16;

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
      await _createCounterEventAuditSchema();
      await _createCounterResolutionSchema();
      await _createCounterRecoverySchema();
      await _createV11Schemas();
      await _createLifecycleStartPauseSchema();
      await _createScoringSchema();
      await _createFinanceSchema();
      await _createGrowthSchema();
      await _createGamificationSchema();
    },
    // Unknown upgrades and downgrades must never silently discard data.
    onUpgrade: (migrator, from, to) async {
      if (from < 1 || from > 15 || to != 16) {
        throw StateError('No database migration from version $from to $to');
      }
      await transaction(() async {
        if (from == 1) await _createHabitSchema();
        if (from <= 2) await _createCounterTargetSchema();
        if (from <= 3) await _createHabitAuditSchema();
        if (from <= 4) await _createOccurrenceSchema();
        if (from <= 5) {
          await _createScheduleSchema();
        } else if (from <= 10) {
          await _upgradeScheduleSchemaToV11();
        }
        if (from <= 6) await _createLifecycleSchema();
        if (from <= 7) await _createCounterEventAuditSchema();
        if (from <= 8) await _createCounterResolutionSchema();
        if (from <= 9) await _createCounterRecoverySchema();
        if (from <= 10) await _createV11Schemas();
        if (from <= 11) await _createLifecycleStartPauseSchema();
        if (from <= 10) {
          await _createScoringSchema();
        } else if (from <= 12) {
          await _upgradeToV13();
        }
        if (from <= 13) await _createFinanceSchema();
        if (from <= 14) await _createGrowthSchema();
        if (from <= 15) await _createGamificationSchema();
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
    await createCounterTargetAndOccurrenceProtectionTriggers();
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

  /// Creates the triggers guarding counter target and occurrence snapshots
  /// against unconfirmed direct updates.
  Future<void> createCounterTargetAndOccurrenceProtectionTriggers() async {
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
      CREATE TRIGGER habit_counter_targets_protect_update
      BEFORE UPDATE ON habit_counter_targets
      WHEN EXISTS (SELECT 1 FROM habit_occurrences WHERE habit_version_id = OLD.habit_version_id)
        AND (NEW.habit_version_id IS NOT OLD.habit_version_id
          OR NEW.target_count IS NOT OLD.target_count OR NEW.unit IS NOT OLD.unit)
      BEGIN
        SELECT RAISE(ABORT, 'target correction workflow required');
      END
    ''');
  }

  Future<void> _createScheduleTableOnly() async {
    await customStatement('''
      CREATE TABLE habit_schedules (
        habit_version_id TEXT NOT NULL PRIMARY KEY
          REFERENCES habit_versions(id) ON DELETE RESTRICT,
        recurrence TEXT NOT NULL CHECK (
          recurrence IN (
            'daily',
            'weekdays',
            'interval',
            'monthly_skip',
            'monthly_last_day',
            'one_time'
          )
        ),
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
          OR (recurrence = 'weekdays'
            AND typeof(weekday_mask) = 'integer'
            AND weekday_mask BETWEEN 1 AND 127)
          OR (recurrence = 'interval'
            AND typeof(weekday_mask) = 'integer'
            AND weekday_mask > 0)
          OR (recurrence IN ('monthly_skip', 'monthly_last_day')
            AND typeof(weekday_mask) = 'integer'
            AND weekday_mask BETWEEN 1 AND 31)
          OR (recurrence = 'one_time'
            AND weekday_mask IS NULL
            AND end_exclusive IS NOT NULL
            AND date(start_date, '+1 day') IS end_exclusive)
        )
      )
    ''');
  }

  Future<void> _createScheduleTriggers() async {
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

  Future<void> _createScheduleSchema() async {
    await _createScheduleTableOnly();
    await _createScheduleTriggers();
  }

  Future<void> _upgradeScheduleSchemaToV11() async {
    await customStatement(
      'DROP TRIGGER IF EXISTS habit_schedules_protect_insert',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS habit_schedules_protect_update',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS habit_schedules_protect_delete',
    );
    await customStatement(
      'ALTER TABLE habit_schedules RENAME TO habit_schedules_legacy_v10',
    );
    await _createScheduleTableOnly();
    await customStatement('''
      INSERT INTO habit_schedules
        (habit_version_id, recurrence, start_date, end_exclusive, weekday_mask)
      SELECT habit_version_id, recurrence, start_date, end_exclusive, weekday_mask
      FROM habit_schedules_legacy_v10
    ''');
    await customStatement('DROP TABLE habit_schedules_legacy_v10');
    await _createScheduleTriggers();
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

  Future<void> _createLifecycleStartPauseSchema() async {
    await customStatement('''
      CREATE TABLE habit_lifecycle_start_pauses (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        initial_event_id TEXT NOT NULL UNIQUE
          REFERENCES habit_lifecycle_events(id) ON DELETE RESTRICT
          CHECK (length(trim(initial_event_id)) > 0),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        reason TEXT
      )
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_lifecycle_start_pauses_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_lifecycle_start_pauses
        BEGIN
          SELECT RAISE(ABORT, 'lifecycle start pauses are immutable');
        END
      ''');
    }
  }

  Future<void> _createCounterEventAuditSchema() => customStatement('''
    CREATE TABLE habit_counter_event_audit (
      event_id TEXT NOT NULL PRIMARY KEY REFERENCES habit_counter_events(id) ON DELETE RESTRICT,
      occurrence_id TEXT NOT NULL REFERENCES habit_occurrences(id) ON DELETE RESTRICT,
      quantity INTEGER NOT NULL CHECK (typeof(quantity) = 'integer' AND quantity > 0),
      occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
    )
  ''');

  Future<void> _createCounterResolutionSchema() async {
    await customStatement('''
      CREATE TABLE habit_counter_resolutions (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL UNIQUE REFERENCES habit_occurrences(id) ON DELETE RESTRICT,
        state TEXT NOT NULL CHECK (state IN ('failed', 'excused')),
        reason TEXT,
        target_count INTEGER NOT NULL CHECK (typeof(target_count) = 'integer' AND target_count > 0),
        progress_total INTEGER NOT NULL CHECK (typeof(progress_total) = 'integer' AND progress_total >= 0 AND progress_total < target_count),
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_counter_resolutions_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_counter_resolutions
        BEGIN
          SELECT RAISE(ABORT, 'resolution correction workflow required');
        END
      ''');
    }
  }

  Future<void> _createCounterRecoverySchema() async {
    await customStatement('''
      CREATE TABLE habit_counter_recoveries (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL REFERENCES habit_occurrences(id) ON DELETE RESTRICT,
        recovery_local_date TEXT NOT NULL CHECK (
          recovery_local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(recovery_local_date, 1, 4) >= '0001'
          AND date(recovery_local_date, '+0 days') IS recovery_local_date
        ),
        quantity INTEGER NOT NULL CHECK (typeof(quantity) = 'integer' AND quantity > 0),
        original_target_count INTEGER NOT NULL CHECK (typeof(original_target_count) = 'integer' AND original_target_count > 0),
        original_progress_total INTEGER NOT NULL CHECK (
          typeof(original_progress_total) = 'integer'
          AND original_progress_total >= 0
          AND original_progress_total < original_target_count
        ),
        remaining_deficit INTEGER NOT NULL CHECK (
          typeof(remaining_deficit) = 'integer'
          AND remaining_deficit >= 0
          AND remaining_deficit < original_target_count - original_progress_total
        ),
        note TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX habit_counter_recoveries_by_occurrence_time
      ON habit_counter_recoveries (occurrence_id, occurred_at_utc_us)
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_counter_recoveries_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_counter_recoveries
        BEGIN
          SELECT RAISE(ABORT, 'recovery correction workflow required');
        END
      ''');
    }
  }

  Future<void> _createV11Schemas() async {
    // 1. Historical counter correction audit & preimages
    await customStatement('''
      CREATE TABLE habit_counter_correction_audit (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        habit_version_id TEXT NOT NULL REFERENCES habit_versions(id) ON DELETE RESTRICT,
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
        previous_target_count INTEGER NOT NULL CHECK (
          typeof(previous_target_count) = 'integer' AND previous_target_count > 0
        ),
        updated_target_count INTEGER NOT NULL CHECK (
          typeof(updated_target_count) = 'integer' AND updated_target_count > 0
        ),
        unit TEXT NOT NULL CHECK (length(trim(unit)) > 0),
        reason TEXT,
        before_snapshot_json TEXT NOT NULL CHECK (length(trim(before_snapshot_json)) > 0),
        after_snapshot_json TEXT NOT NULL CHECK (length(trim(after_snapshot_json)) > 0),
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX habit_counter_correction_audit_by_habit_time
      ON habit_counter_correction_audit (habit_id, occurred_at_utc_us)
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_counter_correction_audit_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_counter_correction_audit
        BEGIN
          SELECT RAISE(ABORT, 'correction audit records are immutable');
        END
      ''');
    }

    // 2. Version-scoped metadata (category, symbol, priority, privacy, ordering)
    await customStatement('''
      CREATE TABLE habit_version_metadata (
        habit_version_id TEXT NOT NULL PRIMARY KEY
          REFERENCES habit_versions(id) ON DELETE RESTRICT,
        description TEXT CHECK (description IS NULL OR length(trim(description)) > 0),
        symbol TEXT CHECK (symbol IS NULL OR length(trim(symbol)) > 0),
        category TEXT NOT NULL CHECK (length(trim(category)) > 0),
        priority TEXT NOT NULL CHECK (priority IN ('critical', 'high', 'normal', 'low')),
        is_private INTEGER NOT NULL CHECK (is_private IN (0, 1)),
        recovery_enabled INTEGER NOT NULL CHECK (recovery_enabled IN (0, 1)),
        include_in_score INTEGER NOT NULL CHECK (include_in_score IN (0, 1)),
        include_in_streak INTEGER NOT NULL CHECK (include_in_streak IN (0, 1)),
        include_in_rewards INTEGER NOT NULL CHECK (include_in_rewards IN (0, 1)),
        display_order INTEGER NOT NULL CHECK (typeof(display_order) = 'integer')
      )
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_version_metadata_protect_${operation.toLowerCase()}
        BEFORE $operation ON habit_version_metadata
        WHEN EXISTS (
          SELECT 1 FROM habit_occurrences WHERE habit_version_id = OLD.habit_version_id
        )
        BEGIN
          SELECT RAISE(ABORT, 'metadata correction workflow required');
        END
      ''');
    }

    // 3. Independent multi-checklist items, occurrences, logs and recoveries
    await customStatement('''
      CREATE TABLE habit_checklist_items (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_version_id TEXT NOT NULL REFERENCES habit_versions(id) ON DELETE RESTRICT,
        label TEXT NOT NULL CHECK (length(trim(label)) > 0),
        display_order INTEGER NOT NULL CHECK (typeof(display_order) = 'integer'),
        recovery_enabled INTEGER NOT NULL CHECK (recovery_enabled IN (0, 1)),
        UNIQUE (habit_version_id, display_order)
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_checklist_occurrences (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        habit_version_id TEXT NOT NULL REFERENCES habit_versions(id) ON DELETE RESTRICT,
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        UNIQUE (habit_id, local_date)
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_checklist_item_logs (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL REFERENCES habit_checklist_occurrences(id) ON DELETE RESTRICT,
        item_id TEXT NOT NULL REFERENCES habit_checklist_items(id) ON DELETE RESTRICT,
        state TEXT NOT NULL CHECK (state IN ('completed', 'failed', 'excused')),
        reason TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer'),
        UNIQUE (occurrence_id, item_id)
      )
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_checklist_item_logs_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_checklist_item_logs
        BEGIN
          SELECT RAISE(ABORT, 'checklist log correction workflow required');
        END
      ''');
    }
    await customStatement('''
      CREATE TABLE habit_checklist_item_recoveries (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        item_log_id TEXT NOT NULL UNIQUE REFERENCES habit_checklist_item_logs(id) ON DELETE RESTRICT,
        occurrence_id TEXT NOT NULL REFERENCES habit_checklist_occurrences(id) ON DELETE RESTRICT,
        item_id TEXT NOT NULL REFERENCES habit_checklist_items(id) ON DELETE RESTRICT,
        recovery_local_date TEXT NOT NULL CHECK (
          recovery_local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(recovery_local_date, 1, 4) >= '0001'
          AND date(recovery_local_date, '+0 days') IS recovery_local_date
        ),
        note TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_checklist_item_recoveries_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_checklist_item_recoveries
        BEGIN
          SELECT RAISE(ABORT, 'checklist recovery correction workflow required');
        END
      ''');
    }

    // 4. Avoidance targets, occurrences, repeated incidents and daily resolutions
    await customStatement('''
      CREATE TABLE habit_avoidance_targets (
        habit_version_id TEXT NOT NULL PRIMARY KEY
          REFERENCES habit_versions(id) ON DELETE RESTRICT,
        max_incidents INTEGER NOT NULL CHECK (
          typeof(max_incidents) = 'integer' AND max_incidents >= 0
        )
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_avoidance_occurrences (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        habit_version_id TEXT NOT NULL REFERENCES habit_versions(id) ON DELETE RESTRICT,
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        max_incidents INTEGER NOT NULL CHECK (
          typeof(max_incidents) = 'integer' AND max_incidents >= 0
        ),
        UNIQUE (habit_id, local_date)
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_avoidance_incidents (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL REFERENCES habit_avoidance_occurrences(id) ON DELETE RESTRICT,
        note TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_avoidance_resolutions (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL UNIQUE REFERENCES habit_avoidance_occurrences(id) ON DELETE RESTRICT,
        state TEXT NOT NULL CHECK (state IN ('confirmed_completed', 'failed', 'excused')),
        incident_count_snapshot INTEGER NOT NULL CHECK (
          typeof(incident_count_snapshot) = 'integer' AND incident_count_snapshot >= 0
        ),
        reason TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_avoidance_resolutions_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_avoidance_resolutions
        BEGIN
          SELECT RAISE(ABORT, 'avoidance resolution correction workflow required');
        END
      ''');
    }

    // 5. Typed targets & logs for boolean, duration, measurement, time_of_day and range
    await _createTypedTargets();
    await customStatement('''
      CREATE TABLE habit_typed_occurrences (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        habit_version_id TEXT NOT NULL REFERENCES habit_versions(id) ON DELETE RESTRICT,
        tracking_type TEXT NOT NULL CHECK (
          tracking_type IN ('boolean', 'duration', 'measurement', 'time_of_day', 'range')
        ),
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        UNIQUE (habit_id, local_date)
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_duration_events (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL REFERENCES habit_typed_occurrences(id) ON DELETE RESTRICT,
        duration_seconds INTEGER NOT NULL CHECK (
          typeof(duration_seconds) = 'integer' AND duration_seconds > 0
        ),
        source TEXT NOT NULL CHECK (source IN ('manual', 'timer')),
        started_at_utc_us INTEGER,
        ended_at_utc_us INTEGER,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer'),
        CHECK (
          (source = 'manual' AND started_at_utc_us IS NULL AND ended_at_utc_us IS NULL)
          OR (source = 'timer'
            AND typeof(started_at_utc_us) = 'integer'
            AND typeof(ended_at_utc_us) = 'integer'
            AND ended_at_utc_us > started_at_utc_us)
        )
      )
    ''');
    await customStatement('''
      CREATE TABLE habit_typed_logs (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        occurrence_id TEXT NOT NULL UNIQUE REFERENCES habit_typed_occurrences(id) ON DELETE RESTRICT,
        state TEXT NOT NULL CHECK (state IN ('completed', 'partial', 'failed', 'excused')),
        scaled_value INTEGER,
        minutes_since_midnight INTEGER CHECK (
          minutes_since_midnight IS NULL
          OR (typeof(minutes_since_midnight) = 'integer'
            AND minutes_since_midnight BETWEEN 0 AND 1439)
        ),
        day_offset INTEGER CHECK (
          day_offset IS NULL OR (typeof(day_offset) = 'integer' AND day_offset BETWEEN -1 AND 1)
        ),
        reason TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    for (final operation in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER habit_typed_logs_no_${operation.toLowerCase()}
        BEFORE $operation ON habit_typed_logs
        BEGIN
          SELECT RAISE(ABORT, 'typed log correction workflow required');
        END
      ''');
    }
  }

  Future<void> _createTypedTargets() async {
    await customStatement('''
      CREATE TABLE habit_typed_targets (
        habit_version_id TEXT NOT NULL PRIMARY KEY
          REFERENCES habit_versions(id) ON DELETE RESTRICT,
        tracking_type TEXT NOT NULL CHECK (
          tracking_type IN ('boolean', 'duration', 'measurement', 'time_of_day', 'range')
        ),
        target_seconds INTEGER,
        scaled_target INTEGER,
        min_scaled INTEGER,
        max_scaled INTEGER,
        decimal_places INTEGER,
        unit TEXT,
        comparison_rule TEXT,
        target_minutes_since_midnight INTEGER,
        CHECK (
          (tracking_type = 'boolean'
            AND target_seconds IS NULL
            AND scaled_target IS NULL
            AND min_scaled IS NULL
            AND max_scaled IS NULL
            AND decimal_places IS NULL
            AND unit IS NULL
            AND comparison_rule IS NULL
            AND target_minutes_since_midnight IS NULL)
          OR (tracking_type = 'duration'
            AND typeof(target_seconds) = 'integer'
            AND target_seconds > 0
            AND scaled_target IS NULL
            AND min_scaled IS NULL
            AND max_scaled IS NULL
            AND decimal_places IS NULL
            AND unit IS NULL
            AND comparison_rule IS NULL
            AND target_minutes_since_midnight IS NULL)
          OR (tracking_type = 'measurement'
            AND typeof(scaled_target) = 'integer'
            AND typeof(decimal_places) = 'integer'
            AND decimal_places BETWEEN 0 AND 6
            AND unit IS NOT NULL
            AND length(trim(unit)) > 0
            AND comparison_rule IN ('at_least', 'at_most', 'exact')
            AND target_seconds IS NULL
            AND min_scaled IS NULL
            AND max_scaled IS NULL
            AND target_minutes_since_midnight IS NULL)
          OR (tracking_type = 'time_of_day'
            AND typeof(target_minutes_since_midnight) = 'integer'
            AND target_minutes_since_midnight BETWEEN 0 AND 1439
            AND comparison_rule IN ('at_or_before', 'at_or_after', 'at_or_near')
            AND target_seconds IS NULL
            AND scaled_target IS NULL
            AND min_scaled IS NULL
            AND max_scaled IS NULL
            AND decimal_places IS NULL
            AND unit IS NULL)
          OR (tracking_type = 'range'
            AND typeof(min_scaled) = 'integer'
            AND typeof(max_scaled) = 'integer'
            AND min_scaled <= max_scaled
            AND typeof(decimal_places) = 'integer'
            AND decimal_places BETWEEN 0 AND 6
            AND unit IS NOT NULL
            AND length(trim(unit)) > 0
            AND target_seconds IS NULL
            AND scaled_target IS NULL
            AND comparison_rule IS NULL
            AND target_minutes_since_midnight IS NULL)
        )
      )
    ''');
  }

  Future<void> _createScoringSchema() async {
    await customStatement('''
      CREATE TABLE habit_version_scoring (
        habit_version_id TEXT NOT NULL PRIMARY KEY
          REFERENCES habit_versions(id) ON DELETE RESTRICT,
        tracking_type TEXT NOT NULL CHECK (tracking_type IN ('measurement', 'time_of_day', 'range')),
        rule_version INTEGER NOT NULL CHECK (typeof(rule_version) = 'integer' AND rule_version > 0),
        tolerance INTEGER,
        CHECK ((tracking_type = 'measurement' AND tolerance IS NULL)
          OR (tracking_type IN ('time_of_day', 'range')
            AND typeof(tolerance) = 'integer' AND tolerance > 0))
      )
    ''');
    for (final operation in ['INSERT', 'UPDATE']) {
      await customStatement('''
        CREATE TRIGGER habit_version_scoring_validate_${operation.toLowerCase()}
        BEFORE $operation ON habit_version_scoring
        WHEN NOT EXISTS (
          SELECT 1 FROM habit_typed_targets
          WHERE habit_version_id = NEW.habit_version_id
            AND tracking_type = NEW.tracking_type
        )
        BEGIN
          SELECT RAISE(ABORT, 'scoring type must match typed target');
        END
      ''');
    }
    for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
      final occurrenceCheck = switch (operation) {
        'INSERT' => 'habit_version_id = NEW.habit_version_id',
        'UPDATE' =>
          'habit_version_id IN (OLD.habit_version_id, NEW.habit_version_id)',
        _ => 'habit_version_id = OLD.habit_version_id',
      };
      await customStatement('''
        CREATE TRIGGER habit_version_scoring_protect_${operation.toLowerCase()}
        BEFORE $operation ON habit_version_scoring
        WHEN EXISTS (
          SELECT 1 FROM habit_typed_occurrences
          WHERE $occurrenceCheck
        )
        BEGIN
          SELECT RAISE(ABORT, 'scoring correction workflow required');
        END
      ''');
    }
    await customStatement('''
      CREATE TRIGGER habit_typed_targets_protect_scoring_update
      BEFORE UPDATE OF habit_version_id, tracking_type ON habit_typed_targets
      WHEN EXISTS (
        SELECT 1 FROM habit_version_scoring
        WHERE habit_version_id = OLD.habit_version_id
          AND (NEW.habit_version_id IS NOT OLD.habit_version_id
            OR NEW.tracking_type IS NOT OLD.tracking_type)
      )
      BEGIN
        SELECT RAISE(ABORT, 'target is used by scoring configuration');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER habit_typed_targets_protect_scoring_delete
      BEFORE DELETE ON habit_typed_targets
      WHEN EXISTS (
        SELECT 1 FROM habit_version_scoring
        WHERE habit_version_id = OLD.habit_version_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'target is used by scoring configuration');
      END
    ''');
  }

  Future<void> _upgradeToV13() async {
    // No table references typed targets, so copy them without rewriting dependents.
    await customStatement(
      'ALTER TABLE habit_typed_targets RENAME TO habit_typed_targets_v12',
    );
    await _createTypedTargets();
    await customStatement(
      'INSERT INTO habit_typed_targets SELECT * FROM habit_typed_targets_v12',
    );
    await customStatement('DROP TABLE habit_typed_targets_v12');
    await customStatement('''
      ALTER TABLE habit_typed_logs ADD COLUMN day_offset INTEGER
        CHECK (day_offset IS NULL OR (typeof(day_offset) = 'integer' AND day_offset BETWEEN -1 AND 1))
    ''');
    await _createScoringSchema();
  }

  Future<void> _createFinanceSchema() async {
    await customStatement('''
      CREATE TABLE finance_wallets (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        opening_balance_idr INTEGER NOT NULL CHECK (typeof(opening_balance_idr) = 'integer'),
        opening_date TEXT NOT NULL CHECK (
          opening_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(opening_date, 1, 4) >= '0001'
          AND date(opening_date, '+0 days') IS opening_date
        ),
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer')
      )
    ''');

    await customStatement('''
      CREATE TABLE finance_categories (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        kind TEXT NOT NULL CHECK (kind IN ('income', 'expense')),
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        UNIQUE (name, kind)
      )
    ''');

    await customStatement('''
      CREATE TABLE finance_transactions (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        wallet_id TEXT NOT NULL REFERENCES finance_wallets(id) ON DELETE RESTRICT,
        category_id TEXT NOT NULL REFERENCES finance_categories(id) ON DELETE RESTRICT,
        type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
        amount_idr INTEGER NOT NULL CHECK (typeof(amount_idr) = 'integer' AND amount_idr > 0),
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        note TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        updated_at_utc_us INTEGER NOT NULL CHECK (typeof(updated_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX finance_transactions_by_date
      ON finance_transactions (local_date, id)
    ''');
    await customStatement('''
      CREATE INDEX finance_transactions_by_wallet
      ON finance_transactions (wallet_id, local_date)
    ''');
    await customStatement('''
      CREATE INDEX finance_transactions_by_category
      ON finance_transactions (category_id, local_date)
    ''');
    for (final op in ['INSERT', 'UPDATE']) {
      await customStatement('''
        CREATE TRIGGER finance_transactions_validate_category_${op.toLowerCase()}
        BEFORE $op ON finance_transactions
        WHEN NOT EXISTS (
          SELECT 1 FROM finance_categories c
          WHERE c.id = NEW.category_id AND c.kind = NEW.type
        )
        BEGIN
          SELECT RAISE(ABORT, 'transaction category kind must match transaction type');
        END
      ''');
    }

    await customStatement('''
      CREATE TABLE finance_transfers (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        from_wallet_id TEXT NOT NULL REFERENCES finance_wallets(id) ON DELETE RESTRICT,
        to_wallet_id TEXT NOT NULL REFERENCES finance_wallets(id) ON DELETE RESTRICT,
        amount_idr INTEGER NOT NULL CHECK (typeof(amount_idr) = 'integer' AND amount_idr > 0),
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        note TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        updated_at_utc_us INTEGER NOT NULL CHECK (typeof(updated_at_utc_us) = 'integer'),
        CHECK (from_wallet_id != to_wallet_id)
      )
    ''');
    await customStatement('''
      CREATE INDEX finance_transfers_by_date
      ON finance_transfers (local_date, id)
    ''');

    await customStatement('''
      CREATE TABLE finance_budgets (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        category_id TEXT NOT NULL REFERENCES finance_categories(id) ON DELETE RESTRICT,
        period_start TEXT NOT NULL CHECK (
          period_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(period_start, 1, 4) >= '0001'
          AND date(period_start, '+0 days') IS period_start
        ),
        period_end_inclusive TEXT NOT NULL CHECK (
          period_end_inclusive GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(period_end_inclusive, 1, 4) >= '0001'
          AND date(period_end_inclusive, '+0 days') IS period_end_inclusive
          AND period_end_inclusive >= period_start
        ),
        limit_idr INTEGER NOT NULL CHECK (typeof(limit_idr) = 'integer' AND limit_idr > 0),
        rollover_enabled INTEGER NOT NULL DEFAULT 0 CHECK (rollover_enabled IN (0, 1)),
        rollover_carry_idr INTEGER NOT NULL DEFAULT 0 CHECK (typeof(rollover_carry_idr) = 'integer'),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        updated_at_utc_us INTEGER NOT NULL CHECK (typeof(updated_at_utc_us) = 'integer'),
        CHECK (rollover_enabled = 1 OR rollover_carry_idr = 0)
      )
    ''');
    await customStatement('''
      CREATE INDEX finance_budgets_by_category_period
      ON finance_budgets (category_id, period_start, period_end_inclusive)
    ''');
    for (final op in ['INSERT', 'UPDATE']) {
      await customStatement('''
        CREATE TRIGGER finance_budgets_validate_expense_${op.toLowerCase()}
        BEFORE $op ON finance_budgets
        WHEN NOT EXISTS (
          SELECT 1 FROM finance_categories c
          WHERE c.id = NEW.category_id AND c.kind = 'expense'
        )
        BEGIN
          SELECT RAISE(ABORT, 'budgets apply to expense categories only');
        END
      ''');
    }

    await customStatement('''
      CREATE TABLE finance_audit (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        entity_type TEXT NOT NULL CHECK (entity_type IN ('wallet', 'category', 'transaction', 'transfer', 'budget')),
        entity_id TEXT NOT NULL CHECK (length(trim(entity_id)) > 0),
        operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'archive', 'delete')),
        previous_values TEXT,
        updated_values TEXT NOT NULL CHECK (length(trim(updated_values)) > 0),
        reason TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX finance_audit_by_entity_time
      ON finance_audit (entity_type, entity_id, occurred_at_utc_us)
    ''');
    for (final op in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER finance_audit_no_${op.toLowerCase()}
        BEFORE $op ON finance_audit
        BEGIN
          SELECT RAISE(ABORT, 'finance audit records are immutable');
        END
      ''');
    }
  }

  Future<void> _createGrowthSchema() async {
    // 1. Optional Journal & Mood (multiple entries per local date, private-aware).
    await customStatement('''
      CREATE TABLE journal_entries (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        title TEXT,
        reflection_text TEXT,
        gratitude_text TEXT,
        mood TEXT CHECK (
          mood IS NULL OR mood IN ('very_low', 'low', 'neutral', 'good', 'great')
        ),
        is_private INTEGER NOT NULL DEFAULT 0 CHECK (is_private IN (0, 1)),
        is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        updated_at_utc_us INTEGER NOT NULL CHECK (typeof(updated_at_utc_us) = 'integer'),
        CHECK (
          (title IS NOT NULL AND length(trim(title)) > 0)
          OR (reflection_text IS NOT NULL AND length(trim(reflection_text)) > 0)
          OR (gratitude_text IS NOT NULL AND length(trim(gratitude_text)) > 0)
          OR mood IS NOT NULL
        )
      )
    ''');
    await customStatement('''
      CREATE INDEX journal_entries_by_date
      ON journal_entries (local_date, created_at_utc_us, id)
    ''');

    await customStatement('''
      CREATE TABLE journal_entry_tags (
        entry_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
        tag TEXT NOT NULL CHECK (length(trim(tag)) > 0),
        PRIMARY KEY (entry_id, tag)
      )
    ''');
    await customStatement('''
      CREATE INDEX journal_entry_tags_by_tag
      ON journal_entry_tags (tag, entry_id)
    ''');

    // 2. Goals, Milestones, Linked Habits, Deduplicated Progress & Status History.
    await customStatement('''
      CREATE TABLE goals (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        title TEXT NOT NULL CHECK (length(trim(title)) > 0),
        description TEXT,
        status TEXT NOT NULL CHECK (
          status IN ('planned', 'in_progress', 'completed', 'paused', 'abandoned')
        ),
        target_date TEXT CHECK (
          target_date IS NULL OR (
            target_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
            AND substr(target_date, 1, 4) >= '0001'
            AND date(target_date, '+0 days') IS target_date
          )
        ),
        target_units INTEGER CHECK (
          target_units IS NULL OR (typeof(target_units) = 'integer' AND target_units > 0)
        ),
        unit_label TEXT,
        is_private INTEGER NOT NULL DEFAULT 0 CHECK (is_private IN (0, 1)),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        updated_at_utc_us INTEGER NOT NULL CHECK (typeof(updated_at_utc_us) = 'integer')
      )
    ''');

    await customStatement('''
      CREATE TABLE goal_status_history (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE RESTRICT,
        previous_status TEXT CHECK (
          previous_status IS NULL
          OR previous_status IN ('planned', 'in_progress', 'completed', 'paused', 'abandoned')
        ),
        new_status TEXT NOT NULL CHECK (
          new_status IN ('planned', 'in_progress', 'completed', 'paused', 'abandoned')
        ),
        reason TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX goal_status_history_by_goal
      ON goal_status_history (goal_id, occurred_at_utc_us, id)
    ''');
    for (final op in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER goal_status_history_no_${op.toLowerCase()}
        BEFORE $op ON goal_status_history
        BEGIN
          SELECT RAISE(ABORT, 'goal status history is immutable');
        END
      ''');
    }

    await customStatement('''
      CREATE TABLE goal_milestones (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE RESTRICT,
        title TEXT NOT NULL CHECK (length(trim(title)) > 0),
        sort_order INTEGER NOT NULL DEFAULT 0 CHECK (typeof(sort_order) = 'integer'),
        is_completed INTEGER NOT NULL DEFAULT 0 CHECK (is_completed IN (0, 1)),
        completed_at_utc_us INTEGER CHECK (
          (is_completed = 0 AND completed_at_utc_us IS NULL)
          OR (is_completed = 1 AND completed_at_utc_us IS NOT NULL AND typeof(completed_at_utc_us) = 'integer')
        ),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX goal_milestones_by_goal
      ON goal_milestones (goal_id, sort_order, id)
    ''');

    await customStatement('''
      CREATE TABLE goal_habit_links (
        goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE RESTRICT,
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        PRIMARY KEY (goal_id, habit_id)
      )
    ''');

    await customStatement('''
      CREATE TABLE goal_progress_entries (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE RESTRICT,
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        units INTEGER NOT NULL CHECK (typeof(units) = 'integer' AND units > 0),
        source TEXT NOT NULL CHECK (
          source IN ('manual', 'linked_habit', 'linked_focus', 'milestone')
        ),
        source_ref_id TEXT CHECK (
          (source = 'manual' AND (source_ref_id IS NULL OR length(trim(source_ref_id)) > 0))
          OR (source != 'manual' AND source_ref_id IS NOT NULL AND length(trim(source_ref_id)) > 0)
        ),
        note TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX goal_progress_unique_source_ref
      ON goal_progress_entries (goal_id, source, source_ref_id)
      WHERE source_ref_id IS NOT NULL
    ''');
    await customStatement('''
      CREATE INDEX goal_progress_by_goal_date
      ON goal_progress_entries (goal_id, local_date, occurred_at_utc_us)
    ''');

    // 3. Restart-Safe Focus / Pomodoro Presets and Sessions.
    await customStatement('''
      CREATE TABLE focus_presets (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        focus_minutes INTEGER NOT NULL CHECK (typeof(focus_minutes) = 'integer' AND focus_minutes > 0),
        short_break_minutes INTEGER NOT NULL CHECK (typeof(short_break_minutes) = 'integer' AND short_break_minutes > 0),
        long_break_minutes INTEGER NOT NULL CHECK (typeof(long_break_minutes) = 'integer' AND long_break_minutes > 0),
        sessions_before_long_break INTEGER NOT NULL DEFAULT 4 CHECK (
          typeof(sessions_before_long_break) = 'integer' AND sessions_before_long_break > 0
        ),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer')
      )
    ''');

    await customStatement('''
      CREATE TABLE focus_sessions (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        preset_id TEXT REFERENCES focus_presets(id) ON DELETE RESTRICT,
        kind TEXT NOT NULL CHECK (kind IN ('focus', 'short_break', 'long_break')),
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        planned_duration_seconds INTEGER NOT NULL CHECK (
          typeof(planned_duration_seconds) = 'integer' AND planned_duration_seconds > 0
        ),
        state TEXT NOT NULL CHECK (
          state IN ('running', 'paused', 'completed', 'interrupted', 'cancelled')
        ),
        cycle_index INTEGER NOT NULL DEFAULT 1 CHECK (
          typeof(cycle_index) = 'integer' AND cycle_index > 0
        ),
        started_at_utc_us INTEGER NOT NULL CHECK (typeof(started_at_utc_us) = 'integer'),
        last_resumed_at_utc_us INTEGER CHECK (
          (state = 'running' AND last_resumed_at_utc_us IS NOT NULL AND typeof(last_resumed_at_utc_us) = 'integer')
          OR (state != 'running' AND last_resumed_at_utc_us IS NULL)
        ),
        deadline_utc_us INTEGER CHECK (
          (state = 'running' AND deadline_utc_us IS NOT NULL AND typeof(deadline_utc_us) = 'integer' AND deadline_utc_us >= last_resumed_at_utc_us)
          OR (state != 'running' AND deadline_utc_us IS NULL)
        ),
        accumulated_elapsed_seconds INTEGER NOT NULL DEFAULT 0 CHECK (
          typeof(accumulated_elapsed_seconds) = 'integer'
          AND accumulated_elapsed_seconds >= 0
          AND accumulated_elapsed_seconds <= planned_duration_seconds
        ),
        ended_at_utc_us INTEGER CHECK (
          (state IN ('completed', 'interrupted', 'cancelled') AND ended_at_utc_us IS NOT NULL AND typeof(ended_at_utc_us) = 'integer')
          OR (state IN ('running', 'paused') AND ended_at_utc_us IS NULL)
        ),
        interruption_reason TEXT CHECK (
          state = 'interrupted' OR interruption_reason IS NULL
        ),
        linked_habit_id TEXT REFERENCES habits(id) ON DELETE RESTRICT,
        linked_goal_id TEXT REFERENCES goals(id) ON DELETE RESTRICT,
        linked_habit_event_id TEXT,
        linked_goal_progress_id TEXT,
        note TEXT
      )
    ''');
    await customStatement('''
      CREATE INDEX focus_sessions_by_date
      ON focus_sessions (local_date, started_at_utc_us, id)
    ''');
    await customStatement('''
      CREATE INDEX focus_sessions_by_state
      ON focus_sessions (state, started_at_utc_us)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX focus_sessions_unique_habit_event
      ON focus_sessions (linked_habit_event_id)
      WHERE linked_habit_event_id IS NOT NULL
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX focus_sessions_unique_goal_progress
      ON focus_sessions (linked_goal_progress_id)
      WHERE linked_goal_progress_id IS NOT NULL
    ''');
  }

  Future<void> _createGamificationSchema() async {
    // 1. Versioned, immutable, idempotent XP ledger (habit occurrences only;
    //    never finance spending/income or repeated edits).
    await customStatement('''
      CREATE TABLE gamification_xp_ledger (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        rule_version INTEGER NOT NULL CHECK (typeof(rule_version) = 'integer' AND rule_version > 0),
        source_type TEXT NOT NULL CHECK (source_type IN ('habit_occurrence')),
        source_key TEXT NOT NULL CHECK (length(trim(source_key)) > 0),
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        local_date TEXT NOT NULL CHECK (
          local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
          AND substr(local_date, 1, 4) >= '0001'
          AND date(local_date, '+0 days') IS local_date
        ),
        entry_kind TEXT NOT NULL CHECK (entry_kind IN ('award', 'reconciliation')),
        status_snapshot TEXT NOT NULL CHECK (status_snapshot IN ('completed', 'recovered', 'revoked')),
        xp_delta INTEGER NOT NULL CHECK (typeof(xp_delta) = 'integer' AND xp_delta != 0),
        reason TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX gamification_xp_unique_award
      ON gamification_xp_ledger (source_type, source_key, rule_version)
      WHERE entry_kind = 'award'
    ''');
    await customStatement('''
      CREATE INDEX gamification_xp_by_source
      ON gamification_xp_ledger (source_type, source_key, occurred_at_utc_us, id)
    ''');
    await customStatement('''
      CREATE INDEX gamification_xp_by_habit_date
      ON gamification_xp_ledger (habit_id, local_date, occurred_at_utc_us)
    ''');
    for (final op in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER gamification_xp_ledger_no_${op.toLowerCase()}
        BEFORE $op ON gamification_xp_ledger
        BEGIN
          SELECT RAISE(ABORT, 'gamification xp ledger entries are immutable');
        END
      ''');
    }

    // 2. Deterministic achievements preserving unlock history even if later invalidated.
    await customStatement('''
      CREATE TABLE gamification_achievements (
        achievement_key TEXT NOT NULL PRIMARY KEY CHECK (length(trim(achievement_key)) > 0),
        rule_version INTEGER NOT NULL CHECK (typeof(rule_version) = 'integer' AND rule_version > 0),
        unlocked_at_utc_us INTEGER NOT NULL CHECK (typeof(unlocked_at_utc_us) = 'integer'),
        is_currently_valid INTEGER NOT NULL CHECK (is_currently_valid IN (0, 1)),
        invalidated_at_utc_us INTEGER CHECK (
          (is_currently_valid = 1 AND invalidated_at_utc_us IS NULL)
          OR (is_currently_valid = 0 AND invalidated_at_utc_us IS NOT NULL AND typeof(invalidated_at_utc_us) = 'integer')
        ),
        last_evaluated_at_utc_us INTEGER NOT NULL CHECK (typeof(last_evaluated_at_utc_us) = 'integer'),
        status_note TEXT
      )
    ''');

    await customStatement('''
      CREATE TABLE gamification_achievement_history (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        achievement_key TEXT NOT NULL REFERENCES gamification_achievements(achievement_key) ON DELETE RESTRICT,
        rule_version INTEGER NOT NULL CHECK (typeof(rule_version) = 'integer' AND rule_version > 0),
        event_type TEXT NOT NULL CHECK (event_type IN ('unlocked', 'invalidated', 'revalidated')),
        reason TEXT,
        occurred_at_utc_us INTEGER NOT NULL CHECK (typeof(occurred_at_utc_us) = 'integer')
      )
    ''');
    await customStatement('''
      CREATE INDEX gamification_achievement_history_by_key
      ON gamification_achievement_history (achievement_key, occurred_at_utc_us, id)
    ''');
    for (final op in ['UPDATE', 'DELETE']) {
      await customStatement('''
        CREATE TRIGGER gamification_achievement_history_no_${op.toLowerCase()}
        BEFORE $op ON gamification_achievement_history
        BEGIN
          SELECT RAISE(ABORT, 'gamification achievement history is immutable');
        END
      ''');
    }

    // 3. Custom activity attributes (reflect activity, not competence or moral worth).
    await customStatement('''
      CREATE TABLE gamification_attributes (
        id TEXT NOT NULL PRIMARY KEY CHECK (length(trim(id)) > 0),
        name TEXT NOT NULL UNIQUE CHECK (length(trim(name)) > 0),
        description TEXT,
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer')
      )
    ''');

    await customStatement('''
      CREATE TABLE gamification_habit_attributes (
        habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE RESTRICT,
        attribute_id TEXT NOT NULL REFERENCES gamification_attributes(id) ON DELETE RESTRICT,
        created_at_utc_us INTEGER NOT NULL CHECK (typeof(created_at_utc_us) = 'integer'),
        PRIMARY KEY (habit_id, attribute_id)
      )
    ''');
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
