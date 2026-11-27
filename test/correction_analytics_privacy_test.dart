import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/application/counter_habit_providers.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_recovery_store.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_correction_controls.dart';

class _Clock implements AppClock {
  DateTime current = DateTime(2026, 11, 24, 10);
  @override
  DateTime now() => current;
}

class _DelayedReader extends AnalyticsCorrectionImpactReader {
  _DelayedReader(super.db, super.clock);
  final gate = Completer<void>();
  final requested = Completer<void>();
  bool? visibility;

  @override
  Future<AnalyticsCorrectionImpactPreview> previewImpact(
    CounterTargetCorrectionProposal proposal, {
    bool includePrivate = false,
  }) async {
    visibility = includePrivate;
    if (!requested.isCompleted) requested.complete();
    await gate.future;
    return super.previewImpact(proposal, includePrivate: includePrivate);
  }
}

const _proposal = CounterTargetCorrectionProposal(
  habitId: 'h',
  versionId: 'v3',
  proposedTargetCount: 5,
  proposedUnit: 'pages',
);

Future<void> _fixture(
  AppDatabase db,
  _Clock clock, {
  required bool unclassified,
}) async {
  final writer = CounterHabitWriter(db, clock);
  final target = CounterTarget(count: 10, unit: 'pages');
  final public = HabitMetadata(category: 'Reading', isPrivate: false);
  await writer.create(
    habitId: 'h',
    versionId: 'v1',
    auditId: 'a1',
    lifecycleEventId: 'l1',
    name: 'Reading',
    effectiveDate: DateTime(2026, 11, 24),
    target: target,
    schedule: DailySchedule(start: LocalDate(2026, 11, 24)),
  );
  await HabitMetadataStore(db).insert('v1', public);
  await writer.scheduleVersion(
    habitId: 'h',
    versionId: 'v2',
    auditId: 'a2',
    name: 'Secret version',
    effectiveDate: DateTime(2026, 11, 25),
    target: target,
    schedule: DailySchedule(start: LocalDate(2026, 11, 25)),
    metadata: unclassified
        ? null
        : HabitMetadata(category: 'Reading', isPrivate: true),
  );
  await writer.scheduleVersion(
    habitId: 'h',
    versionId: 'v3',
    auditId: 'a3',
    name: 'Reading',
    effectiveDate: DateTime(2026, 11, 26),
    target: target,
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    metadata: public,
  );
  final actions = CounterTodayActionService(db, clock);
  for (var day = 24; day <= 26; day++) {
    clock.current = DateTime(2026, 11, day, 10);
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o$day',
      eventId: 'e$day',
      quantity: day == 26 ? 5 : 10,
    );
  }
  await writer.create(
    habitId: 'other',
    versionId: 'other-v',
    auditId: 'other-a',
    lifecycleEventId: 'other-l',
    name: 'Hidden contribution',
    effectiveDate: DateTime(2026, 11, 26),
    target: target,
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
  );
  if (!unclassified) {
    await HabitMetadataStore(db)
        .insert('other-v', HabitMetadata(category: 'Reading', isPrivate: true));
  }
  await actions.recordTodayProgress(
    habitId: 'other',
    occurrenceId: 'other-o',
    eventId: 'other-e',
    quantity: 10,
  );
}

