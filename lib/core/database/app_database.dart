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
  int get schemaVersion => 2;

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
    },
    // Unknown upgrades and downgrades must never silently discard data.
    onUpgrade: (migrator, from, to) async {
      if (from != 1 || to != 2) {
        throw StateError('No database migration from version $from to $to');
      }
      await transaction(() => _createHabitSchema());
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
