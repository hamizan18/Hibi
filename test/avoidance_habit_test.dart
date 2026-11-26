import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('Self Control / O starter template requires explicit confirmation for zero-incident completion and fails immediately on exceeding maxIncidents', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    final service = AvoidanceHabitService(db, clock);

    await service.createFromStarterTemplate(
      template: AvoidanceStarterTemplate.selfControl,
      habitId: 'h_self',
      versionId: 'v_self',
      lifecycleEventId: 'l_self',
      effectiveDate: DateTime(2026, 11, 26),
    );

    // Pure evaluation with 0 incidents and no confirmation is pending, never auto-completed
    final unconfirmed = AvoidanceDayProgress.evaluate(
      maxIncidents: 0,
      incidentCount: 0,
    );
    expect(unconfirmed.status, AvoidanceEffectiveStatus.pending);

    // Confirming completion on Nov 26 with 0 incidents marks it completed
    final nov26 = await service.resolveToday(
      habitId: 'h_self',
      occurrenceId: 'o_26',
      resolutionId: 'r_26',
      state: AvoidanceResolutionState.confirmedCompleted,
    );
    expect(nov26.progress!.status, AvoidanceEffectiveStatus.completed);
    expect(nov26.progress!.incidentCount, 0);

    // On Nov 27, record 2 repeated incidents against max 0 -> immediately failed
    clock.current = DateTime(2026, 11, 27, 14);
    final inc1 = await service.recordIncidentToday(
      habitId: 'h_self',
      occurrenceId: 'o_27',
      incidentId: 'inc1',
    );
    expect(inc1.progress!.status, AvoidanceEffectiveStatus.failed);
    expect(inc1.progress!.incidentCount, 1);

    final inc2 = await service.recordIncidentToday(
      habitId: 'h_self',
      occurrenceId: 'o_27',
      incidentId: 'inc2',
    );
    expect(inc2.progress!.status, AvoidanceEffectiveStatus.failed);
    expect(inc2.progress!.incidentCount, 2);

    // Cannot confirm completion when incidents exceed maxIncidents
    await expectLater(
      service.resolveToday(
        habitId: 'h_self',
        occurrenceId: 'o_27',
        resolutionId: 'bad_confirm',
        state: AvoidanceResolutionState.confirmedCompleted,
      ),
      throwsStateError,
    );
  });
}
