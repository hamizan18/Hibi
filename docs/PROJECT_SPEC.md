# Project specification

Hibi (日々), “Small steps, every day.” / “小さな一歩、毎日。”, is a single-user, offline personal life management and growth application. It adapts to evolving routines rather than imposing fixed habits. Android is the only target; the interface is English, currency is IDR, and dates display like 2026年11月26日(木). There is no account or remote authentication.

## Scope and status

Milestone 0 foundation acceptance is verified; Milestone 1 remains in progress. The habit engine supports counter, checklist, avoidance, boolean, duration, measurement, time-of-day and range tracking, dated configuration, schedules, optional templates and internal counter correction. The roadmap describes future history and analytics, finance, journal and mood, goals and focus, gamification, privacy, reminders, backups and exports. Hide or clearly label unfinished functionality. Starter templates are optional and editable, never automatically populated user records. No real history, financial records, incidents or religious activity may be fabricated.

The Habit Builder is available from Today and More. Today supports current-day logging and dated lifecycle controls for all eight configured tracking types, and prior-date recovery for eligible counter and checklist records. Future-start habits show their first configuration for lifecycle management without making them applicable today. An eligible habit can be paused from its initial start date without overwriting the original event; ordinary transitions remain append-only. Historical correction UI remains unavailable.

## Boundaries

The application must work without internet and use local persistence only. No backend, cloud database, external APIs, Firebase, Supabase, advertising, mandatory authentication, AI analysis, medical diagnosis, religious judgment, or automatic prayer-time or location inference. Rule-based insights must not infer causation. No unauthorized feature or automatic commit, push, publication or release. Future text-record import is optional until separately approved, and requires review and confirmation.

The development Android application ID is `com.example.hibi`, a placeholder requiring owner confirmation before public distribution. Local SQLite is not encrypted by this foundation; device security and future app lock are not equivalent to database encryption. See SECURITY_PRIVACY.md.
