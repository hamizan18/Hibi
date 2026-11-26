import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_schedule.dart';
import 'counter_history_reader.dart';
import 'counter_today_action_service.dart';
import 'habit_metadata_store.dart';

/// Filters historical deficits by the metadata of their original version.
class CounterRecoveryEligibility {
  const CounterRecoveryEligibility(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<List<CounterRecoverableDeficit>> find({
    required String habitId,
    required LocalDate asOfDate,
  }) => _db.transaction(() async {
    final deficits = await CounterHistoryReader(_db)
        .findRecoverableDeficits(habitId: habitId, asOfDate: asOfDate);
    final metadata = HabitMetadataStore(_db);
    final enabled = <String, bool>{};
    final result = <CounterRecoverableDeficit>[];
    for (final deficit in deficits) {
      var allowed = enabled[deficit.versionId];
      if (allowed == null) {
        allowed =
            (await metadata.findForVersion(deficit.versionId))
                ?.recoveryEnabled ==
            true;
        enabled[deficit.versionId] = allowed;
      }
      if (allowed) result.add(deficit);
    }
    return List.unmodifiable(result);
  });

  Future<void> recover({
    required String habitId,
    required LocalDate date,
    required String occurrenceId,
    required String recoveryId,
    required int quantity,
  }) => _db.transaction(() async {
    if (quantity <= 0) throw StateError('Enter a positive whole number.');
    final eligible = await find(habitId: habitId, asOfDate: date);
    final matches = eligible.where((item) => item.occurrenceId == occurrenceId);
    if (matches.isEmpty || quantity > matches.first.remainingDeficit) {
      throw StateError(
        'This deficit is no longer eligible or the quantity is too large.',
      );
    }
    final now = _clock.now();
    final local = now.toLocal();
    if (LocalDate(local.year, local.month, local.day).compareTo(date) != 0) {
      throw StateError('The selected day is no longer today.');
    }
    await CounterTodayActionService(_db, _FixedClock(now)).recoverPriorDeficit(
      recoveryId: recoveryId,
      occurrenceId: occurrenceId,
      quantity: quantity,
    );
  });
}

class _FixedClock implements AppClock {
  const _FixedClock(this.instant);
  final DateTime instant;
  @override
  DateTime now() => instant;
}
