# Handoff

## Current state

Milestone 0 is accepted. Milestone 1 is in progress, with only initial database identity/name-version infrastructure implemented. Read AGENTS.md and the documents it lists before continuing.

## Latest work

Added version 2 habit identity and dated name-version schema, non-overlap triggers and a transactional migration from version 1. Changed `lib/core/database/app_database.dart`, `test/database_test.dart`, added `test/habit_schema_test.dart`, and updated schema, decisions, status and handoff documentation. No UI, production habit records or write API were added.

## Decisions and constraints

See DECISIONS.md and DATABASE_SCHEMA.md. Drift uses explicit SQL without code generation. Schema constraints do not implement correction authorization or immutable historical data; don't expose writes until those protections are implemented. Application ID `com.example.hibi` is a development placeholder; SQLite is not encrypted.

## Verification and blockers

Before the change, analysis and 6 tests passed. After the change, `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, and all 9 `flutter test` tests passed. Migration, rollback, non-overlap and historical name lookup were exercised against isolated local databases. No Android migration test or integration test was run; Milestone 1 is incomplete.

## Next bounded task

Design and implement typed, versioned target configuration for an initial tracking type, with explicit precision and tests; preserve migration safety and do not expose historical edits without correction/audit protections.
