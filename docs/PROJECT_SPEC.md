# Project specification

Hibi (日々), “Small steps, every day.” / “小さな一歩、毎日。”, is a single-user, offline personal life management and growth application. It adapts to evolving routines rather than imposing fixed habits. Android is the only target; the interface is English, currency is IDR, and dates display like 2026年11月26日(木). There is no account or remote authentication.

## Scope and status

Milestone 0 is accepted. Milestone 1 habits and Milestone 2 History/Analytics are implemented and host-tested, including Dynamic Normalized Scoring; Android device visual and migration checks remain outstanding. The owner has not accepted Milestone 2; do not begin Finance before explicit acceptance. The habit engine supports eight tracking types, dated configuration, schedules, optional templates and historical counter target correction. History provides filtering, private-by-default redaction, weighted scores, recording and score coverage, heatmaps, reports and scheduled-occurrence streaks. Starter templates are optional; never fabricate real history or user records.

The Habit Builder is available from Today and More. Today supports current-day logging, dated lifecycle controls, strictly future version/configuration scheduling and read-only version/audit inspection for all eight configured tracking types (`counter`, `checklist`, `avoidance`, `boolean`, `duration`, `measurement`, `timeOfDay`, `range`), prior-date recovery for eligible counter and checklist records, and read-set-bound historical counter target correction preview/confirmation. Future-start habits show their first configuration for lifecycle management without making them applicable today. An eligible habit can be paused from its initial start date without overwriting the original event; ordinary transitions remain append-only.

## Boundaries

The application must work without internet and use local persistence only. No backend, cloud database, external APIs, Firebase, Supabase, advertising, mandatory authentication, AI analysis, medical diagnosis, religious judgment, or automatic prayer-time or location inference. Rule-based insights must not infer causation. No unauthorized feature or automatic commit, push, publication or release. Future text-record import is optional until separately approved, and requires review and confirmation.

The development Android application ID is `com.example.hibi`, a placeholder requiring owner confirmation before public distribution. Local SQLite is not encrypted by this foundation; device security and future app lock are not equivalent to database encryption. See SECURITY_PRIVACY.md.
