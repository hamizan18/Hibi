import 'avoidance_habit.dart';
import 'checklist_habit.dart';
import 'counter_starter_template.dart';

/// Unified catalog of all four approved optional, editable starter templates:
/// Self Control (O), Quran Reading (N), Daily Prayers (S), and Push Up (P).
/// Never automatically populates user records or seeds historical occurrences.
class StarterTemplateCatalog {
  const StarterTemplateCatalog._();

  static final AvoidanceStarterTemplate selfControl =
      AvoidanceStarterTemplate.selfControl;

  static final CounterStarterTemplate quranReading =
      CounterStarterTemplate.quranReading;

  static final ChecklistStarterTemplate dailyPrayers =
      ChecklistStarterTemplate.dailyPrayers;

  static final CounterStarterTemplate pushUp = CounterStarterTemplate.pushUp;

  static const List<String> approvedSymbols = ['O', 'N', 'S', 'P'];
}
