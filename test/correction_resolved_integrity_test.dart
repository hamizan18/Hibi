import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_history_reader.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/data/counter_recovery_store.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;

class TestClock implements AppClock {
  TestClock(this.current);
  DateTime current;
  @override
  DateTime now() => current;
}

Future<void> createHabit(AppDatabase db, TestClock clock) async {
  await CounterHabitWriter(db, clock).create(
    habitId: 'h',
    versionId: 'v',
    auditId: 'create',
    lifecycleEventId: 'life',
    name: 'Reading',
    effectiveDate: DateTime(2026, 11, 20),
    target: CounterTarget(count: 5, unit: 'pages'),
    schedule: DailySchedule(start: LocalDate(2026, 11, 20)),
  );
}

Future<void> makeResolved(
  AppDatabase db,
  TestClock clock,
  int day,
  String id,
  CounterResolutionState state,
) async {
  clock.current = DateTime(2026, 11, day, 9);
  await CounterOccurrenceStore(
    db,
  ).getOrCreate(habitId: 'h', date: LocalDate(2026, 11, day), occurrenceId: id);
  await CounterProgressWriter(
    db,
    clock,
  ).append(eventId: 'e_$id', occurrenceId: id, quantity: 2);
  await CounterResolutionWriter(
    db,
    clock,
  ).resolve(id: 'r_$id', occurrenceId: id, state: state);
}

Future<CounterCorrectionPreview> preview(
  AppDatabase db,
  TestClock clock,
  int target,
) => CounterCorrectionPreviewer(db, clock).preview(
  CounterTargetCorrectionProposal(
    habitId: 'h',
    versionId: 'v',
    proposedTargetCount: target,
    proposedUnit: 'pages',
  ),
);

