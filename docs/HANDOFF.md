# Handoff

## Current state

Milestone 0 is accepted; Milestone 1 remains in progress. Today includes current-day logging, dated lifecycle controls, confirmed pause from initial start for eligible habits, and prior-date recovery for eligible counter and checklist records. Historical correction UI and milestone-wide Android verification remain incomplete.

## Latest work

Schema version 12 adds immutable start-pause records linked to original initial active lifecycle events. The confirmed Today action checks the initial event, first-version date, local day and all occurrence types transactionally. Effective lifecycle readers retain both records, and recovery and counter-correction preview reads account for the pause. Ordinary subsequent transitions remain strictly later-dated. Previous session changes were preserved.

## Decisions and constraints

See ADR-037 through ADR-046 and BUSINESS_RULES.md. Historical counter target corrections require an exact read-set-bound preview (`CounterCorrectionPreview`) and fail as stale if any source row or the local calendar date changes before commit; confirmed commits preserve full before/after JSON preimages in `habit_counter_correction_audit` without modifying source `habit_counter_events`. Extended recurrences preserve the 5-column `habit_schedules` schema. Avoidance habits require explicit daily confirmation for zero-incident completion and never enable recovery. Measurement and range habits use exact fixed-scale signed 64-bit integers (`decimalPlaces` 0..6), never floating point. Starter templates are never auto-populated. SQLite remains unencrypted.

## Verification and blockers

Before changes, `cmd.exe /c "flutter.bat test test/future_start_lifecycle_test.dart test/unified_habit_registry_test.dart test/non_counter_lifecycle_test.dart"` passed 5 tests. The combined format/analyze and 12-file targeted test command recorded in PROGRESS.md passed analysis and 36 tests. `cmd.exe /c "flutter.bat test test/counter_habit_writer_test.dart test/counter_target_test.dart test/habit_schedule_store_test.dart test/habit_schema_test.dart test/occurrence_schema_test.dart test/non_counter_lifecycle_test.dart"` passed 22 tests. Tests used isolated databases and injected clocks.

Historical recovery eligibility is checked against the original version, current active lifecycle and explicit item/habit flags inside the write transaction; absent metadata remains ineligible. Private historical values are hidden unless explicitly revealed. Lower-level recovery writers alone do not enforce all these UI eligibility checks.

Android visual, integration and device migration tests were not run in this session. The previous isolated Android installation was rejected with `INSTALL_FAILED_USER_RESTRICTED`; this rejection was not bypassed or repeated. The widget test exercises Today but is not Android visual verification.

Private visibility is not authentication, and SQLite is unencrypted. Duration timers remain screen-local and may be discarded on navigation, background/resume, visibility changes or midnight. Legacy records without recovery metadata cannot be recovered through these controls.


## Next bounded task

Implement the user-facing future counter configuration/version editing workflow using the existing version writer, preserving historical configurations and validating dates and schedules.
