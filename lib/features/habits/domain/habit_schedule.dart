/// A Gregorian calendar date, not a timestamp or time-zone conversion.
final class LocalDate implements Comparable<LocalDate> {
  factory LocalDate(int year, int month, int day) {
    if (year < 1 ||
        year > 9999 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      throw ArgumentError('Invalid calendar date: $year-$month-$day');
    }
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw ArgumentError('Invalid calendar date: $year-$month-$day');
    }
    return LocalDate._(year, month, day, date.weekday);
  }

  const LocalDate._(this.year, this.month, this.day, this.weekday);

  final int year;
  final int month;
  final int day;

  /// ISO weekday: Monday is 1 and Sunday is 7.
  final int weekday;

  @override
  int compareTo(LocalDate other) {
    final yearComparison = year.compareTo(other.year);
    if (yearComparison != 0) return yearComparison;
    final monthComparison = month.compareTo(other.month);
    if (monthComparison != 0) return monthComparison;
    return day.compareTo(other.day);
  }
}

/// A recurrence only; lifecycle and habit-version applicability are separate.
sealed class HabitSchedule {
  HabitSchedule({required this.start, this.endExclusive}) {
    if (endExclusive != null && endExclusive!.compareTo(start) <= 0) {
      throw ArgumentError('Exclusive end must be after the start date');
    }
  }

  /// Inclusive recurrence anchor, even if it is not a selected weekday.
  final LocalDate start;

  /// Optional exclusive recurrence end.
  final LocalDate? endExclusive;

  bool appliesOn(LocalDate date) =>
      date.compareTo(start) >= 0 &&
      (endExclusive == null || date.compareTo(endExclusive!) < 0) &&
      _matches(date);

  bool _matches(LocalDate date);
}

final class DailySchedule extends HabitSchedule {
  DailySchedule({required super.start, super.endExclusive});

  @override
  bool _matches(LocalDate date) => true;
}

final class WeekdaySchedule extends HabitSchedule {
  WeekdaySchedule({
    required super.start,
    super.endExclusive,
    required Set<int> weekdays,
  }) : weekdays = Set.unmodifiable(weekdays) {
    if (this.weekdays.isEmpty ||
        this.weekdays.any((day) => day < 1 || day > 7)) {
      throw ArgumentError.value(
        weekdays,
        'weekdays',
        'Select ISO weekdays 1 to 7',
      );
    }
  }

  final Set<int> weekdays;

  @override
  bool _matches(LocalDate date) => weekdays.contains(date.weekday);
}
