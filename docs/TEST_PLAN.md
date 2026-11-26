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
