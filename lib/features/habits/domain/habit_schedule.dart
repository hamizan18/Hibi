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

/// Number of days in a Gregorian calendar month.
int daysInGregorianMonth(int year, int month) =>
    DateTime.utc(year, month + 1, 0).day;

/// A recurrence only; lifecycle and habit-version applicability are separate.
sealed class HabitSchedule {
  HabitSchedule({required this.start, this.endExclusive}) {
    if (endExclusive != null && endExclusive!.compareTo(start) <= 0) {
      throw ArgumentError('Exclusive end must be after the start date');
    }
  }

  /// Inclusive recurrence anchor, even if it is not a selected weekday/day.
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

/// Anchored custom day interval (e.g. every 2 days, or every 7 days for weekly).
final class IntervalSchedule extends HabitSchedule {
  IntervalSchedule({
    required super.start,
    super.endExclusive,
    required this.everyDays,
  }) {
    if (everyDays <= 0) {
      throw RangeError.value(everyDays, 'everyDays', 'Must be at least 1 day');
    }
  }

  final int everyDays;

  @override
  bool _matches(LocalDate date) {
    final anchorUtc = DateTime.utc(start.year, start.month, start.day);
    final targetUtc = DateTime.utc(date.year, date.month, date.day);
    final elapsedDays = targetUtc.difference(anchorUtc).inDays;
    return elapsedDays >= 0 && elapsedDays % everyDays == 0;
  }
}

/// Monthly day-of-month recurrence; nonexistent dates skip by default unless
/// [lastDayFallback] is enabled.
final class MonthlyDaySchedule extends HabitSchedule {
  MonthlyDaySchedule({
    required super.start,
    super.endExclusive,
    required this.dayOfMonth,
    this.lastDayFallback = false,
  }) {
    if (dayOfMonth < 1 || dayOfMonth > 31) {
      throw RangeError.range(dayOfMonth, 1, 31, 'dayOfMonth');
    }
  }

  final int dayOfMonth;
  final bool lastDayFallback;

  @override
  bool _matches(LocalDate date) {
    final maxDay = daysInGregorianMonth(date.year, date.month);
    if (dayOfMonth <= maxDay) {
      return date.day == dayOfMonth;
    }
    return lastDayFallback && date.day == maxDay;
  }
}

/// Single-day one-time schedule on [date].
final class OneTimeSchedule extends HabitSchedule {
  OneTimeSchedule({required LocalDate date})
    : super(start: date, endExclusive: _dayAfter(date));

  LocalDate get date => start;

  @override
  bool _matches(LocalDate candidate) => candidate.compareTo(start) == 0;
}

LocalDate _dayAfter(LocalDate date) {
  final next = DateTime.utc(date.year, date.month, date.day + 1);
  return LocalDate(next.year, next.month, next.day);
}
