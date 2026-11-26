# Progress

## Active milestone

Milestone 0 — Project Foundation: in progress, not accepted. Android device/emulator launch and on-device persistence are not verified. Do not start Milestone 1 before all foundation acceptance criteria pass.

## Implemented

- Existing Flutter template adapted for Hibi; Android development ID remains `com.example.hibi`.
- Material 3 dark theme, five navigable destinations explicitly marked unavailable where appropriate, Japanese-style local date, injectable clock, midnight and resume refresh.
- Riverpod and GoRouter; Drift/SQLite version 1 settings table, foreign keys enabled, injected executor, explicit failure for unsupported upgrades; visible database initialization error.
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

## Limitations

No Android device/emulator visual, launch, restart or integration test has been performed. Database is not encrypted; privacy and backup features do not exist yet. No habit, finance or other future feature is implemented. No Git repository is present. No release signing or final application ID has been configured.

## Next bounded task

Run the app on an Android device or emulator, verify all five destinations, Japanese date rendering, database startup and persistence across restart; resolve any Android-specific failures before considering Milestone 0 accepted.
