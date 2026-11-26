import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/counter_day_reader.dart';
import '../data/counter_day_roster_reader.dart';
import '../data/counter_habit_writer.dart';
import '../data/counter_history_reader.dart';
import '../data/counter_occurrence_store.dart';
import '../data/counter_progress_reader.dart';
import '../data/counter_progress_writer.dart';
import '../data/counter_recovery_store.dart';
import '../data/counter_resolution.dart';
import '../data/counter_today_action_service.dart';
import '../data/habit_lifecycle.dart';
import '../domain/habit_schedule.dart';

final habitLifecycleStoreProvider = Provider<HabitLifecycleStore>(
  (ref) => HabitLifecycleStore(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);

final habitLifecycleReaderProvider = Provider<HabitLifecycleReader>(
  (ref) => HabitLifecycleReader(ref.watch(databaseProvider)),
);

final habitApplicabilityReaderProvider = Provider<HabitApplicabilityReader>(
  (ref) => HabitApplicabilityReader(ref.watch(databaseProvider)),
);

final counterHabitWriterProvider = Provider<CounterHabitWriter>(
  (ref) => CounterHabitWriter(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);

final counterOccurrenceStoreProvider = Provider<CounterOccurrenceStore>(
  (ref) => CounterOccurrenceStore(ref.watch(databaseProvider)),
);

final counterProgressReaderProvider = Provider<CounterProgressReader>(
  (ref) => CounterProgressReader(ref.watch(databaseProvider)),
);

final counterProgressWriterProvider = Provider<CounterProgressWriter>(
  (ref) => CounterProgressWriter(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);

final counterResolutionReaderProvider = Provider<CounterResolutionReader>(
  (ref) => CounterResolutionReader(ref.watch(databaseProvider)),
);

final counterResolutionWriterProvider = Provider<CounterResolutionWriter>(
  (ref) => CounterResolutionWriter(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);

final counterRecoveryReaderProvider = Provider<CounterRecoveryReader>(
  (ref) => CounterRecoveryReader(ref.watch(databaseProvider)),
);

final counterRecoveryWriterProvider = Provider<CounterRecoveryWriter>(
  (ref) => CounterRecoveryWriter(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);

final counterDayReaderProvider = Provider<CounterDayReader>(
  (ref) => CounterDayReader(ref.watch(databaseProvider)),
);

final counterDayRosterReaderProvider = Provider<CounterDayRosterReader>(
  (ref) => CounterDayRosterReader(ref.watch(databaseProvider)),
);

final counterHistoryReaderProvider = Provider<CounterHistoryReader>(
  (ref) => CounterHistoryReader(ref.watch(databaseProvider)),
);

final counterTodayActionServiceProvider = Provider<CounterTodayActionService>(
  (ref) => CounterTodayActionService(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);

/// Read-only roster evaluation for any requested local date.
final counterDayRosterProvider = FutureProvider.autoDispose
    .family<List<CounterDayRosterItem>, LocalDate>(
      (ref, date) =>
          ref.watch(counterDayRosterReaderProvider).readForDate(date),
    );

/// Read-only roster evaluation for the current local date from appClockProvider.
final counterTodayRosterProvider =
    FutureProvider.autoDispose<List<CounterDayRosterItem>>((ref) {
      final now = ref.watch(appClockProvider).now().toLocal();
      final today = LocalDate(now.year, now.month, now.day);
      return ref.watch(counterDayRosterReaderProvider).readForDate(today);
    });
