import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

void main() {
  test('daily schedule starts at anchor and stops at the exclusive end', () {
    final schedule = DailySchedule(
      start: LocalDate(2026, 11, 26),
      endExclusive: LocalDate(2026, 11, 29),
    );
    expect(schedule.appliesOn(LocalDate(2026, 11, 25)), isFalse);
    expect(schedule.appliesOn(LocalDate(2026, 11, 26)), isTrue);
    expect(schedule.appliesOn(LocalDate(2026, 11, 28)), isTrue);
    expect(schedule.appliesOn(LocalDate(2026, 11, 29)), isFalse);
  });

  test(
    'weekday schedule respects the anchor even if its weekday is selected',
    () {
      final selected = <int>{DateTime.monday, DateTime.thursday};
      final schedule = WeekdaySchedule(
        start: LocalDate(2026, 11, 28),
        endExclusive: LocalDate(2026, 12, 4),
        weekdays: selected,
      );
      selected.clear();
      expect(schedule.appliesOn(LocalDate(2026, 11, 26)), isFalse);
      expect(schedule.appliesOn(LocalDate(2026, 11, 28)), isFalse);
      expect(schedule.appliesOn(LocalDate(2026, 11, 30)), isTrue);
      expect(schedule.appliesOn(LocalDate(2026, 12, 1)), isFalse);
      expect(schedule.appliesOn(LocalDate(2026, 12, 3)), isTrue);
      expect(schedule.appliesOn(LocalDate(2026, 12, 7)), isFalse);
      expect(
        () => schedule.weekdays.add(DateTime.friday),
        throwsUnsupportedError,
      );
    },
  );

  test('leap days and year boundaries use Gregorian calendar dates', () {
    final schedule = DailySchedule(start: LocalDate(2024, 2, 28));
    expect(schedule.appliesOn(LocalDate(2024, 2, 29)), isTrue);
    expect(schedule.appliesOn(LocalDate(2024, 3, 1)), isTrue);
    final yearEnd = DailySchedule(start: LocalDate(2026, 12, 31));
    expect(yearEnd.appliesOn(LocalDate(2027, 1, 1)), isTrue);
    expect(yearEnd.appliesOn(LocalDate(2026, 12, 30)), isFalse);
    expect(LocalDate(2024, 2, 29).weekday, DateTime.thursday);
    expect(LocalDate(2026, 11, 29).weekday, DateTime.sunday);
  });

  test('interval, monthly (skip vs last-day fallback) and one-time schedules evaluate calendar boundaries accurately', () {
    expect(
      () => IntervalSchedule(start: LocalDate(2026, 1, 1), everyDays: 0),
      throwsRangeError,
    );
    final every3Days = IntervalSchedule(
      start: LocalDate(2026, 11, 26),
      endExclusive: LocalDate(2026, 12, 5),
      everyDays: 3,
    );
    expect(every3Days.appliesOn(LocalDate(2026, 11, 25)), isFalse);
    expect(every3Days.appliesOn(LocalDate(2026, 11, 26)), isTrue);
    expect(every3Days.appliesOn(LocalDate(2026, 11, 27)), isFalse);
    expect(every3Days.appliesOn(LocalDate(2026, 11, 29)), isTrue);
    expect(every3Days.appliesOn(LocalDate(2026, 12, 2)), isTrue);
    expect(every3Days.appliesOn(LocalDate(2026, 12, 5)), isFalse);

    expect(
      () => MonthlyDaySchedule(start: LocalDate(2024, 1, 1), dayOfMonth: 0),
      throwsRangeError,
    );
    expect(
      () => MonthlyDaySchedule(start: LocalDate(2024, 1, 1), dayOfMonth: 32),
      throwsRangeError,
    );

    // Default skip for nonexistent dates (day 31 skips Feb and Apr)
    final monthlySkip = MonthlyDaySchedule(
      start: LocalDate(2024, 1, 1),
      dayOfMonth: 31,
    );
    expect(monthlySkip.appliesOn(LocalDate(2024, 1, 31)), isTrue);
    expect(monthlySkip.appliesOn(LocalDate(2024, 2, 29)), isFalse);
    expect(monthlySkip.appliesOn(LocalDate(2024, 3, 31)), isTrue);
    expect(monthlySkip.appliesOn(LocalDate(2024, 4, 30)), isFalse);

    // Last-day fallback matches Feb 29 in leap year 2024, Feb 28 in 2025, Apr 30
    final monthlyFallback = MonthlyDaySchedule(
      start: LocalDate(2024, 1, 1),
      dayOfMonth: 31,
      lastDayFallback: true,
    );
    expect(monthlyFallback.appliesOn(LocalDate(2024, 1, 31)), isTrue);
    expect(monthlyFallback.appliesOn(LocalDate(2024, 2, 28)), isFalse);
    expect(monthlyFallback.appliesOn(LocalDate(2024, 2, 29)), isTrue);
    expect(monthlyFallback.appliesOn(LocalDate(2025, 2, 28)), isTrue);
    expect(monthlyFallback.appliesOn(LocalDate(2024, 4, 30)), isTrue);

    final oneTime = OneTimeSchedule(date: LocalDate(2026, 11, 26));
    expect(oneTime.appliesOn(LocalDate(2026, 11, 25)), isFalse);
    expect(oneTime.appliesOn(LocalDate(2026, 11, 26)), isTrue);
    expect(oneTime.appliesOn(LocalDate(2026, 11, 27)), isFalse);
  });

  test('rejects invalid dates and invalid schedule ranges', () {
    for (final date in [
      [2023, 2, 29],
      [2024, 2, 30],
      [2026, 4, 31],
      [0, 1, 1],
      [10000, 1, 1],
      [2026, 0, 1],
      [2026, 1, 0],
    ]) {
      expect(() => LocalDate(date[0], date[1], date[2]), throwsArgumentError);
    }
    expect(
      () => DailySchedule(
        start: LocalDate(2026, 1, 1),
        endExclusive: LocalDate(2026, 1, 1),
      ),
      throwsArgumentError,
    );
    expect(
      () => WeekdaySchedule(
        start: LocalDate(2026, 1, 1),
        endExclusive: LocalDate(2025, 12, 31),
        weekdays: {1},
      ),
      throwsArgumentError,
    );
  });

  test('rejects empty or out-of-range weekday sets', () {
    for (final weekdays in [
      <int>{},
      <int>{0},
      <int>{8},
      <int>{1, 8},
    ]) {
      expect(
        () => WeekdaySchedule(start: LocalDate(2026, 1, 1), weekdays: weekdays),
        throwsArgumentError,
      );
    }
  });
}
