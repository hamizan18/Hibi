import '../../habits/domain/habit_schedule.dart';

/// Optional, neutral mood markers for personal reflection.
/// Never used for medical diagnosis or penalizing missing days.
enum JournalMood {
  veryLow('very_low', 'Very low'),
  low('low', 'Low'),
  neutral('neutral', 'Neutral'),
  good('good', 'Good'),
  great('great', 'Great');

  const JournalMood(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static JournalMood fromStorageKey(String raw) {
    for (final mood in values) {
      if (mood.storageKey == raw) return mood;
    }
    throw ArgumentError.value(raw, 'raw', 'Unknown journal mood');
  }
}

/// Normalizes and deduplicates optional journal tags in deterministic order.
List<String> normalizeJournalTags(Iterable<String> rawTags) {
  final seen = <String>{};
  final normalized = <String>[];
  for (final raw in rawTags) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed.isEmpty) continue;
    if (seen.add(trimmed)) {
      normalized.add(trimmed);
    }
  }
  return List<String>.unmodifiable(normalized);
}

/// One optional journal/mood reflection entry bound to an ISO local date.
/// Multiple entries may exist for the same date; absent dates carry no penalty.
class JournalEntry {
  JournalEntry({
    required String id,
    required this.localDate,
    String? title,
    String? reflectionText,
    String? gratitudeText,
    this.mood,
    Iterable<String> tags = const [],
    this.isPrivate = false,
    this.isDeleted = false,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : id = id.trim(),
       title = _cleanOptional(title),
       reflectionText = _cleanOptional(reflectionText),
       gratitudeText = _cleanOptional(gratitudeText),
       tags = normalizeJournalTags(tags) {
    if (this.id.isEmpty) {
      throw ArgumentError('Journal entry id must not be blank');
    }
    if (this.title == null &&
        this.reflectionText == null &&
        this.gratitudeText == null &&
        mood == null) {
      throw ArgumentError(
        'Journal entry requires at least a title, reflection, gratitude note or mood',
      );
    }
  }

  final String id;
  final LocalDate localDate;
  final String? title;
  final String? reflectionText;
  final String? gratitudeText;
  final JournalMood? mood;
  final List<String> tags;
  final bool isPrivate;
  final bool isDeleted;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

/// Descriptive, non-diagnostic summary of recorded journal entries.
class JournalSummary {
  const JournalSummary({
    required this.entryCount,
    required this.distinctDaysCount,
    required this.moodCounts,
    required this.tagCounts,
  });

  final int entryCount;
  final int distinctDaysCount;
  final Map<JournalMood, int> moodCounts;
  final Map<String, int> tagCounts;

  static JournalSummary summarize(Iterable<JournalEntry> entries) {
    final active = entries.where((e) => !e.isDeleted).toList();
    final days = <LocalDate>{};
    final moods = <JournalMood, int>{};
    final tags = <String, int>{};
    for (final entry in active) {
      days.add(entry.localDate);
      final mood = entry.mood;
      if (mood != null) {
        moods[mood] = (moods[mood] ?? 0) + 1;
      }
      for (final tag in entry.tags) {
        tags[tag] = (tags[tag] ?? 0) + 1;
      }
    }
    return JournalSummary(
      entryCount: active.length,
      distinctDaysCount: days.length,
      moodCounts: Map<JournalMood, int>.unmodifiable(moods),
      tagCounts: Map<String, int>.unmodifiable(tags),
    );
  }
}

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
