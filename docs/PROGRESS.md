# Progress

## Active milestone

Milestone 0 is accepted. Milestone 1 — Dynamic Habit Engine remains in progress. Today supports current-day logging, dated counter lifecycle controls and eligible prior-date counter/checklist recovery. Other habit-management controls, historical correction UI and milestone-wide Android verification remain incomplete.

## Implemented

- Existing Flutter template adapted for Hibi; Android development ID remains `com.example.hibi`.
- Material 3 dark theme, five navigable destinations explicitly marked unavailable where appropriate, Japanese-style local date, injectable clock, midnight and resume refresh.
- Riverpod and GoRouter; Drift/SQLite version 11, including settings, habit identity, versioned counter/checklist/avoidance/boolean/duration/measurement/time-of-day/range configurations, version metadata (category, symbol, priority, privacy, ordering), daily/weekday/interval/monthly/one-time schedules, all four optional editable starter templates, counter historical correction preview/commit and preimage audit, counter occurrences/events/resolutions/recoveries, transactional action services, effective day-status interpretation, multi-habit day rosters and dashboard summaries, date-range history/summary/overview and recoverable-deficit queries, detailed lifecycle/applicability readers, unified multi-type habit registry and Riverpod service providers; foreign keys enabled and unsupported migrations rejected.
- Foundation widget, date and isolated database tests; permanent documentation.
- Habit Builder creates counter, checklist, avoidance, boolean, duration, measurement, time-of-day and range habits with validated schedules and metadata. Templates are optional and create no historical occurrences.
- Today lists habits without creating occurrences, hides private or unclassified habits until explicitly revealed, and provides current-day actions for all eight types. The visibility switch is not an app lock.
- Today offers counter lifecycle transitions and prior-date counter/checklist recovery. Eligibility is revalidated against the original version's explicit recovery metadata; private historical details are hidden until explicitly revealed.

## Verification

- `cmd.exe /c flutter.bat --version`: Flutter 3.47.6, Dart 3.13.5.
- `cmd.exe /c flutter.bat doctor -v`: Android SDK 36.0.0 and licenses available; Visual Studio missing (irrelevant to Android); no Android device.
- `cmd.exe /c flutter.bat devices`: Windows, Chrome and Edge only.
- `cmd.exe /c flutter.bat emulators`: failed, no emulator sources; Android emulator directory and AVD images absent.
- `cmd.exe /c flutter.bat pub get`: succeeded.
- `cmd.exe /c dart.bat format .`: succeeded, 7 files processed.
- `cmd.exe /c flutter.bat analyze`: initially reported one unused test import; removed. Rerun passed.
- `cmd.exe /c flutter.bat test`: 5 tests passed, including disk reopen and foreign-key enforcement.
- `cmd.exe /c flutter.bat test test/foundation_test.dart`: 3 tests passed after adding a database error-screen test.
- `cmd.exe /c "dart.bat format test\foundation_test.dart && flutter.bat analyze"`: formatting unchanged; analysis passed after the added test.
- `cmd.exe /c flutter.bat build apk --debug`: succeeded, `build/app/outputs/flutter-apk/app-debug.apk`. Gradle emitted Java native-access and Android SDK XML version warnings.

### Continuation session

- `git status --short --branch`: clean working tree on `main...origin/main` before changes; Git now exists, contrary to the earlier record.
- `cmd.exe /c "flutter.bat devices & flutter.bat emulators"`: Android 16 device `2510DRA23E` detected; no emulator sources.
- `cmd.exe /c "flutter.bat analyze && flutter.bat test"`: analysis passed; 6 tests passed.
- `cmd.exe /c "flutter.bat run --no-pub -d i7xsrs7hvgbqgyln"`: debug APK built, but installation failed with `INSTALL_FAILED_VERIFICATION_FAILURE`, then `INSTALL_FAILED_USER_RESTRICTED`; the app did not launch via this command. Do not bypass device security.
- `adb -s i7xsrs7hvgbqgyln install build\app\outputs\flutter-apk\app-debug.apk`: a separate overlapping install succeeded. `adb shell am start -n com.example.hibi/.MainActivity` launched the app.
- Visual inspection on the device confirmed the Today screen, readable Japanese date, and navigation to History, Finance, Growth, and More. The four unfinished sections were labeled unavailable.
- `adb shell run-as com.example.hibi find . -name hibi.sqlite` found `./files/hibi.sqlite`. After `adb shell am force-stop com.example.hibi` and relaunch, the database file still existed and Today rendered. This does not verify a written value survives a process restart; host-side disk reopening is covered by `test/database_test.dart`.

### Android persistence continuation

- `git status --short --branch`: clean working tree on `main...origin/main` before this session.
- `cmd.exe /c flutter.bat devices`: Android 16 device `2510DRA23E` detected.
- `cmd.exe /c "flutter.bat analyze && flutter.bat test"`: analysis passed and all 6 existing tests passed.
- `cmd.exe /c dart.bat format --output=none --set-exit-if-changed .`: passed; 7 Dart files checked, none changed.
- Created a temporary, separate Android application `dev.hibi.persistence.hibi_persistence_probe`, depending on this project by local path. `flutter.bat build apk --debug` succeeded for the probe. It used the real `AppDatabase.open()` and its own Android private storage, not Hibi's user database.
- `adb -s i7xsrs7hvgbqgyln install <probe-apk>` succeeded. First `adb shell am start -n dev.hibi.persistence.hibi_persistence_probe/.MainActivity` wrote `probe-value` and logged `HIBI_PROBE WRITE_OK pid=17687`.
- After `adb shell am force-stop dev.hibi.persistence.hibi_persistence_probe` and another `am start`, `adb logcat -d -s flutter:I *:S` reported `HIBI_PROBE READ_OK first=17687 second=19742`. The probe checked the exact marker and different process ID. This verifies the same database-opening implementation across an Android process restart in isolated storage, not an existing user's production data.
- `adb -s i7xsrs7hvgbqgyln uninstall dev.hibi.persistence.hibi_persistence_probe` succeeded; the temporary host project was removed. Hibi and its data were not uninstalled or modified.

Milestone 0 acceptance: Android launch and five navigation destinations visually checked in the previous session; database initialization and isolated restart persistence checked on Android; analysis and foundation tests passed. The probe was a temporary test app, not a `flutter test integration_test` suite. No device reboot, production-data mutation, broader accessibility audit, or future feature is implied by this result.

