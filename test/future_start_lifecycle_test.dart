import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/today_habit_roster.dart';

class TestClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  testWidgets(
    'future habits respect privacy and allow later dated lifecycle changes without occurrences',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock();
      final start = LocalDate(2026, 11, 29);
      await CounterHabitWriter(db, clock).create(
        habitId: 'public',
        versionId: 'pv',
        auditId: 'pa',
        lifecycleEventId: 'pl',
        name: 'Future public',
        effectiveDate: DateTime(2026, 11, 29),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: start),
      );
      await HabitMetadataStore(db)
          .insert('pv', HabitMetadata(category: 'General'));
      await BooleanDurationHabitService(db, clock).createBoolean(
        habitId: 'private',
        versionId: 'sv',
        lifecycleEventId: 'sl',
        name: 'Future secret',
        effectiveDate: DateTime(2026, 11, 29),
        schedule: DailySchedule(start: start),
        metadata: HabitMetadata(category: 'General', isPrivate: true),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TodayHabitRoster(date: LocalDate(2026, 11, 26)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Future public'), findsOneWidget);
      expect(find.text('Future secret'), findsNothing);
      expect(find.textContaining('Not started yet.'), findsOneWidget);
      expect(find.text('Current: not yet started'), findsOneWidget);
      expect(find.text('Add progress'), findsNothing);
      await tester.ensureVisible(find.text('Effective date: 2026-11-26'));
      await tester.tap(find.text('Effective date: 2026-11-26'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('29').last);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Pause'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Effective date: 2026-11-29'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30').last);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Pause'));
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      final history = await HabitLifecycleReader(db).readHistory('public');
      expect(history.map((e) => e.state), [
        HabitLifecycleState.active,
        HabitLifecycleState.paused,
      ]);
      expect(history.last.effectiveDate.compareTo(LocalDate(2026, 11, 30)), 0);
      expect(
        (await HabitApplicabilityReader(
          db,
        ).describe('public', LocalDate(2026, 11, 26))).reason,
        HabitApplicabilityReason.beforeStart,
      );
      for (final table in ['habit_occurrences', 'habit_typed_occurrences']) {
        expect(
          (await db
                  .customSelect('SELECT COUNT(*) AS n FROM $table')
                  .getSingle())
              .read<int>('n'),
          0,
        );
      }
      await tester.ensureVisible(
        find.text('Show private or unclassified habits'),
      );
      await tester.tap(find.text('Show private or unclassified habits'));
      await tester.pumpAndSettle();
      expect(find.text('Future secret'), findsOneWidget);
    },
  );
}
