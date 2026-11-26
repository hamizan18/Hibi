import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_audit_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('reads version, lifecycle, event, resolution and recovery audits and persists across disk database reopen', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_counter_audit_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'audit.sqlite'));

    final first = AppDatabase(NativeDatabase(file));
    final clock = MutableClock(DateTime(2026, 11, 26, 8));
    final writer = CounterHabitWriter(first, clock);
    await writer.create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      name: 'Quran Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    clock.current = DateTime(2026, 11, 26, 9);
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v2',
      auditId: 'a2',
      name: 'Quran Reading Extended',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
    );

    final actions = CounterTodayActionService(first, clock);
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e_26',
      quantity: 2,
    );
    clock.current = DateTime(2026, 11, 26, 21);
    await actions.resolveToday(
      habitId: 'h',
      occurrenceId: 'o_26',
      resolutionId: 'r_26',
      state: CounterResolutionState.failed,
      reason: 'Tired',
    );

    clock.current = DateTime(2026, 11, 27, 10);
    await actions.recoverPriorDeficit(
      recoveryId: 'rec_27',
      occurrenceId: 'o_26',
      quantity: 3,
      note: 'Morning recovery',
    );
    await HabitLifecycleStore(first, clock).append(
      id: 'l2',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 12, 2),
      state: HabitLifecycleState.paused,
      reason: 'Trip',
    );

    // Insert a legacy raw event without an audit row to verify no audit is fabricated
    await first.customStatement(
      "INSERT INTO habit_counter_events VALUES ('legacy_event', 'o_26', 1, 5)",
    );
    await first.close();

    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final reader = CounterAuditReader(reopened);

    await expectLater(reader.readForHabit('missing'), throwsStateError);

    final trail = await reader.readForHabit('h');
    expect(trail.habitId, 'h');
    expect(trail.versionAudits.map((a) => a.id), ['a1', 'a2']);
    expect(trail.versionAudits[0].operation, 'create');
    expect(trail.versionAudits[0].previousValues, isNull);
    expect(trail.versionAudits[0].updatedValues['target_count'], 5);
    expect(trail.versionAudits[1].operation, 'schedule_version');
    expect(trail.versionAudits[1].previousValues!['target_count'], 5);

    expect(trail.lifecycleEvents.map((e) => e.id), ['l1', 'l2']);
    expect(trail.lifecycleEvents[1].reason, 'Trip');

    // Only the audited event e_26 appears, not legacy_event
    expect(trail.eventAudits.map((e) => e.eventId), ['e_26']);
    expect(trail.eventAudits.single.quantity, 2);
    expect(
      trail.eventAudits.single.occurrenceDate.compareTo(
        LocalDate(2026, 11, 26),
      ),
      0,
    );

    expect(trail.resolutionAudits.single.resolution.id, 'r_26');
    expect(
      trail.resolutionAudits.single.resolution.state,
      CounterResolutionState.failed,
    );
    expect(trail.resolutionAudits.single.resolution.reason, 'Tired');

    expect(trail.recoveryAudits.single.recovery.id, 'rec_27');
    expect(trail.recoveryAudits.single.recovery.quantity, 3);
    expect(trail.recoveryAudits.single.recovery.remainingDeficit, 0);
    expect(trail.recoveryAudits.single.recovery.note, 'Morning recovery');
  });
}
