import 'counter_target.dart';
import 'habit_schedule.dart';

/// Identifiers for the approved optional counter starter templates.
enum CounterStarterTemplateId { quranReading, pushUp }

/// Optional, editable starter template for a counter habit.
/// Templates never automatically populate user records or seed history.
class CounterStarterTemplate {
  CounterStarterTemplate({
    required this.id,
    required String symbol,
    required String name,
    required this.target,
  }) : symbol = symbol.trim(),
       name = name.trim() {
    if (this.symbol.isEmpty) {
      throw ArgumentError.value(symbol, 'symbol', 'Must not be blank');
    }
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be blank');
    }
  }

  static final CounterStarterTemplate quranReading = CounterStarterTemplate(
    id: CounterStarterTemplateId.quranReading,
    symbol: 'N',
    name: 'Quran Reading',
    target: CounterTarget(count: 5, unit: 'pages'),
  );

  static final CounterStarterTemplate pushUp = CounterStarterTemplate(
    id: CounterStarterTemplateId.pushUp,
    symbol: 'P',
    name: 'Push Up',
    target: CounterTarget(count: 10, unit: 'repetitions'),
  );

  /// Approved counter starter templates. Avoidance and checklist templates
  /// belong to their own tracking-type implementations.
  static final List<CounterStarterTemplate> defaults = List.unmodifiable([
    quranReading,
    pushUp,
  ]);

  final CounterStarterTemplateId id;
  final String symbol;
  final String name;
  final CounterTarget target;

  CounterStarterTemplate copyWith({
    String? symbol,
    String? name,
    CounterTarget? target,
  }) => CounterStarterTemplate(
    id: id,
    symbol: symbol ?? this.symbol,
    name: name ?? this.name,
    target: target ?? this.target,
  );

  HabitSchedule defaultSchedule({
    required LocalDate startDate,
    LocalDate? endExclusive,
  }) => DailySchedule(start: startDate, endExclusive: endExclusive);
}