void main() {
  for (final unclassified in [false, true]) {
    test(
      'correction impact hides ${unclassified ? 'unclassified' : 'private'} scores and streak history by default',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final clock = _Clock();
        await _fixture(db, clock, unclassified: unclassified);
        final before =
            (await db.customSelect('SELECT total_changes() AS n').getSingle())
                .read<int>('n');
        final reader = AnalyticsCorrectionImpactReader(db, clock);
        final hidden = await reader.previewImpact(_proposal);
        expect(hidden.dateScoreImpacts.single.beforeScorePercent, 50);
        expect(hidden.dateScoreImpacts.single.afterScorePercent, 100);
        expect(hidden.beforeStreakWithRecovery.currentStreak, 0);
        expect(hidden.afterStreakWithRecovery.currentStreak, 1);
        expect(hidden.afterStreakWithRecovery.longestStreak, 1);
        expect(hidden.afterStreakCompletedOnly.currentStreak, 1);
        final revealed = await reader.previewImpact(
          _proposal,
          includePrivate: true,
        );
        expect(revealed.dateScoreImpacts.single.beforeScorePercent, 75);
        expect(revealed.afterStreakWithRecovery.currentStreak, 3);
        expect(revealed.afterStreakCompletedOnly.currentStreak, 3);
        const secret = CounterTargetCorrectionProposal(
          habitId: 'h',
          versionId: 'v2',
          proposedTargetCount: 5,
          proposedUnit: 'pages',
        );
        await expectLater(reader.previewImpact(secret), throwsStateError);
        expect(
          (await reader.previewImpact(
            secret,
            includePrivate: true,
          )).preview.versionName,
          'Secret version',
        );
        expect(
          (await db.customSelect('SELECT total_changes() AS n').getSingle())
              .read<int>('n'),
          before,
        );
      },
    );
  }

  test('recovered occurrence becomes failed in preview and after commit when target increases', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock()..current = DateTime(2026, 11, 26, 10);
    final date = LocalDate(2026, 11, 26);
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: date),
    );
    await HabitMetadataStore(db)
        .insert('v', HabitMetadata(category: 'Reading'));
    await CounterTodayActionService(db, clock).recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o',
      eventId: 'e',
      quantity: 2,
    );
    await CounterResolutionWriter(
      db,
      clock,
    ).resolve(id: 'r', occurrenceId: 'o', state: CounterResolutionState.failed);
    clock.current = DateTime(2026, 11, 27, 10);
    await CounterRecoveryWriter(
      db,
      clock,
    ).record(id: 'rec', occurrenceId: 'o', quantity: 3);
    final impact = await AnalyticsCorrectionImpactReader(db, clock)
        .previewImpact(
          const CounterTargetCorrectionProposal(
            habitId: 'h',
            versionId: 'v',
            proposedTargetCount: 8,
            proposedUnit: 'pages',
          ),
        );
    expect(impact.dateScoreImpacts.single.beforeScorePercent, 75);
    expect(impact.dateScoreImpacts.single.afterScorePercent, 0);
    expect(impact.beforeStreakWithRecovery.recoveredDaysCount, 1);
    expect(impact.afterStreakWithRecovery.failedDaysCount, 1);
    await CounterCorrectionWriter(
      db,
      clock,
    ).commit(correctionAuditId: 'correction', confirmedPreview: impact.preview);
    final actual = await AnalyticsReportReader(db).readDashboardSnapshot(
      startInclusive: date,
      endInclusive: date,
      asOfDate: LocalDate(2026, 11, 27),
      filter: const HabitAnalyticsFilter(),
    );
    expect(
      actual.streaks.single.failedDaysCount,
      impact.afterStreakWithRecovery.failedDaysCount,
    );
  });

  testWidgets(
    'visibility changes invalidate an in-flight revealed preview and hide old versions',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock();
      await _fixture(db, clock, unclassified: false);
      final date = LocalDate(2026, 11, 26);
      final summary = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: date)).singleWhere((h) => h.habitId == 'h');
      final reader = _DelayedReader(db, clock);
      Widget app(bool reveal) => ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(clock),
          analyticsCorrectionImpactReaderProvider.overrideWithValue(reader),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CounterCorrectionControls(
                habit: summary,
                date: date,
                showPrivateHistory: reveal,
                onChanged: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Correct historical target'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview target correction'));
      await tester.pump();
      await reader.requested.future;
      expect(reader.visibility, isTrue);
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      reader.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Confirm historical target correction?'), findsNothing);
      await tester.tap(find.text('Correct historical target'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.textContaining('Secret version'), findsNothing);
      await tester.tap(find.textContaining('Revision 3: Reading').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Proposed target count'),
        '5',
      );
      await tester.tap(find.text('Preview target correction'));
      await tester.pumpAndSettle();
      expect(reader.visibility, isFalse);
      expect(
        find.text('Confirm historical target correction?'),
        findsOneWidget,
      );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(find.text('Confirm historical target correction?'), findsNothing);
    },
  );
}