void main() {
  test('resolved corrections preserve snapshots, recovery and audit across reopen and cycles', () async {
    final dir = await Directory.systemTemp.createTemp('counter_correction_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'counter.sqlite'));
    var db = AppDatabase(NativeDatabase(file));
    final clock = TestClock(DateTime(2026, 11, 20, 9));
    await createHabit(db, clock);
    await makeResolved(db, clock, 20, 'failed', CounterResolutionState.failed);
    await makeResolved(
      db,
      clock,
      21,
      'excused',
      CounterResolutionState.excused,
    );
    await makeResolved(
      db,
      clock,
      22,
      'recovered',
      CounterResolutionState.failed,
    );
    clock.current = DateTime(2026, 11, 23, 9);
    await CounterRecoveryWriter(
      db,
      clock,
    ).record(id: 'old', occurrenceId: 'recovered', quantity: 3);
    final proposed = await preview(db, clock, 7);
    expect(proposed.totalAffectedResolutionCount, 3);
    expect(proposed.totalAffectedRecoveryCount, 1);
    await CounterCorrectionWriter(
      db,
      clock,
    ).commit(correctionAuditId: 'z', confirmedPreview: proposed);
    Future<CounterDayEvaluation> day(int n) =>
        CounterDayReader(db)
            .evaluate(habitId: 'h', date: LocalDate(2026, 11, n));
    expect((await day(20)).effectiveStatus, CounterDayEffectiveStatus.failed);
    expect((await day(21)).effectiveStatus, CounterDayEffectiveStatus.excused);
    var recovered = await day(22);
    expect(recovered.effectiveStatus, CounterDayEffectiveStatus.failed);
    expect(recovered.recovery!.remainingDeficit, 2);
    final deficits = await CounterHistoryReader(
      db,
    ).findRecoverableDeficits(habitId: 'h', asOfDate: LocalDate(2026, 11, 23));
    expect(
      deficits
          .singleWhere((entry) => entry.occurrenceId == 'recovered')
          .remainingDeficit,
      2,
    );
    expect(recovered.day.resolution!.target, 5);
    expect(recovered.day.recoveries.single.originalTarget, 5);
    await CounterRecoveryWriter(
      db,
      clock,
    ).record(id: 'new', occurrenceId: 'recovered', quantity: 2);
    recovered = await day(22);
    expect(recovered.effectiveStatus, CounterDayEffectiveStatus.recovered);
    expect(recovered.recovery!.recoveredTotal, 5);
    expect(recovered.day.recoveries.last.originalTarget, 7);
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    // Same injected instant, reverse lexical IDs, and a target cycle prove that
    // timestamps and identifiers cannot define the correction sequence.
    expect(
      (await day(22)).effectiveStatus,
      CounterDayEffectiveStatus.recovered,
    );
    await CounterCorrectionWriter(db, clock).commit(
      correctionAuditId: 'a',
      confirmedPreview: await preview(db, clock, 8),
    );
    expect((await day(22)).recovery!.remainingDeficit, 1);
    await CounterCorrectionWriter(db, clock).commit(
      correctionAuditId: 'm',
      confirmedPreview: await preview(db, clock, 7),
    );
    expect(
      (await day(22)).effectiveStatus,
      CounterDayEffectiveStatus.recovered,
    );
    await expectLater(
      CounterRecoveryWriter(
        db,
        clock,
      ).record(id: 'over', occurrenceId: 'recovered', quantity: 1),
      throwsRangeError,
    );
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    expect(
      (await day(22)).effectiveStatus,
      CounterDayEffectiveStatus.recovered,
    );
    final audits = await CounterCorrectionWriter(
      db,
      clock,
    ).readAuditsForHabit('h');
    expect(audits.length, 3);
    final second = audits.singleWhere((a) => a.id == 'a');
    final third = audits.singleWhere((a) => a.id == 'm');
    expect(second.beforeSnapshot['previous_correction_audit_id'], 'z');
    expect(third.beforeSnapshot['previous_correction_audit_id'], 'a');
    final original = audits.singleWhere((a) => a.id == 'z');
    final source = original.beforeSnapshot['source_occurrences'] as List;
    final preimage = source.cast<Map<String, dynamic>>().singleWhere(
      (e) => e['id'] == 'recovered',
    );
    expect((preimage['resolution'] as Map)['target_count'], 5);
    expect(
      ((preimage['recoveries'] as List).single as Map)['remaining_deficit'],
      0,
    );
    final failedPreview = await preview(db, clock, 9);
    await db.customStatement(
      "CREATE TRIGGER reject_correction BEFORE INSERT ON habit_counter_correction_audit WHEN NEW.id = 'reject' BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    await expectLater(
      CounterCorrectionWriter(
        db,
        clock,
      ).commit(correctionAuditId: 'reject', confirmedPreview: failedPreview),
      throwsA(isA<Exception>()),
    );
    expect((await day(22)).day.recorded!.progress.target, 7);
    expect(
      (await day(22)).effectiveStatus,
      CounterDayEffectiveStatus.recovered,
    );
    expect(
      (await CounterCorrectionWriter(db, clock).readAuditsForHabit('h')).length,
      3,
    );
    await db.close();
  });

  test('one legacy audit can anchor a new correction', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = TestClock(DateTime(2026, 11, 20, 9));
    await createHabit(db, clock);
    await makeResolved(db, clock, 20, 'failed', CounterResolutionState.failed);
    final before = jsonEncode({
      'affected_occurrences': [
        {'occurrence_id': 'failed'},
      ],
    });
    await db.customStatement(
      '''INSERT INTO habit_counter_correction_audit
      (id, habit_id, habit_version_id, effective_start, previous_target_count,
       updated_target_count, unit, before_snapshot_json, after_snapshot_json, occurred_at_utc_us)
      VALUES ('legacy', 'h', 'v', '2026-11-20', 6, 5, 'pages', ?, '{}', 1)''',
      [before],
    );
    expect(
      (await CounterDayReader(
        db,
      ).evaluate(habitId: 'h', date: LocalDate(2026, 11, 20))).effectiveStatus,
      CounterDayEffectiveStatus.failed,
    );
    await CounterCorrectionWriter(db, clock).commit(
      correctionAuditId: 'new',
      confirmedPreview: await preview(db, clock, 7),
    );
    expect(
      (await CounterDayReader(
        db,
      ).evaluate(habitId: 'h', date: LocalDate(2026, 11, 20))).effectiveStatus,
      CounterDayEffectiveStatus.failed,
    );
    final audits = await CounterCorrectionWriter(
      db,
      clock,
    ).readAuditsForHabit('h');
    expect(
      audits
          .singleWhere((audit) => audit.id == 'new')
          .beforeSnapshot['previous_correction_audit_id'],
      'legacy',
    );
  });

  test(
    'ambiguous legacy correction histories remain visible as conflict',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock(DateTime(2026, 11, 20, 9));
      await createHabit(db, clock);
      await makeResolved(
        db,
        clock,
        20,
        'failed',
        CounterResolutionState.failed,
      );
      final before = jsonEncode({
        'affected_occurrences': [
          {'occurrence_id': 'failed'},
        ],
      });
      for (final entry in [('x', 5, 6), ('y', 6, 5)]) {
        await db.customStatement(
          '''INSERT INTO habit_counter_correction_audit
        (id, habit_id, habit_version_id, effective_start, previous_target_count,
         updated_target_count, unit, before_snapshot_json, after_snapshot_json, occurred_at_utc_us)
        VALUES (?, 'h', 'v', '2026-11-20', ?, ?, 'pages', ?, '{}', 1)''',
          [entry.$1, entry.$2, entry.$3, before],
        );
      }
      final result = await CounterDayReader(db)
          .evaluate(habitId: 'h', date: LocalDate(2026, 11, 20));
      expect(result.effectiveStatus, CounterDayEffectiveStatus.conflict);
      expect(result.day.resolution!.target, 5);
      await expectLater(
        preview(db, clock, 7),
        throwsA(isA<CounterCorrectionHistoryException>()),
      );
      expect(
        (await CounterCorrectionWriter(db, clock).readAuditsForHabit('h'))
            .length,
        2,
      );
    },
  );
  test(
    'correction rejects conflicting resolved progress without writing',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock(DateTime(2026, 11, 20, 9));
      await createHabit(db, clock);
      await makeResolved(
        db,
        clock,
        20,
        'failed',
        CounterResolutionState.failed,
      );
      await db.customStatement(
        "INSERT INTO habit_counter_events VALUES ('tampered', 'failed', 1, 1)",
      );
      expect(
        (await CounterDayReader(db).evaluate(
          habitId: 'h',
          date: LocalDate(2026, 11, 20),
        )).effectiveStatus,
        CounterDayEffectiveStatus.conflict,
      );
      await expectLater(preview(db, clock, 7), throwsStateError);
      expect(
        await CounterCorrectionWriter(db, clock).readAuditsForHabit('h'),
        isEmpty,
      );
    },
  );
}
