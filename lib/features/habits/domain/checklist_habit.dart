import 'habit_schedule.dart';

enum ChecklistItemLogState { completed, failed, excused }

enum ChecklistItemEffectiveState {
  pending,
  completed,
  failed,
  excused,
  recovered,
}

enum ChecklistOccurrenceStatus {
  pending,
  partial,
  completed,
  failed,
  recovered,
  excused,
}

/// Definition of a single independent checklist item within a habit version.
class ChecklistItemDefinition {
  ChecklistItemDefinition({
    required String id,
    required String label,
    required this.displayOrder,
    this.recoveryEnabled = true,
  }) : id = id.trim(),
       label = label.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be blank');
    }
    if (this.label.isEmpty) {
      throw ArgumentError.value(label, 'label', 'Must not be blank');
    }
  }

  final String id;
  final String label;
  final int displayOrder;
  final bool recoveryEnabled;
}

/// Optional editable starter template for the Daily Prayers / S checklist habit.
class ChecklistStarterTemplate {
  ChecklistStarterTemplate({
    required String symbol,
    required String name,
    required List<String> itemLabels,
    this.recoveryEnabled = true,
  }) : symbol = symbol.trim(),
       name = name.trim(),
       itemLabels = List.unmodifiable([
         for (final label in itemLabels) label.trim(),
       ]) {
    if (this.symbol.isEmpty) {
      throw ArgumentError.value(symbol, 'symbol', 'Must not be blank');
    }
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be blank');
    }
    if (this.itemLabels.isEmpty ||
        this.itemLabels.any((label) => label.isEmpty)) {
      throw ArgumentError.value(
        itemLabels,
        'itemLabels',
        'Must contain at least one nonblank item label',
      );
    }
  }

  static final ChecklistStarterTemplate dailyPrayers = ChecklistStarterTemplate(
    symbol: 'S',
    name: 'Daily Prayers',
    itemLabels: const ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'],
    recoveryEnabled: true,
  );

  final String symbol;
  final String name;
  final List<String> itemLabels;
  final bool recoveryEnabled;

  ChecklistStarterTemplate copyWith({
    String? symbol,
    String? name,
    List<String>? itemLabels,
    bool? recoveryEnabled,
  }) => ChecklistStarterTemplate(
    symbol: symbol ?? this.symbol,
    name: name ?? this.name,
    itemLabels: itemLabels ?? this.itemLabels,
    recoveryEnabled: recoveryEnabled ?? this.recoveryEnabled,
  );

  HabitSchedule defaultSchedule({
    required LocalDate startDate,
    LocalDate? endExclusive,
  }) => DailySchedule(start: startDate, endExclusive: endExclusive);
}

class ChecklistItemEvaluation {
  const ChecklistItemEvaluation({
    required this.definition,
    required this.state,
  });

  final ChecklistItemDefinition definition;
  final ChecklistItemEffectiveState state;
}

/// Derives per-item and overall checklist status without losing item-level state.
class ChecklistDayProgress {
  const ChecklistDayProgress._({
    required this.items,
    required this.status,
    required this.completedCount,
    required this.recoveredCount,
    required this.failedCount,
    required this.excusedCount,
    required this.pendingCount,
  });

  factory ChecklistDayProgress.evaluate({
    required List<ChecklistItemDefinition> definitions,
    required Map<String, ChecklistItemLogState> loggedStates,
    required Set<String> recoveredItemIds,
  }) {
    if (definitions.isEmpty) {
      throw ArgumentError('Checklist must contain at least one item');
    }
    var completedCount = 0;
    var recoveredCount = 0;
    var failedCount = 0;
    var excusedCount = 0;
    var pendingCount = 0;
    final items = <ChecklistItemEvaluation>[];

    for (final def in definitions) {
      final logged = loggedStates[def.id];
      final effective = switch (logged) {
        null => ChecklistItemEffectiveState.pending,
        ChecklistItemLogState.completed =>
          ChecklistItemEffectiveState.completed,
        ChecklistItemLogState.excused => ChecklistItemEffectiveState.excused,
        ChecklistItemLogState.failed =>
          recoveredItemIds.contains(def.id)
              ? ChecklistItemEffectiveState.recovered
              : ChecklistItemEffectiveState.failed,
      };
      switch (effective) {
        case ChecklistItemEffectiveState.pending:
          pendingCount += 1;
        case ChecklistItemEffectiveState.completed:
          completedCount += 1;
        case ChecklistItemEffectiveState.recovered:
          recoveredCount += 1;
        case ChecklistItemEffectiveState.failed:
          failedCount += 1;
        case ChecklistItemEffectiveState.excused:
          excusedCount += 1;
      }
      items.add(ChecklistItemEvaluation(definition: def, state: effective));
    }

    final total = definitions.length;
    final ChecklistOccurrenceStatus status;
    if (pendingCount == total) {
      status = ChecklistOccurrenceStatus.pending;
    } else if (excusedCount == total) {
      status = ChecklistOccurrenceStatus.excused;
    } else if (pendingCount == 0 && failedCount == 0) {
      status = recoveredCount > 0
          ? ChecklistOccurrenceStatus.recovered
          : ChecklistOccurrenceStatus.completed;
    } else if (pendingCount == 0 &&
        completedCount == 0 &&
        recoveredCount == 0 &&
        failedCount > 0) {
      status = ChecklistOccurrenceStatus.failed;
    } else {
      status = ChecklistOccurrenceStatus.partial;
    }

    return ChecklistDayProgress._(
      items: List.unmodifiable(items),
      status: status,
      completedCount: completedCount,
      recoveredCount: recoveredCount,
      failedCount: failedCount,
      excusedCount: excusedCount,
      pendingCount: pendingCount,
    );
  }

  final List<ChecklistItemEvaluation> items;
  final ChecklistOccurrenceStatus status;
  final int completedCount;
  final int recoveredCount;
  final int failedCount;
  final int excusedCount;
  final int pendingCount;
}
