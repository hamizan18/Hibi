# Handoff

## Current state

Milestone 0 is accepted. Milestone 1 remains in progress: internal counter data infrastructure and daily/weekday recurrence evaluation and low-level persistence exist, but habit tracking is not operational.

## Latest work

Added schema version 6, `HabitScheduleStore`, and `test/habit_schedule_store_test.dart`. Updated existing migration fixtures and schema/business/decision/status documentation. No UI, production data, occurrence generation or lifecycle behavior was added.

## Decisions and constraints

See ADR-013 and DATABASE_SCHEMA.md. Each schedule belongs to a habit version; weekdays use a validated seven-bit ISO mask, and existing versions with no row remain unconfigured. A schedule cannot be inserted/changed/deleted for a version with occurrences. The low-level store is not integrated with the habit writer or audit and is not a user-facing editing workflow. SQLite is unencrypted.

## Verification and blockers

Before changes, analysis and 26 tests passed. Targeted tests passed; a first temporary smoke command failed due to shell path escaping and passed after quoting. After changes, formatting, analysis and all 30 tests passed. Tests used isolated local databases; Android migration and integration tests were not run.

## Next bounded task

Design and implement versioned lifecycle events and an applicability evaluator combining lifecycle, habit version and stored schedule, with isolated tests. Do not generate occurrences until these rules are verified.
