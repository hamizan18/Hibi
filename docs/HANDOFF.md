# Handoff

## Current state

Milestone 0 is accepted. Milestone 1 remains in progress: all internal domain, persistence, recurrence (`daily`, `weekdays`, `interval`, `monthly_skip`, `monthly_last_day`, `one_time`), version metadata (`HabitMetadata` and `HabitPriority`), multi-type tracking engines (`counter`, `checklist`, `avoidance`, `boolean`, `duration`, `measurement`, `timeOfDay`, `range`), all four optional editable starter templates (`Self Control` / `O`, `Quran Reading` / `N`, `Daily Prayers` / `S`, `Push Up` / `P`), counter historical correction preview/commit with preimage audit (schema version 11), multi-habit dashboard/overview readers and Riverpod service providers are implemented and verified in isolated database tests. Only the user-facing Milestone 1 UI screens and final Android device verification remain.

## Latest work

Upgraded `lib/core/database/app_database.dart` to schema version 11 and added `lib/features/habits/data/counter_dashboard_reader.dart`, `lib/features/habits/data/counter_correction_preview.dart`, `lib/features/habits/data/counter_correction_writer.dart`, `lib/features/habits/domain/habit_metadata.dart`, `lib/features/habits/data/habit_metadata_store.dart`, `lib/features/habits/domain/checklist_habit.dart`, `lib/features/habits/data/checklist_habit_store.dart`, `lib/features/habits/domain/avoidance_habit.dart`, `lib/features/habits/data/avoidance_habit_store.dart`, `lib/features/habits/domain/boolean_duration_habit.dart`, `lib/features/habits/data/boolean_duration_habit_store.dart`, `lib/features/habits/domain/measurement_time_range_habit.dart`, `lib/features/habits/data/measurement_time_range_habit_store.dart`, `lib/features/habits/domain/starter_template_catalog.dart`, and `lib/features/habits/data/unified_habit_registry.dart`. Extended `habit_schedule.dart` and `habit_schedule_store.dart` with interval, monthly and one-time schedules, and wired all new services in `counter_habit_providers.dart`. Added corresponding test suites and updated migration fixtures to schema version 11. Updated ARCHITECTURE, BUSINESS_RULES, DATABASE_SCHEMA, DECISIONS (ADR-037 through ADR-046), PROJECT_SPEC, ROADMAP, PROGRESS and HANDOFF.

## Decisions and constraints

See ADR-037 through ADR-046 and BUSINESS_RULES.md. Historical counter target corrections require an exact read-set-bound preview (`CounterCorrectionPreview`) and fail as stale if any source row or the local calendar date changes before commit; confirmed commits preserve full before/after JSON preimages in `habit_counter_correction_audit` without modifying source `habit_counter_events`. Extended recurrences preserve the 5-column `habit_schedules` schema. Avoidance habits require explicit daily confirmation for zero-incident completion and never enable recovery. Measurement and range habits use exact fixed-scale signed 64-bit integers (`decimalPlaces` 0..6), never floating point. Starter templates are never auto-populated. SQLite remains unencrypted.

## Verification and blockers

First `flutter analyze` flagged `const` constructors with validation bodies on `AvoidanceTarget`, `DurationTarget` and `TimeOfDayTarget` plus one unused import; after removing `const` on those constructors and the unused import, `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && git status --short"` passed formatting (86 files unchanged), analysis and all 122 tests (including schema v1–v10 to v11 migration tests). Isolated databases were used; Android device migration and integration tests were not run in this session.

## Next bounded task

Implement the user-facing Milestone 1 Habit Builder and optional Starter Templates UI screen (accessible from Today/More), allowing the user to skip or customize starter templates (`O`, `N`, `S`, `P`) and create habits with validated schedules, targets and metadata using the existing Riverpod providers; verify with widget tests.
