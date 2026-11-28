import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/data_management/data/export_service.dart';
import 'package:hibi/features/growth/data/goal_service.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class _Clock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 27, 9);
}

// Decode the generated PDF's Flate-compressed content and ToUnicode map.
// This checks the text a PDF reader receives, not the original input values.
String _pdfText(Uint8List bytes) {
  final raw = latin1.decode(bytes);
  final streams = <String>[];
  final pattern = RegExp(
    r'/Filter\s*/FlateDecode\s*/Length\s+(\d+)>>\s*stream\r?\n',
  );
  for (final match in pattern.allMatches(raw)) {
    final length = int.parse(match.group(1)!);
    streams.add(
      latin1.decode(
        zlib.decode(bytes.sublist(match.end, match.end + length)),
        allowInvalid: true,
      ),
    );
  }
  final cmap = streams.singleWhere((stream) => stream.contains('beginbfchar'));
  final mapping = <int, int>{};
  for (final match in RegExp(
    r'<([0-9A-Fa-f]{4})>\s*<([0-9A-Fa-f]{4})>',
  ).allMatches(cmap)) {
    mapping[int.parse(match.group(1)!, radix: 16)] = int.parse(
      match.group(2)!,
      radix: 16,
    );
  }
  final text = StringBuffer();
  for (final stream in streams.where((s) => s.contains(']TJ'))) {
    for (final match in RegExp(r'\[<([0-9A-Fa-f]+)>\]TJ').allMatches(stream)) {
      final value = match.group(1)!;
      for (var i = 0; i < value.length; i += 4) {
        final code = mapping[int.parse(value.substring(i, i + 4), radix: 16)];
        if (code == null) throw StateError('PDF glyph has no Unicode mapping');
        text.writeCharCode(code);
      }
    }
  }
  return text.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PDF includes Japanese date and public text, excluding private goals unless requested', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock();
    final today = LocalDate(2026, 11, 27);
    await CounterHabitWriter(db, clock).create(
      habitId: 'public',
      versionId: 'public-v',
      lifecycleEventId: 'public-l',
      auditId: 'public-a',
      name: '日本語の習慣',
      effectiveDate: DateTime(2026, 11, 27),
      target: CounterTarget(count: 1, unit: '回'),
      schedule: DailySchedule(start: today),
    );
    await HabitMetadataStore(db)
        .insert('public-v', HabitMetadata(category: 'Daily', isPrivate: false));
    await GoalService(
      db,
      clock,
    ).createGoal(id: 'public-g', title: '毎日の目標', isPrivate: false);
    await GoalService(
      db,
      clock,
    ).createGoal(id: 'private-g', title: '秘密の目標', isPrivate: true);
    final service = ExportService(db, clock);
    final publicText = _pdfText(await service.exportPdfBytes(asOfDate: today));
    expect(publicText, contains('2026年11月27日(金)'));
    expect(publicText, contains('日本語の習慣'));
    expect(publicText, contains('毎日の目標'));
    expect(publicText, isNot(contains('秘密の目標')));
    final privateText = _pdfText(
      await service.exportPdfBytes(asOfDate: today, includePrivate: true),
    );
    expect(privateText, contains('秘密の目標'));
  });
}