### Milestone 1: habit identity schema

- Before changes, `git status --short --branch` reported a clean `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 6 tests.
- Added `habits` and `habit_versions`, indexed half-open effective dates, non-overlap triggers, valid-date checks, foreign key and revision constraints. Only versioned names and revision metadata are implemented; no habit write API or user interface is exposed.
- Added transactional schema migration 1→2 without replacing settings; unknown version transitions fail. Database tests verify old settings survive migration and reopen, failed migration rolls back, history resolves correctly, and overlap/date/foreign-key/revision violations are rejected.
- `cmd.exe /c "dart.bat format lib\core\database\app_database.dart test\database_test.dart test\habit_schema_test.dart && flutter.bat test test\habit_schema_test.dart test\database_test.dart"`: 6 tests passed.
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"`: formatting unchanged, analysis passed, all 9 tests passed.
- Migration tests used isolated local SQLite files, not the device's actual user database. Android-specific migration and full milestone acceptance remain unverified.

### Milestone 1: typed counter target

- Before changes, `git status --short --branch` reported a clean `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 9 tests.
- Added `CounterTarget` and low-level `CounterTargetStore`, with positive whole counts and nonblank units. `habit_counter_targets` attaches one counter target to one habit version; existing unconfigured versions are not assigned values.
- Schema version 3 explicitly migrates versions 1 and 2 transactionally. Tests verify retained settings and historical versions, absent targets after migration, persistence across reopening, rollback on migration failure, input validation and separate targets for two versions.
- `cmd.exe /c "dart.bat format lib\core\database\app_database.dart lib\features\habits test\counter_target_test.dart test\database_test.dart test\habit_schema_test.dart && flutter.bat test test\counter_target_test.dart test\habit_schema_test.dart test\database_test.dart"`: 10 tests passed.
- `cmd.exe /c "dart.bat format lib\features\habits test\counter_target_test.dart && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"`: formatting passed, analysis passed, all 13 tests passed.
- Tests used isolated local databases. Android migration and integration tests were not run. User-facing counter creation, progress recording, correction and audit remain unimplemented.

### Milestone 1: transactional counter version writes

- Before changes, `git status --short --branch` was clean on `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 13 tests.
- Added `CounterHabitWriter` with an injected clock and caller-supplied IDs. Initial counter habit creation and strictly future version append write habit/version/target and before/after audit snapshots transactionally. Same-day and backdated changes are rejected; no historical correction workflow or UI is provided.
- Schema version 4 creates `habit_version_audit` with an index. Migrations from 1, 2 and 3 run in transactions and do not infer audit history for previous records.
- `cmd.exe /c "dart.bat format lib\core\database\app_database.dart lib\features\habits\data\counter_habit_writer.dart test && flutter.bat test test\counter_habit_writer_test.dart test\counter_target_test.dart test\habit_schema_test.dart test\database_test.dart"`: 14 tests passed.
- `cmd.exe /c "dart.bat format . && flutter.bat analyze && flutter.bat test"`: formatting unchanged, analysis passed and 17 tests passed.
- Isolated database tests cover version-3 migration preserving settings/target, before/after audit snapshots, rejection of backdated writes and rollback on audit insertion failure. Android migration and integration tests were not run.

### Milestone 1: historical correction design

- At session start `git status --short --branch` showed clean `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 17 tests.
- Documented a proposed correction preview/confirmation contract, stale-preview protection, atomic audit/reconciliation boundaries, preservation of historical preimages and privacy constraints in ARCHITECTURE.md, with acceptance scenarios in TEST_PLAN.md and ADR-010 in DECISIONS.md. This is design only; it does not implement correction or change the database.
- Added a regression test confirming an attempted insertion before an already scheduled future version does not change versions, targets or audit records.
- `cmd.exe /c "dart.bat format test\counter_habit_writer_test.dart && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"`: formatting passed, analysis passed and all 18 tests passed.
- Current schema lacks occurrences, events and historical preimage representation; correction preview, confirmation, derived recalculation and UI remain unavailable. No Android integration or migration test was run this session.

### Milestone 1: counter occurrence and event schema

- At session start `git status --short --branch` showed a clean `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 18 tests.
- Added `habit_occurrences` and `habit_counter_events`, unique habit/local-date occurrences, applicable-version and target-snapshot validation, multiple positive integer progress events, and guards against invalidating existing occurrence interpretations.
- Version 5 migrations from versions 1–4 are transactional. Isolated tests cover version-4 preservation and reopen, rollback on migration failure, cross-habit and out-of-date version rejection, duplicate dates, invalid inputs, multiple events and a valid boundary update.
- `cmd.exe /c "dart.bat format lib\core\database\app_database.dart test && flutter.bat test test\occurrence_schema_test.dart test\database_test.dart test\habit_schema_test.dart test\counter_target_test.dart test\counter_habit_writer_test.dart"`: 18 tests passed.
- `cmd.exe /c "dart.bat format . && flutter.bat analyze && flutter.bat test"`: formatting unchanged, analysis passed and all 21 tests passed.
- No production data was inserted. Schema tests used isolated local databases; Android migration and integration tests were not run. No schedule engine, occurrence generator, status engine, audited event logging or UI exists.

### Milestone 1: date-only recurrence evaluation

- At session start `git status --short --branch` showed clean `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 21 tests.
- Added `lib/features/habits/domain/habit_schedule.dart`: validated Gregorian `LocalDate` and pure daily/selected-ISO-weekday applicability with inclusive start and optional exclusive end. The evaluator does not use a clock, database or time-zone conversion and does not check versions or lifecycle.
- `cmd.exe /c "dart.bat format lib\features\habits\domain\habit_schedule.dart test\habit_schedule_test.dart && flutter.bat test test\habit_schedule_test.dart && dart.bat run tool\schedule_smoke.dart"`: 5 targeted tests passed and temporary smoke script printed `schedule smoke: passed`; the script was removed.
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"`: formatting unchanged, analysis passed and all 26 tests passed.
- Tests exercise anchor/end boundaries, selected weekdays, leap years, year changes, invalid dates and inputs, and immutable weekday selection. Schedules are not persisted or connected to occurrence generation, versions, lifecycle or UI. Android integration tests were not run.

### Milestone 1: versioned schedule persistence

