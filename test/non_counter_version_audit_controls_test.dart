import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/non_counter_version_service.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/non_counter_version_audit_controls.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  testWidgets(
    'schedules future checklist version on Today and redacts private non-counter audit history until revealed',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock();
      final today = LocalDate(2026, 11, 26);

      await ChecklistHabitService(db, clock).createFromStarterTemplate(
        template: ChecklistStarterTemplate.dailyPrayers,
        habitId: 'h_prayers',
        versionId: 'v_prayers_1',
        lifecycleEventId: 'l_prayers_1',
        itemIds: const ['i1', 'i2', 'i3', 'i4', 'i5'],
        effectiveDate: DateTime(2026, 11, 26),
      );
      await AvoidanceHabitService(db, clock).createFromStarterTemplate(
        template: AvoidanceStarterTemplate.selfControl,
        habitId: 'h_self',
        versionId: 'v_self_1',
        lifecycleEventId: 'l_self_1',
        effectiveDate: DateTime(2026, 11, 26),
      );

      final summaries = await UnifiedHabitRegistryReader(db)
          .readAll(asOfDate: today);
      final prayersSummary = summaries.firstWhere(
        (s) => s.habitId == 'h_prayers',
      );
      final selfSummary = summaries.firstWhere((s) => s.habitId == 'h_self');

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
                child: NonCounterVersionAndAuditControls(
                  habit: prayersSummary,
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
        find.textContaining('Effective: Revision 1: Daily Prayers — 5 items'),
        findsOneWidget,
      );

      await tester.tap(find.text('Schedule future version'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Future version name'),
        'Daily Prayers + Duha',
      );
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Future checklist items (comma-separated)',
        ),
        'Fajr, Duha, Dhuhr, Asr, Maghrib, Isha',
      );
      final submit = find.byKey(const Key('non-counter-future-version-submit'));
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(changed, 1);
      expect(
        find.textContaining('Revision 2: Daily Prayers + Duha — 6 items'),
        findsOneWidget,
      );

      final bundle = await NonCounterVersionService(
        db,
        clock,
      ).readConfigurationAndAudit(habitId: 'h_prayers', asOfDate: today);
      expect(bundle.futureVersions.single.checklistItems!.length, 6);
      expect(bundle.versionAudits.length, 2);

      // Private avoidance audit sheet is redacted when showPrivateHistory is false
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: NonCounterAuditHistorySheet(
                habit: selfSummary,
                date: today,
                showPrivateHistory: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Private historical configuration and audit'),
        findsOneWidget,
      );

      // Revealed when showPrivateHistory is true
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: NonCounterAuditHistorySheet(
                habit: selfSummary,
                date: today,
                showPrivateHistory: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('History & Audit: Self Control'),
        findsOneWidget,
      );
      expect(find.textContaining('max 0 incidents'), findsOneWidget);
      expect(find.textContaining('[create]'), findsOneWidget);
    },
  );
}
