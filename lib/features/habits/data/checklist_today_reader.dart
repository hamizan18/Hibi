import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/checklist_habit.dart';

/// Reads the definitions for a known applicable version without creating a day.
class ChecklistTodayReader {
  const ChecklistTodayReader(this._db);

  final AppDatabase _db;

  Future<List<ChecklistItemDefinition>> readDefinitions(
    String versionId,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT id, label, display_order, recovery_enabled '
          'FROM habit_checklist_items WHERE habit_version_id = ? '
          'ORDER BY display_order, id',
          variables: [Variable<String>(versionId)],
        )
        .get();
    return [
      for (final row in rows)
        ChecklistItemDefinition(
          id: row.read<String>('id'),
          label: row.read<String>('label'),
          displayOrder: row.read<int>('display_order'),
          recoveryEnabled: row.read<int>('recovery_enabled') == 1,
        ),
    ];
  }
}

/// Inspects the immutable confirmation snapshot without modifying an occurrence.
class AvoidanceTodayReader {
  const AvoidanceTodayReader(this._db);

  final AppDatabase _db;

  Future<int?> readResolutionIncidentCount(String occurrenceId) async {
    final row = await _db
        .customSelect(
          'SELECT incident_count_snapshot FROM habit_avoidance_resolutions WHERE occurrence_id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    return row?.read<int>('incident_count_snapshot');
  }
}