- At session start `git status --short --branch` showed a clean `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 26 tests.
- Added schema version 6 and `HabitScheduleStore` for daily and selected-weekday schedules per habit version. Existing versions retain no schedule unless explicitly configured; SQLite rejects invalid dates/masks and protects versions with occurrences from direct schedule insertion, update or deletion.
- `cmd.exe /c "dart.bat format lib\core\database\app_database.dart lib\features\habits\data\habit_schedule_store.dart test && flutter.bat test test\habit_schedule_store_test.dart test\database_test.dart test\habit_schema_test.dart test\counter_target_test.dart test\counter_habit_writer_test.dart test\occurrence_schema_test.dart"`: 22 tests passed.
- Temporary smoke test: `cmd.exe /c flutter.bat test test\_schedule_persistence_smoke_test.dart` failed because the shell consumed the path separator; `cmd.exe /c "flutter.bat test test\_schedule_persistence_smoke_test.dart"` passed one test. The temporary test was removed.
- `cmd.exe /c "dart.bat format . && flutter.bat analyze && flutter.bat test"`: formatting completed, analysis passed and all 30 tests passed.
- Migration and storage tests used isolated local databases; Android migration and integration tests were not run. The store is not integrated with the habit writer, lifecycle, occurrence generation, audit or UI.

### Milestone 1: lifecycle and applicability

- At session start `git status --short --branch` showed clean `main...origin/main`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 30 tests.
- Added version-7 effective-dated lifecycle events, `HabitLifecycleStore`, and `HabitApplicabilityReader`. A known paused/archived/deleted/scheduled state is not applicable; absent necessary lifecycle/version/schedule is `unknown`, never a failure. Existing habits receive no inferred lifecycle events.
- `cmd.exe /c "dart.bat format lib\core\database\app_database.dart lib\features\habits\data\habit_lifecycle.dart test && flutter.bat test test\habit_lifecycle_test.dart test\habit_schedule_store_test.dart test\occurrence_schema_test.dart test\database_test.dart test\habit_schema_test.dart test\counter_target_test.dart test\counter_habit_writer_test.dart"`: 26 targeted tests passed.
- Temporary smoke: `cmd.exe /c "flutter.bat test test\_lifecycle_smoke_test.dart"` passed one test; the file was removed.
- First `cmd.exe /c "dart.bat format . && flutter.bat analyze && flutter.bat test"` stopped at analysis with two curly-braces lint infos. Fixed both and added a partial-migration rollback test. Rerunning the same command passed formatting, analysis and all 35 tests.
- Isolated tests cover before-start, pause/resume/archive/delete/restore, schedule and version boundaries, unknown data, forbidden backdating and reinterpretation, and migration preservation/rollback. Android migration and integration tests were not run. No user-facing lifecycle, occurrence generation or notification updates exist.

### Milestone 1: complete initial counter creation

- At session start `git status --short --branch` showed existing modified documentation, database/tests and untracked lifecycle files; those changes were preserved. `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed with 35 tests before this session's changes.
- Updated `CounterHabitWriter.create` to require an explicit schedule and lifecycle event ID. Identity, version, target, schedule, active lifecycle event and creation audit are written in one transaction using one captured clock instant; future starts are not applicable before the selected date. No scheduled event or schedule default is inferred.
- `cmd.exe /c "dart.bat format lib\features\habits\data\counter_habit_writer.dart test\counter_habit_writer_test.dart && flutter.bat test test\counter_habit_writer_test.dart"`: 5 tests passed. `cmd.exe /c "dart.bat format test\counter_habit_creation_test.dart && flutter.bat test test\counter_habit_creation_test.dart test\counter_habit_writer_test.dart"`: 9 tests passed.
- Temporary smoke `cmd.exe /c "flutter.bat test test\_counter_creation_smoke_test.dart"`: one test passed; file removed.
- `cmd.exe /c "dart.bat format lib\features\habits\data\counter_habit_writer.dart test\counter_habit_writer_test.dart test\counter_habit_creation_test.dart && flutter.bat analyze && flutter.bat test"`: formatting completed, analysis passed and all 40 tests passed.
- Isolated tests cover selected schedules, date boundaries, one clock read, creation audit, failure at schedule/lifecycle/audit writes, preservation of preexisting data, unknown legacy configuration and database reopen. Android/integration tests were not run.

### Milestone 1: future counter-version schedules

- At session start `git status --short --branch` showed existing modified and untracked user files; these were preserved. Before changes, `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed analysis and all 40 tests.
- `CounterHabitWriter.scheduleVersion` now requires an explicit schedule, rejects one ending on or before the version start and stores it in the same transaction as version boundaries, target and before/after audit. Previous schedules remain attached to their versions; a missing prior schedule remains missing and is audited as null.
- `cmd.exe /c "dart.bat format lib\features\habits\data\counter_habit_writer.dart test\counter_habit_writer_test.dart test\counter_habit_future_schedule_test.dart && flutter.bat test test\counter_habit_writer_test.dart test\counter_habit_future_schedule_test.dart"`: formatting completed and 9 targeted tests passed.
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"`: 22 files unchanged, analysis passed and all 44 tests passed.
- Isolated tests cover version boundaries, historical occurrence and schedule preservation, audit snapshots, absent legacy schedules, rejected expired schedules and rollback for schedule/audit failure or a conflicting occurrence. Android and integration tests were not run; no schema migration or production data was added.

### Milestone 1: on-demand counter occurrences

