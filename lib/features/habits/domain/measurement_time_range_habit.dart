enum MeasurementComparisonRule { atLeast, atMost, exact }

enum TimeComparisonRule { atOrBefore, atOrAfter }

enum TypedValueStatus { completed, partial, failed, excused }

/// Fixed-scale integer measurement target (decimalPlaces 0..6, no floating point).
class MeasurementTarget {
  MeasurementTarget({
    required this.scaledTarget,
    required this.decimalPlaces,
    required String unit,
    required this.rule,
  }) : unit = unit.trim() {
    if (decimalPlaces < 0 || decimalPlaces > 6) {
      throw RangeError.range(decimalPlaces, 0, 6, 'decimalPlaces');
    }
    if (this.unit.isEmpty) {
      throw ArgumentError.value(unit, 'unit', 'Must not be blank');
    }
  }

  final int scaledTarget;
  final int decimalPlaces;
  final String unit;
  final MeasurementComparisonRule rule;

  TypedValueStatus evaluate(int scaledValue) {
    final matches = switch (rule) {
      MeasurementComparisonRule.atLeast => scaledValue >= scaledTarget,
      MeasurementComparisonRule.atMost => scaledValue <= scaledTarget,
      MeasurementComparisonRule.exact => scaledValue == scaledTarget,
    };
    return matches ? TypedValueStatus.completed : TypedValueStatus.partial;
  }
}

/// Time-of-day target in minutes since local midnight (0..1439).
class TimeOfDayTarget {
  TimeOfDayTarget({
    required this.targetMinutesSinceMidnight,
    required this.rule,
  }) {
    if (targetMinutesSinceMidnight < 0 || targetMinutesSinceMidnight > 1439) {
      throw RangeError.range(
        targetMinutesSinceMidnight,
        0,
        1439,
        'targetMinutesSinceMidnight',
      );
    }
  }

  final int targetMinutesSinceMidnight;
  final TimeComparisonRule rule;

  TypedValueStatus evaluate(int loggedMinutesSinceMidnight) {
    if (loggedMinutesSinceMidnight < 0 || loggedMinutesSinceMidnight > 1439) {
      throw RangeError.range(
        loggedMinutesSinceMidnight,
        0,
        1439,
        'loggedMinutesSinceMidnight',
      );
    }
    final matches = switch (rule) {
      TimeComparisonRule.atOrBefore =>
        loggedMinutesSinceMidnight <= targetMinutesSinceMidnight,
      TimeComparisonRule.atOrAfter =>
        loggedMinutesSinceMidnight >= targetMinutesSinceMidnight,
    };
    return matches ? TypedValueStatus.completed : TypedValueStatus.failed;
  }
}

/// Inclusive fixed-scale integer range target `[minScaled, maxScaled]`.
class RangeTarget {
  RangeTarget({
    required this.minScaled,
    required this.maxScaled,
    required this.decimalPlaces,
    required String unit,
  }) : unit = unit.trim() {
    if (decimalPlaces < 0 || decimalPlaces > 6) {
      throw RangeError.range(decimalPlaces, 0, 6, 'decimalPlaces');
    }
    if (maxScaled < minScaled) {
      throw ArgumentError('maxScaled must be >= minScaled');
    }
    if (this.unit.isEmpty) {
      throw ArgumentError.value(unit, 'unit', 'Must not be blank');
    }
  }

  final int minScaled;
  final int maxScaled;
  final int decimalPlaces;
  final String unit;

  TypedValueStatus evaluate(int scaledValue) =>
      (scaledValue >= minScaled && scaledValue <= maxScaled)
      ? TypedValueStatus.completed
      : TypedValueStatus.partial;
}
