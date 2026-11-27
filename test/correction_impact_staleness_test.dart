import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_correction_controls.dart';

class _Clock implements AppClock {
  DateTime current = DateTime(2026, 11, 25, 12);
  @override
  DateTime now() => current;
}

const _proposal = CounterTargetCorrectionProposal(
  habitId: 'h',
  versionId: 'v2',
  proposedTargetCount: 5,
  proposedUnit: 'pages',
);

Future<void> _fixture(AppDatabase db, _Clock clock) async {
  final writer = CounterHabitWriter(db, clock);
  final target = CounterTarget(count: 10, unit: 'pages');
  await writer.create(
    habitId: 'h',
    versionId: 'v1',
    auditId: 'a1',
    lifecycleEventId: 'l1',
    name: 'Reading',
    effectiveDate: DateTime(2026, 11, 25),
    target: target,
    schedule: DailySchedule(start: LocalDate(2026, 11, 25)),
  );
  await HabitMetadataStore(db).insert('v1', HabitMetadata(category: 'Books'));
  await writer.scheduleVersion(
    habitId: 'h',
    versionId: 'v2',
    auditId: 'a2',
    name: 'Reading',
    effectiveDate: DateTime(2026, 11, 26),
    target: target,
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    metadata: HabitMetadata(category: 'Books'),
  );
  final actions = CounterTodayActionService(db, clock);
  await actions.recordTodayProgress(
    habitId: 'h',
    occurrenceId: 'old-o',
    eventId: 'old-e',
    quantity: 10,
  );
  clock.current = DateTime(2026, 11, 26, 12);
  await actions.recordTodayProgress(
    habitId: 'h',
    occurrenceId: 'new-o',
    eventId: 'new-e',
    quantity: 5,
  );
  await writer.create(
    habitId: 'other',
    versionId: 'other-v',
    auditId: 'other-a',
    lifecycleEventId: 'other-l',
    name: 'Other',
    effectiveDate: DateTime(2026, 11, 26),
    target: target,
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
  );
  await HabitMetadataStore(db)
      .insert('other-v', HabitMetadata(category: 'Other'));
}

Future<int> _target(AppDatabase db) async =>
    (await db
            .customSelect(
              "SELECT target_count FROM habit_counter_targets WHERE habit_version_id = 'v2'",
            )
            .getSingle())
        .read<int>('target_count');

void main() {
  final mutations = <String, Future<void> Function(AppDatabase, _Clock)>{
    'another habit records progress': (db, clock) =>
        CounterTodayActionService(db, clock).recordTodayProgress(
          habitId: 'other',
          occurrenceId: 'other-o',
          eventId: 'other-e',
          quantity: 7,
        ),
    'another habit changes its target': (db, clock) => db.customStatement(
      "UPDATE habit_counter_targets SET target_count = 12 WHERE habit_version_id = 'other-v'",
    ),
    'another habit changes priority': (db, clock) => db.customStatement(
      "UPDATE habit_version_metadata SET priority = 'critical' WHERE habit_version_id = 'other-v'",
    ),
    'another habit becomes private': (db, clock) => db.customStatement(
      "UPDATE habit_version_metadata SET is_private = 1 WHERE habit_version_id = 'other-v'",
    ),
    'a streak source event changes outside the corrected version':
        (db, clock) => db.customStatement(
          "INSERT INTO habit_counter_events (id, occurrence_id, quantity, occurred_at_utc_us) VALUES ('extra', 'old-o', 1, 1)",
        ),
    'midnight passes': (db, clock) async {
      clock.current = DateTime(2026, 11, 27, 0, 1);
    },
  };

  for (final entry in mutations.entries) {
    test('impact-bound direct commit rejects when ${entry.key}', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock();
      await _fixture(db, clock);
      final previewer = CounterCorrectionPreviewer(db, clock);
      final ordinary = await previewer.preview(_proposal);
      final impact = await AnalyticsCorrectionImpactReader(
        db,
        clock,
      ).previewImpact(_proposal);
      expect(await previewer.isStale(ordinary), isFalse);
      expect(await previewer.isStale(impact.preview), isFalse);
      await entry.value(db, clock);
      expect(await previewer.isStale(impact.preview), isTrue);
      expect(await previewer.isStale(ordinary), entry.key == 'midnight passes');
      final before =
          (await db.customSelect('SELECT total_changes() AS n').getSingle())
              .read<int>('n');
      final writer = CounterCorrectionWriter(db, clock);
      await expectLater(
        writer.commit(correctionAuditId: 'c', confirmedPreview: impact.preview),
        throwsStateError,
      );
      expect(await _target(db), 10);
      expect(await writer.readAuditsForHabit('h'), isEmpty);
      expect(
        (await db.customSelect('SELECT total_changes() AS n').getSingle())
            .read<int>('n'),
        before,
      );
    });
  }

  test(
    'unchanged impact preview and ordinary direct preview can commit',
    () async {
      for (final withImpact in [false, true]) {
        final db = AppDatabase(NativeDatabase.memory());
        final clock = _Clock();
        await _fixture(db, clock);
        final preview = withImpact
            ? (await AnalyticsCorrectionImpactReader(
                db,
                clock,
              ).previewImpact(_proposal)).preview
            : await CounterCorrectionPreviewer(db, clock).preview(_proposal);
        await CounterCorrectionWriter(
          db,
          clock,
        ).commit(correctionAuditId: 'c', confirmedPreview: preview);
        expect(await _target(db), 5);
        await db.close();
      }
    },
  );

  test('both preview kinds detect a changed corrected occurrence', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock();
    await _fixture(db, clock);
    final previewer = CounterCorrectionPreviewer(db, clock);
    final ordinary = await previewer.preview(_proposal);
    final impact = await AnalyticsCorrectionImpactReader(
      db,
      clock,
    ).previewImpact(_proposal);
    await CounterTodayActionService(db, clock).recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'unused',
      eventId: 'new-extra',
      quantity: 1,
    );
    final writer = CounterCorrectionWriter(db, clock);
    for (final preview in [ordinary, impact.preview]) {
      expect(await previewer.isStale(preview), isTrue);
      await expectLater(
        writer.commit(correctionAuditId: 'c', confirmedPreview: preview),
        throwsStateError,
      );
    }
    expect(await _target(db), 10);
    expect(await writer.readAuditsForHabit('h'), isEmpty);
  });

  testWidgets(
    'cancellation writes nothing and a changed score source rejects confirmation',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock();
      await _fixture(db, clock);
      final date = LocalDate(2026, 11, 26);
      final habit = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: date)).singleWhere((h) => h.habitId == 'h');
      var changed = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CounterCorrectionControls(
                  habit: habit,
                  date: date,
                  showPrivateHistory: false,
                  onChanged: () => changed++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Correct historical target'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Proposed target count'),
        '5',
      );
      final before =
          (await db.customSelect('SELECT total_changes() AS n').getSingle())
              .read<int>('n');
      await tester.tap(find.text('Preview target correction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        (await db.customSelect('SELECT total_changes() AS n').getSingle())
            .read<int>('n'),
        before,
      );
      await tester.tap(find.text('Preview target correction'));
      await tester.pumpAndSettle();
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'other',
        occurrenceId: 'other-o',
        eventId: 'other-e',
        quantity: 7,
      );
      await tester.tap(find.text('Confirm correction'));
      await tester.pumpAndSettle();
      expect(find.textContaining('stale'), findsOneWidget);
      expect(changed, 0);
      expect(await _target(db), 10);
      expect(
        await CounterCorrectionWriter(db, clock).readAuditsForHabit('h'),
        isEmpty,
      );
    },
  );
}
