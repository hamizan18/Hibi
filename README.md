# Hibi (日々)

Small steps, every day. An offline-first personal life management application for Android.

## Status

Milestone 0 (foundation) is in progress. Habit tracking, history, finance and other product features are not implemented yet. See `docs/PROGRESS.md` and `docs/ROADMAP.md`.

## Development

Install Flutter with Android development support and accept the Android SDK licenses. This project was inspected with Flutter 3.47.6 and Dart 3.13.5.

```sh
flutter pub get
flutter run
flutter analyze
flutter test
```

Select a connected Android device or start an Android emulator before running the app. The development application ID `com.example.hibi` is a placeholder and must be replaced before public distribution.

The application has no account or backend. Local storage is not automatically encrypted; see `docs/SECURITY_PRIVACY.md`. Read `AGENTS.md` and the documentation in `docs/` before continuing development.
