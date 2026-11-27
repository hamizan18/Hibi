import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 10);
  @override
  DateTime now() => current;
}

void main() {
  test('UnifiedHabitHistoryReader and AnalyticsReportReader evaluate all tracking types and filter private habits with zero writes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = TestClock();
    final nov26 = LocalDate(2026, 11, 26);

    // 1. Public Counter habit (Critical 4)
    await CounterHabitWriter(db, clock).create(
      habitId: 'h_cnt',
      versionId: 'v_cnt',
      auditId: 'a_cnt',
      lifecycleEventId: 'l_cnt',
      name: 'Quran Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: nov26),
    );
    await HabitMetadataStore(db).insert(
      'v_cnt',
      HabitMetadata(
        category: 'Spiritual',
        priority: HabitPriority.critical,
        isPrivate: false,
        recoveryEnabled: true,
      ),
    );
    await CounterTodayActionService(db, clock).recordTodayProgress(
      habitId: 'h_cnt',
      occurrenceId: 'o_cnt_26',
      eventId: 'e_cnt_1',
      quantity: 5,
    );

    // 2. Public Checklist habit (High 3) with 2 items, 1 logged
    await ChecklistHabitService(db, clock).create(
      habitId: 'h_chk',
      versionId: 'v_chk',
      lifecycleEventId: 'l_chk',
      name: 'Prayers',
      effectiveDate: DateTime(2026, 11, 26),
      items: [
        ChecklistItemDefinition(id: 'i1', label: 'Fajr', displayOrder: 0),
        ChecklistItemDefinition(id: 'i2', label: 'Dhuhr', displayOrder: 1),
      ],
      schedule: DailySchedule(start: nov26),
      metadata: HabitMetadata(
        category: 'Spiritual',
        priority: HabitPriority.high,
        isPrivate: false,
      ),
    );
    await ChecklistHabitService(db, clock).logItemToday(
      habitId: 'h_chk',
      occurrenceId: 'o_chk_26',
      logId: 'log_chk_1',
      itemId: 'i1',
      state: ChecklistItemLogState.completed,
    );

    // 3. Private Avoidance habit (Normal 2)
    await AvoidanceHabitService(db, clock).create(
      habitId: 'h_av',
      versionId: 'v_av',
      lifecycleEventId: 'l_av',
      name: 'Self Control',
      effectiveDate: DateTime(2026, 11, 26),
      target: AvoidanceTarget(maxIncidents: 0),
      schedule: DailySchedule(start: nov26),
      metadata: HabitMetadata(
        category: 'Personal',
        priority: HabitPriority.normal,
        isPrivate: true,
        recoveryEnabled: false,
      ),
    );

    // 4. Public Duration & Measurement habits (left pending on Nov 26)
    await BooleanDurationHabitService(db, clock).createDuration(
      habitId: 'h_dur',
      versionId: 'v_dur',
      lifecycleEventId: 'l_dur',
      name: 'Study',
      effectiveDate: DateTime(2026, 11, 26),
      target: DurationTarget(targetSeconds: 1800),
      schedule: DailySchedule(start: nov26),
      metadata: HabitMetadata(
        category: 'Growth',
        priority: HabitPriority.normal,
        isPrivate: false,
      ),
    );
    await MeasurementTimeRangeHabitService(db, clock).createMeasurement(
      habitId: 'h_meas',
      versionId: 'v_meas',
      lifecycleEventId: 'l_meas',
      name: 'Water',
      effectiveDate: DateTime(2026, 11, 26),
      target: MeasurementTarget(
        scaledTarget: 20,
        decimalPlaces: 1,
        unit: 'L',
        rule: MeasurementComparisonRule.atLeast,
      ),
      schedule: DailySchedule(start: nov26),
      metadata: HabitMetadata(
        category: 'Health',
        priority: HabitPriority.low,
        isPrivate: false,
      ),
    );

    final reportReader = AnalyticsReportReader(db);
    final publicReport = await reportReader.readPeriodReport(
      startInclusive: nov26,
      endInclusive: nov26,
      filter: const HabitAnalyticsFilter(includePrivate: false),
    );
    // Public habits on Nov 26: h_cnt (weight 4, completed 1.0), h_chk (weight 3, partial 0.5),
    // h_dur (pending), h_meas (pending).
    // Score = 100 * (4 * 1.0 + 3 * 0.5) / (4 + 3) = 550 / 7 = 78.5714%
    expect(publicReport.habitSummaries.length, 4);
    expect(
      publicReport.overallWeightedScorePercent,
      closeTo(550.0 / 7.0, 0.001),
    );
    expect(publicReport.overallRecordingCoveragePercent, closeTo(50.0, 0.001));
    expect(
      publicReport.overallChecklistItemCoveragePercent,
      closeTo(50.0, 0.001),
    );

    // When includePrivate is true, h_av is also included (5 habits total)
    final privateReport = await reportReader.readPeriodReport(
      startInclusive: nov26,
      endInclusive: nov26,
      filter: const HabitAnalyticsFilter(includePrivate: true),
    );
    expect(privateReport.habitSummaries.length, 5);

    // Reading analytics created zero new occurrence rows
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_typed_occurrences')
              .getSingle())
          .read<int>('n'),
      0,
    );
  });
}
