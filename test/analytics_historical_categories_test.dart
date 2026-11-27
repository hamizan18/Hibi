import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class _Clock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 25, 12);
}

void main() {
  test('category choices cover visible period versions even without a current version', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final writer = CounterHabitWriter(db, _Clock());
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
    await HabitMetadataStore(db)
        .insert('v1', HabitMetadata(category: 'Old public'));
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v2',
      auditId: 'a2',
      name: 'Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: target,
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      metadata: HabitMetadata(category: 'Secret', isPrivate: true),
    );
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v3',
      auditId: 'a3',
      name: 'Reading',
      effectiveDate: DateTime(2026, 11, 27),
      target: target,
      schedule: DailySchedule(start: LocalDate(2026, 11, 27)),
    );
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v4',
      auditId: 'a4',
      name: 'Reading',
      effectiveDate: DateTime(2026, 11, 28),
      target: target,
      schedule: DailySchedule(start: LocalDate(2026, 11, 28)),
      metadata: HabitMetadata(category: 'New public'),
    );
    await db.customStatement(
      "UPDATE habit_versions SET effective_end = '2026-11-29' WHERE id = 'v4'",
    );
    final reader = AnalyticsReportReader(db);
    Future<AnalyticsDashboardSnapshot> read(HabitAnalyticsFilter filter) =>
        reader.readDashboardSnapshot(
          startInclusive: LocalDate(2026, 11, 25),
          endInclusive: LocalDate(2026, 11, 28),
          asOfDate: LocalDate(2026, 11, 30),
          filter: filter,
        );
    final public = await read(
      const HabitAnalyticsFilter(category: 'Old public'),
    );
    expect(public.availableHabits, isEmpty);
    expect(public.availableCategories, ['New public', 'Old public']);
    final revealed = await read(
      const HabitAnalyticsFilter(
        habitId: 'does-not-exist',
        category: 'Old public',
        includePrivate: true,
      ),
    );
    expect(revealed.availableCategories, [
      'New public',
      'Old public',
      'Secret',
      'Unclassified',
    ]);
    final narrow = await reader.readDashboardSnapshot(
      startInclusive: LocalDate(2026, 11, 26),
      endInclusive: LocalDate(2026, 11, 27),
      asOfDate: LocalDate(2026, 11, 30),
    );
    expect(narrow.availableCategories, isEmpty);
  });
}
