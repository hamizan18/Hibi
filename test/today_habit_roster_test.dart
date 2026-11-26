import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/today_habit_roster.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  testWidgets(
    'roster hides private data and never writes occurrences on load',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = FixedClock();
      for (final private in [false, true]) {
        final suffix = private ? 'private' : 'public';
        await CounterHabitWriter(db, clock).create(
          habitId: 'h_$suffix',
          versionId: 'v_$suffix',
          auditId: 'a_$suffix',
          lifecycleEventId: 'l_$suffix',
          name: private ? 'Sensitive name' : 'Walk',
          effectiveDate: DateTime(2026, 11, 26),
          target: CounterTarget(count: 5, unit: 'steps'),
          schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
        );
        await HabitMetadataStore(db).insert(
          'v_$suffix',
          HabitMetadata(category: 'Health', isPrivate: private),
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
                child: TodayHabitRoster(date: LocalDate(2026, 11, 26)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Walk'), findsOneWidget);
      expect(find.text('Sensitive name'), findsNothing);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        0,
      );
      await tester.tap(find.text('Show private or unclassified habits'));
      await tester.pumpAndSettle();
      expect(find.text('Sensitive name'), findsOneWidget);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  testWidgets(
    'unconfigured legacy habit remains unknown without creating data',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement("INSERT INTO habits VALUES ('legacy', 1)");
      await db.customStatement(
        "INSERT INTO habit_versions VALUES ('v_legacy', 'legacy', 'Legacy', '2026-01-01', NULL, 1, 1)",
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(FixedClock()),
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
      expect(find.text('Legacy'), findsNothing);
      await tester.tap(find.text('Show private or unclassified habits'));
      await tester.pumpAndSettle();
      expect(find.text('Legacy'), findsOneWidget);
      expect(
        find.text('Status unknown: configuration is incomplete.'),
        findsOneWidget,
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  testWidgets('saving another habit preserves an active timer', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = FixedClock();
    final start = LocalDate(2026, 11, 26);
    await CounterHabitWriter(db, clock).create(
      habitId: 'counter',
      versionId: 'counter_v',
      auditId: 'counter_a',
      lifecycleEventId: 'counter_l',
      name: 'Counter',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'times'),
      schedule: DailySchedule(start: start),
    );
    await HabitMetadataStore(db)
        .insert('counter_v', HabitMetadata(category: 'Health'));
    await BooleanDurationHabitService(db, clock).createDuration(
      habitId: 'duration',
      versionId: 'duration_v',
      lifecycleEventId: 'duration_l',
      name: 'Duration',
      effectiveDate: DateTime(2026, 11, 26),
      target: DurationTarget(targetSeconds: 10),
      schedule: DailySchedule(start: start),
      metadata: HabitMetadata(category: 'Health'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: TodayHabitRoster(date: start)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start timer'));
    await tester.tap(find.text('Start timer'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(TextField, 'Progress amount'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Progress amount'),
      '1',
    );
    await tester.ensureVisible(find.text('Add progress'));
    await tester.tap(find.text('Add progress'));
    await tester.pumpAndSettle();
    expect(find.text('Stop and save timer'), findsOneWidget);
  });
}
