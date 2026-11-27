import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'test_schema_downgrade.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test('creation and future version preserve old target and record audit snapshots', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final writer = CounterHabitWriter(db, FixedClock());
    await writer.create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v2',
      auditId: 'a2',
      name: 'Read more',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 20, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
    );
    final versions = await db
        .customSelect(
          'SELECT v.id, v.effective_start, v.effective_end, t.target_count FROM habit_versions v JOIN habit_counter_targets t ON t.habit_version_id = v.id ORDER BY v.effective_start',
        )
        .get();
    expect(versions.map((v) => v.read<int>('target_count')), [5, 20]);
    expect(versions.first.read<String>('effective_end'), '2026-12-01');
    expect(versions.last.readNullable<String>('effective_end'), isNull);
    final audit = await db
        .customSelect(
          "SELECT previous_values, updated_values FROM habit_version_audit WHERE id = 'a2'",
        )
        .getSingle();
    final previous = jsonDecode(
      audit.read<String>('previous_values'),
    ) as Map<String, dynamic>;
    final updated = jsonDecode(
      audit.read<String>('updated_values'),
    ) as Map<String, dynamic>;
    expect(previous['target_count'], 5);
    expect(previous['effective_end'], isNull);
    expect(updated['closed_version']['effective_end'], '2026-12-01');
    expect(updated['new_version']['target_count'], 20);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_version_audit')
              .getSingle())
          .read<int>('n'),
      2,
    );
  });

  test(
    'inserting before a scheduled version leaves history unchanged',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final writer = CounterHabitWriter(db, FixedClock());
      await writer.create(
        habitId: 'h',
        versionId: 'v1',
        auditId: 'a1',
        lifecycleEventId: 'l1',
        name: 'Read',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      await writer.scheduleVersion(
        habitId: 'h',
        versionId: 'v2',
        auditId: 'a2',
        name: 'Read more',
        effectiveDate: DateTime(2026, 12, 15),
        target: CounterTarget(count: 20, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 12, 15)),
      );
      await expectLater(
        writer.scheduleVersion(
          habitId: 'h',
          versionId: 'v3',
          auditId: 'a3',
          name: 'Earlier change',
          effectiveDate: DateTime(2026, 12, 1),
          target: CounterTarget(count: 10, unit: 'pages'),
          schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
        ),
        throwsStateError,
      );
      final versions = await db.customSelect('''
      SELECT v.id, v.effective_end, t.target_count
      FROM habit_versions v
      JOIN habit_counter_targets t ON t.habit_version_id = v.id
      ORDER BY v.effective_start
    ''').get();
      expect(versions.map((row) => row.read<String>('id')), ['v1', 'v2']);
      expect(versions.map((row) => row.read<int>('target_count')), [5, 20]);
      expect(versions.first.read<String>('effective_end'), '2026-12-15');
      expect(versions.last.readNullable<String>('effective_end'), isNull);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_version_audit')
                .getSingle())
            .read<int>('n'),
        2,
      );
    },
  );

  test(
    'backdated and same-day edits are refused without changing history',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final writer = CounterHabitWriter(db, FixedClock());
      final target = CounterTarget(count: 5, unit: 'pages');
      await expectLater(
        writer.create(
          habitId: 'past',
          versionId: 'pv',
          auditId: 'pa',
          lifecycleEventId: 'lp',
          name: 'Read',
          effectiveDate: DateTime(2026, 11, 25),
          target: target,
          schedule: DailySchedule(start: LocalDate(2026, 11, 25)),
        ),
        throwsStateError,
      );
      await writer.create(
        habitId: 'h',
        versionId: 'v1',
        auditId: 'a1',
        lifecycleEventId: 'l1',
        name: 'Read',
        effectiveDate: DateTime(2026, 11, 26),
        target: target,
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      await expectLater(
        writer.scheduleVersion(
          habitId: 'h',
          versionId: 'v2',
          auditId: 'a2',
          name: 'Changed',
          effectiveDate: DateTime(2026, 11, 26),
          target: target,
          schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
        ),
        throwsStateError,
      );
      expect(
        (await db.customSelect('SELECT COUNT(*) AS n FROM habits').getSingle())
            .read<int>('n'),
        1,
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_version_audit')
                .getSingle())
            .read<int>('n'),
        1,
      );
      expect(
        (await db
                .customSelect(
                  "SELECT effective_end FROM habit_versions WHERE id = 'v1'",
                )
                .getSingle())
            .readNullable<String>('effective_end'),
        isNull,
      );
    },
  );

  test(
    'audit failure rolls back closing the previous version and new target',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final writer = CounterHabitWriter(db, FixedClock());
      final target = CounterTarget(count: 5, unit: 'pages');
      await writer.create(
        habitId: 'h',
        versionId: 'v1',
        auditId: 'a1',
        lifecycleEventId: 'l1',
        name: 'Read',
        effectiveDate: DateTime(2026, 11, 26),
        target: target,
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      await expectLater(
        writer.scheduleVersion(
          habitId: 'h',
          versionId: 'v2',
          auditId: 'a1',
          name: 'Changed',
          effectiveDate: DateTime(2026, 12, 1),
          target: target,
          schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_versions')
                .getSingle())
            .read<int>('n'),
        1,
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_counter_targets')
                .getSingle())
            .read<int>('n'),
        1,
      );
      expect(
        (await db
                .customSelect(
                  "SELECT effective_end FROM habit_versions WHERE id = 'v1'",
                )
                .getSingle())
            .readNullable<String>('effective_end'),
        isNull,
      );
    },
  );

  test(
    'version 3 migration preserves settings and habit configuration',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'hibi_audit_migration_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File(path.join(dir.path, 'test.sqlite'));
      final db = AppDatabase(NativeDatabase(file));
      await db.setSetting('theme', 'dark');
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-26', NULL, 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_counter_targets VALUES ('v', 5, 'pages')",
      );
      await db.close();
      final legacy = sqlite3.open(file.path);
      dropV11Tables(legacy);
      legacy.execute('DROP TABLE habit_counter_recoveries');
      legacy.execute('DROP TABLE habit_counter_resolutions');
      legacy.execute('DROP TABLE habit_counter_event_audit');
      legacy.execute('DROP TABLE habit_lifecycle_events');
      legacy.execute('DROP TABLE habit_schedules');
      legacy.execute('DROP TABLE habit_counter_events');
      legacy.execute('DROP TRIGGER habit_versions_protect_occurrences');
      legacy.execute('DROP TRIGGER habit_counter_targets_protect_update');
      legacy.execute('DROP TRIGGER habit_counter_targets_protect_delete');
      legacy.execute('DROP TABLE habit_occurrences');
      legacy.execute('DROP TABLE habit_version_audit');
      legacy.execute('PRAGMA user_version = 3');
      legacy.close();
      final migrated = AppDatabase(NativeDatabase(file));
      addTearDown(migrated.close);
      expect(await migrated.getSetting('theme'), 'dark');
      expect(
        (await migrated
                .customSelect(
                  "SELECT target_count FROM habit_counter_targets WHERE habit_version_id = 'v'",
                )
                .getSingle())
            .read<int>('target_count'),
        5,
      );
      expect(
        (await migrated.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        12,
      );
      expect(
        (await migrated
                .customSelect('SELECT COUNT(*) AS n FROM habit_version_audit')
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );
}
