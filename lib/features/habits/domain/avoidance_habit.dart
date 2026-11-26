import 'habit_metadata.dart';
import 'habit_schedule.dart';

enum AvoidanceResolutionState { confirmedCompleted, failed, excused }

enum AvoidanceEffectiveStatus { pending, completed, failed, excused }

/// Target configuration for an avoidance habit (maximum permitted incidents >= 0).
class AvoidanceTarget {
  AvoidanceTarget({required this.maxIncidents}) {
    if (maxIncidents < 0) {
      throw RangeError.value(
        maxIncidents,
        'maxIncidents',
        'Must be zero or a positive integer',
      );
    }
  }

  final int maxIncidents;
}

/// Optional editable starter template for the private Self Control / O habit.
class AvoidanceStarterTemplate {
  AvoidanceStarterTemplate({
    required String symbol,
    required String name,
    required this.target,
    this.isPrivate = true,
  }) : symbol = symbol.trim(),
       name = name.trim() {
    if (this.symbol.isEmpty) {
      throw ArgumentError.value(symbol, 'symbol', 'Must not be blank');
    }
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be blank');
    }
  }

  static final AvoidanceStarterTemplate selfControl = AvoidanceStarterTemplate(
    symbol: 'O',
    name: 'Self Control',
    target: AvoidanceTarget(maxIncidents: 0),
    isPrivate: true,
  );

  final String symbol;
  final String name;
  final AvoidanceTarget target;
  final bool isPrivate;

  /// Avoidance habits never support recovery.
  bool get recoveryEnabled => false;

  AvoidanceStarterTemplate copyWith({
    String? symbol,
    String? name,
    AvoidanceTarget? target,
    bool? isPrivate,
  }) => AvoidanceStarterTemplate(
    symbol: symbol ?? this.symbol,
    name: name ?? this.name,
    target: target ?? this.target,
    isPrivate: isPrivate ?? this.isPrivate,
  );

  HabitSchedule defaultSchedule({
    required LocalDate startDate,
    LocalDate? endExclusive,
  }) => DailySchedule(start: startDate, endExclusive: endExclusive);

  HabitMetadata defaultMetadata({String category = 'Personal'}) =>
      HabitMetadata(
        symbol: symbol,
        category: category,
        isPrivate: isPrivate,
        recoveryEnabled: false,
      );
}

/// Pure avoidance day evaluation: zero incidents without confirmation remains
/// pending, while exceeding maxIncidents fails immediately.
class AvoidanceDayProgress {
  const AvoidanceDayProgress._({
    required this.maxIncidents,
    required this.incidentCount,
    required this.resolution,
    required this.status,
  });

  factory AvoidanceDayProgress.evaluate({
    required int maxIncidents,
    required int incidentCount,
    AvoidanceResolutionState? resolution,
  }) {
    if (maxIncidents < 0) {
      throw RangeError.value(maxIncidents, 'maxIncidents', 'Must be >= 0');
    }
    if (incidentCount < 0) {
      throw RangeError.value(incidentCount, 'incidentCount', 'Must be >= 0');
    }
    final AvoidanceEffectiveStatus status;
    if (incidentCount > maxIncidents) {
      status = AvoidanceEffectiveStatus.failed;
    } else if (resolution == AvoidanceResolutionState.failed) {
      status = AvoidanceEffectiveStatus.failed;
    } else if (resolution == AvoidanceResolutionState.excused) {
      status = AvoidanceEffectiveStatus.excused;
    } else if (resolution == AvoidanceResolutionState.confirmedCompleted) {
      status = AvoidanceEffectiveStatus.completed;
    } else {
      status = AvoidanceEffectiveStatus.pending;
    }
    return AvoidanceDayProgress._(
      maxIncidents: maxIncidents,
      incidentCount: incidentCount,
      resolution: resolution,
      status: status,
    );
  }

  final int maxIncidents;
  final int incidentCount;
  final AvoidanceResolutionState? resolution;
  final AvoidanceEffectiveStatus status;
}
