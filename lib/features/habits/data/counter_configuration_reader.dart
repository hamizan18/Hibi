import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/counter_target.dart';
import '../domain/habit_schedule.dart';
import 'counter_target_store.dart';
import 'habit_lifecycle.dart';
import 'habit_schedule_store.dart';

/// Read-only snapshot of a habit version and its optional counter target and schedule.
class CounterVersionSnapshot {
  const CounterVersionSnapshot({
    required this.versionId,
    required this.habitId,
    required this.name,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.revision,
    required this.createdAtUtc,
    required this.target,
    required this.schedule,
  });

  final String versionId;
  final String habitId;
  final String name;
  final LocalDate effectiveStart;
  final LocalDate? effectiveEnd;
  final int revision;
  final DateTime createdAtUtc;
  final CounterTarget? target;
  final HabitSchedule? schedule;

  bool get isFullyConfigured => target != null && schedule != null;
}

/// Complete read-only configuration and version timeline for a counter habit as of a local date.
class CounterHabitConfiguration {
  const CounterHabitConfiguration({
    required this.habitId,
    required this.createdAtUtc,
    required this.asOfDate,
    required this.applicability,
    required this.effectiveLifecycle,
    required this.lifecycleHistory,
    required this.effectiveVersion,
    required this.priorVersions,
    required this.futureVersions,
    required this.allVersions,
  });

  final String habitId;
  final DateTime createdAtUtc;
  final LocalDate asOfDate;
  final HabitApplicabilityDetail applicability;
  final HabitLifecycleEvent? effectiveLifecycle;
  final List<HabitLifecycleEvent> lifecycleHistory;
  final CounterVersionSnapshot? effectiveVersion;
  final List<CounterVersionSnapshot> priorVersions;
  final List<CounterVersionSnapshot> futureVersions;
  final List<CounterVersionSnapshot> allVersions;
}

/// Reads a counter habit's configuration, lifecycle history and version timeline
/// in one transaction without mutating data or inferring missing defaults.
class CounterConfigurationReader {
  const CounterConfigurationReader(this._db);

  final AppDatabase _db;

  Future<CounterHabitConfiguration> read({
    required String habitId,
    required LocalDate asOfDate,
  }) => _db.transaction(() => _readForHabit(habitId, asOfDate));

  Future<List<CounterHabitConfiguration>> readAll({
    required LocalDate asOfDate,
  }) => _db.transaction(() async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM habits ORDER BY created_at_utc_us ASC, id ASC',
        )
        .get();
    final configs = <CounterHabitConfiguration>[];
    for (final row in rows) {
      configs.add(await _readForHabit(row.read<String>('id'), asOfDate));
    }
    return List.unmodifiable(configs);
  });

  Future<CounterHabitConfiguration> _readForHabit(
    String habitId,
    LocalDate asOfDate,
  ) async {
    final habit = await _db
        .customSelect(
          'SELECT id, created_at_utc_us FROM habits WHERE id = ?',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    if (habit == null) throw StateError('Habit does not exist');

    final versionRows = await _db
        .customSelect(
          '''
      SELECT id, name, effective_start, effective_end, created_at_utc_us, revision
      FROM habit_versions
      WHERE habit_id = ?
      ORDER BY effective_start ASC, revision ASC
      ''',
          variables: [Variable<String>(habitId)],
        )
        .get();

    final targetStore = CounterTargetStore(_db);
    final scheduleStore = HabitScheduleStore(_db);
    final allVersions = <CounterVersionSnapshot>[];
    final priorVersions = <CounterVersionSnapshot>[];
    final futureVersions = <CounterVersionSnapshot>[];
    CounterVersionSnapshot? effectiveVersion;

    for (final row in versionRows) {
      final versionId = row.read<String>('id');
      final start = _parseDate(row.read<String>('effective_start'));
      final rawEnd = row.readNullable<String>('effective_end');
      final end = rawEnd == null ? null : _parseDate(rawEnd);
      final snapshot = CounterVersionSnapshot(
        versionId: versionId,
        habitId: habitId,
        name: row.read<String>('name'),
        effectiveStart: start,
        effectiveEnd: end,
        revision: row.read<int>('revision'),
        createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.read<int>('created_at_utc_us'),
          isUtc: true,
        ),
        target: await targetStore.findForVersion(versionId),
        schedule: await scheduleStore.findForVersion(versionId),
      );
      allVersions.add(snapshot);
      if (start.compareTo(asOfDate) > 0) {
        futureVersions.add(snapshot);
      } else if (end != null && end.compareTo(asOfDate) <= 0) {
        priorVersions.add(snapshot);
      } else {
        effectiveVersion = snapshot;
      }
    }

    final lifecycleReader = HabitLifecycleReader(_db);
    final effectiveLifecycle = await lifecycleReader.findEffectiveOn(
      habitId,
      asOfDate,
    );
    final lifecycleHistory = await lifecycleReader.readHistory(habitId);
    final applicability = await HabitApplicabilityReader(_db)
        .describe(habitId, asOfDate);

    return CounterHabitConfiguration(
      habitId: habitId,
      createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        habit.read<int>('created_at_utc_us'),
        isUtc: true,
      ),
      asOfDate: asOfDate,
      applicability: applicability,
      effectiveLifecycle: effectiveLifecycle,
      lifecycleHistory: lifecycleHistory,
      effectiveVersion: effectiveVersion,
      priorVersions: List.unmodifiable(priorVersions),
      futureVersions: List.unmodifiable(futureVersions),
      allVersions: List.unmodifiable(allVersions),
    );
  }
}

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
