import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/reminders/data/reminder_service.dart';

class _Clock implements AppClock {
  _Clock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('uses generic text for private habits by default, falls back to inexact mode, and cancels when paused', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock(DateTime(2026, 11, 27, 7, 0));
    final gateway = InMemoryNotificationGateway(
      permissionGranted: true,
      exactAlarmsAvailable: false,
    );
    final reminders = ReminderService(db, clock, gateway);
    final today = LocalDate(2026, 11, 27);

    // 1. Private habit
    await CounterHabitWriter(db, clock).create(
      habitId: 'h_priv',
      versionId: 'v_priv',
      lifecycleEventId: 'l_priv',
      auditId: 'a_priv',
      name: 'Secret Private Habit',
      effectiveDate: DateTime(2026, 11, 27),
      target: CounterTarget(count: 1, unit: 'time'),
      schedule: DailySchedule(start: today),
    );
    await HabitMetadataStore(db)
        .insert('v_priv', HabitMetadata(category: 'Private', isPrivate: true));

    final remPriv = await reminders.createReminder(
      id: 'rem_priv',
      habitId: 'h_priv',
      hour: 8,
      minute: 30,
      customMessage: 'Very sensitive note',
    );
    expect(remPriv.lastScheduleMode, 'inexact'); // Inexact fallback verified!
    final scheduledPriv = gateway
        .scheduled[ReminderService.notificationIdForReminder('rem_priv')]!;
    // Private habit name & sensitive message must NOT leak by default!
    expect(scheduledPriv.title, ReminderService.genericPrivateTitle);
    expect(scheduledPriv.body, ReminderService.genericPrivateBody);
    expect(scheduledPriv.title.contains('Secret'), isFalse);
    expect(scheduledPriv.body.contains('sensitive'), isFalse);

    // 2. Pausing the habit cancels future reminders on reschedule!
    clock.current = DateTime(2026, 11, 28, 7, 0);
    await CounterLifecycleActionService(db, clock).pause(
      habitId: 'h_priv',
      eventId: 'l_priv_pause',
      effectiveDate: LocalDate(2026, 11, 28),
      reason: 'Taking a break',
    );
    await reminders.rescheduleAll();
    final updated = (await reminders.readReminderById('rem_priv'))!;
    expect(updated.lastScheduleMode, 'skipped_inactive');
    expect(
      gateway.scheduled.containsKey(
        ReminderService.notificationIdForReminder('rem_priv'),
      ),
      isFalse,
    );
  });

  test('records permission_denied honestly when Android notification permission is denied', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock(DateTime(2026, 11, 27, 7, 0));
    final gateway = InMemoryNotificationGateway(permissionGranted: false);
    final reminders = ReminderService(db, clock, gateway);
    final today = LocalDate(2026, 11, 27);

    await CounterHabitWriter(db, clock).create(
      habitId: 'h_pub',
      versionId: 'v_pub',
      lifecycleEventId: 'l_pub',
      auditId: 'a_pub',
      name: 'Morning Walk',
      effectiveDate: DateTime(2026, 11, 27),
      target: CounterTarget(count: 1, unit: 'walk'),
      schedule: DailySchedule(start: today),
    );
    await HabitMetadataStore(db)
        .insert('v_pub', HabitMetadata(category: 'Health', isPrivate: false));

    final rem = await reminders.createReminder(
      id: 'rem_pub',
      habitId: 'h_pub',
      hour: 9,
      minute: 0,
    );
    expect(rem.lastScheduleMode, 'permission_denied');
    expect(gateway.scheduled, isEmpty);
  });
}
