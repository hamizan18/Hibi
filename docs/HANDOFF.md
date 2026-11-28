# Handoff

## Current state

**Milestone 0 through Milestone 6 are accepted by the owner. Milestone 7 — Finalization remains active pending owner acceptance.** Japanese PDF content and five-tab navigation passed on Android in an isolated test application; production app installation was not changed. Do not commit, push, publish or release without explicit owner permission.

## Habit Builder spacing and switches — 2026-11-28

- Builder fields now have larger gaps, the scrollable form respects the bottom system safe area, and its preference labels no longer toggle values; the switches remain labeled for assistive technology. Privacy copy now distinguishes optional App Lock from unencrypted SQLite.
- `flutter.bat test --no-pub test/habit_builder_screen_test.dart test/dynamic_scoring_forms_test.dart`: 10 tests passed after fixing an initial unsupported `Switch.semanticLabel` compile error. Exact commands and results are in PROGRESS.md. The user requested a guided first-use simulation using existing optional templates; do not create test records in their production database.
- The debug APK built successfully at `build/app/outputs/flutter-apk/app-debug.apk` (Java native-access warning), without installation. A host preview with a simulated bottom inset was inspected but timed out after writing its screenshot; it does not prove Android navigation-bar behavior. Next: safely install on a test device and verify spacing, bottom navigation clearance, and switch-only interaction.

## Navigation and builder refresh — 2026-11-28

- Tab routes now switch without a route animation. Each screen still performs its local reads on entry, with a short text loading state when necessary; no stale or fabricated cache was introduced.
- Refreshed the shared theme, Today empty/privacy cards and section headers. The Habit Builder now groups its existing options into explained sections with responsive dropdowns. All habit types and storage rules remain unchanged.
- A 390×844 host widget screenshot of the builder was inspected with a system font. It is not device verification. The first preview exposed `ListTile` ink assertions; section containers were changed to `Material`. Both temporary previews did not finish normally and were removed.
- `flutter.bat analyze --no-pub` passed; the retried targeted suite passed 30 tests, including builder validation, tab switching and History privacy. The initial targeted run failed 3 tests due to a now-offscreen dropdown and replacement of the spinner; test interactions/expectations were updated without removing behavior checks. Exact command and preview limitations are in PROGRESS.md.
- `flutter.bat build apk --debug --no-pub` with D: temporary storage succeeded, producing `build/app/outputs/flutter-apk/app-debug.apk`; Java native-access warning. It was not installed. Next: review the updated UI and actual tab/data-load speed on an Android device using a safe installation and existing backup.

## UI refresh — 2026-11-28

- Updated the shared dark theme and introductory copy, made habit creation easier to reach, grouped Today habit management under `Habit options`, and redesigned the History heatmap with responsive, selectable date tiles and a plain-English N/A explanation.
- Added original Android launcher icon resources (sprout and rising sun). Existing user data, schema, business rules and private-by-default behavior were not intentionally changed. No production installation was performed.
- Targeted widget/acceptance run passed 33 tests; exact command and the initial timeout/locked-file retry are recorded in PROGRESS.md. Static analysis passed before the test-selector updates. The isolated Today screenshot used Flutter's block test font, so visual and typography verification on Android is still needed; no device installation was performed.
- `flutter.bat build apk --debug --no-pub` with `TEMP`/`TMP` on D: succeeded; output is `build/app/outputs/flutter-apk/app-debug.apk`. Gradle emitted Java native-access and SDK XML version warnings. No APK was installed.
- Review the refreshed UI with the owner before accepting Milestone 7. Other advanced screens still contain technical language and may need a separate usability pass.

## Continuation review — 2026-11-28

- Working tree contains pre-existing PDF/font and documentation changes; preserve them. The current PDF export loads the bundled font and excludes private records by default. No application code or user data was changed in this review.
- `cmd.exe /c "flutter.bat test test/pdf_japanese_export_test.dart"` passed 1 isolated-database test for Japanese PDF text and default/opt-in private goal visibility. It checks PDF text mappings, not visual rendering; prior independent visual verification is described below.
- Milestone 7 remains pending explicit owner acceptance. The prior isolated Android results below are historical; this review did not repeat device, biometric or notification checks. Confirm the application ID and signing key separately before any distribution.

