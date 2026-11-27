import 'package:drift/drift.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../../habits/data/habit_lifecycle.dart';
import '../../habits/data/habit_metadata_store.dart';
import '../../habits/domain/habit_schedule.dart';

/// Persisted user-configured local reminder for a habit.
class HabitReminder {
  const HabitReminder({
    required this.id,
    required this.habitId,
    required this.hour,
    required this.minute,
    required this.isEnabled,
    required this.allowSensitiveText,
    this.customMessage,
    required this.lastScheduleMode,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String habitId;
  final int hour;
  final int minute;
  final bool isEnabled;
  final bool allowSensitiveText;
  final String? customMessage;
  final String lastScheduleMode;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  String get formattedTime =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Sanitized notification payload ready for scheduling.
class ScheduledNotificationRequest {
  const ScheduledNotificationRequest({
    required this.notificationId,
    required this.reminderId,
    required this.title,
    required this.body,
    required this.scheduledAtLocal,
  });

  final int notificationId;
  final String reminderId;
  final String title;
  final String body;
  final DateTime scheduledAtLocal;
}

enum NotificationScheduleOutcome { exact, inexact, permissionDenied }

/// Abstraction over platform local notifications (flutter_local_notifications on
/// Android; in-memory fake in host unit/widget tests).
abstract class LocalNotificationGateway {
  Future<bool> hasNotificationPermission();
  Future<bool> requestNotificationPermission();
  Future<bool> canScheduleExactAlarms();
  Future<NotificationScheduleOutcome> schedule(
    ScheduledNotificationRequest request,
  );
  Future<void> cancel(int notificationId);
}

class InMemoryNotificationGateway implements LocalNotificationGateway {
  InMemoryNotificationGateway({
    this.permissionGranted = true,
    this.exactAlarmsAvailable = false,
  });

  bool permissionGranted;
  bool exactAlarmsAvailable;
  final Map<int, ScheduledNotificationRequest> scheduled = {};
  final List<int> cancelledIds = [];

  @override
  Future<bool> hasNotificationPermission() async => permissionGranted;

  @override
  Future<bool> requestNotificationPermission() async => permissionGranted;

  @override
  Future<bool> canScheduleExactAlarms() async => exactAlarmsAvailable;

  @override
  Future<NotificationScheduleOutcome> schedule(
    ScheduledNotificationRequest request,
  ) async {
    if (!permissionGranted) {
      return NotificationScheduleOutcome.permissionDenied;
    }
    scheduled[request.notificationId] = request;
    return exactAlarmsAvailable
        ? NotificationScheduleOutcome.exact
        : NotificationScheduleOutcome.inexact;
  }

  @override
  Future<void> cancel(int notificationId) async {
    scheduled.remove(notificationId);
    cancelledIds.add(notificationId);
  }
}

class FlutterLocalNotificationsGateway implements LocalNotificationGateway {
  FlutterLocalNotificationsGateway([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<bool> hasNotificationPermission() async {
    try {
      await _ensureInitialized();
      return await _android?.areNotificationsEnabled() ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      await _ensureInitialized();
      return await _android?.requestNotificationsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> canScheduleExactAlarms() async {
    try {
      await _ensureInitialized();
      return await _android?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<NotificationScheduleOutcome> schedule(
    ScheduledNotificationRequest request,
  ) async {
    try {
      await _ensureInitialized();
      final permitted = await hasNotificationPermission();
      if (!permitted) {
        return NotificationScheduleOutcome.permissionDenied;
      }
      final exact = await canScheduleExactAlarms();
      final mode = exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle;
      final scheduledTz = tz.TZDateTime.from(
        request.scheduledAtLocal.toUtc(),
        tz.UTC,
      );
      await _plugin.zonedSchedule(
        id: request.notificationId,
        title: request.title,
        body: request.body,
        scheduledDate: scheduledTz,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'hibi_habit_reminders',
            'Habit Reminders',
            channelDescription:
                'Local schedule-aware reminders configured by the user.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        androidScheduleMode: mode,
      );
      return exact
          ? NotificationScheduleOutcome.exact
          : NotificationScheduleOutcome.inexact;
    } catch (_) {
      return NotificationScheduleOutcome.permissionDenied;
    }
  }

  @override
  Future<void> cancel(int notificationId) async {
    try {
      await _ensureInitialized();
      await _plugin.cancel(id: notificationId);
    } catch (_) {
      // Ignore on unsupported host test platforms.
    }
  }
}

/// Schedule-aware local reminder service.
///
/// Rules enforced (per BUSINESS_RULES.md & SECURITY_PRIVACY.md):
/// - 100% user-configured local times; never infers prayer times or location.
/// - Checks habit applicability (paused, archived, deleted or unscheduled
///   habits cancel/skip reminders instead of firing false alerts).
/// - Uses generic notification text by default for private or unclassified
///   habits unless `allowSensitiveText` is explicitly enabled.
/// - Automatically falls back to inexact Android scheduling when exact alarms
///   are unavailable, and records honest Android delivery limitations.
class ReminderService {
  const ReminderService(this._db, this._clock, this._gateway);

  static const String genericPrivateTitle = 'Hibi check-in';
  static const String genericPrivateBody =
      'You have a scheduled private check-in.';
  static const String androidLimitationNotice =
      'Reminders are local and schedule-aware. On Android, exact alarm '
      'permission may be unavailable; Hibi falls back to inexact alarms and '
      'cannot guarantee delivery under OEM battery optimization or Doze mode.';

  final AppDatabase _db;
  final AppClock _clock;
  final LocalNotificationGateway _gateway;

  Future<HabitReminder> createReminder({
    required String id,
    required String habitId,
    required int hour,
    required int minute,
    bool isEnabled = true,
    bool allowSensitiveText = false,
    String? customMessage,
  }) async {
    if (hour < 0 || hour > 23) {
      throw RangeError.range(hour, 0, 23, 'hour');
    }
    if (minute < 0 || minute > 59) {
      throw RangeError.range(minute, 0, 59, 'minute');
    }
    final cleanId = id.trim();
    final cleanHabitId = habitId.trim();
    if (cleanId.isEmpty || cleanHabitId.isEmpty) {
      throw ArgumentError('Reminder id and habitId must not be blank');
    }
    final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.transaction(() async {
      final habit = await _db
          .customSelect(
            'SELECT id FROM habits WHERE id = ?',
            variables: [Variable<String>(cleanHabitId)],
          )
          .getSingleOrNull();
      if (habit == null) {
        throw StateError('Habit not found: $cleanHabitId');
      }
      await _db.customStatement(
        '''
        INSERT INTO habit_reminders (
          id, habit_id, hour, minute, is_enabled, allow_sensitive_text,
          custom_message, last_schedule_mode, created_at_utc_us, updated_at_utc_us
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
        ''',
        [
          cleanId,
          cleanHabitId,
          hour,
          minute,
          isEnabled ? 1 : 0,
          allowSensitiveText ? 1 : 0,
          _cleanOptional(customMessage),
          nowUs,
          nowUs,
        ],
      );
    });
    await rescheduleReminder(cleanId);
    return (await readReminderById(cleanId))!;
  }

  Future<void> setReminderEnabled(String reminderId, bool enabled) async {
    final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      'UPDATE habit_reminders SET is_enabled = ?, updated_at_utc_us = ? WHERE id = ?',
      [enabled ? 1 : 0, nowUs, reminderId.trim()],
    );
    await rescheduleReminder(reminderId);
  }

  Future<void> deleteReminder(String reminderId) async {
    final cleanId = reminderId.trim();
    await _gateway.cancel(notificationIdForReminder(cleanId));
    await _db.customStatement('DELETE FROM habit_reminders WHERE id = ?', [
      cleanId,
    ]);
  }

  Future<List<HabitReminder>> readAllReminders() async {
    final rows = await _db.customSelect('''
          SELECT id, habit_id, hour, minute, is_enabled, allow_sensitive_text,
                 custom_message, last_schedule_mode, created_at_utc_us, updated_at_utc_us
          FROM habit_reminders
          ORDER BY hour ASC, minute ASC, id ASC
        ''').get();
    return [for (final row in rows) _mapRow(row)];
  }

  Future<HabitReminder?> readReminderById(String reminderId) async {
    final row = await _db
        .customSelect(
          '''
          SELECT id, habit_id, hour, minute, is_enabled, allow_sensitive_text,
                 custom_message, last_schedule_mode, created_at_utc_us, updated_at_utc_us
          FROM habit_reminders
          WHERE id = ?
          ''',
          variables: [Variable<String>(reminderId.trim())],
        )
        .getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  /// Reschedules all reminders (e.g. after pause, archive, schedule edit or boot).
  Future<List<HabitReminder>> rescheduleAll() async {
    final reminders = await readAllReminders();
    for (final r in reminders) {
      await rescheduleReminder(r.id);
    }
    return readAllReminders();
  }

  /// Evaluates the next applicable date (within the next 31 days) for the
  /// reminder's habit and schedules or cancels its local notification.
  Future<String> rescheduleReminder(String reminderId) async {
    final reminder = await readReminderById(reminderId);
    if (reminder == null) {
      throw StateError('Reminder not found: $reminderId');
    }
    final notifId = notificationIdForReminder(reminder.id);

    if (!reminder.isEnabled) {
      await _gateway.cancel(notifId);
      await _updateScheduleMode(reminder.id, 'disabled');
      return 'disabled';
    }

    final nowLocal = _clock.now().toLocal();
    final nextFire = await _findNextApplicableFireTime(
      habitId: reminder.habitId,
      hour: reminder.hour,
      minute: reminder.minute,
      nowLocal: nowLocal,
    );
    if (nextFire == null) {
      await _gateway.cancel(notifId);
      await _updateScheduleMode(reminder.id, 'skipped_inactive');
      return 'skipped_inactive';
    }

    final payload = await _buildNotificationText(
      reminder: reminder,
      targetDate: LocalDate(nextFire.year, nextFire.month, nextFire.day),
    );
    final outcome = await _gateway.schedule(
      ScheduledNotificationRequest(
        notificationId: notifId,
        reminderId: reminder.id,
        title: payload.title,
        body: payload.body,
        scheduledAtLocal: nextFire,
      ),
    );
    final mode = switch (outcome) {
      NotificationScheduleOutcome.exact => 'exact',
      NotificationScheduleOutcome.inexact => 'inexact',
      NotificationScheduleOutcome.permissionDenied => 'permission_denied',
    };
    await _updateScheduleMode(reminder.id, mode);
    return mode;
  }

  Future<bool> requestPermission() => _gateway.requestNotificationPermission();

  /// Deterministic positive 31-bit notification ID derived from reminder ID.
  static int notificationIdForReminder(String reminderId) {
    var hash = 2166136261;
    for (final unit in reminderId.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  Future<DateTime?> _findNextApplicableFireTime({
    required String habitId,
    required int hour,
    required int minute,
    required DateTime nowLocal,
  }) async {
    final reader = HabitApplicabilityReader(_db);
    for (var offset = 0; offset < 32; offset++) {
      final day = DateTime(
        nowLocal.year,
        nowLocal.month,
        nowLocal.day + offset,
      );
      final fire = DateTime(day.year, day.month, day.day, hour, minute);
      if (!fire.isAfter(nowLocal)) continue;
      final localDate = LocalDate(day.year, day.month, day.day);
      final detail = await reader.describe(habitId, localDate);
      if (detail.applicability == HabitApplicability.applicable) {
        return fire;
      }
    }
    return null;
  }

  Future<({String title, String body})> _buildNotificationText({
    required HabitReminder reminder,
    required LocalDate targetDate,
  }) async {
    final detail = await HabitApplicabilityReader(_db)
        .describe(reminder.habitId, targetDate);
    final versionId = detail.versionId;
    final metadata = versionId == null
        ? null
        : await HabitMetadataStore(_db).findForVersion(versionId);
    final isPrivateOrUnclassified = metadata == null || metadata.isPrivate;

    if (isPrivateOrUnclassified && !reminder.allowSensitiveText) {
      return (title: genericPrivateTitle, body: genericPrivateBody);
    }

    String? habitName;
    if (versionId != null) {
      final row = await _db
          .customSelect(
            'SELECT name FROM habit_versions WHERE id = ?',
            variables: [Variable<String>(versionId)],
          )
          .getSingleOrNull();
      habitName = row?.read<String>('name');
    }

    final title = habitName ?? 'Hibi reminder';
    final body =
        reminder.customMessage ??
        'Scheduled check-in at ${reminder.formattedTime}.';
    return (title: title, body: body);
  }

  Future<void> _updateScheduleMode(String reminderId, String mode) async {
    final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      UPDATE habit_reminders
      SET last_schedule_mode = ?, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [mode, nowUs, reminderId],
    );
  }

  HabitReminder _mapRow(QueryRow row) => HabitReminder(
    id: row.read<String>('id'),
    habitId: row.read<String>('habit_id'),
    hour: row.read<int>('hour'),
    minute: row.read<int>('minute'),
    isEnabled: row.read<int>('is_enabled') == 1,
    allowSensitiveText: row.read<int>('allow_sensitive_text') == 1,
    customMessage: row.readNullable<String>('custom_message'),
    lastScheduleMode: row.read<String>('last_schedule_mode'),
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('created_at_utc_us'),
      isUtc: true,
    ),
    updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('updated_at_utc_us'),
      isUtc: true,
    ),
  );
}

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
