# Handoff

## Current state

Milestone 0 is accepted; Milestone 1 remains in progress. Today includes current-day logging, dated counter lifecycle controls and prior-date recovery for eligible counter and checklist records. Non-counter lifecycle controls, historical correction UI and milestone-wide Android verification remain incomplete.

## Latest work

Added `counter_lifecycle_controls.dart`, `counter_recovery_controls.dart`, `checklist_recovery_controls.dart`, and transactional counter/checklist recovery eligibility services. Today shows controls for visible habits and keeps private historical recovery details hidden until explicitly revealed. Archive/soft-delete require confirmation; lifecycle dates must respect the append-only history. Updated roster refresh to preserve other widgets while reloading. No schema change.

## Decisions and constraints

See ADR-037 through ADR-046 and BUSINESS_RULES.md. Historical counter target corrections require an exact read-set-bound preview (`CounterCorrectionPreview`) and fail as stale if any source row or the local calendar date changes before commit; confirmed commits preserve full before/after JSON preimages in `habit_counter_correction_audit` without modifying source `habit_counter_events`. Extended recurrences preserve the 5-column `habit_schedules` schema. Avoidance habits require explicit daily confirmation for zero-incident completion and never enable recovery. Measurement and range habits use exact fixed-scale signed 64-bit integers (`decimalPlaces` 0..6), never floating point. Starter templates are never auto-populated. SQLite remains unencrypted.

## Verification and blockers

At session start, `cmd.exe /c "flutter.bat test test/today_habit_roster_test.dart test/counter_today_card_test.dart test/checklist_avoidance_today_cards_test.dart"` passed 10 tests. After implementation, `flutter.bat analyze` and the four targeted control/roster test files passed 20 tests, with a nine-file format check unchanged. Full commands and intermediate lint/test fixture failures are recorded in PROGRESS.md. Tests use isolated databases and injected clocks.

Historical recovery eligibility is checked against the original version, current active lifecycle and explicit item/habit flags inside the write transaction; absent metadata remains ineligible. Private historical values are hidden unless explicitly revealed. Lower-level recovery writers alone do not enforce all these UI eligibility checks.

Android visual, integration and device migration tests were not run in this session. The previous isolated Android installation was rejected with `INSTALL_FAILED_USER_RESTRICTED`; this rejection was not bypassed or repeated.

Private visibility is not authentication, and SQLite is unencrypted. Duration timers remain screen-local and may be discarded on navigation, background/resume, visibility changes or midnight. Legacy records without recovery metadata cannot be recovered through these controls.


## Next bounded task

Implement dated lifecycle controls for non-counter habits with semantic precondition checks and tests, preserving historical progress and existing transition restrictions.