## Android verification retry

- On Android 16 `2510DRA23E`, `flutter.bat test integration_test/pdf_probe_test.dart -d i7xsrs7hvgbqgyln` in disposable project `D:\hibi_pdf_retry_20261127` passed one test. It used the real `ExportService`, the bundled font, an in-memory database and a separate application ID (`dev.hibi.pdfverify.hibi_pdf_verify`), checking the Japanese date and public habit/goal text plus private-goal exclusion and explicit inclusion through PDF Unicode mappings.
- `flutter.bat test integration_test/app_test.dart -d i7xsrs7hvgbqgyln` in the same isolated app passed the five-destination navigation test. This used in-memory storage and injected security/notification gateways, not the owner's production data or platform security services.
- Repeated the isolated PDF test with `flutter.bat test --reporter expanded integration_test/pdf_probe_test.dart -d i7xsrs7hvgbqgyln` to capture the synthetic PDF bytes. Independent PyMuPDF extraction verified the Japanese date, public habit and goal, and confirmed the private goal appears only with explicit opt-in; the rasterized public PDF was visually inspected on the host. Direct `run-as` retrieval after the first run failed because Flutter had already removed the test package.
- After the tests, `adb -s i7xsrs7hvgbqgyln shell pm list packages dev.hibi.pdfverify.hibi_pdf_verify` returned no package. The disposable project, logs, generated PDFs and temporary directory were removed.
- Next bounded task: owner review of Milestone 7 and explicit acceptance if satisfied; discuss production application ID and signing separately before distribution. The tests used injected gateways and did not prove biometric or notification behavior on Android.
- All Flutter test commands set `TEMP` and `TMP` to `D:\hibi_probe_tmp_20261127`; the builds emitted a Java native-access warning. The tests did not install or modify `com.example.hibi`.


## Final verification session

- `flutter.bat devices` and `adb devices -l` detected Android 16 `2510DRA23E` (`i7xsrs7hvgbqgyln`).
- `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test -j 2"`: formatting passed (196 files unchanged), analysis passed, but the complete test command timed out after 600 seconds, with the last reported count `+294`; this is not a full-suite pass. Disk C: filled during the overlapping probe build; the cause of the test stall was not established.
- Retry `cmd.exe /c "set TEMP=D:\hibi_test_temp_20261127&& set TMP=D:\hibi_test_temp_20261127&& flutter.bat test -j 2"`: `01:21 +314: All tests passed!` with a Drift multiple-database warning in the existing backup test. The disposable D: temp directory was removed.
- The first isolated Android probe (`dev.hibi.pdfverify.hibi_pdf_verify`) build in `%TEMP%` failed with `java.io.IOException: There is not enough space on the disk`; it did not reach installation. The probe's own temporary build directory was removed and the probe was moved to `D:\hibi_pdf_verify_20261127` for a retry with `TEMP`/`TMP` on D:. The user's Hibi app and data were not touched.
- Retry from D: with `TEMP`/`TMP` on D: built the isolated APK successfully, but `flutter.bat test integration_test/pdf_probe_test.dart -d i7xsrs7hvgbqgyln` could not install it: `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`. Flutter's automatic cleanup reported `DELETE_FAILED_INTERNAL_ERROR`. No Android PDF or navigation test ran; device security was not bypassed.
- The disposable host probe directory was removed after the failed installation; no production app or data was cleared. To complete Android verification, the owner must permit USB installation on the device, then rerun a fresh isolated probe.


## PDF continuation — 2026-11-27

