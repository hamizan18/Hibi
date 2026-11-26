import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'test_schema_downgrade.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

Future<void> prepare(AppDatabase db) async {
  await CounterHabitWriter(db, FixedClock()).create(
    habitId: 'h',
    versionId: 'v',
    auditId: 'a',
    lifecycleEventId: 'l',
    name: 'Read',
    effectiveDate: DateTime(2026, 11, 26),
    target: CounterTarget(count: 5, unit: 'pages'),
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
  );
  await CounterOccurrenceStore(
    db,
  ).getOrCreate(habitId: 'h', date: LocalDate(2026, 11, 26), occurrenceId: 'o');
}

void main() {
  for (final state in CounterResolutionState.values) {
    test(
      'explicit ${state.name} retains partial progress and creation audit',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await prepare(db);
        final progress = CounterProgressWriter(db, FixedClock());
        await progress.append(eventId: 'e', occurrenceId: 'o', quantity: 2);
        final writer = CounterResolutionWriter(db, FixedClock());
        await writer.resolve(
          id: 'r',
          occurrenceId: 'o',
          state: state,
          reason: 'Reason',
        );
        final day = await CounterDayReader(db)
            .read(habitId: 'h', date: LocalDate(2026, 11, 26));
        expect(day.recorded!.progress.total, 2);
        expect(day.resolution!.state, state);
        expect(day.resolution!.target, 5);
        expect(day.resolution!.progress, 2);
        expect(day.resolution!.reason, 'Reason');
        expect(day.resolution!.occurredAtUtc, FixedClock().now().toUtc());
        await expectLater(
          writer.resolve(id: 'r2', occurrenceId: 'o', state: state),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          progress.append(eventId: 'e2', occurrenceId: 'o', quantity: 3),
          throwsStateError,
        );
        await expectLater(
          db.customStatement(
            "UPDATE habit_counter_resolutions SET state = 'failed' WHERE id = 'r'",
          ),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          db.customStatement(
            "DELETE FROM habit_counter_resolutions WHERE id = 'r'",
          ),
          throwsA(isA<Exception>()),
        );
        expect(
          (await db
                  .customSelect(
                    'SELECT SUM(quantity) AS n FROM habit_counter_events',
                  )
                  .getSingle())
              .read<int>('n'),
          2,
        );
      },
    );
  }

  test(
    'completed, missing, future and unknown occurrences cannot be resolved',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await prepare(db);
      final writer = CounterResolutionWriter(db, FixedClock());
      await expectLater(
        writer.resolve(
          id: 'missing',
          occurrenceId: 'missing',
          state: CounterResolutionState.failed,
        ),
        throwsStateError,
      );
      await CounterOccurrenceStore(db).getOrCreate(
        habitId: 'h',
        date: LocalDate(2026, 11, 27),
        occurrenceId: 'future',
      );
      await expectLater(
        writer.resolve(
          id: 'future',
          occurrenceId: 'future',
          state: CounterResolutionState.failed,
        ),
        throwsStateError,
      );
      await CounterProgressWriter(
        db,
        FixedClock(),
      ).append(eventId: 'e', occurrenceId: 'o', quantity: 5);
      for (final state in CounterResolutionState.values) {
        await expectLater(
          writer.resolve(id: state.name, occurrenceId: 'o', state: state),
          throwsStateError,
        );
      }
      await db.customStatement("INSERT INTO habits VALUES ('h2', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v2', 'h2', 'Read', '2026-11-26', NULL, 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_counter_targets VALUES ('v2', 5, 'pages')",
      );
      await db.customStatement(
        "INSERT INTO habit_occurrences VALUES ('unknown', 'h2', 'v2', '2026-11-26', 5, 'pages')",
      );
      await expectLater(
        writer.resolve(
          id: 'unknown',
          occurrenceId: 'unknown',
          state: CounterResolutionState.excused,
        ),
        throwsStateError,
      );
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_counter_resolutions',
                )
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  test(
    'failed resolution insert rolls back and permits later progress',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await prepare(db);
      await db.customStatement(
        "CREATE TRIGGER reject_resolution BEFORE INSERT ON habit_counter_resolutions BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        CounterResolutionWriter(db, FixedClock()).resolve(
          id: 'r',
          occurrenceId: 'o',
          state: CounterResolutionState.failed,
        ),
        throwsA(isA<Exception>()),
      );
      await CounterProgressWriter(
        db,
        FixedClock(),
      ).append(eventId: 'e', occurrenceId: 'o', quantity: 2);
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_counter_resolutions',
                )
                .getSingle())
            .read<int>('n'),
        0,
      );
      expect(
        (await db
                .customSelect('SELECT quantity FROM habit_counter_events')
                .getSingle())
            .read<int>('quantity'),
        2,
      );
    },
  );

  test(
    'version 8 migration preserves progress without inventing resolutions',
    () async {
      final dir = await Directory.systemTemp.createTemp('hibi_resolution_v8_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(path.join(dir.path, 'db.sqlite'));
      final original = AppDatabase(NativeDatabase(file));
      await prepare(original);
      await CounterProgressWriter(
        original,
        FixedClock(),
      ).append(eventId: 'e', occurrenceId: 'o', quantity: 2);
      await original.close();
      final legacy = sqlite3.open(file.path);
      dropV11Tables(legacy);
      legacy.execute('DROP TABLE habit_counter_recoveries');
      legacy.execute('DROP TABLE habit_counter_resolutions');
      legacy.execute('PRAGMA user_version = 8');
      legacy.close();
      final migrated = AppDatabase(NativeDatabase(file));
      expect(
        (await migrated
                .customSelect('SELECT quantity FROM habit_counter_events')
                .getSingle())
            .read<int>('quantity'),
        2,
      );
      expect(
        (await migrated
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_counter_resolutions',
                )
                .getSingle())
            .read<int>('n'),
        0,
      );
      await CounterResolutionWriter(migrated, FixedClock()).resolve(
        id: 'r',
        occurrenceId: 'o',
        state: CounterResolutionState.excused,
      );
      await migrated.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(
        (await CounterResolutionReader(reopened).find('o'))!.state,
        CounterResolutionState.excused,
      );
    },
  );

  test(
    'failed v8 migration rolls back partial schema and preserves progress',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'hibi_resolution_failure_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File(path.join(dir.path, 'db.sqlite'));
      final original = AppDatabase(NativeDatabase(file));
      await prepare(original);
      await CounterProgressWriter(
        original,
        FixedClock(),
      ).append(eventId: 'e', occurrenceId: 'o', quantity: 2);
      await original.close();
      final legacy = sqlite3.open(file.path);
      dropV11Tables(legacy);
      legacy.execute('DROP TABLE habit_counter_recoveries');
      legacy.execute('DROP TABLE habit_counter_resolutions');
      legacy.execute(
        "CREATE TRIGGER habit_counter_resolutions_no_update BEFORE UPDATE ON habit_counter_events BEGIN SELECT RAISE(ABORT, 'collision'); END",
      );
      legacy.execute('PRAGMA user_version = 8');
      legacy.close();
      final migrated = AppDatabase(NativeDatabase(file));
      await expectLater(
        migrated.getSetting('theme'),
        throwsA(isA<Exception>()),
      );
      await migrated.close();
      final unchanged = sqlite3.open(file.path);
      addTearDown(unchanged.close);
      expect(unchanged.select('PRAGMA user_version').first['user_version'], 8);
      expect(
        unchanged
            .select("SELECT quantity FROM habit_counter_events WHERE id = 'e'")
            .single['quantity'],
        2,
      );
      expect(
        unchanged.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'habit_counter_resolutions'",
        ),
        isEmpty,
      );
    },
  );
}
