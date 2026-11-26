# Handoff

## Current state

Milestone 0 is accepted; Milestone 1 remains in progress. The Habit Builder is reachable from Today and More; daily logging, lifecycle/recovery controls, historical correction UI and milestone-wide Android verification remain incomplete.

## Latest work

Added `lib/features/habits/presentation/habit_builder_screen.dart` and navigation in `lib/app/app.dart`. The form creates all eight existing tracking types, supports daily/weekday/interval/monthly/one-time schedules and today or future start dates, version metadata, and all four optional editable templates. Counter configuration and metadata share a transaction; opening or editing the form creates no records. Added widget coverage in `test/habit_builder_screen_test.dart` and navigation coverage in `test/foundation_test.dart`. No schema changes.

## Decisions and constraints

See ADR-037 through ADR-046 and BUSINESS_RULES.md. Historical counter target corrections require an exact read-set-bound preview (`CounterCorrectionPreview`) and fail as stale if any source row or the local calendar date changes before commit; confirmed commits preserve full before/after JSON preimages in `habit_counter_correction_audit` without modifying source `habit_counter_events`. Extended recurrences preserve the 5-column `habit_schedules` schema. Avoidance habits require explicit daily confirmation for zero-incident completion and never enable recovery. Measurement and range habits use exact fixed-scale signed 64-bit integers (`decimalPlaces` 0..6), never floating point. Starter templates are never auto-populated. SQLite remains unencrypted.

## Verification and blockers

Before changes, `cmd.exe /c "flutter.bat test test/unified_habit_registry_test.dart test/habit_schedule_store_test.dart test/habit_metadata_test.dart"` passed 9 tests. Initial `flutter.bat analyze` stopped on six deprecated dropdown `value` uses; after changing them to `initialValue`, `cmd.exe /c "flutter.bat analyze && flutter.bat test test/habit_builder_screen_test.dart test/foundation_test.dart"` passed analysis and 8 tests. After adding checklist and exact-decimal/interval scenarios, `cmd.exe /c "flutter.bat test test/habit_builder_screen_test.dart"` passed 6 tests. Tests used isolated databases and an injected clock. Device `2510DRA23E` running Android 16 was detected; milestone-wide Android migration/integration tests were not run.

An isolated temporary Android application built successfully with `cmd.exe /c "flutter.bat run -d i7xsrs7hvgbqgyln -t lib/probe.dart"`, but installation was rejected with `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`. The screen was not visually verified on the device; no installation restriction was bypassed. The temporary application and files were removed.

Known pre-existing audit gap: the checklist, avoidance and typed-habit creation services do not write `habit_version_audit` creation snapshots; the builder exposes those existing paths. Lifecycle creation is recorded, but it is not a complete target/metadata creation audit. Milestone 1 must not be accepted until this is addressed and tested.

The final combined format/analysis/test attempt found formatting unchanged and analysis clean, but its test compiler reported missing temporary `output.dill` and the command timed out after 300 seconds. Earlier targeted widget runs passed; do not treat the timed-out run as successful.

The subsequent `cmd.exe /c "flutter.bat test test/habit_builder_screen_test.dart test/foundation_test.dart"` passed all 10 tests. The same final attempt had already verified formatting of the four changed Dart files and clean analysis before the timeout.

## Next bounded task

Add transactional creation audit snapshots for non-counter habit types and test rollback and historical preservation; then implement the Today roster and current-day logging UI without fabricating occurrences.
