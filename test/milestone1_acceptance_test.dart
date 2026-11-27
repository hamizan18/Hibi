import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/counter_audit_reader.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_history_reader.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/non_counter_version_service.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_starter_template.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;

class AcceptanceClock implements AppClock {
  DateTime current = DateTime(2026, 11, 25, 8);
  @override
  DateTime now() => current;
}

void main() {
  test('Milestone 1 acceptance: dynamic creation, preserved history across version changes, no pre-start or pause failures, multi-event persistence, bounded recovery and auditable corrections survive disk database restart', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'hibi_m1_acceptance_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final dbFile = File(path.join(tempDir.path, 'hibi_m1.sqlite'));
    final clock = AcceptanceClock();

    // Phase 1: Open database, create counter & checklist habits from templates,
    // log multi-event progress, pause/resume, recover, schedule future versions,
    // and commit a confirmed historical counter target correction.
    final db1 = AppDatabase(NativeDatabase(dbFile));
    try {
      // 1. Create Quran Reading starting 2026-11-25 (target 5 pages daily)
      await CounterHabitWriter(db1, clock).createFromStarterTemplate(
        template: CounterStarterTemplate.quranReading,
        habitId: 'h_quran',
        versionId: 'v_quran_1',
        auditId: 'aud_quran_create',
        lifecycleEventId: 'life_quran_1',
        effectiveDate: DateTime(2026, 11, 25),
      );
      await HabitMetadataStore(db1).insert(
        'v_quran_1',
        HabitMetadata(
          category: 'Spiritual',
          symbol: 'N',
          recoveryEnabled: true,
        ),
      );

      // 2. Create Daily Prayers checklist starting 2026-11-25
      await ChecklistHabitService(db1, clock).createFromStarterTemplate(
        template: ChecklistStarterTemplate.dailyPrayers,
        habitId: 'h_prayers',
        versionId: 'v_prayers_1',
        lifecycleEventId: 'life_prayers_1',
        itemIds: const ['p1', 'p2', 'p3', 'p4', 'p5'],
        effectiveDate: DateTime(2026, 11, 25),
      );

      // Verify creation generated zero occurrence rows
      expect(
        (await db1
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        0,
      );

      // 3. On Nov 25: log 2 pages on Quran Reading, then resolve as failed
      final counterActions = CounterTodayActionService(db1, clock);
      await counterActions.recordTodayProgress(
        habitId: 'h_quran',
        occurrenceId: 'occ_q_25',
        eventId: 'ev_q_25_1',
        quantity: 2,
      );
      await counterActions.resolveToday(
        habitId: 'h_quran',
        occurrenceId: 'occ_q_25',
        resolutionId: 'res_q_25',
        state: CounterResolutionState.failed,
        reason: 'Travel fatigue',
      );

      // Schedule future version v_quran_2 starting Nov 26 with target 6 pages
      await CounterHabitWriter(db1, clock).scheduleVersion(
        habitId: 'h_quran',
        versionId: 'v_quran_2',
        auditId: 'aud_quran_v2',
        name: 'Quran Reading',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 6, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
        metadata: HabitMetadata(
          category: 'Spiritual',
          symbol: 'N',
          recoveryEnabled: true,
        ),
      );

      // Schedule future checklist version v_prayers_2 starting Nov 27 (6 items)
      await NonCounterVersionService(db1, clock).scheduleChecklistVersion(
        habitId: 'h_prayers',
        versionId: 'v_prayers_2',
        auditId: 'aud_prayers_v2',
        name: 'Daily Prayers + Duha',
        effectiveDate: DateTime(2026, 11, 27),
        items: [
          for (var i = 0; i < 6; i++)
            ChecklistItemDefinition(
              id: 'p2_$i',
              label: const [
                'Fajr',
                'Duha',
                'Dhuhr',
                'Asr',
                'Maghrib',
                'Isha',
              ][i],
              displayOrder: i,
              recoveryEnabled: true,
            ),
        ],
        schedule: DailySchedule(start: LocalDate(2026, 11, 27)),
      );

      // 4. Advance clock to Nov 26: recover Nov 25 deficit (+3 pages),
      // and log two separate progress events (2 + 3 = 5 pages) on Nov 26
      clock.current = DateTime(2026, 11, 26, 9);
      await counterActions.recoverPriorDeficit(
        recoveryId: 'rec_q_25',
        occurrenceId: 'occ_q_25',
        quantity: 3,
        note: 'Read 3 makeup pages after Fajr',
      );
      await counterActions.recordTodayProgress(
        habitId: 'h_quran',
        occurrenceId: 'occ_q_26',
        eventId: 'ev_q_26_1',
        quantity: 2,
      );
      await counterActions.recordTodayProgress(
        habitId: 'h_quran',
        occurrenceId: 'occ_q_26',
        eventId: 'ev_q_26_2',
        quantity: 3,
      );

      // Preview and confirm historical target correction on v_quran_2 from 6 to 5 pages
      final preview = await CounterCorrectionPreviewer(db1, clock).preview(
        const CounterTargetCorrectionProposal(
          habitId: 'h_quran',
          versionId: 'v_quran_2',
          proposedTargetCount: 5,
          proposedUnit: 'pages',
          reason: 'Keep daily target at 5 pages',
        ),
      );
      expect(
        preview.affectedOccurrences.single.proposedProgressStatus.name,
        'completed',
      );
      await CounterCorrectionWriter(
        db1,
        clock,
      ).commit(correctionAuditId: 'corr_q_v2', confirmedPreview: preview);

      // Schedule pause on Nov 27 and resume on Nov 28
      final lifecycleService = CounterLifecycleActionService(db1, clock);
      await lifecycleService.pause(
        eventId: 'life_quran_pause_27',
        habitId: 'h_quran',
        effectiveDate: LocalDate(2026, 11, 27),
        reason: 'Rest day',
      );
      await lifecycleService.resume(
        eventId: 'life_quran_resume_28',
        habitId: 'h_quran',
        effectiveDate: LocalDate(2026, 11, 28),
        reason: 'Back on schedule',
      );
    } finally {
      await db1.close();
    }

    // Phase 2: Reopen database from disk in a fresh AppDatabase instance and
    // verify all history, evaluations, non-counter versions and audits survive.
    final db2 = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db2.close);

    final history = await CounterHistoryReader(db2).readRange(
      habitId: 'h_quran',
      startInclusive: LocalDate(2026, 11, 24),
      endInclusive: LocalDate(2026, 11, 28),
    );
    expect(history.length, 5);

    // Nov 24 (before start): notApplicable (beforeStart), never failed
    expect(
      history[0].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );
    final nov24Detail = await HabitApplicabilityReader(db2)
        .describe('h_quran', LocalDate(2026, 11, 24));
    expect(nov24Detail.reason, HabitApplicabilityReason.beforeStart);

    // Nov 25: originally failed (2/5), fully recovered (+3), original progress preserved as 2
    expect(
      history[1].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.recovered,
    );
    expect(history[1].evaluation.day.recorded!.progress.total, 2);
    expect(history[1].evaluation.day.recorded!.progress.target, 5);
    expect(history[1].evaluation.recovery!.recoveredTotal, 3);

    // Nov 26: 2 + 3 = 5 pages under corrected target 5 -> completed
    expect(
      history[2].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.completed,
    );
    expect(history[2].evaluation.day.recorded!.progress.total, 5);
    expect(history[2].evaluation.day.recorded!.progress.target, 5);

    // Nov 27 (paused): notApplicable, never failed
    expect(
      history[3].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );
    final nov27Detail = await HabitApplicabilityReader(db2)
        .describe('h_quran', LocalDate(2026, 11, 27));
    expect(nov27Detail.reason, HabitApplicabilityReason.paused);

    // Nov 28 (resumed): pending with no occurrence row created
    expect(
      history[4].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(history[4].evaluation.hasOccurrence, isFalse);

    // Full 6-stream counter audit trail survived disk restart
    final counterAudits = await CounterAuditReader(db2).readForHabit('h_quran');
    expect(counterAudits.versionAudits.length, 2);
    expect(counterAudits.correctionAudits.length, 1);
    expect(counterAudits.correctionAudits.single.previousTargetCount, 6);
    expect(counterAudits.correctionAudits.single.updatedTargetCount, 5);
    expect(counterAudits.lifecycleEvents.length, 3);
    expect(counterAudits.eventAudits.length, 3);
    expect(counterAudits.resolutionAudits.length, 1);
    expect(counterAudits.recoveryAudits.length, 1);

    // Non-counter checklist version timeline & audits survived disk restart
    final prayersBundle = await NonCounterVersionService(db2, clock)
        .readConfigurationAndAudit(
          habitId: 'h_prayers',
          asOfDate: LocalDate(2026, 11, 26),
        );
    expect(prayersBundle.effectiveVersion!.checklistItems!.length, 5);
    expect(prayersBundle.futureVersions.single.checklistItems!.length, 6);
    expect(prayersBundle.versionAudits.length, 2);

    // Re-evaluating Nov 26 still sees target 5 and creates zero extra occurrences
    final reEval = await CounterDayReader(db2)
        .evaluate(habitId: 'h_quran', date: LocalDate(2026, 11, 26));
    expect(reEval.effectiveStatus, CounterDayEffectiveStatus.completed);
  });
}
