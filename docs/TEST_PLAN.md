# Test plan

This plan specifies future checks, not passed results. Run unit, widget, isolated database and integration tests appropriate to each milestone. Inject a fake clock, test business rules independently of UI, and never weaken tests or disable validation to pass. Record exact commands and observed outcomes in PROGRESS.md/HANDOFF.md. Do not claim device verification without a supported device or emulator.

| Test ID | Required scenarios |
| --- | --- |
| T-001 | Verify offline operation and absence of network services or authentication. |
| T-002 | Launch on available Android device/emulator, navigation, database initialization and persistence after restart; foundational tests and static analysis. |
| T-003 | Create today and future habits; verify yesterday excluded, weekday/interval/monthly nonexistent dates, leap year, lifecycle pause/resume/archive/restore and repeated idempotent generation. |
| T-004 | Effective target changes preserve historical targets; preview, confirm and audit backdated changes and recalculation. |
| T-005 | 2 + 3 pages against target 5; repeated incidents, independent checklist items, invalid inputs, partial/multiple bounded recovery linked to original date without double-counting, missing versus failed. |
| T-006 | Weighted scoring, coverage, exclusions, no-data, corrections and streaks through paused and unscheduled dates. |
| T-007 | Opening balance, income, expense, atomic transfer, editing, budgets and integer precision. |
| T-008 | Journal and goal persistence; focus start/pause/resume/completion, interruption and restart, duplicate prevention. |
| T-009 | One reward per eligible occurrence, repeated saves, correction reconciliation, level boundaries and achievement validity; private exclusions. |
| T-010 | Private records absent from default exports and diagnostic logs; app lock; valid backup round trip, invalid backup rejection and failed restore preserving original data; Android notification limitations. |
| T-011 | Local midnight, leap years, month/year boundaries and time-zone changes do not reinterpret history. |
| T-012 | Forms, validation, loading, empty states, navigation, screen reader labels, scaling, small screens and Japanese UI/PDF glyphs. |
| T-013 | Foreign-key enforcement, uniqueness, atomicity and schema migration preserving existing records. |
| T-014 | Import preview, conflicting/duplicate headings, explicit mapping, missing values and transactional confirmation. |

Before marking a milestone complete, run relevant `dart format .`, `flutter analyze`, `flutter test`; when required and available also `flutter test integration_test` and `flutter build apk --debug`, plus necessary code generation. Execute integration tests on a supported device/emulator when available. Roadmap acceptance criteria are mandatory; report unavailable checks and unresolved failures rather than claiming completion.

For Android process-restart persistence verification, use a separate test application ID and private storage, not the user's `com.example.hibi` database. The test should use the real `AppDatabase.open()` path, write a known marker and process ID, stop its process, relaunch, and verify both the marker and a different process ID. Remove only the test application and its own data afterwards. A database file's existence alone does not establish that a written value survived. Record the device, commands, outcomes and any limitations in PROGRESS.md.

## Milestone 7 PDF verification

`test/pdf_japanese_export_test.dart` checks extracted Unicode mappings and page text for the Japanese date, a public habit and a public goal, plus exclusion and explicit inclusion of a private goal. Supplement this with an independent PDF reader and visual inspection: an exception-free PDF or a font mapping alone does not prove the glyphs render correctly. Retain private-by-default export behavior and the unencrypted-file warning.

The isolated Android 16 probe generated PDFs using `ExportService` and the bundled font; independent PyMuPDF extraction and host-side visual inspection passed for the fixture described in PROGRESS.md. The five-tab Android integration test also passed in the isolated app with injected gateways. These results do not establish on-device biometric or notification delivery behavior.


## Milestone 2 validation gaps

- Android visual checks, Android database migration and current-milestone Android restart verification remain outstanding. There is no `integration_test/` suite. Use a separate test application ID and isolated storage for migration probes; never clear or uninstall the user's app to test migration.
- Recorded boolean, duration, measurement, time-of-day and range outcomes now have isolated history coverage, including a read-only `total_changes()` check. Extend mixed-type and historical-privacy fixtures and verify every relevant occurrence/log table as needed.
- Exercise period presets, combined filters, hidden selections, both streak modes, empty and pending views, private-data redaction during reload, screen-reader semantics, enlarged text, small screens and Japanese glyphs.
- Verify local midnight, time-zone changes, leap days and month/year boundaries in the history and correction flows. Verify actual older Android database upgrades and rollback with representative data; host migration fixtures are not Android verification.
- Dynamic normalized scoring has automated formula, service, aggregation, form and isolated migration coverage. Android-specific migration, visual behavior and time-zone/device-clock changes remain unverified. See ARCHITECTURE.md for supported and unavailable score cases.

## Historical correction acceptance (partially implemented)

Counter target correction has a preview, confirmation, immutable audit and host-side recalculation coverage. The wider scenarios below are acceptance targets, not a claim that every scenario or every tracking type has been verified.

- Preview a counter target correction spanning multiple versions and existing occurrences: show exact local date range, original/proposed targets, affected record counts, and possible score, streak and reward impact; distinguish unknown impact from zero.
- Cancel or decline confirmation: all versions, occurrences, events, recoveries, audit entries and derived state remain unchanged.
- Change any affected version, schedule, occurrence, event or recovery after preview: confirmation must fail as stale without writes; a new preview is required. Exercise a local-day boundary and time-zone change.
- A confirmation displaying cross-habit scores must detect changes in contributing habit data before commit. Analytics-bound previews now include the habit-table snapshot in stale checks; see `test/correction_impact_staleness_test.dart`.
- Confirm a valid correction: preserve preimages and source events, resolve versions deterministically without overlap, append old/new audit snapshots, and reconcile every implemented affected derived value. Verify an occurrence before the range and an unrelated habit stay unchanged.
- Reject incompatible tracking-type/unit reinterpretation; preserve missing and pending records, and never invent failures or recovery quantities.
- Inject a failure after partial mutation, after audit insertion and during any derived-data reconciliation; each failure must leave the database and derived state unchanged. Repeating a confirmed request must not duplicate changes or rewards.
- Verify private correction previews and audit history follow private-access rules and sensitive details do not appear in diagnostic logs or ordinary exports.
