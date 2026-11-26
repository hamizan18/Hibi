# Handoff

## Current state

Milestone 0 is accepted; Milestone 1 remains in progress. The Habit Builder is reachable from Today and More; daily logging, lifecycle/recovery controls, historical correction UI and milestone-wide Android verification remain incomplete.

## Latest work

Added `habit_creation_audit.dart` and integrated it into the checklist, avoidance, boolean/duration and measurement/time/range services. Their seven non-counter types now write creation snapshots in the same transaction as configuration, schedule, lifecycle and metadata. No schema or public creation API changed. `test/non_counter_creation_audit_test.dart` covers snapshots, rollback and disk reopen without inventing audits for legacy records.

## Decisions and constraints

See ADR-037 through ADR-046 and BUSINESS_RULES.md. Historical counter target corrections require an exact read-set-bound preview (`CounterCorrectionPreview`) and fail as stale if any source row or the local calendar date changes before commit; confirmed commits preserve full before/after JSON preimages in `habit_counter_correction_audit` without modifying source `habit_counter_events`. Extended recurrences preserve the 5-column `habit_schedules` schema. Avoidance habits require explicit daily confirmation for zero-incident completion and never enable recovery. Measurement and range habits use exact fixed-scale signed 64-bit integers (`decimalPlaces` 0..6), never floating point. Starter templates are never auto-populated. SQLite remains unencrypted.

## Verification and blockers

At session start, `cmd.exe /c "flutter.bat test test/habit_builder_screen_test.dart test/foundation_test.dart"` passed 10 baseline tests. `cmd.exe /c "flutter.bat analyze && flutter.bat test test/non_counter_creation_audit_test.dart test/checklist_habit_test.dart test/avoidance_habit_test.dart test/boolean_duration_habit_test.dart test/measurement_time_range_habit_test.dart test/habit_builder_screen_test.dart"` passed analysis and 32 tests. A subsequent six-file format check passed and `flutter.bat test test/non_counter_creation_audit_test.dart` passed all 22 audit tests; exact format command is in PROGRESS.md. Tests used injected clocks and isolated databases.

Android integration and device migration tests were not run in this session. The previous session's isolated Android test build could not be installed because the device rejected installation with `INSTALL_FAILED_USER_RESTRICTED`.

Creation snapshots are unencrypted and contain sensitive configuration. Legacy non-counter habits created before this change still lack a creation snapshot; no values were invented to backfill them. Counter creation's existing audit format is unchanged.


## Next bounded task

Implement the Today habit roster and current-day logging UI using existing services, preserving pending/unknown states and not fabricating occurrences.