- Starting `git status --short` showed existing modifications to `docs/HANDOFF.md`, `docs/PROGRESS.md` and `docs/TEST_PLAN.md`; these were preserved.
- The normal PDF export now embeds offline Noto Sans JP from Google Fonts (`assets/fonts/NotoSansJP.ttf`, SHA-256 `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f`) under SIL OFL 1.1 (`assets/fonts/OFL.txt`); missing assets cause an error rather than silent text substitution. Existing data and private-by-default filtering are unchanged.
- `cmd.exe /c "dart.bat format lib/features/data_management/data/export_service.dart test/backup_export_test.dart test/milestone7_finalization_test.dart test/pdf_japanese_export_test.dart && flutter.bat analyze && flutter.bat test test/pdf_japanese_export_test.dart test/backup_export_test.dart test/milestone7_finalization_test.dart"`: formatting unchanged, analysis clean, 10 tests passed. Drift warned about multiple database instances in the existing backup test.
- `cmd.exe /c "flutter.bat build apk --debug"`: succeeded, producing `build/app/outputs/flutter-apk/app-debug.apk`; Gradle reported Java native-access and Android SDK XML version warnings. The APK was not installed.
- A throwaway isolated database test generated public and private PDFs; an independent PyMuPDF text extraction confirmed `2026年11月27日(金)`, `日本語の習慣`, and `毎日の目標`, and confirmed `秘密の目標` only appears on explicit private opt-in. The public PDF was rasterized and visually inspected; the temporary test and files were removed. This is host verification, not an Android-device export.
- An initial targeted run failed because `backup_export_test.dart` did not initialize the Flutter asset binding; fixed the test setup. The first format/analyze run then stopped on one unnecessary-import lint; fixed and reran successfully.
- Next bounded task: perform remaining Milestone 7 final verification, including the updated Android PDF export on isolated data, before requesting owner acceptance. Preserve offline behavior and do not begin deferred features.


## Historical continuation — 2026-11-27 (superseded above)

- Starting Git status: `git status --short` reported no changes; branch `main`.
- `cmd.exe /c "flutter.bat test test/milestone7_finalization_test.dart"`: 7 tests passed. The fallback PDF test emitted `Helvetica has no Unicode support`; it does not prove correct Japanese glyphs.
- `cmd.exe /c "flutter.bat devices"` detected Android 16 `2510DRA23E` (`i7xsrs7hvgbqgyln`); no device test or installation was performed in this session.
- The PDF screen calls `ExportService.exportPdfBytes` without a Unicode font. The default Helvetica path uses an ISO date and replaces unsupported characters; R-012's Japanese PDF glyph requirement remains unmet on this path. Prior claims that T-012 passed refer to a fallback-safety test, not successful Japanese PDF rendering. Historical sections below are session snapshots, not current status.
- No app code or user data was changed. Next bounded task: provide a licensed, bundled offline Japanese font for the normal PDF export and verify actual glyphs and private-by-default behavior before requesting Milestone 7 acceptance. Do not start a later milestone or deferred import.


## Earlier work

Completed Milestone 7 — Finalization (ADR-087):
- Added `integration_test` SDK dev_dependency (`pubspec.yaml`) and `integration_test/app_test.dart` (isolated in-memory DB).
- Extended `ExportService.exportPdfBytes` (`lib/features/data_management/data/export_service.dart`) with optional `unicodeFont`/`unicodeBoldFont` injection for native Japanese PDF glyphs alongside ASCII-safe Helvetica fallback.
- Wired optional git-ignored `android/key.properties` release signing in `android/app/build.gradle.kts` and `.gitignore` (preserving debug fallback for local verification and `com.example.hibi` placeholder until owner confirmation).
- Added `test/milestone7_finalization_test.dart` covering `T-001` (offline/manifest/pubspec boundaries), `T-011` (leap years, Japanese weekdays, year rollover, timezone stability), `T-012` (all 5 tabs at 320px/2.0x text scaling + PDF Unicode safety), `T-013` (`v1 -> v17` disk migration + foreign keys), and a 60-day multi-domain performance benchmark.
- Synchronized `README.md`, `PROJECT_SPEC.md`, `ROADMAP.md`, `DECISIONS.md` (ADR-087), `PROGRESS.md` and `HANDOFF.md`.

## Decisions and constraints

