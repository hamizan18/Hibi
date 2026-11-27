import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_correction_controls.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  testWidgets(
    'previews historical target correction, cancels with zero writes, rejects stale preview and commits confirmed correction with preimage audit',
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
        name: 'Push Up',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 10, unit: 'reps'),
        schedule: DailySchedule(start: today),
      );
      await HabitMetadataStore(db)
          .insert('v1', HabitMetadata(category: 'Exercise', isPrivate: false));
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'h',
        occurrenceId: 'o_26',
        eventId: 'e1',
        quantity: 6,
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
                child: CounterCorrectionControls(
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

      await tester.tap(find.text('Correct historical target'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Proposed target count'),
        '5',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Correction reason (optional)'),
        'Fix typo',
      );
      await tester.tap(find.text('Preview target correction'));
      await tester.pumpAndSettle();

      expect(
        find.text('Confirm historical target correction?'),
        findsOneWidget,
      );
      expect(
        find.textContaining('partial @ 10 -> completed @ 5'),
        findsOneWidget,
      );

      // 1. Cancel performs no writes
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(changed, 0);
      expect(
        (await CounterDayReader(
          db,
        ).evaluate(habitId: 'h', date: today)).effectiveStatus,
        CounterDayEffectiveStatus.partial,
      );

      // 2. Make preview stale by advancing clock past midnight while dialog is open
      await tester.tap(find.text('Preview target correction'));
      await tester.pumpAndSettle();
      clock.current = DateTime(2026, 11, 27, 0, 1);
      await tester.tap(find.text('Confirm correction'));
      await tester.pumpAndSettle();
      expect(find.textContaining('stale'), findsOneWidget);
      expect(changed, 0);
      expect(
        await CounterCorrectionWriter(db, clock).readAuditsForHabit('h'),
        isEmpty,
      );

      // 3. Fresh preview and confirm commits atomically
      clock.current = DateTime(2026, 11, 26, 15);
      await tester.enterText(
        find.widgetWithText(TextField, 'Proposed target count'),
        '5',
      );
      await tester.tap(find.text('Preview target correction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm correction'));
      await tester.pumpAndSettle();

      expect(changed, 1);
      final updatedDay = await CounterDayReader(db)
          .evaluate(habitId: 'h', date: today);
      expect(updatedDay.effectiveStatus, CounterDayEffectiveStatus.completed);
      expect(updatedDay.day.recorded!.progress.target, 5);
      expect(updatedDay.day.recorded!.progress.total, 6);

      final audits = await CounterCorrectionWriter(
        db,
        clock,
      ).readAuditsForHabit('h');
      expect(audits.length, 1);
      expect(audits.single.previousTargetCount, 10);
      expect(audits.single.updatedTargetCount, 5);
    },
  );
}
