# Handoff

## Current state

Milestone 0 foundation acceptance is verified; Milestone 1 is next and has not been started. Read AGENTS.md and the documents it lists before continuing.

## Latest work

Verified Android process-restart persistence with a temporary separate Android test app using Hibi's `AppDatabase.open()`. Updated PROGRESS.md, TEST_PLAN.md, ROADMAP.md, PROJECT_SPEC.md, README.md and this handoff. No production application code or user data was changed.

## Decisions and constraints

See DECISIONS.md and DATABASE_SCHEMA.md. The database uses explicit SQL via Drift without code generation, and only has a settings table. Application ID `com.example.hibi` is a development placeholder; SQLite is not encrypted. Android only; no backend, account, or fake records.

## Verification and blockers

`flutter analyze` passed and all 6 existing `flutter test` tests passed. The isolated Android probe wrote a marker under PID 17687, then read it under PID 19742 after force-stop and relaunch. The probe APK and temporary host project were removed; Hibi's database was not touched. See PROGRESS.md for the command sequence and previous Android visual verification. This was a temporary test app, not an integration_test suite. SQLite is not encrypted.

## Next bounded task

Design the Milestone 1 habit identity and effective-dated configuration schema and a non-destructive migration with tests. Preserve historical configurations and user data; do not build unrelated features.
