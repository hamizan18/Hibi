import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_audit_history_sheet.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 25, 12);
  @override
  DateTime now() => current;
}

void main() {
  testWidgets(
    'displays 7-day range summary, six audit streams and enforces private visibility redaction without creating occurrences',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock();

      await CounterHabitWriter(db, clock).create(
        habitId: 'h',
        versionId: 'v1',
        auditId: 'a_create',
        lifecycleEventId: 'l1',
        name: 'Secret Counter',
        effectiveDate: DateTime(2026, 11, 25),
        target: CounterTarget(count: 10, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 25)),
      );
      await HabitMetadataStore(db).insert(
        'v1',
        HabitMetadata(
          category: 'Personal',
          isPrivate: true,
          recoveryEnabled: true,
        ),
      );

      await CounterHabitWriter(db, clock).scheduleVersion(
        habitId: 'h',
        versionId: 'v2',
        auditId: 'a_v2',
        name: 'Secret Counter',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 10, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
        metadata: HabitMetadata(
          category: 'Personal',
          isPrivate: true,
          recoveryEnabled: true,
        ),
      );

      final actions = CounterTodayActionService(db, clock);
      await actions.recordTodayProgress(
        habitId: 'h',
        occurrenceId: 'o_25',
        eventId: 'ev_1',
        quantity: 2,
      );
      await actions.resolveToday(
        habitId: 'h',
        occurrenceId: 'o_25',
        resolutionId: 'res_1',
        state: CounterResolutionState.failed,
        reason: 'Busy evening',
      );

      // Next day (Nov 26): recover remaining 8 pages on o_25 and log 5 pages on o_26
      clock.current = DateTime(2026, 11, 26, 10);
      await actions.recoverPriorDeficit(
        recoveryId: 'rec_1',
        occurrenceId: 'o_25',
        quantity: 8,
        note: 'Recovered next morning',
      );
      await actions.recordTodayProgress(
        habitId: 'h',
        occurrenceId: 'o_26',
        eventId: 'ev_2',
        quantity: 5,
      );

      // Correct v2 target from 10 to 5 on Nov 26
      final preview = await CounterCorrectionPreviewer(db, clock).preview(
        const CounterTargetCorrectionProposal(
          habitId: 'h',
          versionId: 'v2',
          proposedTargetCount: 5,
          proposedUnit: 'pages',
          reason: 'Adjusted target',
        ),
      );
      await CounterCorrectionWriter(
        db,
        clock,
      ).commit(correctionAuditId: 'corr_1', confirmedPreview: preview);

      clock.current = DateTime(2026, 11, 27, 10);
      final summary = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: LocalDate(2026, 11, 27))).single;

      // 1. When showPrivateHistory is false, private details are hidden
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CounterAuditHistorySheet(
                habit: summary,
                date: LocalDate(2026, 11, 27),
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
      expect(find.textContaining('Adjusted target'), findsNothing);

      // 2. When showPrivateHistory is true, all 6 audit streams and range summary render
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CounterAuditHistorySheet(
                habit: summary,
                date: LocalDate(2026, 11, 27),
                showPrivateHistory: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('History & Audit: Secret Counter'),
        findsOneWidget,
      );
      expect(find.textContaining('Recovered: 1'), findsOneWidget);
      expect(
        find.textContaining('10 -> 5 pages (Adjusted target)'),
        findsOneWidget,
      );
      expect(find.textContaining('Busy evening'), findsOneWidget);
      expect(find.textContaining('Recovered next morning'), findsOneWidget);

      // Viewing history & audit created no occurrence for Nov 27
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        2,
      );
    },
  );
}
