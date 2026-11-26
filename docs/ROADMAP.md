# Roadmap

Milestone 0 foundation acceptance is verified; Milestone 1 is in progress and incomplete. An internal audited counter writer, counter occurrence/event schema, and daily/weekday evaluator and low-level versioned schedule storage exist; operational tracking and historical correction workflows do not. Each milestone depends on the accepted foundation and preceding relevant capabilities. See PROGRESS.md for exact results and limitations.

| Milestone | Scope | Acceptance summary |
| --- | --- | --- |
| 0 Foundation | Environment, project structure, theme, Riverpod, navigation, Drift, clock, error handling, documentation and foundational tests | Launch on available supported Android device/emulator; navigation, database initialization and persistence verified; analysis and foundational tests pass. Record unavailable checks. |
| 1 Dynamic habits | Builder, categories, tracking types, recurrence, versioning, lifecycle, occurrences, logging, checklist, events, recovery and audit | Dynamic creation; history preserved across changes; no pre-start or pause failures; events persist and corrections auditable after restart. |
| 2 History and analytics | Calendar, filtering, weighted score, coverage, heatmaps, streaks, reports | Deterministic fixtures; proper exclusions and pending; corrections recalculate. |
| 3 Finance | Wallets, opening balances, income, expenses, categories, transfers, budgets, reports | Accurate balances, atomic transfers excluded from income/expense, edits reflected. |
| 4 Journal, goals, focus | Journal, mood, goals, milestones, focus/Pomodoro and history | Persistence, interruption/restart handling and no duplicate linked progress. |
| 5 Gamification | XP ledger, levels, achievements, attributes and reward history | Idempotent rewards, reconciliation, reproducible achievements and privacy exclusions. |
| 6 Privacy, reminders, data | App lock, PIN, biometrics, private controls, local notifications, backup/restore and JSON/CSV/PDF | Supported lifecycle lock, ordinary disclosure protection, valid restore, invalid restore safety, correct reports, documented Android/security limits. |
| 7 Finalization | Regression, migrations, accessibility, performance, UI, release configuration and documentation | Approved requirements implemented or explicitly deferred; no known critical data loss; required tests pass; release build verified where possible. |

Legacy text import remains optional until its milestone is explicitly approved. No future feature is implied to be implemented by this roadmap.
