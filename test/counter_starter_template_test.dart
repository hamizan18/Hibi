import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_roster_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_starter_template.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 9);
}

void main() {
  test(
    'default starter templates match approved specification and validate edits',
    () {
      final templates = CounterStarterTemplate.defaults;
      expect(templates.length, 2);

      final quran = CounterStarterTemplate.quranReading;
      expect(quran.id, CounterStarterTemplateId.quranReading);
      expect(quran.symbol, 'N');
      expect(quran.name, 'Quran Reading');
      expect(quran.target.count, 5);
      expect(quran.target.unit, 'pages');

      final pushUp = CounterStarterTemplate.pushUp;
      expect(pushUp.id, CounterStarterTemplateId.pushUp);
      expect(pushUp.symbol, 'P');
      expect(pushUp.name, 'Push Up');
      expect(pushUp.target.count, 10);
      expect(pushUp.target.unit, 'repetitions');

      final edited = quran.copyWith(
        name: '  Evening Quran  ',
        target: CounterTarget(count: 10, unit: 'pages'),
      );
      expect(edited.name, 'Evening Quran');
      expect(edited.symbol, 'N');
      expect(edited.target.count, 10);

      expect(() => quran.copyWith(name: '   '), throwsArgumentError);
      expect(() => quran.copyWith(symbol: ' '), throwsArgumentError);
    },
  );

  test('starter templates are never auto-populated and explicit instantiation preserves user edits without seeding historical records', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    // Skipping templates leaves database completely empty
    expect(
      await CounterDayRosterReader(db).readForDate(LocalDate(2026, 11, 26)),
      isEmpty,
    );

    final writer = CounterHabitWriter(db, FixedClock());
    await writer.createFromStarterTemplate(
      template: CounterStarterTemplate.quranReading,
      habitId: 'h_quran',
      versionId: 'v_quran',
      auditId: 'a_quran',
      lifecycleEventId: 'l_quran',
      effectiveDate: DateTime(2026, 11, 26),
    );

    final customizedPushUp = CounterStarterTemplate.pushUp.copyWith(
      name: 'Morning Push Up',
      target: CounterTarget(count: 15, unit: 'reps'),
    );
    await writer.createFromStarterTemplate(
      template: customizedPushUp,
      habitId: 'h_pushup',
      versionId: 'v_pushup',
      auditId: 'a_pushup',
      lifecycleEventId: 'l_pushup',
      effectiveDate: DateTime(2026, 11, 26),
      schedule: WeekdaySchedule(
        start: LocalDate(2026, 11, 26),
        weekdays: {1, 3, 5},
      ),
    );

    // Rejects backdated starter template instantiation
    await expectLater(
      writer.createFromStarterTemplate(
        template: CounterStarterTemplate.pushUp,
        habitId: 'h_past',
        versionId: 'v_past',
        auditId: 'a_past',
        lifecycleEventId: 'l_past',
        effectiveDate: DateTime(2026, 11, 25),
      ),
      throwsStateError,
    );

    final rosterNov26 = await CounterDayRosterReader(db)
        .readForDate(LocalDate(2026, 11, 26));
    expect(rosterNov26.length, 2);
    // Both habits share FixedClock timestamp, so id ordering places h_pushup before h_quran
    expect(rosterNov26[0].name, 'Morning Push Up');
    expect(
      rosterNov26[0].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );

    expect(rosterNov26[1].name, 'Quran Reading');
    expect(
      rosterNov26[1].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(rosterNov26[1].evaluation.configuredTarget!.count, 5);
    expect(rosterNov26[1].evaluation.hasOccurrence, isFalse);

    // Zero occurrences or events were seeded
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      0,
    );
  });
}
