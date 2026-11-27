import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/domain/dynamic_normalized_scoring.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';
import 'package:hibi/features/habits/presentation/history_analytics_screen.dart';

class _Clock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  testWidgets(
    'History displays valid and unavailable score coverage separately',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock();
      final day = LocalDate(2026, 11, 26);
      final service = MeasurementTimeRangeHabitService(db, clock);
      for (final configured in [true, false]) {
        final id = configured ? 'configured' : 'legacy';
        await service.createMeasurement(
          habitId: id,
          versionId: 'v_$id',
          lifecycleEventId: 'l_$id',
          name: id,
          effectiveDate: clock.now(),
          target: MeasurementTarget(
            scaledTarget: 10,
            decimalPlaces: 0,
            unit: 'units',
            rule: MeasurementComparisonRule.atLeast,
          ),
          schedule: DailySchedule(start: day),
          metadata: HabitMetadata(category: 'Test', isPrivate: false),
          scoring: configured ? const HabitScoringConfig.measurement() : null,
        );
        await service.logMeasurementToday(
          habitId: id,
          occurrenceId: 'o_$id',
          logId: 'log_$id',
          scaledValue: 5,
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HistoryAnalyticsView(asOfDate: day),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Daily weighted score: 50.0%'), findsOneWidget);
      expect(
        find.text('Score coverage: 1 scored, 1 recorded N/A (50.0%)'),
        findsWidgets,
      );
      expect(find.textContaining('score N/A'), findsWidgets);
    },
  );
}
