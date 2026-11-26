import '../../../core/database/app_database.dart';
import '../domain/counter_day_status.dart';
import '../domain/counter_range_summary.dart';
import '../domain/habit_schedule.dart';
import 'counter_configuration_reader.dart';
import 'counter_day_reader.dart';
import 'counter_history_reader.dart';

/// Complete read-only overview of a counter habit on a reference date and
/// across a requested local date range.
class CounterHabitOverview {
  const CounterHabitOverview({
    required this.configuration,
    required this.asOfEvaluation,
    required this.rangeHistory,
    required this.rangeSummary,
    required this.recoverableDeficits,
  });

  final CounterHabitConfiguration configuration;
  final CounterDayEvaluation asOfEvaluation;
  final List<CounterDateHistoryItem> rangeHistory;
  final CounterRangeSummary rangeSummary;
  final List<CounterRecoverableDeficit> recoverableDeficits;
}

/// Composes counter habit configuration, as-of day evaluation, date-range
/// history, range summary and recoverable deficits in one read transaction.
class CounterHabitOverviewReader {
  const CounterHabitOverviewReader(this._db);

  final AppDatabase _db;

  Future<CounterHabitOverview> read({
    required String habitId,
    required LocalDate asOfDate,
    required LocalDate rangeStartInclusive,
    required LocalDate rangeEndInclusive,
  }) {
    if (rangeEndInclusive.compareTo(rangeStartInclusive) < 0) {
      throw ArgumentError(
        'rangeEndInclusive must not precede rangeStartInclusive',
      );
    }
    return _db.transaction(() async {
      final configuration = await CounterConfigurationReader(_db)
          .read(habitId: habitId, asOfDate: asOfDate);
      final asOfEvaluation = await CounterDayReader(_db)
          .evaluate(habitId: habitId, date: asOfDate);
      final historyReader = CounterHistoryReader(_db);
      final rangeHistory = await historyReader.readRange(
        habitId: habitId,
        startInclusive: rangeStartInclusive,
        endInclusive: rangeEndInclusive,
      );
      final rangeSummary = CounterRangeSummary.fromEvaluations(
        rangeHistory.map((item) => item.evaluation),
      );
      final recoverableDeficits = await historyReader.findRecoverableDeficits(
        habitId: habitId,
        asOfDate: asOfDate,
      );
      return CounterHabitOverview(
        configuration: configuration,
        asOfEvaluation: asOfEvaluation,
        rangeHistory: rangeHistory,
        rangeSummary: rangeSummary,
        recoverableDeficits: recoverableDeficits,
      );
    });
  }
}