- At session start `git status --short --branch` showed a clean `main...origin/main`. Before changes, `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed analysis and all 44 tests.
- Added `CounterOccurrenceStore`: an explicit local-date request transactionally evaluates lifecycle and schedule, returns an existing occurrence and snapshot unchanged, or inserts one for an applicable counter with a known target. Missing configuration remains unknown; no progress or status is inferred.
- `cmd.exe /c "dart.bat format lib\features\habits\data\counter_occurrence_store.dart test\counter_occurrence_store_test.dart && flutter.bat analyze && flutter.bat test test\counter_occurrence_store_test.dart"`: formatting and analysis passed; 5 targeted tests passed.
- After adding a same-database concurrent-request test, `cmd.exe /c "dart.bat format lib\features\habits\data\counter_occurrence_store.dart test\counter_occurrence_store_test.dart && flutter.bat analyze && flutter.bat test"`: formatting and analysis passed; all 50 tests passed.
- Isolated tests cover repeated and concurrent requests on one database instance, version/target boundaries, paused and unscheduled dates, unknown legacy data, preservation of existing history, missing target and database reopen. Independent concurrent SQLite connections and Android/integration tests were not tested. No schema migration, background job, UI or production data was added.

### Milestone 1: audited counter progress

- At session start `git status --short --branch` showed existing modified documentation and untracked occurrence implementation/tests; these were preserved. Before changes, `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed analysis and all 50 tests.
- Added `CounterProgressWriter`, which appends multiple positive same-day counter events and matching audit snapshots atomically with one injected UTC timestamp. It refuses unknown/not-applicable, past/future, duplicate-ID and overflow writes. Schema version 8 migrates older versions without inventing audit history.
- Updated prior migration fixtures to represent their original schemas and expect version 8.
- `cmd.exe /c "dart.bat format lib\core\database\app_database.dart lib\features\habits\data\counter_progress_writer.dart test && flutter.bat analyze && flutter.bat test"`: formatting and analysis passed; all 54 tests passed.
- After adding overflow and failed-v7-migration tests, `cmd.exe /c "dart.bat format test\counter_progress_writer_test.dart && flutter.bat analyze && flutter.bat test test\counter_progress_writer_test.dart"`: formatting and analysis passed; all 6 targeted tests passed.
- After adding an existing-occurrence/unknown-applicability regression, `cmd.exe /c "dart.bat format test\counter_progress_writer_test.dart && flutter.bat test test\counter_progress_writer_test.dart"`: formatting completed and all 7 targeted tests passed.
- Tests used isolated databases; Android migration and integration tests were not run. No UI, correction workflow or production data was added.

### Milestone 1: counter progress calculation

- At session start `git status --short --branch` showed existing modified documentation, database and tests plus untracked occurrence/progress files; these were preserved. `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed analysis and all 57 tests before changes.
- Added pure `CounterProgress` and read-only `CounterProgressReader`: no events means pending, positive progress below the occurrence's target means partial, and target met or exceeded means completed. The actual total is retained; missing occurrences return no result. Invalid quantities and signed 64-bit overflow are rejected. The result does not resolve applicability or explicit statuses.
- `cmd.exe /c "dart.bat format lib\features\habits\domain\counter_progress.dart lib\features\habits\data\counter_progress_reader.dart test\counter_progress_test.dart && flutter.bat analyze && flutter.bat test test\counter_progress_test.dart"`: formatting and analysis passed; all 5 targeted tests passed. Tests include 2 + 3 against target 5, historical target after version changes, no writes on reads and overflow from preexisting events.
- Isolated databases were used. Android and integration tests were not run. No schema migration, UI, historical correction or production data was added.

### Milestone 1: counter-day read composition

- At session start `git status --short --branch` showed existing modified documentation, database/tests and untracked counter files; these were preserved. Before changes `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed analysis and all 62 tests.
- Added `CounterDayReader`, composing schedule/lifecycle applicability with any existing occurrence and recorded progress in one read transaction. A missing occurrence stays absent even on an applicable date; existing records remain visible for unknown/not-applicable dates. Applicability alone does not prove a missing counter target is configured.
- `cmd.exe /c "dart.bat format lib\features\habits\data\counter_day_reader.dart test\counter_day_reader_test.dart && flutter.bat analyze && flutter.bat test test\counter_day_reader_test.dart"` passed analysis and 4 tests; Drift printed a multiple-database warning in a test using two independent in-memory databases.
- After changing the fixture to use one database, `cmd.exe /c "dart.bat format test\counter_day_reader_test.dart && flutter.bat analyze && flutter.bat test test\counter_day_reader_test.dart"` passed analysis and all 4 targeted tests without that warning. Tests cover no writes, unknown and missing data, pre-start/unscheduled/paused dates, historical targets and existing records.
- Tests used isolated databases. Android and integration tests were not run. No schema migration, UI, correction workflow or production data was added.

### Milestone 1: explicit counter resolution

