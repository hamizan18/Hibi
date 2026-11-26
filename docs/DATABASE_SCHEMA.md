# Database schema

## Current status

Schema version 3 is defined in `lib/core/database/app_database.dart` using explicit Drift SQL. SQLite is not encrypted at rest.

| Table | Column | SQLite type | Constraints |
| --- | --- | --- | --- |
| `app_settings` | `key` | TEXT | NOT NULL, PRIMARY KEY |
| `app_settings` | `value` | TEXT | NOT NULL |
| `habits` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habits` | `created_at_utc_us` | INTEGER | NOT NULL; UTC Unix microseconds |
| `habit_versions` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habit_versions` | `habit_id` | TEXT | NOT NULL, foreign key to `habits(id)`, ON DELETE RESTRICT |
| `habit_versions` | `name` | TEXT | NOT NULL, nonblank |
| `habit_versions` | `effective_start` | TEXT | NOT NULL; valid ISO calendar date |
| `habit_versions` | `effective_end` | TEXT | NULL or valid ISO date strictly after start; exclusive |
| `habit_versions` | `created_at_utc_us` | INTEGER | NOT NULL; UTC Unix microseconds |
| `habit_versions` | `revision` | INTEGER | NOT NULL, positive, unique per habit |
| `habit_counter_targets` | `habit_version_id` | TEXT | NOT NULL, PRIMARY KEY, foreign key to `habit_versions(id)`, ON DELETE RESTRICT |
| `habit_counter_targets` | `target_count` | INTEGER | NOT NULL, SQLite integer storage class, positive |
| `habit_counter_targets` | `unit` | TEXT | NOT NULL, nonblank after SQLite space trimming |

The settings and identity primary keys and per-habit revision constraint have SQLite implicit unique indexes. `habit_versions_by_habit_start` indexes `(habit_id, effective_start)`. Insert and update triggers reject overlapping half-open intervals for the same habit, including unbounded ends. Dates must be real calendar dates in `YYYY-MM-DD` with years 0001–9999. The database enables `PRAGMA foreign_keys = ON` per connection. New databases create the current schema; migrations 1→3 and 2→3 add required tables transactionally without replacing existing settings or versions. Unsupported upgrades or downgrades fail rather than reset data. The disk database is `hibi.sqlite` in the application support directory.

Counter targets are linked to a specific habit version; the row's presence identifies a counter configuration. Counts use exact positive whole units in the signed SQLite 64-bit integer range (1 to 9223372036854775807), without fractions or floating point; decimal measurements need a separate precision design. `CounterTarget` additionally trims whitespace and rejects blank units. Existing versions without target rows remain explicitly unconfigured: migration never guesses a type, target or unit.

Only identity, version name, dates, revision metadata and counter target storage exist. Other tracking types, schedules, lifecycle events, occurrences, correction/audit workflows and a production habit editing service are not implemented. `CounterTargetStore` is a low-level insert/read API, not authorization to modify history; raw SQL constraints cannot enforce correction or audit policy. No user habits or production records are seeded.

## Planned logical domains (not implemented schema)

Habit identity, categories, effective-dated versions, schedules, lifecycle events, checklist items, occurrences, progress events, checklist logs, recoveries and reminders; finance wallets, transactions, categories, transfers and budgets; journal entries, mood and tags; goals, milestones and progress; XP and attribute events, achievements; focus sessions and presets; settings, audit and backup history. Introduce only tables needed by the active milestone.

## Required design and migration constraints

Enable and test SQLite foreign keys. Give records stable identifiers; define and document actual primary and foreign keys, column types, nullability, indexes and uniqueness with each migration. An occurrence references its habit and applicable version, with one occurrence per habit and applicable date; checklist results and reward events must be unique as appropriate, while multiple progress events remain possible. Effective version intervals must not overlap. Related writes, transfers, corrections and restore are transactional. Index commonly queried dates and foreign keys; derived statistics must be rebuildable. Monetary IDR amounts are integer rupiah, never floating point; explicitly define precision for habit measurements. Separate ISO calendar dates from consistent UTC timestamps. Use explicit, tested, data-preserving migrations; destructive resets are not a normal migration strategy.
