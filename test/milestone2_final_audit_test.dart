import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/data/unified_habit_history_reader.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';
import 'package:hibi/features/habits/presentation/history_analytics_screen.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'test_schema_downgrade.dart';

class _AuditClock implements AppClock {
  _AuditClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('v12 to v13 migration preserves representative multi-type data, keeps legacy scores N/A without guessing config, and prevents full heatmap intensity when N/A scores exist', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_m2_audit_v13_');
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
    final file = File(path.join(dir.path, 'hibi.sqlite'));
    final day = LocalDate(2026, 11, 26);

    // Build a v12 database containing representative legacy records across
    // counter, measurement, time_of_day and range habits.
    final seed = AppDatabase(NativeDatabase(file));
    await seed.setSetting('theme', 'dark');
    await seed.close();

    final legacy = sqlite.sqlite3.open(file.path);
    dropV13Schema(legacy);
    legacy.execute('PRAGMA foreign_keys = ON');
    legacy.execute("INSERT INTO habits VALUES ('h_cnt', 1)");
    legacy.execute(
      "INSERT INTO habit_versions VALUES ('v_cnt', 'h_cnt', 'Push Up', '2026-11-26', NULL, 1, 1)",
    );
    legacy.execute(
      "INSERT INTO habit_counter_targets VALUES ('v_cnt', 10, 'reps')",
    );
    legacy.execute(
      "INSERT INTO habit_schedules VALUES ('v_cnt', 'daily', '2026-11-26', NULL, NULL)",
    );
    legacy.execute(
      "INSERT INTO habit_version_metadata VALUES ('v_cnt', NULL, 'P', 'Health', 'normal', 0, 1, 1, 1, 1, 0)",
    );
    legacy.execute(
      "INSERT INTO habit_lifecycle_events VALUES ('l_cnt', 'h_cnt', '2026-11-26', NULL, 'active', NULL, 1)",
    );
    legacy.execute(
      "INSERT INTO habit_occurrences VALUES ('o_cnt', 'h_cnt', 'v_cnt', '2026-11-26', 10, 'reps')",
    );
    legacy.execute(
      "INSERT INTO habit_counter_events VALUES ('e_cnt', 'o_cnt', 10, 2)",
    );

    legacy.execute("INSERT INTO habits VALUES ('h_meas', 2)");
    legacy.execute(
      "INSERT INTO habit_versions VALUES ('v_meas', 'h_meas', 'Hydration', '2026-11-26', NULL, 2, 1)",
    );
    legacy.execute(
      "INSERT INTO habit_typed_targets (habit_version_id, tracking_type, scaled_target, decimal_places, unit, comparison_rule) "
      "VALUES ('v_meas', 'measurement', 20, 1, 'L', 'at_least')",
    );
    legacy.execute(
      "INSERT INTO habit_schedules VALUES ('v_meas', 'daily', '2026-11-26', NULL, NULL)",
    );
    legacy.execute(
      "INSERT INTO habit_version_metadata VALUES ('v_meas', NULL, NULL, 'Health', 'normal', 0, 0, 1, 1, 1, 1)",
    );
    legacy.execute(
      "INSERT INTO habit_lifecycle_events VALUES ('l_meas', 'h_meas', '2026-11-26', NULL, 'active', NULL, 2)",
    );
    legacy.execute(
      "INSERT INTO habit_typed_occurrences VALUES ('o_meas', 'h_meas', 'v_meas', 'measurement', '2026-11-26')",
    );
    legacy.execute(
      "INSERT INTO habit_typed_logs (id, occurrence_id, state, scaled_value, occurred_at_utc_us) "
      "VALUES ('log_meas', 'o_meas', 'completed', 20, 3)",
    );
    legacy.execute('PRAGMA user_version = 12');
    legacy.close();

    // Open with AppDatabase (migrates v12 -> v13)
    final migrated = AppDatabase(NativeDatabase(file));
    try {
      expect(
        (await migrated.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        17,
      );
      expect(
        (await migrated.customSelect('PRAGMA foreign_keys').getSingle())
            .read<int>('foreign_keys'),
        1,
      );
      // Zero guessed scoring configs
      expect(
        await migrated
            .customSelect('SELECT * FROM habit_version_scoring')
            .get(),
        isEmpty,
      );

      final evals = await UnifiedHabitHistoryReader(migrated).readDay(
        date: day,
        filter: const HabitAnalyticsFilter(includePrivate: false),
      );
      final meas = evals.singleWhere((e) => e.habitId == 'h_meas');
      expect(meas.status, HabitAnalyticsStatus.completed);
      expect(meas.scoringUnavailable, isTrue);
      expect(meas.scoreMultiplier, isNull);

      final report = await AnalyticsReportReader(migrated).readPeriodReport(
        startInclusive: day,
        endInclusive: day,
        filter: const HabitAnalyticsFilter(includePrivate: false),
      );
      final cell = report.dailyCells.single;
      expect(cell.scoreSummary.weightedScorePercent, closeTo(100.0, 0.001));
      expect(cell.scoreSummary.validScoreCount, 1);
      expect(cell.scoreSummary.unavailableRecordedScoreCount, 1);
      // Must NOT be HeatmapIntensity.full because a recorded habit has score N/A
      expect(cell.intensity, HeatmapIntensity.high);
    } finally {
      await migrated.close();
    }

    // Disk reopen confirms persistence after migration
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(await reopened.getSetting('theme'), 'dark');
    final log = await reopened
        .customSelect(
          "SELECT state, scaled_value, day_offset FROM habit_typed_logs WHERE id = 'log_meas'",
        )
        .getSingle();
    expect(log.read<String>('state'), 'completed');
    expect(log.read<int>('scaled_value'), 20);
    expect(log.readNullable<int>('day_offset'), isNull);
  });

