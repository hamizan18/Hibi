# Progress

## Active milestone

Milestone 0 is accepted. Milestone 1 — Dynamic Habit Engine is in progress; internal initial and future counter versions now require explicit schedules, but habit tracking is not operational.

## Implemented

- Existing Flutter template adapted for Hibi; Android development ID remains `com.example.hibi`.
- Material 3 dark theme, five navigable destinations explicitly marked unavailable where appropriate, Japanese-style local date, injectable clock, midnight and resume refresh.
- Riverpod and GoRouter; Drift/SQLite version 7, including settings, habit identity, versioned counter targets and schedules, audit, counter occurrences/events and lifecycle history; foreign keys enabled and unsupported migrations rejected.
- Foundation widget, date and isolated database tests; permanent documentation.

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

## Limitations

Database, occurrence data, lifecycle reasons and audit snapshots are unencrypted; private-view access control and privacy deletion are not implemented. Lifecycle, notifications, occurrence generation, status and UI are not integrated into an operational habit workflow. Missing rows or events do not establish success or failure. Schema guards do not implement historical correction or permanent privacy deletion. Raw SQL and low-level stores bypass transition/audit safeguards. No release signing or final application ID has been configured.

## Next bounded task

Implement an internal, transactional, idempotent counter occurrence retrieval/creation path for a requested local date, using applicability and the correct version/target snapshot; explicitly preserve unknown and not-applicable outcomes. Test repeated requests, version boundaries, pauses and existing data; do not expose UI or infer completion/failure.
