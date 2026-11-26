import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/counter_target.dart';

/// Low-level storage only. Do not expose writes until historical corrections
/// and audit rules are implemented by an application service.
class CounterTargetStore {
  const CounterTargetStore(this._database);

  final AppDatabase _database;

  Future<void> insert(String versionId, CounterTarget target) =>
      _database.customStatement(
        'INSERT INTO habit_counter_targets (habit_version_id, target_count, unit) VALUES (?, ?, ?)',
        [versionId, target.count, target.unit],
      );

  Future<CounterTarget?> findForVersion(String versionId) async {
    final row = await _database
        .customSelect(
          'SELECT target_count, unit FROM habit_counter_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return CounterTarget(
      count: row.read<int>('target_count'),
      unit: row.read<String>('unit'),
    );
  }
}
