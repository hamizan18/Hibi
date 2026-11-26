import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/counter_progress.dart';

/// Reads an occurrence's snapshot and recorded events without modifying them.
/// Applicability and explicit status overrides are separate concerns.
class CounterProgressReader {
  const CounterProgressReader(this._db);

  final AppDatabase _db;

  Future<({CounterProgress progress, String unit})?> find(
    String occurrenceId,
  ) async {
    final rows = await _db
        .customSelect(
          '''
      SELECT o.target_count, o.unit, e.quantity
      FROM habit_occurrences o
      LEFT JOIN habit_counter_events e ON e.occurrence_id = o.id
      WHERE o.id = ?
      ''',
          variables: [Variable<String>(occurrenceId)],
        )
        .get();
    if (rows.isEmpty) return null;
    final quantities = rows
        .map((row) => row.readNullable<int>('quantity'))
        .whereType<int>();
    return (
      progress: CounterProgress.fromEvents(
        target: rows.first.read<int>('target_count'),
        quantities: quantities,
      ),
      unit: rows.first.read<String>('unit'),
    );
  }
}