The owner approved version-scoped Dynamic Normalized Scoring: minimum measurement uses `clamp(actual / target, 0, 1)` for positive targets; maximum direction uses `clamp(target / actual, 0, 1)` when above a positive maximum; zero/negative or exact cases without an approved ratio are N/A when not completed. Time-of-day uses deviation/tolerance with before, after and near modes; range uses distance to the nearest boundary/tolerance. Tolerances are explicit per version. Completion status is independent of score; legacy numeric/time/range versions without valid scoring configuration remain N/A, never guessed or counted as zero. Score coverage separates valid from unavailable recorded scores. See ARCHITECTURE.md and BUSINESS_RULES.md.

## Verification and blockers

`cmd.exe /c "dart.bat format . && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test test/habit_analytics_domain_test.dart test/unified_habit_history_reader_test.dart test/history_analytics_screen_test.dart test/milestone2_acceptance_test.dart test/counter_correction_controls_test.dart test/counter_correction_preview_test.dart test/milestone1_acceptance_test.dart test/foundation_test.dart && flutter.bat build apk --debug && git status --short"` passed: 134 files formatted (0 changed), static analysis reported no issues in 10.7s, all 14 test suites passed (including isolated on-disk database close/reopen acceptance in `test/milestone2_acceptance_test.dart` and `test/milestone1_acceptance_test.dart`), and `flutter.bat build apk --debug` built `build\app\outputs\flutter-apk\app-debug.apk` in 67.5s. On-device APK installation was not re-attempted so as not to repeat or bypass the previously recorded `INSTALL_FAILED_USER_RESTRICTED` device restriction.

Latest continuation baseline: `git status --short --branch` showed a clean `main...origin/main`; `cmd.exe /c "flutter.bat test test/milestone2_acceptance_test.dart test/habit_analytics_domain_test.dart test/unified_habit_history_reader_test.dart test/history_analytics_screen_test.dart"` passed all 6 tests. No Android visual or device migration checks were repeated.

Milestone 2 validation review: `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test"` passed formatting (134 files unchanged), analysis and all 209 tests. `cmd.exe /c "flutter.bat devices && adb devices -l && flutter.bat emulators"` found no Android device and no emulator sources (exit code 1); device visual/migration verification was not performed. No integration test directory exists.

Correction privacy, resolved-occurrence consistency and cross-habit stale-impact checks have regression coverage. History excludes future dates from current-month reporting, handles hidden selections and historical categories, and treats unknown/conflict streak days as unresolved. Dynamic normalized scoring is implemented with version-scoped configuration and N/A for legacy versions without valid scoring rules. Multiple unlinked legacy correction audits remain conflicts. Milestone 2 is not accepted.

Latest targeted verification: `cmd.exe /c "dart.bat format test/history_privacy_reload_test.dart && flutter.bat analyze && flutter.bat test test/history_streak_privacy_test.dart test/history_privacy_reload_test.dart test/history_analytics_screen_test.dart test/milestone2_acceptance_test.dart"` passed analysis and all 6 tests. An earlier command stopped on a lint, which was fixed; see PROGRESS.md. Android visual and migration checks remain outstanding.

Latest correction verification: `cmd.exe /c "dart.bat format lib/features/habits/data/counter_correction_preview.dart test/correction_resolved_integrity_test.dart && flutter.bat analyze && flutter.bat test test/correction_resolved_integrity_test.dart test/correction_analytics_privacy_test.dart test/counter_correction_preview_test.dart test/counter_correction_writer_test.dart test/counter_correction_controls_test.dart test/counter_recovery_store_test.dart test/milestone2_acceptance_test.dart"` passed analysis and all 19 tests. An earlier run failed two widget tests; fixes and exact commands are recorded in PROGRESS.md. Android visual and migration checks remain outstanding.

Latest stabilization verification: `cmd.exe /c "dart.bat format lib/features/habits/data/counter_correction_preview.dart && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && flutter.bat build apk --debug"` passed formatting, analysis, all 242 tests and debug APK build. Earlier analysis failed on a type-promotion error that was fixed. `cmd.exe /c "flutter.bat devices & adb devices -l & flutter.bat emulators"` found no Android device or emulator and exited 1. See PROGRESS.md for exact results and warnings.

