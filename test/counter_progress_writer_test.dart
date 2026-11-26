import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'test_schema_downgrade.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12, 30);
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
  test(
    'multiple events and their audits commit with exact UTC timestamp',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await prepare(db);
      final writer = CounterProgressWriter(db, FixedClock());
      await writer.append(eventId: 'e1', occurrenceId: 'o', quantity: 2);
      await writer.append(eventId: 'e2', occurrenceId: 'o', quantity: 3);
      final rows = await db.customSelect('''
      SELECT e.id, e.quantity, e.occurred_at_utc_us, a.quantity AS audit_quantity,
             a.occurred_at_utc_us AS audit_time, a.occurrence_id
      FROM habit_counter_events e JOIN habit_counter_event_audit a ON a.event_id = e.id ORDER BY e.id
    ''').get();
      expect(rows.map((r) => r.read<int>('quantity')), [2, 3]);
      for (final row in rows) {
        expect(row.read<int>('audit_quantity'), row.read<int>('quantity'));
        expect(row.read<String>('occurrence_id'), 'o');
        expect(
          row.read<int>('occurred_at_utc_us'),
          FixedClock().now().toUtc().microsecondsSinceEpoch,
        );
        expect(
          row.read<int>('audit_time'),
          row.read<int>('occurred_at_utc_us'),
        );
      }
      await expectLater(
        writer.append(eventId: 'e1', occurrenceId: 'o', quantity: 2),
        throwsA(isA<Exception>()),
      );
      expect(
        (await db
                .customSelect(
                  'SELECT SUM(quantity) AS n FROM habit_counter_events',
                )
                .getSingle())
            .read<int>('n'),
        5,
      );
    },
  );

  test(
    'invalid progress, unknown occurrence and non-current dates are rejected',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await prepare(db);
      final writer = CounterProgressWriter(db, FixedClock());
      for (final quantity in [0, -1]) {
        await expectLater(
          writer.append(
            eventId: 'invalid',
            occurrenceId: 'o',
            quantity: quantity,
          ),
          throwsRangeError,
        );
      }
      await expectLater(
        writer.append(eventId: 'missing', occurrenceId: 'missing', quantity: 1),
        throwsStateError,
      );
      await CounterOccurrenceStore(db).getOrCreate(
        habitId: 'h',
        date: LocalDate(2026, 11, 27),
        occurrenceId: 'future',
      );
      await expectLater(
        writer.append(eventId: 'future', occurrenceId: 'future', quantity: 1),
        throwsStateError,
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_counter_events')
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  test(
    'existing occurrence with unknown applicability is not modified',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-26', NULL, 1, 1)",
      );
      await db.customStatement(
        "INSERT INTO habit_counter_targets VALUES ('v', 5, 'pages')",
      );
      await db.customStatement(
        "INSERT INTO habit_occurrences VALUES ('o', 'h', 'v', '2026-11-26', 5, 'pages')",
      );
      await expectLater(
        CounterProgressWriter(
          db,
          FixedClock(),
        ).append(eventId: 'e', occurrenceId: 'o', quantity: 1),
        throwsStateError,
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_counter_events')
                .getSingle())
            .read<int>('n'),
        0,
      );
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_counter_event_audit',
                )
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  test(
    'audit insertion failure rolls back the event and leaves prior progress',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await prepare(db);
      final writer = CounterProgressWriter(db, FixedClock());
      await writer.append(eventId: 'ok', occurrenceId: 'o', quantity: 2);
      await db.customStatement(
        "CREATE TRIGGER reject_event_audit BEFORE INSERT ON habit_counter_event_audit WHEN NEW.event_id = 'bad' BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        writer.append(eventId: 'bad', occurrenceId: 'o', quantity: 3),
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
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_counter_event_audit',
                )
                .getSingle())
            .read<int>('n'),
        1,
      );
    },
  );

  test('v7 migration retains existing events without inventing audit records', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_event_audit_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'db.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await prepare(original);
    await original.customStatement(
      "INSERT INTO habit_counter_events VALUES ('legacy', 'o', 2, 1)",
    );
    await original.close();
    final legacy = sqlite3.open(file.path);
    dropV11Tables(legacy);
    legacy.execute('DROP TABLE habit_counter_recoveries');
    legacy.execute('DROP TABLE habit_counter_resolutions');
    legacy.execute('DROP TABLE habit_counter_event_audit');
    legacy.execute('PRAGMA user_version = 7');
    legacy.close();
    final migrated = AppDatabase(NativeDatabase(file));
    expect(
      (await migrated
              .customSelect(
                "SELECT quantity FROM habit_counter_events WHERE id = 'legacy'",
              )
              .getSingle())
          .read<int>('quantity'),
      2,
    );
    expect(
      (await migrated
              .customSelect(
                'SELECT COUNT(*) AS n FROM habit_counter_event_audit',
              )
              .getSingle())
          .read<int>('n'),
      0,
    );
    await CounterProgressWriter(
      migrated,
      FixedClock(),
    ).append(eventId: 'new', occurrenceId: 'o', quantity: 3);
    await migrated.close();
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      (await reopened
              .customSelect(
                'SELECT SUM(quantity) AS n FROM habit_counter_events',
              )
              .getSingle())
          .read<int>('n'),
      5,
    );
    expect(
      (await reopened
              .customSelect(
                'SELECT COUNT(*) AS n FROM habit_counter_event_audit',
              )
              .getSingle())
          .read<int>('n'),
      1,
    );
  });

  test('rejects overflow without changing the event or audit ledger', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await prepare(db);
    final writer = CounterProgressWriter(db, FixedClock());
    await writer.append(
      eventId: 'max',
      occurrenceId: 'o',
      quantity: 9223372036854775807,
    );
    await expectLater(
      writer.append(eventId: 'overflow', occurrenceId: 'o', quantity: 1),
      throwsRangeError,
    );
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_counter_events')
              .getSingle())
          .read<int>('n'),
      1,
    );
    expect(
      (await db
              .customSelect(
                'SELECT COUNT(*) AS n FROM habit_counter_event_audit',
              )
              .getSingle())
          .read<int>('n'),
      1,
    );
  });

  test('failed v7 migration preserves old events and schema version', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_event_failure_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'db.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await prepare(original);
    await original.customStatement(
      "INSERT INTO habit_counter_events VALUES ('legacy', 'o', 2, 1)",
    );
    await original.close();
    final legacy = sqlite3.open(file.path);
    legacy.execute('PRAGMA user_version = 7');
    legacy.close();
    final migrated = AppDatabase(NativeDatabase(file));
    await expectLater(migrated.getSetting('theme'), throwsA(isA<Exception>()));
    await migrated.close();
    final unchanged = sqlite3.open(file.path);
    addTearDown(unchanged.close);
    expect(unchanged.select('PRAGMA user_version').first['user_version'], 7);
    expect(
      unchanged
          .select(
            "SELECT quantity FROM habit_counter_events WHERE id = 'legacy'",
          )
          .single['quantity'],
      2,
    );
  });
}
