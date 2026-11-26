# Handoff

## Current state

Milestone 0 is accepted. Milestone 1 remains in progress: internal counter workflows now support effective day-status interpretation (with conflict preservation), pure and persisted bounded prior-date counter recovery (schema version 10), read-only multi-habit day rosters, date-range history and recoverable-deficit queries, transactional current-day counter progress/resolution/recovery actions, detailed lifecycle history and applicability reasons, optional editable counter starter templates (`Quran Reading` and `Push Up`), and Riverpod service providers, but habit tracking UI and historical correction workflows are not operational.

## Latest work

Added `lib/features/habits/data/counter_history_reader.dart`, `lib/features/habits/data/counter_today_action_service.dart`, `lib/features/habits/domain/counter_starter_template.dart`, and `lib/features/habits/application/counter_habit_providers.dart`. Extended `lib/features/habits/data/habit_lifecycle.dart` with `HabitLifecycleEvent`, `HabitLifecycleReader`, `HabitApplicabilityReason` and `HabitApplicabilityReader.describe`, and extended `lib/features/habits/data/counter_habit_writer.dart` with `createFromStarterTemplate`. Added `test/counter_history_reader_test.dart`, `test/counter_today_action_service_test.dart`, `test/habit_lifecycle_detail_test.dart`, `test/counter_starter_template_test.dart`, and `test/counter_habit_providers_test.dart`. Updated ARCHITECTURE, BUSINESS_RULES, DATABASE_SCHEMA, DECISIONS (ADR-027 through ADR-031), PROJECT_SPEC, ROADMAP, PROGRESS and HANDOFF. No UI, historical correction or production data was added.

## Decisions and constraints

See ADR-027 through ADR-031 and BUSINESS_RULES.md. `CounterHistoryReader` evaluates inclusive date intervals in one read transaction without creating occurrences and lists prior failed occurrences with remaining deficits only when the habit is active on `asOfDate`. `CounterTodayActionService` combines on-demand occurrence creation with same-day progress or resolution in one transaction so validation or insert failures roll back any newly created occurrence. `HabitApplicabilityReader.describe` distinguishes 11 applicability reasons without schema changes. `CounterStarterTemplate` defines optional, editable starter templates that never auto-seed database rows. Riverpod providers inject `databaseProvider` and `appClockProvider` for deterministic testing. Direct SQL can bypass application checks; immutable triggers on lifecycle, resolution and recovery tables require a future correction/privacy-deletion design. SQLite is unencrypted.

## Verification and blockers

Existing uncommitted Milestone 1 changes from the previous session were present and preserved. After implementing Tasks 1–5 and updating documentation, the first full test run passed 99 of 100 tests, with 1 assertion in `test/counter_starter_template_test.dart` failing due to equal-timestamp ID tie-breaking (`h_pushup` before `h_quran`). After updating that test expectation, `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && git status --short"` passed formatting (51 files unchanged), analysis and all 100 tests. Isolated databases were used; Android migration and integration tests were not run in this session.

## Next bounded task

Implement a read-only counter habit configuration and version-timeline reader that returns a habit's current/effective version, counter target, schedule, lifecycle state/history and scheduled future versions in one transaction without mutating data or inferring defaults. Do not add UI.