Dynamic scoring verification: `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && flutter.bat build apk --debug"` passed formatting, analysis, all 264 tests and debug APK build. A subsequently added score-coverage widget test passed with `cmd.exe /c "dart.bat format test/dynamic_scoring_screen_test.dart && flutter.bat test test/dynamic_scoring_screen_test.dart"`. Initial failures and fixes are recorded in PROGRESS.md. Android visual and migration checks remain outstanding.

Milestone 3 Finance verification (2026-11-27):
- `cmd.exe /c "dart.bat format . && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && flutter.bat build apk --debug"`: exited 0; 159 files formatted (0 changed), `flutter.bat analyze` found no issues (10.6s), **all 276 tests passed** (00:58, including `finance_domain_test.dart`, `finance_service_test.dart`, `finance_screen_test.dart`, `milestone3_acceptance_test.dart` and all v1..v13→v14 migration tests), and `flutter.bat build apk --debug` built `build\app\outputs\flutter-apk\app-debug.apk` (31.7s; Gradle emitted Java native-access warning).
- Physical Android 16 (API 36) verification on `2510DRA23E` (`i7xsrs7hvgbqgyln`, `1080x2392`):
  - Pre-upgrade `files/hibi.sqlite` header `user_version` = `12` (`00 00 00 0c`, `344,064` bytes).
  - `adb -s i7xsrs7hvgbqgyln install -r "build\app\outputs\flutter-apk\app-debug.apk"` succeeded in-place (`Performing Streamed Install` → `Success`).
  - `adb -s i7xsrs7hvgbqgyln shell am start -W -n com.example.hibi/.MainActivity` cold-launched cleanly (`Status: ok`, `TotalTime: 4510` ms, Impeller Vulkan).
  - Post-upgrade `files/hibi.sqlite` header `user_version` = `14` (`00 00 00 0e`, `442,368` bytes) — real live `v12 -> v14` migration succeeded without wiping user data.
  - Navigated across all 5 bottom tabs (`Today`, `History`, `Finance`, `Growth`, `More`) and visually inspected Finance (top + scrolled bottom) and Growth screenshots: zero RenderFlex/layout issues, zero `flutter`/`AndroidRuntime`/`System.err` errors in `logcat`. No fake records were created in the owner's live DB; interactive Finance CRUD/restart and timezone-change testing remain for manual verification or isolated `integration_test/` in a future pass.

Milestone 4 Growth verification (2026-11-27):
- `cmd.exe /c "dart.bat format . && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && flutter.bat build apk --debug"`: exited 0; 171 files formatted (0 changed), `flutter.bat analyze` found no issues (9.5s), **all 288 tests passed** (01:03, including `growth_domain_test.dart`, `growth_service_test.dart`, `growth_screen_test.dart`, `milestone4_acceptance_test.dart` and all v1..v14→v15 migration tests), and `flutter.bat build apk --debug` built `build\app\outputs\flutter-apk\app-debug.apk` (32.1s; Gradle emitted Java native-access warning).
- Physical Android 16 (API 36) verification on `2510DRA23E` (`i7xsrs7hvgbqgyln`, `1080x2392`):
  - `adb -s i7xsrs7hvgbqgyln install -r "build\app\outputs\flutter-apk\app-debug.apk"` succeeded in-place (`Performing Streamed Install` → `Success`).
  - `adb -s i7xsrs7hvgbqgyln shell am start -W -n com.example.hibi/.MainActivity` cold-launched cleanly (`Status: ok`, `TotalTime: 4542` ms, Impeller Vulkan).
  - Post-upgrade `files/hibi.sqlite` header `user_version` = `15` (`00 00 00 0f`) — real live `v14 -> v15` migration succeeded without wiping user data.
  - Visually inspected `Growth` tab (`Journal`, `Goals`, `Focus` sections): zero layout issues, zero `flutter`/`AndroidRuntime`/`System.err` errors in `logcat`. No fake records were created in the owner's live DB.

