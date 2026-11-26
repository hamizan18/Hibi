# Progress

## Active milestone

Milestone 0 — Project Foundation: accepted against its foundation criteria. Milestone 1 — Dynamic Habit Engine is next and has not been started.

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

## Limitations

Database is not encrypted; privacy and backup features do not exist yet. No habit, finance or other future feature is implemented. No release signing or final application ID has been configured. See the latest handoff for current Android verification.

## Next bounded task

Design the Milestone 1 habit identity and effective-dated configuration schema and its migration with tests, before adding habit UI.
