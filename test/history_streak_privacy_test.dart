import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class _Clock implements AppClock {
  DateTime current = DateTime(2026, 11, 24, 10);

  @override
  DateTime now() => current;
}

void main() {
  for (final unclassified in [false, true]) {
    test(
      'dashboard streak stops at ${unclassified ? 'unclassified' : 'private'} history until revealed',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final clock = _Clock();
        final writer = CounterHabitWriter(db, clock);
        final target = CounterTarget(count: 5, unit: 'pages');
        final publicMetadata = HabitMetadata(
          category: 'Reading',
          isPrivate: false,
        );
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
        await HabitMetadataStore(db).insert('v1', publicMetadata);
        await writer.scheduleVersion(
          habitId: 'h',
          versionId: 'v2',
          auditId: 'a2',
          name: 'Reading',
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
          metadata: publicMetadata,
        );
        final actions = CounterTodayActionService(db, clock);
        for (var day = 24; day <= 26; day++) {
          clock.current = DateTime(2026, 11, day, 10);
          await actions.recordTodayProgress(
            habitId: 'h',
            occurrenceId: 'o$day',
            eventId: 'e$day',
            quantity: 5,
          );
        }

        Future<int> changes() async =>
            (await db.customSelect('SELECT total_changes() AS n').getSingle())
                .read<int>('n');
        final before = await changes();
        final reader = AnalyticsReportReader(db);
        final start = LocalDate(2026, 11, 24);
        final end = LocalDate(2026, 11, 26);
        final public = await reader.readDashboardSnapshot(
          startInclusive: start,
          endInclusive: end,
          asOfDate: end,
        );
        final hidden = public.streaks.single;
        expect(hidden.currentStreak, 1);
        expect(hidden.longestStreak, 1);
        expect(hidden.applicableDaysCount, 1);
        expect(hidden.completedDaysCount, 1);
        expect(hidden.recoveredDaysCount, 0);
        expect(hidden.failedDaysCount, 0);
        expect(hidden.excusedDaysCount, 0);
        expect(hidden.skippedNotApplicableCount, 0);
        expect(hidden.unresolvedPendingDates, isEmpty);
        expect(hidden.state, StreakResolutionState.active);

        final revealed = await reader.readDashboardSnapshot(
          startInclusive: start,
          endInclusive: end,
          asOfDate: end,
          filter: const HabitAnalyticsFilter(includePrivate: true),
        );
        final full = revealed.streaks.single;
        expect(full.currentStreak, 3);
        expect(full.longestStreak, 3);
        expect(full.applicableDaysCount, 3);
        expect(full.completedDaysCount, 3);
        expect(await changes(), before);
      },
    );
  }
}
