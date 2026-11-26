# Business rules

All rules below describe planned behavior unless implemented and verified in the active milestone.

## Dates and scheduling

The day changes at 00:00 local device time. Store ISO `YYYY-MM-DD` calendar keys separately from UTC event timestamps; retain local date and time-zone context as needed so zone changes do not reinterpret historical records. Refresh the dashboard on resume or day change without requiring the app to stay open. Inject a clock; handle leap years, month/year boundaries and zone changes.

Support daily, weekdays, anchored weekly/monthly/custom intervals, fixed date ranges and one-time schedules, future start, optional end and pause periods. Monthly nonexistent dates default to skip unless the user selects last-day fallback. Effective intervals must not overlap. Occurrence generation is deterministic and idempotent, at most one primary occurrence per habit and applicable date, with multiple events; never depend on a continuous background process.

## Habits and history

Habits are user-defined and can be created, edited, paused, resumed, archived and deleted. Store identity separately from effective-dated versions of name/display, type, target, unit, checklist, priority, schedule, recovery, streak, scoring, rewards and attribute associations. Occurrences reference their applicable version. Future changes never rewrite prior targets; incompatible type or unit changes never reinterpret history. Backdated changes require affected records and date range preview, impact explanation, confirmation, transactional update, audit and derived-data recalculation.

Support boolean, counter (multiple entries), duration (manual and timer), independent multi-checklist items, avoidance (multiple incidents and configurable maximum), measurement with validated units, time-based and range-based tracking. Critical target configurations must be validated and typed, not opaque unvalidated strings. Each habit supports applicable description, symbol, icon, color, category, priority, target, unit, schedule, effective dates, reminders, recovery, streak, score/reward inclusion, privacy, ordering and lifecycle.

The currently implemented counter target representation stores a positive whole-number count and a nonblank unit per habit version. Counts use signed 64-bit SQLite integers; fractional values are not supported for this type. A missing target row is unconfigured, never a zero target or inferred default. Counter recording, historical correction and audit workflows remain unimplemented.

Scheduled habits do not apply before start; paused periods do not count as expected. Resumption retains history; archives remain historically accessible. Soft-delete by default; hard deletion requires explicit confirmation, explains impact, leaves no orphans and handles sensitive audit/derived data. Pause/archive updates future reminders. Lifecycle requires dated events, not only an active flag.

Optional editable starter templates: private Self Control/O avoidance, max 0, no recovery; Quran Reading/N, 5 pages daily with recovery; Daily Prayers/S, Fajr, Dhuhr, Asr, Maghrib and Isha independently configurable; Push Up/P, 10 repetitions daily. They can be skipped and never seed historical records. Do not infer sensitive meaning or make religious judgments.

## Status, recovery, scoring and streaks

Stable states: `completed`, `failed`, `recovered`, `pending`, `partial`, `excused`, `not_applicable`. Missing is pending, never silently failed. Completed satisfies the configured target; partial has insufficient progress; failed is explicitly unsuccessful or confirmed by a rule; recovered fulfills an eligible prior deficit; excused is an explicit exemption; not applicable is unscheduled. Avoidance with no incident data is not automatically confirmed success: require daily confirmation or a configured completion rule. Validate input and disallow contradictory states; preserve checklist-level status.

Recovery references the original occurrence, optional checklist item, target date, original target/progress, remaining deficit, time, quantity, note and result. Support partial/multiple recovery; never exceed the deficit or automatically count it toward today's independent target. Disable by default where recovery is meaningless; allow eligible counters and checklists.

Priority weights Critical 4, High 3, Normal 2, Low 1. Weighted score = 100 × sum(weight × multiplier) / sum(eligible weights): completed 1, recovered 0.75, partial normalized and clamped, failed 0; pending, excused and not applicable excluded. Allow per-habit exclusion; show recording coverage separately and item-level checklist coverage. No eligible data means No Data, not 0% or 100%; incomplete recording must not look fully successful. Scores do not measure human worth or faith.

Streaks follow scheduled occurrences, not raw calendar days. Configurable accepted statuses include completed-only and completed-plus-recovered. Unscheduled, paused and excused dates normally neither increment nor break; past pending makes the streak unresolved, current pending does not immediately reset it, confirmed failure breaks it. Recalculate after corrections.

## Finance, journal, goals, focus and rewards

Store IDR as integer rupiah. Balance = opening + income − expense + incoming transfers − outgoing transfers. Transfers are atomic, never income/expense, and cannot target the same wallet. Validate amount, date, category, wallet and type; audit historical changes. Budgets apply to explicit periods/categories and expenses only; no automatic rollover unless enabled. Distinguish cash flow from balance and incomplete records from total finances.

Journal/mood are optional, support multiple entries per date, tags, gratitude and reflections, and never penalize absence or diagnose. Goals have planned, in-progress, completed, paused or abandoned status, optional milestones and linked habits; prevent duplicate manual/linked progress and retain history. Focus/Pomodoro defaults are 25/5/15 minutes with a long break after four sessions; persist deadline/elapsed state for restart, distinguish interruption and prevent duplicate progress/rewards.

Gamification uses versioned rules and an idempotent ledger: defaults 10 XP completed, 5 recovered, zero failed/pending/excused/not-applicable; only one reward per eligible occurrence, reconciled on correction. Level 1 starts at zero; advancing from level L requires 100 × L XP. Achievements must be deterministic; preserve unlock history even if later invalidated. Custom attributes reflect activity, not competence or moral worth. No XP for spending, larger income or repeated edits; permit opt-out, especially for private/religious habits, and avoid punishment or manipulation.

## Notifications, imports and audit

Reminders are local, schedule-aware, user-configured and rescheduled on changes; handle permission, reboot and Android scheduling constraints. Use inexact fallback when exact alarms unavailable and never guarantee delivery. No automatic prayer times. Private text is generic by default.

Audit significant creation, changes, lifecycle and historical corrections with entity, operation, old/new values, timestamp and optional reason; transact with related writes, omit secrets and enforce private access. Ordinary audit is append-oriented; privacy deletion also addresses sensitive audit data.

Optional legacy import requires parsing, user mapping of symbols and start dates, preview, explicit resolution of duplicate dates/conflicts, confirmation, transactional import and recalculation with summary. Missing data stays missing/pending; never fabricate values, balances or incidents. Map “outcome” to expense only on user confirmation.
