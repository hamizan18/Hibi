import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/dynamic_normalized_scoring.dart';

/// Persists the scoring rules selected for an individual habit version.
class HabitScoringStore {
  const HabitScoringStore(this._db);

  final AppDatabase _db;

  Future<void> insert(String versionId, HabitScoringConfig config) {
    final tolerance = config.tolerance;
    if (config.type != DynamicScoreType.measurement &&
        (tolerance == null || tolerance <= 0)) {
      throw ArgumentError.value(tolerance, 'tolerance', 'Must be positive');
    }
    final type = switch (config.type) {
      DynamicScoreType.measurement => 'measurement',
      DynamicScoreType.timeOfDay => 'time_of_day',
      DynamicScoreType.range => 'range',
    };
    return _db.customStatement(
      'INSERT INTO habit_version_scoring '
      '(habit_version_id, tracking_type, rule_version, tolerance) VALUES (?, ?, 1, ?)',
      [versionId, type, tolerance],
    );
  }

  Future<HabitScoringConfig?> findForVersion(String versionId) async {
    final row = await _db
        .customSelect(
          'SELECT tracking_type, rule_version, tolerance FROM habit_version_scoring '
          'WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (row == null || row.read<int>('rule_version') != 1) return null;
    final tolerance = row.readNullable<int>('tolerance');
    return switch (row.read<String>('tracking_type')) {
      'measurement' when tolerance == null =>
        const HabitScoringConfig.measurement(),
      'time_of_day' when tolerance != null && tolerance > 0 =>
        HabitScoringConfig.timeOfDay(toleranceMinutes: tolerance),
      'range' when tolerance != null && tolerance > 0 =>
        HabitScoringConfig.range(toleranceScaled: tolerance),
      _ => null,
    };
  }
}
