import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_configuration_reader.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_future_version_controls.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  testWidgets(
    'schedules a future counter version with updated target, schedule and metadata while preserving current version and historical targets',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock();
      final today = LocalDate(2026, 11, 26);

      await CounterHabitWriter(db, clock).create(
        habitId: 'h',
        versionId: 'v1',
        auditId: 'a1',
        lifecycleEventId: 'l1',
        name: 'Quran Reading',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: today),
      );
      await HabitMetadataStore(db).insert(
        'v1',
        HabitMetadata(
          category: 'Spiritual',
          symbol: 'N',
          recoveryEnabled: true,
        ),
      );

      final summary = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: today)).single;
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
                child: CounterFutureVersionControls(
                  habit: summary,
                  date: today,
                  showPrivateHistory: false,
                  onChanged: () => changed++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Effective: Revision 1: Quran Reading — 5 pages'),
        findsOneWidget,
      );

      await tester.tap(find.text('Schedule future version'));
      await tester.pumpAndSettle();

      // Invalid target 0 is rejected without writing
      await tester.enterText(
        find.widgetWithText(TextField, 'Future target count'),
        '0',
      );
      final submitButton = find.byKey(
        const Key('counter-future-version-submit'),
      );
      await tester.ensureVisible(submitButton);
      await tester.pumpAndSettle();
      await tester.tap(submitButton);
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a positive whole-number target count.'),
        findsOneWidget,
      );
      expect(changed, 0);

      // Valid future version starting 2026-11-27 with target 10 pages
      final nameField = find.widgetWithText(TextField, 'Future version name');
      await tester.ensureVisible(nameField);
      await tester.pumpAndSettle();
      await tester.enterText(nameField, 'Quran Reading 10');
      await tester.enterText(
        find.widgetWithText(TextField, 'Future target count'),
        '10',
      );
      await tester.ensureVisible(submitButton);
      await tester.pumpAndSettle();
      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      expect(changed, 1);
      expect(
        find.textContaining('Revision 2: Quran Reading 10 — 10 pages'),
        findsOneWidget,
      );

      // Verify Nov 26 still uses target 5 and Nov 27 uses target 10
      final nov26 = await CounterDayReader(db)
          .evaluate(habitId: 'h', date: LocalDate(2026, 11, 26));
      expect(nov26.configuredTarget!.count, 5);

      final nov27 = await CounterDayReader(db)
          .evaluate(habitId: 'h', date: LocalDate(2026, 11, 27));
      expect(nov27.configuredTarget!.count, 10);

      final config = await CounterConfigurationReader(db)
          .read(habitId: 'h', asOfDate: today);
      expect(config.futureVersions.length, 1);
      expect(config.futureVersions.single.metadata!.category, 'Spiritual');
    },
  );
}
