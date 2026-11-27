import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/theme/hibi_theme.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/growth/presentation/growth_screen.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class _TestClock implements AppClock {
  _TestClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  testWidgets(
    'GrowthView Rewards section displays XP, level, achievements, custom attributes and opt-out',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _TestClock(DateTime(2026, 11, 27, 10, 0));
      final today = LocalDate(2026, 11, 27);

      await CounterHabitWriter(db, clock).create(
        habitId: 'h1',
        versionId: 'v1',
        lifecycleEventId: 'l1',
        auditId: 'a1',
        name: 'Reading',
        effectiveDate: DateTime(2026, 11, 27),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: today),
      );
      await HabitMetadataStore(db).insert(
        'v1',
        HabitMetadata(
          category: 'Learning',
          isPrivate: false,
          includeInRewards: true,
        ),
      );
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'h1',
        occurrenceId: 'occ1',
        eventId: 'ev1',
        quantity: 5,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            theme: createHibiTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: GrowthView(asOfDate: today),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, 'Rewards'));
      await tester.pumpAndSettle();

      expect(find.text('Level 1 • 10 XP'), findsOneWidget);
      expect(find.text('First Step'), findsOneWidget);
      expect(find.textContaining('Unlocked (valid)'), findsOneWidget);
      expect(find.text('Reward History (1)'), findsOneWidget);

      // Create a custom attribute via dialog.
      await tester.ensureVisible(find.text('Add attribute'));
      await tester.tap(find.text('Add attribute'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Attribute name (e.g. Consistency)'),
        'Consistency',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Consistency — Lv 1'), findsOneWidget);
    },
  );
}
