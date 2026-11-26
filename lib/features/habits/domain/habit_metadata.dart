/// Approved priority levels and deterministic scoring weights.
enum HabitPriority {
  critical(4),
  high(3),
  normal(2),
  low(1);

  const HabitPriority(this.weight);
  final int weight;
}

/// Version-scoped display, category, priority, inclusion and privacy metadata.
class HabitMetadata {
  HabitMetadata({
    String? description,
    String? symbol,
    required String category,
    this.priority = HabitPriority.normal,
    this.isPrivate = false,
    this.recoveryEnabled = false,
    this.includeInScore = true,
    this.includeInStreak = true,
    this.includeInRewards = true,
    this.displayOrder = 0,
  }) : description = _trimOrNull(description),
       symbol = _trimOrNull(symbol),
       category = category.trim() {
    if (description != null && this.description == null) {
      throw ArgumentError.value(
        description,
        'description',
        'Must not be whitespace only',
      );
    }
    if (symbol != null && this.symbol == null) {
      throw ArgumentError.value(
        symbol,
        'symbol',
        'Must not be whitespace only',
      );
    }
    if (this.category.isEmpty) {
      throw ArgumentError.value(category, 'category', 'Must not be blank');
    }
  }

  final String? description;
  final String? symbol;
  final String category;
  final HabitPriority priority;
  final bool isPrivate;
  final bool recoveryEnabled;
  final bool includeInScore;
  final bool includeInStreak;
  final bool includeInRewards;
  final int displayOrder;
}

String? _trimOrNull(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
