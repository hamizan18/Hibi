# Handoff

## Current state

Milestone 0 is in progress; do not begin the habit engine. Existing Flutter template was adapted without initializing Git or creating production records. Read AGENTS.md and the documents it lists before continuing.

## Latest work

Added the foundation: `lib/app/app.dart`, `lib/app/theme/hibi_theme.dart`, `lib/core/services/app_clock.dart`, `lib/core/database/app_database.dart`, app entry point, dependencies in `pubspec.yaml` and lockfile, Android display label, `test/foundation_test.dart`, `test/database_test.dart`, and permanent documentation. Removed obsolete Flutter counter test. Five destinations are navigation placeholders, not implemented product features. The app initializes its local database before showing the router and reports initialization errors.

## Decisions and constraints

See DECISIONS.md and DATABASE_SCHEMA.md. The database uses explicit SQL via Drift without code generation, and only has a settings table. Application ID `com.example.hibi` is a development placeholder; SQLite is not encrypted. Android only; no backend, account, or fake records.

## Verification and blockers

See PROGRESS.md for exact commands. Dependency resolution, format, static analysis after fixing one unused import, database and widget tests, and Android debug APK build passed. The build emitted Java native-access and Android SDK XML version warnings. No connected Android device or emulator or AVD image was found, so launch, visual review and persistence across Android restart remain unverified. Visual Studio is absent but is not required for the Android target.

## Next bounded task

Connect an Android device or install/start an Android emulator. Run the debug app, inspect all destinations and Japanese glyphs, and verify database initialization and persistence across restart. Fix Android-specific issues and repeat relevant checks before declaring Milestone 0 complete.
