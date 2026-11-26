# Handoff

## Current state

Milestone 0 is accepted. Milestone 1 remains in progress: internal counter data infrastructure and pure daily/weekday recurrence evaluation exist, but habit tracking is not operational.

## Latest work

Added `lib/features/habits/domain/habit_schedule.dart` and `test/habit_schedule_test.dart`. The pure evaluator supports anchored daily and selected-weekday recurrence with optional exclusive end and validated calendar dates. No database, occurrence generation or UI was changed. Updated BUSINESS_RULES.md, DECISIONS.md, PROJECT_SPEC.md, ROADMAP.md, DATABASE_SCHEMA.md, PROGRESS.md and this handoff.

## Decisions and constraints

See ADR-012 and BUSINESS_RULES.md. `LocalDate` carries Gregorian components rather than a timestamp. Callers must determine the relevant local date and combine recurrence with effective version and lifecycle state. Schedules are not yet stored; no default must be invented for existing versions. SQLite is unencrypted.

## Verification and blockers

Before changes, analysis and 21 tests passed. Five targeted date/recurrence tests and a temporary `dart run` smoke script passed; the script was removed. After changes, formatting, analysis and all 26 tests passed. No Android integration test was run.

## Next bounded task

Design and implement versioned persistence for daily and selected-weekday schedules with a non-destructive migration and tests. Do not infer schedules for existing versions or generate occurrences before lifecycle integration.
