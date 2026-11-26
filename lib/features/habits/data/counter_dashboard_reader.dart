import '../../../core/database/app_database.dart';
import '../domain/counter_range_summary.dart';
import '../domain/habit_schedule.dart';
import 'counter_day_roster_reader.dart';
import 'counter_history_reader.dart';
import 'habit_lifecycle.dart';

/// Per-habit dashboard entry combining day roster status, specific applicability
/// reason and any prior failed occurrences eligible for recovery on that date.
class CounterDashboardHabitItem {
  const CounterDashboardHabitItem({
    required this.rosterItem,
    required this.applicabilityDetail,
    required this.recoverableDeficits,
  });

  final CounterDayRosterItem rosterItem;
  final HabitApplicabilityDetail applicabilityDetail;
  final List<CounterRecoverableDeficit> recoverableDeficits;
}

/// Complete read-only multi-habit counter dashboard snapshot for a local date.
class CounterDashboardSummary {
  const CounterDashboardSummary({
    required this.date,
    required this.items,
    required this.daySummary,
    required this.totalRecoverableDeficitCount,
    required this.totalRecoverableDeficitQuantity,
  });

  final LocalDate date;
  final List<CounterDashboardHabitItem> items;
  final CounterRangeSummary daySummary;
  final int totalRecoverableDeficitCount;
  final int totalRecoverableDeficitQuantity;
}

/// Evaluates all stored counter habits on a local date together with their
/// applicability details and prior recoverable deficits in one read transaction.
class CounterDashboardReader {
  const CounterDashboardReader(this._db);

  final AppDatabase _db;

  Future<CounterDashboardSummary> readForDate(LocalDate date) =>
      _db.transaction(() async {
        const maximum = 9223372036854775807;
        final roster = await CounterDayRosterReader(_db).readForDate(date);
        final applicabilityReader = HabitApplicabilityReader(_db);
        final historyReader = CounterHistoryReader(_db);

        final items = <CounterDashboardHabitItem>[];
        var deficitCount = 0;
        var deficitQuantity = 0;

        for (final rosterItem in roster) {
          final detail = await applicabilityReader.describe(
            rosterItem.habitId,
            date,
          );
          final deficits = await historyReader.findRecoverableDeficits(
            habitId: rosterItem.habitId,
            asOfDate: date,
          );
          deficitCount += deficits.length;
          for (final deficit in deficits) {
            if (deficit.remainingDeficit > maximum - deficitQuantity) {
              throw RangeError(
                'Total recoverable deficit exceeds signed 64-bit range',
              );
            }
            deficitQuantity += deficit.remainingDeficit;
          }
          items.add(
            CounterDashboardHabitItem(
              rosterItem: rosterItem,
              applicabilityDetail: detail,
              recoverableDeficits: deficits,
            ),
          );
        }

        final daySummary = CounterRangeSummary.fromEvaluations(
          roster.map((item) => item.evaluation),
        );

        return CounterDashboardSummary(
          date: date,
          items: List.unmodifiable(items),
          daySummary: daySummary,
          totalRecoverableDeficitCount: deficitCount,
          totalRecoverableDeficitQuantity: deficitQuantity,
        );
      });
}