Milestone 5 Gamification verification (2026-11-27):
- `cmd.exe /c "dart.bat format . && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && flutter.bat build apk --debug"`: exited 0; 179 files formatted (0 changed), `flutter.bat analyze` found no issues (9.3s), **all 298 tests passed** (01:06, including `gamification_domain_test.dart`, `gamification_service_test.dart`, `gamification_screen_test.dart`, `milestone5_acceptance_test.dart` and all v1..v15→v16 migration tests), and `flutter.bat build apk --debug` built `build\app\outputs\flutter-apk\app-debug.apk` (33.3s; Gradle emitted Java native-access warning).
- Physical Android 16 (API 36) verification on `2510DRA23E` (`i7xsrs7hvgbqgyln`, `1080x2392`):
  - `adb -s i7xsrs7hvgbqgyln install -r "build\app\outputs\flutter-apk\app-debug.apk"` succeeded in-place (`Performing Streamed Install` → `Success`).
  - `adb -s i7xsrs7hvgbqgyln shell am start -W -n com.example.hibi/.MainActivity` cold-launched cleanly (`Status: ok`, `TotalTime: 4803` ms, Impeller Vulkan).
  - Post-upgrade `files/hibi.sqlite` header `user_version` = `16` (`00 00 00 10`) — real live `v15 -> v16` migration succeeded without wiping user data.
  - Visually inspected `Growth` tab showing `Journal`, `Goals`, `Focus` and `Rewards` chips: zero layout issues, zero `flutter`/`AndroidRuntime`/`System.err` errors in `logcat`.

