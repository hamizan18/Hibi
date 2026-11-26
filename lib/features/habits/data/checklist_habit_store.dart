import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/checklist_habit.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
import 'habit_schedule_store.dart';

typedef ChecklistDayView = ({
  HabitApplicability applicability,
  String? occurrenceId,
  ChecklistDayProgress? progress,
});

/// Transactional creation, per-item logging, prior-item recovery and read-only
/// day evaluation for independent multi-checklist habits.
class ChecklistHabitService {
  const ChecklistHabitService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> create({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required List<ChecklistItemDefinition> items,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    if (items.isEmpty) {
      throw ArgumentError('Checklist habit requires at least one item');
    }
    final now = _clock.now();
    final startDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    final startKey = _dateKey(startDate);
    if (startKey.compareTo(_dateKey(_localDate(now))) < 0) {
      throw StateError('Backdated checklist creation requires correction');
    }
    final timestamp = now.toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      'INSERT INTO habits (id, created_at_utc_us) VALUES (?, ?)',
      [habitId, timestamp],
    );
    await _db.customStatement(
      '''
      INSERT INTO habit_versions
        (id, habit_id, name, effective_start, effective_end, created_at_utc_us, revision)
      VALUES (?, ?, ?, ?, NULL, ?, 1)
      ''',
      [versionId, habitId, name.trim(), startKey, timestamp],
    );
    for (final item in items) {
      await _db.customStatement(
        '''
        INSERT INTO habit_checklist_items
          (id, habit_version_id, label, display_order, recovery_enabled)
        VALUES (?, ?, ?, ?, ?)
        ''',
        [
          item.id,
          versionId,
          item.label,
          item.displayOrder,
          item.recoveryEnabled ? 1 : 0,
        ],
      );
    }
    if (metadata != null) {
      await HabitMetadataStore(_db).insert(versionId, metadata);
    }
    await HabitScheduleStore(_db).insert(versionId, schedule);
    await HabitLifecycleStore(_db, _CapturedClock(now)).append(
      id: lifecycleEventId,
      habitId: habitId,
      effectiveDate: startDate,
      state: HabitLifecycleState.active,
    );
  });

  Future<void> createFromStarterTemplate({
    required ChecklistStarterTemplate template,
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required List<String> itemIds,
    required DateTime effectiveDate,
    HabitSchedule? schedule,
    HabitMetadata? metadata,
  }) {
    if (itemIds.length != template.itemLabels.length) {
      throw ArgumentError(
        'itemIds length (${itemIds.length}) must match itemLabels length (${template.itemLabels.length})',
      );
    }
    final startDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    return create(
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      name: template.name,
      effectiveDate: effectiveDate,
      items: [
        for (var i = 0; i < template.itemLabels.length; i++)
          ChecklistItemDefinition(
            id: itemIds[i],
            label: template.itemLabels[i],
            displayOrder: i,
            recoveryEnabled: template.recoveryEnabled,
          ),
      ],
      schedule: schedule ?? template.defaultSchedule(startDate: startDate),
      metadata:
          metadata ??
          HabitMetadata(
            symbol: template.symbol,
            category: 'Spiritual',
            recoveryEnabled: template.recoveryEnabled,
          ),
    );
  }

  Future<ChecklistDayView> logItemToday({
    required String habitId,
    required String occurrenceId,
    required String logId,
    required String itemId,
    required ChecklistItemLogState state,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final todayKey = _dateKey(today);
    final detail = await HabitApplicabilityReader(_db).describe(habitId, today);
    if (detail.applicability != HabitApplicability.applicable ||
        detail.versionId == null) {
      throw StateError('Checklist habit is not applicable today');
    }
    final versionId = detail.versionId!;
    final itemRow = await _db
        .customSelect(
          'SELECT id FROM habit_checklist_items WHERE id = ? AND habit_version_id = ?',
          variables: [Variable<String>(itemId), Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (itemRow == null) {
      throw StateError('Checklist item does not belong to applicable version');
    }

    final existingOcc = await _db
        .customSelect(
          'SELECT id FROM habit_checklist_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(todayKey)],
        )
        .getSingleOrNull();
    final actualOccId = existingOcc?.read<String>('id') ?? occurrenceId;
    if (existingOcc == null) {
      await _db.customStatement(
        '''
        INSERT INTO habit_checklist_occurrences (id, habit_id, habit_version_id, local_date)
        VALUES (?, ?, ?, ?)
        ''',
        [actualOccId, habitId, versionId, todayKey],
      );
    }

    await _db.customStatement(
      '''
      INSERT INTO habit_checklist_item_logs
        (id, occurrence_id, item_id, state, reason, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        logId,
        actualOccId,
        itemId,
        state.name,
        reason,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return readDay(habitId: habitId, date: today);
  });

  Future<ChecklistDayView> recoverFailedItem({
    required String recoveryId,
    required String occurrenceId,
    required String itemId,
    String? note,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final todayKey = _dateKey(today);

    final occRow = await _db
        .customSelect(
          'SELECT habit_id, habit_version_id, local_date FROM habit_checklist_occurrences WHERE id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    if (occRow == null) {
      throw StateError('Checklist occurrence does not exist');
    }
    final habitId = occRow.read<String>('habit_id');
    final occDateKey = occRow.read<String>('local_date');
    if (occDateKey.compareTo(todayKey) >= 0) {
      throw StateError('Only prior-date checklist items can be recovered');
    }

    final lifecycle = await HabitLifecycleReader(_db)
        .findEffectiveOn(habitId, today);
    if (lifecycle == null || lifecycle.state != HabitLifecycleState.active) {
      throw StateError('Habit must be active on the recovery date');
    }

    final itemRow = await _db
        .customSelect(
          'SELECT recovery_enabled FROM habit_checklist_items WHERE id = ? AND habit_version_id = ?',
          variables: [
            Variable<String>(itemId),
            Variable<String>(occRow.read<String>('habit_version_id')),
          ],
        )
        .getSingleOrNull();
    if (itemRow == null || itemRow.read<int>('recovery_enabled') != 1) {
      throw StateError('Checklist item is not eligible for recovery');
    }

    final logRow = await _db
        .customSelect(
          'SELECT id, state FROM habit_checklist_item_logs WHERE occurrence_id = ? AND item_id = ?',
          variables: [Variable<String>(occurrenceId), Variable<String>(itemId)],
        )
        .getSingleOrNull();
    if (logRow == null || logRow.read<String>('state') != 'failed') {
      throw StateError(
        'Only explicitly failed checklist items can be recovered',
      );
    }

    await _db.customStatement(
      '''
      INSERT INTO habit_checklist_item_recoveries
        (id, item_log_id, occurrence_id, item_id, recovery_local_date, note, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        recoveryId,
        logRow.read<String>('id'),
        occurrenceId,
        itemId,
        todayKey,
        note,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return readDay(habitId: habitId, date: _parseDate(occDateKey));
  });

  Future<ChecklistDayView> readDay({
    required String habitId,
    required LocalDate date,
  }) => _db.transaction(() async {
    final applicability = await HabitApplicabilityReader(_db)
        .evaluate(habitId, date);
    final key = _dateKey(date);
    final occRow = await _db
        .customSelect(
          'SELECT id, habit_version_id FROM habit_checklist_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(key)],
        )
        .getSingleOrNull();
    if (occRow == null) {
      return (applicability: applicability, occurrenceId: null, progress: null);
    }
    final occId = occRow.read<String>('id');
    final versionId = occRow.read<String>('habit_version_id');
    final itemRows = await _db
        .customSelect(
          '''
      SELECT id, label, display_order, recovery_enabled
      FROM habit_checklist_items
      WHERE habit_version_id = ?
      ORDER BY display_order ASC, id ASC
      ''',
          variables: [Variable<String>(versionId)],
        )
        .get();
    final definitions = [
      for (final row in itemRows)
        ChecklistItemDefinition(
          id: row.read<String>('id'),
          label: row.read<String>('label'),
          displayOrder: row.read<int>('display_order'),
          recoveryEnabled: row.read<int>('recovery_enabled') == 1,
        ),
    ];
    final logRows = await _db
        .customSelect(
          'SELECT item_id, state FROM habit_checklist_item_logs WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .get();
    final loggedStates = <String, ChecklistItemLogState>{
      for (final row in logRows)
        row.read<String>('item_id'): ChecklistItemLogState.values.byName(
          row.read<String>('state'),
        ),
    };
    final recRows = await _db
        .customSelect(
          'SELECT item_id FROM habit_checklist_item_recoveries WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .get();
    final recoveredIds = <String>{
      for (final row in recRows) row.read<String>('item_id'),
    };
    return (
      applicability: applicability,
      occurrenceId: occId,
      progress: ChecklistDayProgress.evaluate(
        definitions: definitions,
        loggedStates: loggedStates,
        recoveredItemIds: recoveredIds,
      ),
    );
  });
}

LocalDate _localDate(DateTime instant) {
  final local = instant.toLocal();
  return LocalDate(local.year, local.month, local.day);
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);

class _CapturedClock implements AppClock {
  const _CapturedClock(this.instant);
  final DateTime instant;

  @override
  DateTime now() => instant;
}
