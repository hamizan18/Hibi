# Hibi (日々)

Small steps, every day. / 小さな一歩、毎日。

An offline-first, single-user personal life management and growth application for Android.

## Status

Milestones 0 through 6 are accepted by the owner, and **Milestone 7 — Finalization** is implemented and verified on host (`dart format`, `flutter analyze`, full automated test suite, Android debug APK and Android release APK builds). See `docs/PROGRESS.md`, `docs/ROADMAP.md` and `docs/HANDOFF.md` for exact verification commands, results and documented limitations.

Implemented modules (SQLite schema v17):
- **Today & Dynamic Habits (Milestone 1):** eight tracking types (`counter`, `checklist`, `avoidance`, `boolean`, `duration`, `measurement`, `timeOfDay`, `range`), effective-dated versioning, schedules, dated lifecycle transitions, bounded recovery, audited historical counter target corrections, and optional editable starter templates (`O`, `N`, `S`, `P`).
- **History & Analytics (Milestone 2):** calendar heatmaps, filters, private-by-default redaction, Dynamic Normalized Scoring, recording/score/checklist coverage, period reports and scheduled-occurrence streaks.
- **Finance (Milestone 3):** integer-IDR wallets with opening balances, income/expense categories, audited transactions, atomic inter-wallet transfers excluded from income/expense, period-scoped expense budgets, cash-flow vs balance reports and immutable audit trail.
- **Growth — Journal, Goals & Focus (Milestone 4):** optional multi-entry-per-day journal & neutral mood reflections, goals with milestones, immutable status history and deduplicated linked progress, and restart-safe 25/5/15 Focus/Pomodoro sessions.
- **Gamification (Milestone 5):** opt-in versioned immutable XP ledger (`10 XP` completed, `5 XP` recovered), `100 × L` levels, deterministic achievements preserving unlock history on invalidation, custom non-moralizing activity attributes, private/opt-out exclusions and atomic correction reconciliation.
- **Privacy, Reminders & Data (Milestone 6):** optional local App Lock (PBKDF2-HMAC-SHA256 salted PIN in Android Keystore, BiometricPrompt, resume lock, `FLAG_SECURE`, wipe-based forgotten-PIN recovery), trigger-preserving permanent privacy deletion, schedule-aware local reminders with generic private text and inexact Android fallback, AES-GCM-256 encrypted atomic backup/restore with pre-restore snapshots, and private-by-default JSON/CSV/PDF exports.
- **Deferred (not enabled):** optional legacy text import (`R-014`) remains disabled until separately approved.

## Development & Verification

Install Flutter with Android development support and accept the Android SDK licenses. Verified with Flutter 3.47.6 and Dart 3.13.5.

```sh
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

## Release & Security Notes

- The development Android application ID `com.example.hibi` is a placeholder and must be confirmed/replaced by the owner before public distribution.
- Release signing automatically reads `android/key.properties` (ignored by Git) when present, and falls back to debug keys for local build verification only.
- Hibi has no backend, account, network permission (`INTERNET` is absent), analytics, advertising or AI.
- Local SQLite (`hibi.sqlite`) is **not encrypted at rest**; App Lock protects ordinary unlocked-device UI access only, while exported backups are encrypted by default with PBKDF2-HMAC-SHA256 + AES-GCM-256. See `docs/SECURITY_PRIVACY.md`.