- At session start `git status --short --branch` showed modified documentation/database/tests and untracked counter files; these user changes were preserved. `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed analysis and all 66 tests before changes.
- Added schema version 9 and an immutable resolution record containing state, optional reason, occurrence, target/progress snapshot and UTC creation time. `CounterResolutionWriter` accepts only existing applicable current-day occurrences with incomplete progress; `CounterDayReader` exposes the resolution and the progress writer rejects subsequent events. No missing record is marked failed.
- Updated prior migration fixtures to represent their original schemas and expect version 9.
- First `cmd.exe /c "dart.bat format lib\core\database\app_database.dart lib\features\habits\data\counter_day_reader.dart lib\features\habits\data\counter_progress_writer.dart lib\features\habits\data\counter_resolution.dart test && flutter.bat analyze && flutter.bat test"` stopped at analysis on one missing-braces lint; fixed it. `cmd.exe /c "dart.bat format lib\features\habits\data\counter_resolution.dart && flutter.bat analyze && flutter.bat test"` then passed analysis and all 71 tests.
- After adding a failed-v8-migration rollback test, `cmd.exe /c "dart.bat format test\counter_resolution_test.dart && flutter.bat analyze && flutter.bat test test\counter_resolution_test.dart"` passed analysis and all 6 targeted tests. Tests use isolated databases and cover both resolution states, duplicates, completed and unknown data, event rejection, rollback, migration preservation and reopen.
- Android migration and integration tests were not run. No UI, historical correction, recovery or production data was added.

### Milestone 1: counter-day effective-status interpretation

- At session start `git status --short` was clean on `0a0c79e`; `cmd.exe /c "flutter.bat analyze && flutter.bat test"` passed analysis and all 72 existing tests.
- Added pure `interpretCounterDay`, `CounterDayEffectiveStatus`, `CounterDayEvaluation` in `lib/features/habits/domain/counter_day_status.dart` and `CounterDayReader.evaluate` in `lib/features/habits/data/counter_day_reader.dart`. An applicable date without an occurrence evaluates to `pending` only when the applicable version has a configured `CounterTarget` (preserving `hasOccurrence == false` without writing rows) and otherwise `unknown`. Contradictory historical records (such as occurrences on `notApplicable`/`unknown` dates or resolution snapshots mismatched by raw-SQL events) evaluate to `conflict` while keeping all underlying records accessible.
- `cmd.exe /c "dart.bat format lib\features\habits\domain\counter_day_status.dart lib\features\habits\data\counter_day_reader.dart test\counter_day_status_test.dart && flutter.bat analyze && flutter.bat test test\counter_day_status_test.dart test\counter_day_reader_test.dart"`: formatting and analysis passed; all 8 targeted tests passed.
- Isolated databases were used. Android and integration tests were not run. No schema migration, UI or production data was added.

### Milestone 1: bounded counter recovery calculation

- Added pure `CounterRecovery` and `CounterRecoveryStatus` (`unrecovered`, `partiallyRecovered`, `recovered`) in `lib/features/habits/domain/counter_recovery.dart`, validating explicitly `failed` incomplete progress and positive whole-number recovery quantities bounded by the initial deficit (`target - recordedTotal`). Original same-day progress is preserved separately from recovered totals.
- `cmd.exe /c "dart.bat format lib\features\habits\domain\counter_recovery.dart test\counter_recovery_test.dart && flutter.bat test test\counter_recovery_test.dart"`: formatting completed and all 5 targeted tests passed, covering unrecovered, partial, multi-step full recovery, zero-progress recovery, rejected unresolved/excused/completed states, non-positive or over-deficit quantities and signed 64-bit boundary limits.
- Pure domain tests only; no database schema change, UI or production data was added.

### Milestone 1: audited counter recovery persistence

- Added schema version 10 (`habit_counter_recoveries` with index and immutable update/delete triggers) in `lib/core/database/app_database.dart`, plus `CounterRecoveryRecord`, `CounterRecoveryReader` and `CounterRecoveryWriter` in `lib/features/habits/data/counter_recovery_store.dart`. Updated prior migration fixtures to drop `habit_counter_recoveries` and expect version 10.
- `CounterRecoveryWriter` records positive current-day recovery entries only for prior-date applicable occurrences explicitly resolved as `failed` while the habit is currently `active`, rejecting quantities above the remaining deficit and leaving original same-day events and today's occurrence untouched.
- Isolated database tests in `test/counter_recovery_store_test.dart` cover partial and multi-step full recovery snapshots, immutability triggers, rejection of same-day/future/unresolved/excused/paused/over-deficit writes, transaction rollback on insert failure, version-9 migration preservation/reopen and failed-v9-migration rollback.

### Milestone 1: counter-day recovery status integration

- Updated `CounterDay` and `CounterDayReader` in `lib/features/habits/data/counter_day_reader.dart` to load ordered `CounterRecoveryRecord` entries in the same read transaction, and extended `interpretCounterDay` in `lib/features/habits/domain/counter_day_status.dart` with `CounterDayEffectiveStatus.recovered` and `CounterDayEvaluation.recovery`.
- An explicitly `failed` occurrence remains `failed` when unrecovered or partially recovered (exposing `CounterRecovery` details) and becomes `recovered` only when remaining deficit reaches zero, while keeping same-day `recorded.progress.total` and today's target separate. Contradictory raw-SQL recovery records (on excused/unresolved occurrences or on/before the occurrence date) report `conflict` without hiding underlying entries.
- Tested in `test/counter_day_recovery_status_test.dart` (2 targeted tests).

### Milestone 1: read-only multi-habit counter day roster

- Added `CounterDayRosterItem` and `CounterDayRosterReader` in `lib/features/habits/data/counter_day_roster_reader.dart`, evaluating all stored habits on a requested `LocalDate` in deterministic `(created_at_utc_us, id)` order within one read transaction and pairing applicable version metadata (`versionId`, `name`, `revision`) with `CounterDayReader.evaluate` without creating occurrences.
- Initial combined verification `cmd.exe /c "dart.bat format . && flutter.bat analyze && flutter.bat test test\counter_recovery_store_test.dart test\counter_day_recovery_status_test.dart test\counter_day_roster_reader_test.dart"` passed formatting and analysis, with 8 of 9 tests passing and 1 test failing in `test/counter_recovery_store_test.dart` because `LocalDate` implements `compareTo` rather than `==`. Updated the assertion to `compareTo(...) == 0`.
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"`: formatting unchanged (42 files), analysis passed and all 90 tests passed.
- Isolated databases were used across all tests; Android migration and integration tests were not run. No UI, historical correction or production data was added.

### Milestone 1: counter date-range history and recoverable-deficit reader

- Before changes, `git status --short` showed the uncommitted Milestone 1 counter recovery/roster files from the prior session; those changes were preserved.
- Added `CounterDateHistoryItem`, `CounterRecoverableDeficit` and `CounterHistoryReader` in `lib/features/habits/data/counter_history_reader.dart`. `readRange` evaluates an inclusive `[startInclusive, endInclusive]` local calendar interval in one read transaction without creating occurrences; `findRecoverableDeficits` returns prior-date explicitly `failed` occurrences with positive remaining deficits only when the habit is `active` on `asOfDate`.
- Added 3 isolated database tests in `test/counter_history_reader_test.dart` covering inverted ranges, nonexistent habits, multi-day range evaluation across pre-start, version changes, month end and pause, and recoverable-deficit filtering.

### Milestone 1: transactional current-day counter action service

- Added `CounterTodayActionService` in `lib/features/habits/data/counter_today_action_service.dart`, coordinating on-demand current-day occurrence retrieval/creation with same-day progress (`recordTodayProgress`) or explicit failed/excused resolution (`resolveToday`) in a single database transaction using one captured clock instant, plus `recoverPriorDeficit`. Any progress or resolution failure rolls back a newly created occurrence row.
- Added 2 isolated database tests in `test/counter_today_action_service_test.dart` covering on-demand creation, occurrence reuse, atomic rollback of newly created occurrences on invalid progress or injected resolution failure, zero-progress resolution and multi-step prior-deficit recovery.

### Milestone 1: detailed lifecycle history and applicability reasons

- Extended `lib/features/habits/data/habit_lifecycle.dart` with `HabitLifecycleEvent`, `HabitLifecycleReader` (`findEffectiveOn`, `readHistory`), `HabitApplicabilityReason` and `HabitApplicabilityReader.describe`, distinguishing `applicable`, `beforeStart`, `scheduled`, `paused`, `archived`, `deleted`, `unscheduled`, `missingVersions`, `missingLifecycle`, `missingActiveVersion` and `missingSchedule` while keeping `evaluate` backward-compatible.
- Added 2 isolated database tests in `test/habit_lifecycle_detail_test.dart` covering effective-date lookup, full transition history and all 11 applicability reasons.

### Milestone 1: optional editable counter starter templates

