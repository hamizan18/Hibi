import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/application/counter_habit_providers.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/history_analytics_screen.dart';

class _FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

class _ControlledReader extends AnalyticsReportReader {
  _ControlledReader(super.db, this.publicSnapshot, this.privateSnapshot);

  final AnalyticsDashboardSnapshot publicSnapshot;
  final AnalyticsDashboardSnapshot privateSnapshot;
  final privateReload = Completer<AnalyticsDashboardSnapshot>();
  final publicReload = Completer<AnalyticsDashboardSnapshot>();
  final filters = <HabitAnalyticsFilter>[];

  @override
  Future<AnalyticsDashboardSnapshot> readDashboardSnapshot({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    required LocalDate asOfDate,
    StreakCompletionMode streakMode =
        StreakCompletionMode.completedAndRecovered,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(),
  }) {
    filters.add(filter);
    switch (filters.length) {
      case 1:
        return Future.value(publicSnapshot);
      case 2:
        return Future.value(privateSnapshot);
      case 3:
        return privateReload.future;
      case 4:
        return publicReload.future;
      default:
        throw StateError('Unexpected dashboard load');
    }
  }
}

void main() {
  testWidgets('hiding private analytics discards old data during reload', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _FixedClock();
    final date = LocalDate(2026, 11, 26);
    final writer = CounterHabitWriter(db, clock);
    for (final isPrivate in [false, true]) {
      final id = isPrivate ? 'private' : 'public';
      await writer.create(
        habitId: id,
        versionId: 'version_$id',
        auditId: 'audit_$id',
        lifecycleEventId: 'lifecycle_$id',
        name: isPrivate ? 'Secret Habit' : 'Public Habit',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 1, unit: 'times'),
        schedule: DailySchedule(start: date),
      );
      await HabitMetadataStore(db).insert(
        'version_$id',
        HabitMetadata(
          category: isPrivate ? 'Secret Category' : 'Public Category',
          isPrivate: isPrivate,
        ),
      );
    }

    final realReader = AnalyticsReportReader(db);
    Future<AnalyticsDashboardSnapshot> snapshot(
      LocalDate start,
      bool includePrivate,
    ) => realReader.readDashboardSnapshot(
      startInclusive: start,
      endInclusive: date,
      asOfDate: date,
      filter: HabitAnalyticsFilter(includePrivate: includePrivate),
    );

    final public7 = await snapshot(LocalDate(2026, 11, 20), false);
    final private7 = await snapshot(LocalDate(2026, 11, 20), true);
    final private30 = await snapshot(LocalDate(2026, 10, 28), true);
    final public30 = await snapshot(LocalDate(2026, 10, 28), false);
    final reader = _ControlledReader(db, public7, private7);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [analyticsReportReaderProvider.overrideWithValue(reader)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HistoryAnalyticsView(asOfDate: date),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Public Habit'), findsWidgets);
    expect(find.textContaining('Secret Habit'), findsNothing);

    final privacySwitch = find.text('Show private or unclassified habits');
    await tester.tap(privacySwitch);
    await tester.pumpAndSettle();
    expect(find.textContaining('Secret Habit'), findsWidgets);
    expect(find.textContaining('Secret Category'), findsWidgets);
    expect(find.text('Habit recording coverage: 0/2 (0.0%)'), findsOneWidget);
    for (final key in [
      'selected-day-inspection-card',
      'period-analytics-report-card',
      'habit-streaks-card',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.textContaining('Secret Habit'),
        ),
        findsWidgets,
      );
    }

    // A non-privacy filter reload keeps the previous snapshot, as before.
    await tester.tap(find.text('Last 30 days'));
    await tester.pump();
    expect(find.textContaining('Secret Habit'), findsWidgets);
    expect(reader.filters.map((f) => f.includePrivate), [false, true, true]);

    await tester.tap(privacySwitch);
    await tester.pump();
    expect(reader.filters.map((f) => f.includePrivate), [
      false,
      true,
      true,
      false,
    ]);
    expect(find.text('Loading history…'), findsOneWidget);
    expect(find.textContaining('Secret Habit'), findsNothing);
    expect(find.textContaining('Secret Category'), findsNothing);
    expect(find.text('Habit recording coverage: 0/2 (0.0%)'), findsNothing);
    expect(find.byKey(const Key('heatmap-cell-2026-11-26')), findsNothing);
    expect(find.byKey(const Key('period-analytics-report-card')), findsNothing);
    expect(find.byKey(const Key('habit-streaks-card')), findsNothing);

    // An older private request completing out of order must not restore it.
    reader.privateReload.complete(private30);
    await tester.pump();
    expect(find.text('Loading history…'), findsOneWidget);
    expect(find.textContaining('Secret Habit'), findsNothing);
    expect(find.textContaining('Secret Category'), findsNothing);

    reader.publicReload.complete(public30);
    await tester.pumpAndSettle();
    expect(find.textContaining('Public Habit'), findsWidgets);
    expect(find.text('Habit recording coverage: 0/1 (0.0%)'), findsOneWidget);
    expect(find.textContaining('Secret Habit'), findsNothing);
    expect(find.textContaining('Secret Category'), findsNothing);
    expect(find.byKey(const Key('heatmap-cell-2026-11-26')), findsOneWidget);
  });
}
