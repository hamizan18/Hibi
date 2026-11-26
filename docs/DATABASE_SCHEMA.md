# Database schema

## Current status

Schema version 11 is defined in `lib/core/database/app_database.dart` using explicit Drift SQL. SQLite is not encrypted at rest.

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
| `habit_version_audit` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habit_version_audit` | `habit_id` | TEXT | NOT NULL, foreign key to `habits(id)`, ON DELETE RESTRICT |
| `habit_version_audit` | `operation` | TEXT | NOT NULL, `create` or `schedule_version` |
| `habit_version_audit` | `previous_values` | TEXT | NULL or JSON snapshot before change |
| `habit_version_audit` | `updated_values` | TEXT | NOT NULL, JSON snapshot after change |
| `habit_version_audit` | `occurred_at_utc_us` | INTEGER | NOT NULL; UTC Unix microseconds |
| `habit_occurrences` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habit_occurrences` | `habit_id` | TEXT | NOT NULL, foreign key to `habits(id)`, ON DELETE RESTRICT; unique with `local_date` |
| `habit_occurrences` | `habit_version_id` | TEXT | NOT NULL, foreign key to `habit_versions(id)`, ON DELETE RESTRICT |
| `habit_occurrences` | `local_date` | TEXT | NOT NULL, valid ISO local date; unique with `habit_id` |
| `habit_occurrences` | `target_count` | INTEGER | NOT NULL, positive integer snapshot matching the applicable counter version on insert |
| `habit_occurrences` | `unit` | TEXT | NOT NULL, nonblank snapshot matching that version on insert |
| `habit_counter_events` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habit_counter_events` | `occurrence_id` | TEXT | NOT NULL, foreign key to `habit_occurrences(id)`, ON DELETE RESTRICT |
| `habit_counter_events` | `quantity` | INTEGER | NOT NULL, positive integer; multiple events per occurrence |
| `habit_counter_events` | `occurred_at_utc_us` | INTEGER | NOT NULL, integer UTC Unix microseconds |
| `habit_counter_event_audit` | `event_id` | TEXT | NOT NULL, PRIMARY KEY, foreign key to `habit_counter_events(id)`, ON DELETE RESTRICT |
| `habit_counter_event_audit` | `occurrence_id` | TEXT | NOT NULL, foreign key to `habit_occurrences(id)`, ON DELETE RESTRICT; occurrence snapshot |
| `habit_counter_event_audit` | `quantity` | INTEGER | NOT NULL, positive integer creation snapshot |
| `habit_counter_event_audit` | `occurred_at_utc_us` | INTEGER | NOT NULL, integer UTC Unix microseconds at creation |
| `habit_counter_resolutions` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habit_counter_resolutions` | `occurrence_id` | TEXT | NOT NULL, UNIQUE, foreign key to `habit_occurrences(id)`, ON DELETE RESTRICT |
| `habit_counter_resolutions` | `state` | TEXT | NOT NULL, `failed` or `excused` |
| `habit_counter_resolutions` | `reason` | TEXT | NULL or user-provided reason |
| `habit_counter_resolutions` | `target_count` | INTEGER | NOT NULL, positive integer snapshot |
| `habit_counter_resolutions` | `progress_total` | INTEGER | NOT NULL, integer from zero to strictly below target |
| `habit_counter_resolutions` | `occurred_at_utc_us` | INTEGER | NOT NULL, integer UTC Unix microseconds |
| `habit_counter_recoveries` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habit_counter_recoveries` | `occurrence_id` | TEXT | NOT NULL, foreign key to `habit_occurrences(id)`, ON DELETE RESTRICT |
| `habit_counter_recoveries` | `recovery_local_date` | TEXT | NOT NULL, valid ISO local date |
| `habit_counter_recoveries` | `quantity` | INTEGER | NOT NULL, positive integer |
| `habit_counter_recoveries` | `original_target_count` | INTEGER | NOT NULL, positive integer snapshot |
| `habit_counter_recoveries` | `original_progress_total` | INTEGER | NOT NULL, integer from zero to strictly below original target |
| `habit_counter_recoveries` | `remaining_deficit` | INTEGER | NOT NULL, integer from zero to strictly below initial deficit |
| `habit_counter_recoveries` | `note` | TEXT | NULL or user-provided note |
| `habit_counter_recoveries` | `occurred_at_utc_us` | INTEGER | NOT NULL, integer UTC Unix microseconds |
| `habit_schedules` | `habit_version_id` | TEXT | NOT NULL, PRIMARY KEY, foreign key to `habit_versions(id)`, ON DELETE RESTRICT |
| `habit_schedules` | `recurrence` | TEXT | NOT NULL: `daily`, `weekdays`, `interval`, `monthly_skip`, `monthly_last_day`, or `one_time` |
| `habit_schedules` | `start_date` | TEXT | NOT NULL, valid ISO date; inclusive anchor |
| `habit_schedules` | `end_exclusive` | TEXT | NULL or valid ISO date strictly after start (exact `+1 day` for `one_time`) |
| `habit_schedules` | `weekday_mask` | INTEGER | NULL for `daily`/`one_time`; 1–127 for `weekdays`; $>0$ interval days for `interval`; 1–31 day-of-month for monthly |
| `habit_counter_correction_audit` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank; immutable counter correction preimage/postimage audit |
| `habit_version_metadata` | `habit_version_id` | TEXT | NOT NULL, PRIMARY KEY, foreign key to `habit_versions(id)`; category, symbol, priority, privacy, ordering |
| `habit_checklist_items` | `id` | TEXT | NOT NULL, PRIMARY KEY; independent checklist items per `habit_version_id` |
| `habit_checklist_occurrences` | `id` | TEXT | NOT NULL, PRIMARY KEY; unique `(habit_id, local_date)` checklist occurrence |
| `habit_checklist_item_logs` | `id` | TEXT | NOT NULL, PRIMARY KEY; immutable per-item `completed`, `failed`, or `excused` log |
| `habit_checklist_item_recoveries` | `id` | TEXT | NOT NULL, PRIMARY KEY; immutable prior-date recovery for a failed checklist item |
| `habit_avoidance_targets` | `habit_version_id` | TEXT | NOT NULL, PRIMARY KEY; non-negative integer `max_incidents` |
| `habit_avoidance_occurrences` | `id` | TEXT | NOT NULL, PRIMARY KEY; unique `(habit_id, local_date)` avoidance occurrence |
| `habit_avoidance_incidents` | `id` | TEXT | NOT NULL, PRIMARY KEY; multiple incident entries per avoidance occurrence |
| `habit_avoidance_resolutions` | `id` | TEXT | NOT NULL, PRIMARY KEY; immutable `confirmed_completed`, `failed`, or `excused` decision |
| `habit_typed_targets` | `habit_version_id` | TEXT | NOT NULL, PRIMARY KEY; validated `boolean`, `duration`, `measurement`, `time_of_day`, or `range` target |
| `habit_typed_occurrences` | `id` | TEXT | NOT NULL, PRIMARY KEY; unique `(habit_id, local_date)` occurrence for typed habits |
| `habit_duration_events` | `id` | TEXT | NOT NULL, PRIMARY KEY; positive integer `duration_seconds` (`manual` or `timer`) |
| `habit_typed_logs` | `id` | TEXT | NOT NULL, PRIMARY KEY; immutable result log for boolean, duration, measurement, time_of_day, or range |
| `habit_lifecycle_events` | `id` | TEXT | NOT NULL, PRIMARY KEY, nonblank |
| `habit_lifecycle_events` | `habit_id` | TEXT | NOT NULL, foreign key to `habits(id)`, ON DELETE RESTRICT |
| `habit_lifecycle_events` | `effective_date` | TEXT | NOT NULL, valid ISO date; unique per habit |
| `habit_lifecycle_events` | `previous_state` | TEXT | NULL or one of the lifecycle states |
| `habit_lifecycle_events` | `state` | TEXT | NOT NULL: `scheduled`, `active`, `paused`, `archived`, or `deleted` |
| `habit_lifecycle_events` | `reason` | TEXT | NULL or local user-provided reason |
| `habit_lifecycle_events` | `created_at_utc_us` | INTEGER | NOT NULL, integer UTC Unix microseconds |

The settings and identity primary keys and per-habit revision/occurrence/lifecycle-date uniqueness constraints have SQLite implicit unique indexes. `habit_versions_by_habit_start` indexes `(habit_id, effective_start)`; `habit_version_audit_by_habit_time` indexes `(habit_id, occurred_at_utc_us)`; `habit_occurrences_by_version_date` indexes `(habit_version_id, local_date)`; `habit_counter_events_by_occurrence_time` indexes `(occurrence_id, occurred_at_utc_us)`; `habit_counter_recoveries_by_occurrence_time` indexes `(occurrence_id, occurred_at_utc_us)`; `habit_counter_correction_audit_by_habit_time` indexes `(habit_id, occurred_at_utc_us)`. Insert and update triggers reject overlapping half-open version intervals for the same habit. Valid dates are real `YYYY-MM-DD` dates in years 0001–9999. Foreign keys are enabled per connection. Migrations from versions 1 through 10 to 11 add missing tables and upgrade `habit_schedules` transactionally without replacing existing records. Unsupported transitions fail rather than reset data. The disk database is `hibi.sqlite` in the application support directory.

Counter targets are linked to a specific habit version; the row's presence identifies a counter configuration. Counts use exact positive whole units in the signed SQLite 64-bit integer range (1 to 9223372036854775807), without fractions or floating point; decimal measurements need a separate precision design. `CounterTarget` additionally trims whitespace and rejects blank units. Existing versions without target rows remain explicitly unconfigured: migration never guesses a type, target or unit.

Occurrence insertion requires a matching habit, applicable version interval, and matching counter target snapshot. Triggers reject occurrence interpretation changes, target changes/deletion when occurrences reference the version, and version changes that would invalidate an existing occurrence or change its name. A version end may still change when all referenced occurrences remain in range. These restrictions do not implement a correction workflow or permanent privacy deletion; those workflows require an explicit future design and migration.

`habit_schedules` stores one typed recurrence per habit version. In `weekday_mask`, bit 0 is Monday and bit 6 is Sunday; at least one weekday must be selected. The recurrence anchor may precede the version's effective interval; consumers must combine both intervals. Existing versions without a schedule remain unconfigured and migration does not guess defaults. Triggers reject inserting, changing or deleting a schedule if its version has occurrences; these triggers do not constitute a correction/audit workflow and future privacy deletion needs an explicit design.

`HabitLifecycleStore` records effective-dated transitions with previous/new state, optional reason and UTC creation time, using a transaction and an injected clock. Its internal append path validates transition order and disallows backdating or two events on the same date. Database triggers reject event updates/deletes and insertion that could reinterpret existing later occurrences; direct SQL can still bypass the store's transition validation. Existing habits receive no inferred events. `HabitApplicabilityReader` combines the latest applicable lifecycle event, effective version and stored schedule; it returns `unknown` for missing necessary data, rather than guessing. See BUSINESS_RULES.md for boundaries.

Schema version 8 adds `habit_counter_event_audit`; migration from versions 1–7 preserves existing events and does not invent audit records for them. The internal counter writer inserts each event and its creation snapshot in one transaction. Its ordinary API only appends; direct SQL is not protected against update/delete of event or audit rows and can bypass the writer. The event ID is the audit primary key, identifying one creation snapshot per event. The snapshot and source event are unencrypted.

Counter progress is derived on demand from `habit_occurrences.target_count` and `habit_counter_events.quantity`; the reader does not persist a status or modify events. It reads the target snapshot and events together, so later versions do not change an earlier occurrence's target. Missing occurrences return no result, and invalid/overflowing totals fail rather than being silently adjusted.

The internal counter-day view reads lifecycle/schedule applicability and any matching occurrence, progress, resolution and recovery entries in one transaction; it does not write rows or create a pending occurrence. Its raw applicability result is independent of the optional historical occurrence, while `CounterDayReader.evaluate` additionally checks the applicable version's counter target when no occurrence exists and surfaces any contradictory historical data as `conflict` without hiding underlying records. `CounterDayRosterReader` reads all habits in deterministic `(created_at_utc_us, id)` order for a requested local date, pairing effective version metadata with `CounterDayReader.evaluate` in one read transaction. `CounterHistoryReader`, `CounterConfigurationReader`, `CounterAuditReader` and `CounterHabitOverviewReader` read inclusive date intervals, partitioned version timelines (`priorVersions`, `effectiveVersion`, `futureVersions`), all five persisted audit tables (`habit_version_audit`, `habit_lifecycle_events`, `habit_counter_event_audit`, `habit_counter_resolutions`, `habit_counter_recoveries`), and combined habit overviews in read-only transactions without inventing missing legacy records. `CounterTodayActionService` and `CounterLifecycleActionService` wrap current-day occurrence/progress/resolution writes and semantic lifecycle transitions in atomic write transactions.

Schema version 9 adds immutable counter resolution creation records, serving as their own local audit snapshots. The database rejects resolution updates/deletes; internal writers enforce applicability, current local date and progress consistency. One resolution exists per occurrence. Internal progress writes reject resolved occurrences, but direct SQL can bypass progress and resolution consistency checks. Migration from earlier versions creates no resolutions. Future correction and permanent privacy deletion require an explicit design.

Schema version 10 adds immutable counter recovery creation records (`habit_counter_recoveries`), each storing its recovery local date, positive quantity, original target/progress snapshot, remaining deficit after the entry, optional note and UTC timestamp. Update and delete triggers reject changes without a future correction workflow. Multiple recovery rows may reference one failed prior-date occurrence until `remaining_deficit` reaches zero. Migration from versions 1–9 preserves existing data without inventing recovery records. Direct SQL can bypass application-level eligibility and cumulative-deficit checks; `CounterDayReader.evaluate` flags inconsistent raw-SQL recovery rows as `conflict`.

Internal counter creation writes the identity, initial version, target, explicitly supplied schedule, initial active lifecycle event and creation audit atomically. The lifecycle event becomes effective on the selected start date, including future starts; no separate scheduled event is inserted. A future-version append atomically closes the prior version, inserts its successor and explicit schedule, and audits both schedules; a missing prior schedule is recorded as null, not inferred. An internal on-demand occurrence store checks applicability and counter target within a transaction and preserves existing records, without setting a status or writing progress. The stores are not integrated with notifications or UI and do not implement historical correction. Lifecycle reasons and audit/occurrence data may contain personal information and are unencrypted. Lifecycle trigger restrictions must be addressed explicitly in future audited correction and privacy-deletion workflows. No production records are seeded.

## Planned logical domains (not implemented schema)

Habit identity, categories, effective-dated versions, schedules, lifecycle events, checklist items, occurrences, progress events, checklist logs, recoveries and reminders; finance wallets, transactions, categories, transfers and budgets; journal entries, mood and tags; goals, milestones and progress; XP and attribute events, achievements; focus sessions and presets; settings, audit and backup history. Introduce only tables needed by the active milestone.

## Required design and migration constraints

Enable and test SQLite foreign keys. Give records stable identifiers; define and document actual primary and foreign keys, column types, nullability, indexes and uniqueness with each migration. An occurrence references its habit and applicable version, with one occurrence per habit and applicable date; checklist results and reward events must be unique as appropriate, while multiple progress events remain possible. Effective version intervals must not overlap. Related writes, transfers, corrections and restore are transactional. Index commonly queried dates and foreign keys; derived statistics must be rebuildable. Monetary IDR amounts are integer rupiah, never floating point; explicitly define precision for habit measurements. Separate ISO calendar dates from consistent UTC timestamps. Use explicit, tested, data-preserving migrations; destructive resets are not a normal migration strategy.