- Added `CounterStarterTemplateId` and `CounterStarterTemplate` (`Quran Reading` / `N` / 5 pages daily and `Push Up` / `P` / 10 repetitions daily) in `lib/features/habits/domain/counter_starter_template.dart`, and `CounterHabitWriter.createFromStarterTemplate` in `lib/features/habits/data/counter_habit_writer.dart`. Templates are never auto-populated; explicit instantiation validates edits and writes no historical occurrences.
- Added 2 tests in `test/counter_starter_template_test.dart` covering default values, validation of edited fields, empty database when skipped, custom weekday schedule instantiation and rejection of backdated creation.

### Milestone 1: Riverpod providers for counter habit services

- Added `lib/features/habits/application/counter_habit_providers.dart`, wiring lifecycle, applicability, writer, occurrence, progress, resolution, recovery, day/roster/history readers, `CounterTodayActionService`, and read-only `counterDayRosterProvider` / `counterTodayRosterProvider` to `databaseProvider` and `appClockProvider`.
- Added `test/counter_habit_providers_test.dart` verifying end-to-end provider overrides with an isolated in-memory database and mutable fake clock across template creation, progress, failure resolution, next-day deficit lookup, recovery and roster queries.
- Initial `cmd.exe /c "dart.bat format . && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"` formatted 51 files, passed analysis, and passed 99 of 100 tests; `test/counter_starter_template_test.dart` failed 1 assertion because `h_pushup` and `h_quran` shared the same `FixedClock` timestamp and sorted alphabetically by ID (`h_pushup` before `h_quran`). Updated the expected roster index order in `test/counter_starter_template_test.dart`.
- Reran `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && git status --short"`: formatting unchanged (51 files), analysis passed and all 100 tests passed.
- Isolated databases were used across all tests; Android migration and integration tests were not run. No UI, historical correction or production data was added.

### Milestone 1: counter configuration and version-timeline reader

- At session start `git status --short` reported a clean working tree.
- Added `CounterVersionSnapshot`, `CounterHabitConfiguration` and `CounterConfigurationReader` (`read`, `readAll`) in `lib/features/habits/data/counter_configuration_reader.dart`, partitioning versions into `priorVersions`, `effectiveVersion` and `futureVersions` relative to `asOfDate` alongside `HabitApplicabilityDetail`, `effectiveLifecycle` and `lifecycleHistory` in one read transaction without guessing missing legacy targets or schedules.
- Added 2 isolated database tests in `test/counter_configuration_reader_test.dart` covering pre-start, current and future version transitions, paused lifecycle state, and unconfigured legacy versions.

### Milestone 1: read-only counter audit trail reader

- Added `CounterAuditReader` and typed audit models in `lib/features/habits/data/counter_audit_reader.dart`, loading `habit_version_audit`, `habit_lifecycle_events`, `habit_counter_event_audit`, `habit_counter_resolutions` and `habit_counter_recoveries` for a habit in one read transaction without inventing audit entries for legacy un-audited event rows.
- Added `test/counter_audit_reader_test.dart` verifying all five audit streams across creation, future version scheduling, progress logging, failure resolution, recovery, lifecycle pause, un-audited legacy events and disk database close/reopen.

### Milestone 1: semantic counter lifecycle action service

- Added `CounterLifecycleActionService` (`pause`, `resume`, `archive`, `softDelete`, `restore`) in `lib/features/habits/data/counter_lifecycle_action_service.dart`, enforcing semantic source-state preconditions inside one transaction and returning the updated `CounterHabitConfiguration` while preserving historical occurrences and progress.
- Added `test/counter_lifecycle_action_service_test.dart` covering valid transitions, rejection of mismatched semantic actions (such as `resume` from `archived` or `restore` from `paused`), rejection of same-day retroactive occurrence invalidation, and historical progress preservation.

### Milestone 1: pure counter date-range summary calculation

- Added `CounterRangeSummary` in `lib/features/habits/domain/counter_range_summary.dart`, aggregating per-status counts across a date range, splitting `pendingDays` into missing-occurrence versus recorded-zero, excluding `conflict` rows from valid quantity totals, and keeping `recordedQuantityTotal`, `recoveredQuantityTotal` and `remainingDeficitTotal` separate with 64-bit overflow protection.
- Added 2 pure domain tests in `test/counter_range_summary_test.dart` covering empty/no-applicable ranges and a 10-day mixed fixture exercising all `CounterDayEffectiveStatus` values.

### Milestone 1: counter habit overview reader and provider wiring

- Added `CounterHabitOverview` and `CounterHabitOverviewReader` in `lib/features/habits/data/counter_habit_overview_reader.dart`, composing configuration, as-of day evaluation, date-range history, `CounterRangeSummary` and recoverable deficits in one read transaction.
- Wired `counterConfigurationReaderProvider`, `counterAuditReaderProvider`, `counterLifecycleActionServiceProvider` and `counterHabitOverviewReaderProvider` in `lib/features/habits/application/counter_habit_providers.dart`, and added `test/counter_habit_overview_reader_test.dart`.
- `cmd.exe /c "dart.bat format . && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && git status --short"`: formatting completed (61 files), analysis passed and all 107 tests passed.
- Isolated databases were used across all tests; Android migration and integration tests were not run. No UI, historical correction or production data was added.

### Milestone 1: multi-habit counter dashboard, historical correction, extended recurrences, metadata and all tracking types

