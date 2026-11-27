import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
import 'habit_schedule_store.dart';

enum HabitTrackingType {
  unconfigured,
  counter,
  checklist,
  avoidance,
  boolean,
  duration,
  measurement,
  timeOfDay,
  range,
}

class UnifiedHabitSummary {
  const UnifiedHabitSummary({
    required this.habitId,
    required this.versionId,
    required this.name,
    required this.trackingType,
    required this.metadata,
    required this.schedule,
    required this.applicability,
  });

  final String habitId;
  final String? versionId;
  final String? name;
  final HabitTrackingType trackingType;
  final HabitMetadata? metadata;
  final HabitSchedule? schedule;
  final HabitApplicabilityDetail applicability;
}

/// Read-only registry for a local date. Before the first version starts, its
/// configuration is shown for management; applicability still describes the
/// requested date. Version gaps do not fall forward to a future version.
class UnifiedHabitRegistryReader {
  const UnifiedHabitRegistryReader(this._db);

  final AppDatabase _db;

  Future<List<UnifiedHabitSummary>> readAll({required LocalDate asOfDate}) =>
      _db.transaction(() async {
        final key = _dateKey(asOfDate);
        final habits = await _db
            .customSelect(
              'SELECT id FROM habits ORDER BY created_at_utc_us ASC, id ASC',
            )
            .get();
        final metadataStore = HabitMetadataStore(_db);
        final scheduleStore = HabitScheduleStore(_db);
        final applicabilityReader = HabitApplicabilityReader(_db);
        final summaries = <UnifiedHabitSummary>[];

        for (final habit in habits) {
          final habitId = habit.read<String>('id');
          final applicability = await applicabilityReader.describe(
            habitId,
            asOfDate,
          );
          final versionRow =
              applicability.reason == HabitApplicabilityReason.beforeStart
              ? await _db
                    .customSelect(
                      'SELECT id, name FROM habit_versions WHERE habit_id = ? ORDER BY effective_start ASC LIMIT 1',
                      variables: [Variable<String>(habitId)],
                    )
                    .getSingleOrNull()
              : await _db
                    .customSelect(
                      '''
            SELECT id, name
            FROM habit_versions
            WHERE habit_id = ? AND effective_start <= ?
              AND (effective_end IS NULL OR ? < effective_end)
            ''',
                      variables: [
                        Variable<String>(habitId),
                        Variable<String>(key),
                        Variable<String>(key),
                      ],
                    )
                    .getSingleOrNull();
          final versionId = versionRow?.read<String>('id');
          final trackingType = versionId == null
              ? HabitTrackingType.unconfigured
              : await _detectTrackingType(versionId);
          final metadata = versionId == null
              ? null
              : await metadataStore.findForVersion(versionId);
          final schedule = versionId == null
              ? null
              : await scheduleStore.findForVersion(versionId);
          summaries.add(
            UnifiedHabitSummary(
              habitId: habitId,
              versionId: versionId,
              name: versionRow?.read<String>('name'),
              trackingType: trackingType,
              metadata: metadata,
              schedule: schedule,
              applicability: applicability,
            ),
          );
        }
        return List.unmodifiable(summaries);
      });

  Future<HabitTrackingType> _detectTrackingType(String versionId) async {
    final counter = await _db
        .customSelect(
          'SELECT 1 FROM habit_counter_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (counter != null) return HabitTrackingType.counter;

    final checklist = await _db
        .customSelect(
          'SELECT 1 FROM habit_checklist_items WHERE habit_version_id = ? LIMIT 1',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (checklist != null) return HabitTrackingType.checklist;

    final avoidance = await _db
        .customSelect(
          'SELECT 1 FROM habit_avoidance_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (avoidance != null) return HabitTrackingType.avoidance;

    final typed = await _db
        .customSelect(
          'SELECT tracking_type FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    return switch (typed?.read<String>('tracking_type')) {
      'boolean' => HabitTrackingType.boolean,
      'duration' => HabitTrackingType.duration,
      'measurement' => HabitTrackingType.measurement,
      'time_of_day' => HabitTrackingType.timeOfDay,
      'range' => HabitTrackingType.range,
      _ => HabitTrackingType.unconfigured,
    };
  }
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