Milestone 6 Privacy, Reminders & Data verification (2026-11-27):
- `dart.bat format --output=none --set-exit-if-changed .`: 193 files formatted (0 changed).
- `flutter.bat analyze`: `No issues found!` (9.7s).
- `flutter.bat test -j 2` (with `TEMP`/`TMP` on `D:\` after stopping Gradle daemon due to `C:\` having only `0.04 GB` free): **`01:32 +306: All tests passed!`** (including `app_lock_privacy_test.dart`, `reminder_service_test.dart`, `backup_export_test.dart`, `milestone6_acceptance_test.dart` (`T-010`) and all v1..v16→v17 migration tests).
- `flutter.bat build apk --debug`: **`√ Built build\app\outputs\flutter-apk\app-debug.apk` (`37.0s`)**.
- Physical Android 16 (API 36) verification on `2510DRA23E` (`i7xsrs7hvgbqgyln`, `1080x2392`):
  - `adb -s i7xsrs7hvgbqgyln install -r "build\app\outputs\flutter-apk\app-debug.apk"` succeeded (`Performing Streamed Install` → `Success`).
  - `adb -s i7xsrs7hvgbqgyln shell am start -W -n com.example.hibi/.MainActivity` cold-launched cleanly (`Status: ok`, `TotalTime: 5392` ms, Impeller Vulkan).
  - Post-upgrade `files/hibi.sqlite` header `user_version` = `17` (`00 00 00 11`) — real live `v16 -> v17` migration succeeded without wiping user data.
  - Visually inspected `More` tab (`Privacy & App Lock` with live Android BiometricPrompt detection, `Local Habit Reminders`, `Backup, Restore & Exports`): zero layout issues, zero `flutter`/`AndroidRuntime`/`System.err` errors in `logcat`.

Milestone 7 Finalization verification (2026-11-27):
- `cmd.exe /c "dart.bat format . && dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test -j 2 && flutter.bat build apk --debug && flutter.bat build apk --release"`: exited **0**:
  - 195 files formatted (0 changed in 1.00s).
  - `flutter.bat analyze`: `No issues found!` (5.5s, including `integration_test/app_test.dart`).
  - `flutter.bat test -j 2`: **`01:26 +313: All tests passed!`** (covering `T-001`–`T-013` + 60-day performance benchmark).
  - `flutter.bat build apk --debug`: `√ Built build\app\outputs\flutter-apk\app-debug.apk` (147.7s).
  - `flutter.bat build apk --release`: **`√ Built build\app\outputs\flutter-apk\app-release.apk (63.4MB)`** (169.3s).
- Physical Android 16 release-APK verification on `2510DRA23E` (`i7xsrs7hvgbqgyln`):
  - `adb -s i7xsrs7hvgbqgyln install -r "build\app\outputs\flutter-apk\app-release.apk"` → `Success`.
  - Cold launch `am start -W`: `Status: ok`, `LaunchState: COLD`, **`TotalTime: 1773` ms** (AOT Impeller Vulkan), zero `flutter`/`AndroidRuntime`/`System.err` errors in `logcat`.

## Next bounded task

Await explicit final owner acceptance of **Milestone 7 — Finalization**, and owner instructions regarding: (1) committing/pushing changes to Git, (2) optional final Android `applicationId` and release keystore (`android/key.properties`) if public distribution is planned, and (3) whether optional legacy text import (`R-014`) should remain deferred. Do not commit, push, publish or release without explicit owner approval.

## Session handoff — owner-directed pause

The latest request explicitly forbids additional implementation or a broad audit in this session. The owner wants a separate final audit in the next session. Do not commit, push, release, accept Milestone 2 on the owner's behalf, or begin Finance.

### Implemented work and decisions

- Eight habit tracking types, historical versions, recovery, Today, and History/Analytics are present; counter historical corrections retain preimages. Correction preview privacy, stale binding across habit data, legacy private streak boundaries, History reload privacy, future-month coverage, hidden filters, historical category choices and unknown/conflict streak semantics have host regression tests.
- Schema v13 adds `habit_version_scoring` and nullable typed-log `day_offset`; no legacy scoring configuration, offset, raw value or completion state was backfilled. New time/range scoring tolerances are explicit. Time-of-day supports before/after/near; near completes only at the exact target minute and uses circular distance for score. Missing or unsupported scoring rules produce N/A and do not enter the score denominator. Score coverage is distinct from recording coverage.
- Negative target misses and exact measurement misses have no approved normalized formula and remain N/A. Minimum zero is 100% when satisfied, otherwise N/A; maximum zero with positive actual is 0%. Numeric calculations, range/time tolerances and edge cases are described in ARCHITECTURE.md.
- Ordinary future changes create a new habit version; correction workflows require preview and confirmation. No future gamification rule is implied to exist or derive XP from score.

### Verification and known limits

- Last full command: `cmd.exe /c "dart.bat format --output=none --set-exit-if-changed . && flutter.bat analyze && flutter.bat test && flutter.bat build apk --debug"`: format unchanged (149 files), analysis passed, 264 tests passed, debug APK built at `build/app/outputs/flutter-apk/app-debug.apk`. Gradle emitted a Java native-access warning.
- After that full run, `cmd.exe /c "dart.bat format test/dynamic_scoring_screen_test.dart && flutter.bat test test/dynamic_scoring_screen_test.dart"` passed one additional widget test. It was not part of the 264-test full run. Earlier 17 test failures were fixed; exact commands and causes are recorded in PROGRESS.md.
- Latest device check: `cmd.exe /c "flutter.bat devices & adb devices -l & flutter.bat emulators"` found no Android device or emulator source (exit 1). Android visual behavior, device migration, timezone changes and device integration remain unverified. There is no `integration_test/` suite. Host migration tests use isolated databases; they do not prove actual Android migration.
- Multiple unlinked legacy counter-correction audits cannot be safely ordered from their stored data; affected records remain `conflict`, and ambiguous correction previews are rejected. Do not guess or rewrite them. Analytics-bound correction snapshots conservatively include all habit tables, so unrelated habit changes can invalidate a preview and large databases may incur extra work.
- SQLite and audit snapshots are not encrypted. The private visibility switch is not authentication; app lock and privacy deletion remain future scope. Old time logs lack relative-day offset/timezone context; do not reconstruct these from the current device. Score N/A can change formerly displayed aggregates without changing source records. Formal accessibility, full mixed-type/history edge cases, device timezone boundaries and migration from representative genuine old schemas require final verification.

### Working-tree inventory

`git status --short --branch` at the start of this handoff reported `main...origin/main`, no staged files, 40 modified and 16 untracked files. This documentation-only handoff also modified the previously clean `docs/PROJECT_SPEC.md` and `docs/ROADMAP.md`; the inventory below includes them. Preserve all changes and check status again at the start of the next session.

Modified:
```text
README.md
docs/ARCHITECTURE.md
docs/BUSINESS_RULES.md
docs/DATABASE_SCHEMA.md
docs/HANDOFF.md
docs/PROJECT_SPEC.md
docs/PROGRESS.md
docs/ROADMAP.md
docs/TEST_PLAN.md
lib/core/database/app_database.dart
lib/features/habits/data/counter_correction_preview.dart
lib/features/habits/data/counter_correction_writer.dart
lib/features/habits/data/counter_day_reader.dart
lib/features/habits/data/counter_recovery_store.dart
lib/features/habits/data/habit_analytics_reader.dart
lib/features/habits/data/habit_creation_audit.dart
lib/features/habits/data/measurement_time_range_habit_store.dart
lib/features/habits/data/non_counter_version_service.dart
lib/features/habits/data/numeric_today_reader.dart
lib/features/habits/data/unified_habit_history_reader.dart
lib/features/habits/domain/counter_day_status.dart
lib/features/habits/domain/habit_analytics.dart
lib/features/habits/domain/measurement_time_range_habit.dart
lib/features/habits/presentation/counter_correction_controls.dart
lib/features/habits/presentation/habit_builder_screen.dart
lib/features/habits/presentation/history_analytics_screen.dart
lib/features/habits/presentation/non_counter_version_audit_controls.dart
lib/features/habits/presentation/numeric_today_cards.dart
test/counter_correction_controls_test.dart
test/counter_habit_writer_test.dart
test/counter_recovery_store_test.dart
test/counter_target_test.dart
test/database_test.dart
test/habit_lifecycle_test.dart
test/habit_schedule_store_test.dart
test/habit_schema_test.dart
test/history_analytics_screen_test.dart
test/non_counter_creation_audit_test.dart
test/non_counter_version_service_test.dart
test/occurrence_schema_test.dart
test/test_schema_downgrade.dart
test/unified_habit_registry_test.dart
```

Untracked:
```text
lib/features/habits/data/habit_scoring_store.dart
lib/features/habits/domain/dynamic_normalized_scoring.dart
test/analytics_historical_categories_test.dart
test/correction_analytics_privacy_test.dart
test/correction_impact_staleness_test.dart
test/correction_resolved_integrity_test.dart
test/dynamic_normalized_scoring_test.dart
test/dynamic_scoring_analytics_test.dart
test/dynamic_scoring_forms_test.dart
test/dynamic_scoring_screen_test.dart
test/dynamic_scoring_services_test.dart
test/history_filter_regression_test.dart
test/history_privacy_reload_test.dart
test/history_streak_privacy_test.dart
test/history_streak_uncertain_test.dart
test/history_typed_outcomes_test.dart
```

### Final Milestone 2 Audit & Verification — next session

1. Read AGENTS.md and its ordered documentation list, then inspect Git status and the actual implementation. Preserve all existing modifications; do not infer completion from this handoff alone.
2. Review Dynamic Normalized Scoring end to end: all formulas and signed/zero/overflow boundaries; completion versus score; legacy N/A and score coverage; historical version/tolerance immutability; midnight/date offset semantics; preview and audit impacts. Investigate any reproducible defects without rewriting user records or silently changing approved business rules.
3. Verify schema v13 upgrade paths using representative old data, foreign keys, rollback, disk reopen, unchanged source values/statuses, no guessed configuration and no destructive migration. Investigate unlinked legacy correction audit conflicts without inventing their order; report unresolved cases explicitly.
4. Check History privacy, filter and streak behavior, correction preview staleness, accessibility and regression against Milestone 1. Run relevant formatting, analysis, the full test suite and Android debug build; record exact commands and observed results. Do not weaken tests or treat previous results as new results.
5. Check for an authorized Android device/emulator. If available, use separate test application ID and isolated storage for visual and migration/restart probes; do not clear, uninstall or modify the user's app/data or bypass security. If unavailable, report the exact limitation. Check midnight and timezone behavior only on disposable data.
6. Update affected technical documentation, PROGRESS.md and HANDOFF.md with actual outcomes and any remaining risks. Provide beginner-friendly Indonesian manual steps and expected results. Request the owner's explicit Milestone 2 acceptance; do not start Milestone 3 without it.