  testWidgets(
    'HistoryAnalyticsView handles 320px width, 2.0x text scaling, semantics labels and partial-score heatmap tag without layout overflow',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _AuditClock(DateTime(2026, 11, 26, 12));
      final day = LocalDate(2026, 11, 26);

      // 1 completed counter habit + 1 legacy measurement habit (score N/A)
      await CounterHabitWriter(db, clock).create(
        habitId: 'h_long',
        versionId: 'v_long',
        auditId: 'a_long',
        lifecycleEventId: 'l_long',
        name: 'Very Long Habit Name For Small Screen Scaling Verification',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: day),
      );
      await HabitMetadataStore(db).insert(
        'v_long',
        HabitMetadata(
          category: 'Very Long Category Label For Narrow Viewport Testing',
          isPrivate: false,
        ),
      );
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'h_long',
        occurrenceId: 'o_long',
        eventId: 'e_long',
        quantity: 5,
      );

      await MeasurementTimeRangeHabitService(db, clock).createMeasurement(
        habitId: 'h_legacy',
        versionId: 'v_legacy',
        lifecycleEventId: 'l_legacy',
        name: 'Legacy Measurement',
        effectiveDate: DateTime(2026, 11, 26),
        target: MeasurementTarget(
          scaledTarget: 10,
          decimalPlaces: 0,
          unit: 'u',
          rule: MeasurementComparisonRule.atLeast,
        ),
        schedule: DailySchedule(start: day),
        metadata: HabitMetadata(category: 'Health', isPrivate: false),
      );
      await MeasurementTimeRangeHabitService(db, clock).logMeasurementToday(
        habitId: 'h_legacy',
        occurrenceId: 'o_legacy',
        logId: 'log_legacy',
        scaledValue: 10,
      );

      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2.0),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: HistoryAnalyticsView(asOfDate: day),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('100% (partial score)'), findsOneWidget);
      expect(find.textContaining('intensity: high'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp(r'2026-11-26, score 100% \(partial score\), intensity high'),
        ),
        findsOneWidget,
      );
    },
  );
}