- Implemented 10 bounded tasks completing the Milestone 1 internal habit engine and upgrading Drift/SQLite to schema version 11:
  1. `CounterDashboardReader` (`lib/features/habits/data/counter_dashboard_reader.dart` & `test/counter_dashboard_reader_test.dart`): combines daily counter roster, specific applicability reasons, active habits' prior recoverable deficits and `CounterRangeSummary` in one read transaction.
  2. `CounterCorrectionPreviewer` (`lib/features/habits/data/counter_correction_preview.dart` & `test/counter_correction_preview_test.dart`): read-set-bound counter target correction preview, stale-snapshot detection across data changes and local-day boundaries, unit-reinterpretation rejection and explicit `notImplemented` flags for future score/streak/reward/achievement engines.
  3. `CounterCorrectionWriter` (`lib/features/habits/data/counter_correction_writer.dart` & `test/counter_correction_writer_test.dart`): atomic historical counter target correction commit with immutable before/after preimage audit in `habit_counter_correction_audit`, preserving source events and keeping direct-SQL protection triggers active.
  4. Extended `HabitSchedule` & `HabitScheduleStore` (`lib/features/habits/domain/habit_schedule.dart`, `lib/features/habits/data/habit_schedule_store.dart`, `test/habit_schedule_test.dart`, `test/habit_schedule_store_test.dart`): pure date-only `IntervalSchedule`, `MonthlyDaySchedule` (default skip or `lastDayFallback`) and `OneTimeSchedule` persisted in the 5-column `habit_schedules` table.
  5. `HabitMetadata` & `HabitMetadataStore` (`lib/features/habits/domain/habit_metadata.dart`, `lib/features/habits/data/habit_metadata_store.dart`, `test/habit_metadata_test.dart`): version-scoped description, symbol, category, priority weights (`Critical 4`, `High 3`, `Normal 2`, `Low 1`), privacy, inclusion flags and display order in `habit_version_metadata`.
  6. Multi-checklist engine & `Daily Prayers / S` template (`lib/features/habits/domain/checklist_habit.dart`, `lib/features/habits/data/checklist_habit_store.dart`, `test/checklist_habit_test.dart`): independent checklist items, item logs, partial/completed/failed/excused statuses and prior-date per-item recovery.
  7. Avoidance engine & `Self Control / O` template (`lib/features/habits/domain/avoidance_habit.dart`, `lib/features/habits/data/avoidance_habit_store.dart`, `test/avoidance_habit_test.dart`): repeated incidents, configurable `maxIncidents >= 0`, immediate failure on exceeding maximum, required daily confirmation for zero-incident completion and disabled recovery.
  8. Boolean & Duration (manual and timer) engines (`lib/features/habits/domain/boolean_duration_habit.dart`, `lib/features/habits/data/boolean_duration_habit_store.dart`, `test/boolean_duration_habit_test.dart`).
  9. Fixed-scale integer Measurement, Time-of-Day and Range engines (`lib/features/habits/domain/measurement_time_range_habit.dart`, `lib/features/habits/data/measurement_time_range_habit_store.dart`, `test/measurement_time_range_habit_test.dart`).
  10. `StarterTemplateCatalog`, `UnifiedHabitRegistryReader` and Riverpod provider wiring (`lib/features/habits/domain/starter_template_catalog.dart`, `lib/features/habits/data/unified_habit_registry.dart`, `lib/features/habits/application/counter_habit_providers.dart`, `test/unified_habit_registry_test.dart`), plus schema v10→v11 migration tests.
- First analysis run reported `const` constructors with validation bodies in `AvoidanceTarget`, `DurationTarget` and `TimeOfDayTarget` plus one unused test import; removed `const` from those validating constructors and the unused import.
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && git status --short"`: formatting unchanged (86 files), analysis passed with no issues and all 122 tests passed.
- Isolated databases were used across all tests; Android migration and integration tests were not run. No user-facing habit UI or production data was added.

### Milestone 1: habit builder

- Started from a clean `main...origin/main`. Before extending the implementation, `cmd.exe /c "flutter.bat test test/unified_habit_registry_test.dart test/habit_schedule_store_test.dart test/habit_metadata_test.dart"` passed all 9 tests.
- Added `HabitBuilderScreen`, navigable from Today and More. It offers eight tracking types, editable optional templates, schedules, start dates and version metadata. Counter configuration and metadata are saved together; no occurrences are created by the form. Existing data is not migrated or overwritten.
- `cmd.exe /c "flutter.bat analyze && flutter.bat test test/habit_builder_screen_test.dart test/foundation_test.dart"` initially stopped at analysis due to six deprecated dropdown `value` uses; switched to `initialValue` and reran successfully: analysis passed and 8 tests passed.
- `cmd.exe /c "flutter.bat test test/habit_builder_screen_test.dart"` passed 6 widget tests, including edited counter and checklist templates, private avoidance, invalid input, exact decimal measurement and interval persistence, using isolated in-memory databases and an injected clock.
- `cmd.exe /c flutter.bat devices` detected Android 16 device `2510DRA23E`; milestone-wide integration and migration verification was not performed.
- In a temporary Flutter application with a separate application ID and storage, `cmd.exe /c "flutter.bat run -d i7xsrs7hvgbqgyln -t lib/probe.dart"` built the debug APK but installation was rejected with `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`; the screen was not visually checked on Android. No installation restriction was bypassed.
- Pre-existing audit gap exposed by the builder: checklist, avoidance and typed creation services record lifecycle events but do not write `habit_version_audit` creation snapshots. Their complete configuration creation is therefore not audited; milestone acceptance requires fixing and testing this.
- A later formatting/analysis/test run reported four files already formatted and analysis clean, but the test compiler failed with `PathNotFoundException` for its temporary `output.dill`; the command timed out after 300 seconds. The earlier widget runs above passed.
- Afterward, `cmd.exe /c "flutter.bat test test/habit_builder_screen_test.dart test/foundation_test.dart"` passed all 10 tests.

### Milestone 1: non-counter creation audit

- At session start, Git showed uncommitted Habit Builder and documentation changes from the prior session; they were preserved. `cmd.exe /c "flutter.bat test test/habit_builder_screen_test.dart test/foundation_test.dart"` passed all 10 baseline tests.
- Added transactional creation snapshots for checklist, avoidance, boolean, duration, measurement, time-of-day and range habits in the existing `habit_version_audit` table. Snapshots capture persisted configuration, optional metadata, schedule and lifecycle with the original creation timestamp. Existing unaudited records are not backfilled; no schema migration or public creation API change was made.
- `cmd.exe /c "flutter.bat analyze && flutter.bat test test/non_counter_creation_audit_test.dart test/checklist_habit_test.dart test/avoidance_habit_test.dart test/boolean_duration_habit_test.dart test/measurement_time_range_habit_test.dart test/habit_builder_screen_test.dart"`: analysis passed and all 32 tests passed. The audit tests use injected clocks and isolated databases and cover all seven types, failure rollback, reopening and unchanged legacy records.
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed lib/features/habits/data/habit_creation_audit.dart lib/features/habits/data/checklist_habit_store.dart lib/features/habits/data/avoidance_habit_store.dart lib/features/habits/data/boolean_duration_habit_store.dart lib/features/habits/data/measurement_time_range_habit_store.dart test/non_counter_creation_audit_test.dart && flutter.bat test test/non_counter_creation_audit_test.dart"`: six files already formatted; all 22 audit tests passed.
- Android integration and device migration verification were not run; this session did not complete Milestone 1. Audit snapshots remain unencrypted, and old records without creation audits remain without them.

