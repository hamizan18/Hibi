import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/data/counter_recovery_store.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'test_schema_downgrade.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

Future<MutableClock> prepareFailedOccurrence(AppDatabase db) async {
  final clock = MutableClock(DateTime(2026, 11, 26, 9));
  await CounterHabitWriter(db, clock).create(
    habitId: 'h',
    versionId: 'v',
    auditId: 'a',
    lifecycleEventId: 'l',
    name: 'Quran Reading',
    effectiveDate: DateTime(2026, 11, 26),
    target: CounterTarget(count: 5, unit: 'pages'),
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
  );
  await CounterOccurrenceStore(
    db,
  ).getOrCreate(habitId: 'h', date: LocalDate(2026, 11, 26), occurrenceId: 'o');
  await CounterProgressWriter(
    db,
    clock,
  ).append(eventId: 'e1', occurrenceId: 'o', quantity: 2);
  await CounterResolutionWriter(db, clock).resolve(
    id: 'r1',
    occurrenceId: 'o',
    state: CounterResolutionState.failed,
    reason: 'Fell asleep',
  );
  return clock;
}

void main() {
  test('partial and multi-step recoveries persist immutable snapshots without altering same-day or today progress', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = await prepareFailedOccurrence(db);

    clock.current = DateTime(2026, 11, 27, 10, 15);
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 27),
      occurrenceId: 'o_today',
    );
    final writer = CounterRecoveryWriter(db, clock);
    await writer.record(
      id: 'rec1',
      occurrenceId: 'o',
      quantity: 1,
      note: 'Morning catch-up',
    );
    clock.current = DateTime(2026, 11, 27, 18, 45);
    await writer.record(
      id: 'rec2',
      occurrenceId: 'o',
      quantity: 2,
      note: 'Evening completion',
    );

    final entries = await CounterRecoveryReader(db).findForOccurrence('o');
    expect(entries.length, 2);
    expect(entries[0].id, 'rec1');
    expect(entries[0].recoveryDate.compareTo(LocalDate(2026, 11, 27)), 0);
    expect(entries[0].quantity, 1);
    expect(entries[0].originalTarget, 5);
    expect(entries[0].originalProgress, 2);
    expect(entries[0].remainingDeficit, 2);
    expect(entries[0].note, 'Morning catch-up');
    expect(entries[0].occurredAtUtc, DateTime(2026, 11, 27, 10, 15).toUtc());

    expect(entries[1].id, 'rec2');
    expect(entries[1].quantity, 2);
    expect(entries[1].remainingDeficit, 0);
    expect(entries[1].note, 'Evening completion');

    final originalDay = await CounterDayReader(db)
        .read(habitId: 'h', date: LocalDate(2026, 11, 26));
    expect(originalDay.recorded!.progress.total, 2);

    final todayDay = await CounterDayReader(db)
        .read(habitId: 'h', date: LocalDate(2026, 11, 27));
    expect(todayDay.recorded!.progress.total, 0);

    await expectLater(
      writer.record(id: 'rec3', occurrenceId: 'o', quantity: 1),
      throwsRangeError,
    );
    await expectLater(
      db.customStatement(
        "UPDATE habit_counter_recoveries SET quantity = 3 WHERE id = 'rec1'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      db.customStatement(
        "DELETE FROM habit_counter_recoveries WHERE id = 'rec1'",
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('rejects same-day, future, unresolved, excused, paused, over-deficit and invalid recoveries', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = await prepareFailedOccurrence(db);
    final writer = CounterRecoveryWriter(db, clock);

    await expectLater(
      writer.record(id: 'same_day', occurrenceId: 'o', quantity: 1),
      throwsStateError,
    );

    clock.current = DateTime(2026, 11, 27, 12);
    for (final badQuantity in [0, -1, 4]) {
      await expectLater(
        writer.record(id: 'bad_q', occurrenceId: 'o', quantity: badQuantity),
        throwsRangeError,
      );
    }
    await expectLater(
      writer.record(id: 'missing', occurrenceId: 'missing', quantity: 1),
      throwsStateError,
    );

    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 27),
      occurrenceId: 'o_unresolved',
    );
    clock.current = DateTime(2026, 11, 28, 12);
    await expectLater(
      writer.record(
        id: 'unresolved',
        occurrenceId: 'o_unresolved',
        quantity: 1,
      ),
      throwsStateError,
    );

    clock.current = DateTime(2026, 11, 27, 12);
    await CounterResolutionWriter(db, clock).resolve(
      id: 'r_excused',
      occurrenceId: 'o_unresolved',
      state: CounterResolutionState.excused,
    );
    clock.current = DateTime(2026, 11, 28, 12);
    await expectLater(
      writer.record(id: 'excused', occurrenceId: 'o_unresolved', quantity: 1),
      throwsStateError,
    );

    await HabitLifecycleStore(db, clock).append(
      id: 'pause',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 28),
      state: HabitLifecycleState.paused,
    );
    await expectLater(
      writer.record(id: 'while_paused', occurrenceId: 'o', quantity: 1),
      throwsStateError,
    );

    expect(
      (await db
              .customSelect(
                'SELECT COUNT(*) AS n FROM habit_counter_recoveries',
              )
              .getSingle())
          .read<int>('n'),
      0,
    );
  });

  test(
    'failed recovery insertion rolls back and preserves existing deficit',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = await prepareFailedOccurrence(db);
      clock.current = DateTime(2026, 11, 27, 12);
      await db.customStatement(
        "CREATE TRIGGER reject_recovery BEFORE INSERT ON habit_counter_recoveries WHEN NEW.id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      final writer = CounterRecoveryWriter(db, clock);
      await expectLater(
        writer.record(id: 'fail', occurrenceId: 'o', quantity: 2),
        throwsA(isA<Exception>()),
      );
      await writer.record(id: 'ok', occurrenceId: 'o', quantity: 3);
      final entries = await CounterRecoveryReader(db).findForOccurrence('o');
      expect(entries.length, 1);
      expect(entries.single.id, 'ok');
      expect(entries.single.remainingDeficit, 0);
    },
  );

  test(
    'version 9 migration preserves resolutions without inventing recoveries',
    () async {
      final dir = await Directory.systemTemp.createTemp('hibi_recovery_v9_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(path.join(dir.path, 'db.sqlite'));
      final original = AppDatabase(NativeDatabase(file));
      final clock = await prepareFailedOccurrence(original);
      await original.close();

      final legacy = sqlite3.open(file.path);
      dropV11Tables(legacy);
      legacy.execute('DROP TABLE habit_counter_recoveries');
      legacy.execute('PRAGMA user_version = 9');
      legacy.close();

      final migrated = AppDatabase(NativeDatabase(file));
      expect(
        (await migrated.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        14,
      );
      expect(
        (await CounterResolutionReader(migrated).find('o'))!.state,
        CounterResolutionState.failed,
      );
      expect(
        await CounterRecoveryReader(migrated).findForOccurrence('o'),
        isEmpty,
      );

      clock.current = DateTime(2026, 11, 27, 12);
      await CounterRecoveryWriter(
        migrated,
        clock,
      ).record(id: 'rec', occurrenceId: 'o', quantity: 3);
      await migrated.close();

      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      final entries = await CounterRecoveryReader(reopened)
          .findForOccurrence('o');
      expect(entries.single.quantity, 3);
      expect(entries.single.remainingDeficit, 0);
    },
  );

  test('failed version 9 migration rolls back partial schema and preserves resolutions', () async {
    final dir = await Directory.systemTemp.createTemp(
      'hibi_recovery_v9_failure_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'db.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    await prepareFailedOccurrence(original);
    await original.close();

    final legacy = sqlite3.open(file.path);
    dropV11Tables(legacy);
    legacy.execute('DROP TABLE habit_counter_recoveries');
    legacy.execute(
      "CREATE TRIGGER habit_counter_recoveries_no_update BEFORE UPDATE ON habit_counter_events BEGIN SELECT RAISE(ABORT, 'collision'); END",
    );
    legacy.execute('PRAGMA user_version = 9');
    legacy.close();

    final migrated = AppDatabase(NativeDatabase(file));
    await expectLater(migrated.getSetting('theme'), throwsA(isA<Exception>()));
    await migrated.close();

    final unchanged = sqlite3.open(file.path);
    addTearDown(unchanged.close);
    expect(unchanged.select('PRAGMA user_version').first['user_version'], 9);
    expect(
      unchanged
          .select("SELECT state FROM habit_counter_resolutions WHERE id = 'r1'")
          .single['state'],
      'failed',
    );
    expect(
      unchanged.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'habit_counter_recoveries'",
      ),
      isEmpty,
    );
  });
}
