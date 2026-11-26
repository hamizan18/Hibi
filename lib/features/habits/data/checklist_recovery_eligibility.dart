import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_schedule.dart';
import 'checklist_habit_store.dart';
import 'habit_lifecycle.dart';

class ChecklistRecoveryCandidate {
  const ChecklistRecoveryCandidate({
    required this.occurrenceId,
    required this.itemId,
    required this.label,
    required this.date,
    required this.isPrivate,
  });

  final String occurrenceId;
  final String itemId;
  final String label;
  final LocalDate date;
  final bool isPrivate;
}

/// Reads and revalidates historical item recovery without creating occurrences.
class ChecklistRecoveryEligibility {
  const ChecklistRecoveryEligibility(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<List<ChecklistRecoveryCandidate>> read({
    required String habitId,
    required LocalDate date,
  }) => _db.transaction(() => _eligible(habitId, date));

  Future<List<ChecklistRecoveryCandidate>> _eligible(
    String habitId,
    LocalDate date,
  ) async {
    if (!_isToday(date, _clock.now())) return [];
    final lifecycle = await HabitLifecycleReader(_db)
        .findEffectiveOn(habitId, date);
    if (lifecycle?.state != HabitLifecycleState.active) return [];
    final rows = await _db
        .customSelect(
          '''
      SELECT o.id AS occurrence_id, o.habit_version_id, o.local_date,
             i.id AS item_id, i.label, m.is_private
      FROM habit_checklist_occurrences o
      JOIN habit_checklist_items i ON i.habit_version_id = o.habit_version_id
      JOIN habit_checklist_item_logs l ON l.occurrence_id = o.id AND l.item_id = i.id
      JOIN habit_version_metadata m ON m.habit_version_id = o.habit_version_id
      WHERE o.habit_id = ? AND o.local_date < ?
        AND i.recovery_enabled = 1 AND m.recovery_enabled = 1
        AND l.state = 'failed'
        AND NOT EXISTS (SELECT 1 FROM habit_checklist_item_recoveries r
                        WHERE r.occurrence_id = o.id AND r.item_id = i.id)
      ORDER BY o.local_date DESC, i.display_order, i.id
    ''',
          variables: [Variable<String>(habitId), Variable<String>(_key(date))],
        )
        .get();
    final candidates = <ChecklistRecoveryCandidate>[];
    for (final row in rows) {
      final historicalDate = _parseDate(row.read<String>('local_date'));
      final detail = await HabitApplicabilityReader(_db)
          .describe(habitId, historicalDate);
      if (detail.applicability != HabitApplicability.applicable ||
          detail.versionId != row.read<String>('habit_version_id')) {
        continue;
      }
      candidates.add(
        ChecklistRecoveryCandidate(
          occurrenceId: row.read<String>('occurrence_id'),
          itemId: row.read<String>('item_id'),
          label: row.read<String>('label'),
          date: historicalDate,
          isPrivate: row.read<int>('is_private') == 1,
        ),
      );
    }
    return candidates;
  }

  Future<void> recover({
    required String habitId,
    required LocalDate date,
    required String occurrenceId,
    required String itemId,
    required String recoveryId,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final capturedClock = _FixedClock(now);
    final candidates = await ChecklistRecoveryEligibility(
      _db,
      capturedClock,
    )._eligible(habitId, date);
    if (!_isToday(date, now) ||
        !candidates.any(
          (candidate) =>
              candidate.occurrenceId == occurrenceId &&
              candidate.itemId == itemId,
        )) {
      throw StateError('Checklist item is no longer eligible for recovery');
    }
    await ChecklistHabitService(_db, capturedClock).recoverFailedItem(
      recoveryId: recoveryId,
      occurrenceId: occurrenceId,
      itemId: itemId,
    );
  });
}

bool _isToday(LocalDate date, DateTime now) {
  final local = now.toLocal();
  return date.year == local.year &&
      date.month == local.month &&
      date.day == local.day;
}

class _FixedClock implements AppClock {
  const _FixedClock(this.instant);
  final DateTime instant;
  @override
  DateTime now() => instant;
}

String _key(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