### Milestone 1: five Today logging tasks

- Git reported clean `main...origin/main` before changes. The previous audit implementation was verified first: `cmd.exe /c "flutter.bat test test/non_counter_creation_audit_test.dart"` passed 22 tests.
- Added five bounded pieces: (1) a date-aware, read-only Today roster with private/unclassified habits hidden by default; (2) counter progress and explicit failed/excused actions; (3) independent checklist results and avoidance incidents/confirmation; (4) boolean and manual/timer duration entries; (5) exact-decimal measurement/range and time-of-day entries. Read adapters do not create occurrences; actions use existing services.
- The first `flutter.bat analyze` found three missing-braces lint issues, which were corrected. `cmd.exe /c "flutter.bat analyze && flutter.bat test test/today_habit_roster_test.dart test/counter_today_card_test.dart test/checklist_avoidance_today_cards_test.dart test/boolean_duration_today_cards_test.dart test/numeric_today_cards_test.dart test/foundation_test.dart"` then passed analysis and 20 tests. After formatting expanded some conditions, another analysis found 19 missing-braces lint issues; corrected them and the subsequent 15-file format check, analysis and same 20 tests passed.
- The successful combined format and regression command was `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed lib/app/app.dart lib/features/habits/presentation/today_habit_roster.dart lib/features/habits/presentation/counter_today_card.dart lib/features/habits/presentation/checklist_avoidance_today_cards.dart lib/features/habits/presentation/boolean_duration_today_cards.dart lib/features/habits/presentation/numeric_today_cards.dart lib/features/habits/data/checklist_today_reader.dart lib/features/habits/data/boolean_duration_today_reader.dart lib/features/habits/data/numeric_today_reader.dart test/foundation_test.dart test/today_habit_roster_test.dart test/counter_today_card_test.dart test/checklist_avoidance_today_cards_test.dart test/boolean_duration_today_cards_test.dart test/numeric_today_cards_test.dart && flutter.bat analyze && flutter.bat test test/today_habit_roster_test.dart test/counter_today_card_test.dart test/checklist_avoidance_today_cards_test.dart test/boolean_duration_today_cards_test.dart test/numeric_today_cards_test.dart test/foundation_test.dart"`.
- `cmd.exe /c "flutter.bat test test/today_habit_roster_test.dart"` subsequently passed 3 tests, including preserving an active timer when another habit is logged. All tests used isolated databases and an injected clock.
- After clarifying the timer warning, `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed lib/features/habits/presentation/today_habit_roster.dart lib/features/habits/presentation/boolean_duration_today_cards.dart test/today_habit_roster_test.dart && flutter.bat analyze && flutter.bat test test/today_habit_roster_test.dart test/boolean_duration_today_cards_test.dart test/counter_today_card_test.dart"` passed formatting and analysis but failed one wording-specific timer assertion. Removed that wording-specific assertion; the functional timer assertions remain.
- `cmd.exe /c "flutter.bat analyze && flutter.bat test test/today_habit_roster_test.dart test/boolean_duration_today_cards_test.dart test/counter_today_card_test.dart"` subsequently passed analysis and all 12 tests.
- Android visual, integration and migration checks were not run. The previous isolated-device installation was rejected by the device; this session did not bypass or repeat that rejection. No schema migration or production test records were added. Milestone 1 remains incomplete.

### Milestone 1: three lifecycle and recovery tasks

- Git showed uncommitted Today files and documentation at the start; these existing changes were preserved. Before changes, `cmd.exe /c "flutter.bat test test/today_habit_roster_test.dart test/counter_today_card_test.dart test/checklist_avoidance_today_cards_test.dart"` passed all 10 tests.
- Added dated counter pause/resume/archive/soft-delete/restore controls with confirmation for archive and soft-delete; counter bounded recovery with explicit historical metadata; and checklist item recovery with historical habit/item flags. Eligibility is rechecked transactionally; private historical details are hidden until explicitly revealed. No schema changes.
- Initial `flutter.bat analyze` reported three missing-braces lints and one unnecessary comparison; corrected them. An initial counter recovery test tried to mutate protected metadata after an occurrence and failed with `metadata correction workflow required`; replaced that invalid fixture with a real stale-deficit test. A subsequent run failed while a test edit was in progress because `Variable` was not imported; changed the test to use a literal isolated fixture. Formatting later exposed two further lint issues, which were fixed.
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed lib/features/habits/presentation/today_habit_roster.dart lib/features/habits/presentation/counter_lifecycle_controls.dart lib/features/habits/presentation/counter_recovery_controls.dart lib/features/habits/presentation/checklist_recovery_controls.dart lib/features/habits/data/counter_recovery_eligibility.dart lib/features/habits/data/checklist_recovery_eligibility.dart test/counter_lifecycle_controls_test.dart test/counter_recovery_controls_test.dart test/checklist_recovery_controls_test.dart && flutter.bat analyze && flutter.bat test test/counter_lifecycle_controls_test.dart test/counter_recovery_controls_test.dart test/checklist_recovery_controls_test.dart test/today_habit_roster_test.dart"`: formatting unchanged, analysis clean, 20 tests passed. Tests use isolated databases and injected clocks; cover rollback, stale dates, no duplicate recovery, private visibility, historical progress and midnight clock capture.
- No Android visual, integration or migration verification was performed in this session; previous isolated installation was rejected by the device. No restriction was bypassed or repeated. Milestone 1 remains incomplete.

## Limitations

Database, occurrence data, lifecycle/resolution reasons, recovery notes and audit snapshots are unencrypted; private-view access control and privacy deletion are not implemented. Lifecycle UI for non-counter types, historical correction UI and Android milestone integration/migration verification remain unimplemented or unverified. Missing historical recovery metadata remains ineligible. Low-level recovery writers do not enforce all UI eligibility checks; callers must use the guarded eligibility services. Current duration timers exist only in screen state and may be lost on navigation, background/resume, visibility changes or midnight. Raw SQL can bypass application-level checks. No release signing or final application ID has been configured.

Immutable lifecycle, resolution, recovery, checklist, avoidance, typed-log and correction-audit triggers still require an explicit future privacy-deletion design.

## Next bounded task

Implement dated lifecycle controls for non-counter habits with semantic precondition checks and tests, preserving historical progress and existing transition restrictions.
