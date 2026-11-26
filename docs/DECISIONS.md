# Architecture decision records

## ADR-001: Offline-only Android foundation — 2026-11-26

Context: a single-user personal application must function without network access. Decision: Flutter Android-only, local Drift/SQLite, no backend or accounts. Alternatives: cloud synchronization or remote database. Consequences: no account recovery or cross-device synchronization; backups require explicit local data management. SQLite is not encrypted by default.

## ADR-002: Feature-first with injected dependencies — 2026-11-26

Context: incremental features need testable rules without needless complexity. Decision: presentation, application/state, domain and data responsibilities grouped by feature, with Riverpod for injection and an injectable clock. Alternatives: monolithic widgets or a full framework for every layer. Consequences: independently testable logic; create layers only where useful.

## ADR-003: Milestone-scoped dependencies — 2026-11-26

Context: preferred packages cover future functionality but are not all needed now. Decision: add only compatible packages needed by the active milestone; use Material 3, GoRouter, Riverpod and Drift for the foundation. Alternatives: install all planned packages immediately. Consequences: future dependency choices and versions remain subject to SDK compatibility and milestone approval.

## ADR-004: Development identity — 2026-11-26

Context: no final application ID was supplied. Decision: retain `com.example.hibi` as a development placeholder. Alternative: invent a production identifier. Consequence: confirm the permanent ID before public distribution; changing it affects Android application identity.

## ADR-005: Minimal explicit Drift schema — 2026-11-26

Context: the foundation needs persistence without creating future feature tables. Decision: Drift with a single explicit SQL settings table and no generated code. Native SQLite opens lazily in the application support directory; tests inject their own executor. Alternatives: generated Drift tables now or unused feature tables. Consequences: small initial dependency and schema surface, but queries do not have automatic table change notifications; introduce typed generated tables and explicit migrations as features require them.

## ADR-006: Local date presentation — 2026-11-26

Context: the foundation only displays one Japanese-style date format. Decision: use a small weekday mapping and an injected local clock; recalculate on resume and at the next local midnight. Alternative: introduce Intl as a direct dependency for this single format. Consequence: add Intl if later formatting requirements justify it; historical date storage remains a separate future responsibility.

## ADR-007: Dated habit identity schema — 2026-11-26

Context: habit identity and historical configuration must be separated without destroying existing settings. Decision: schema version 2 adds identity and name-version tables via an explicit transactional migration; ISO local dates use inclusive starts and exclusive ends, with SQLite overlap triggers and unique per-habit revision numbers. UTC creation instants use integer microseconds since the Unix epoch. Alternative: overwrite habit names or rely on application-only interval checks. Consequences: adjacent versions are valid and overlapping intervals are rejected even through direct SQL; application-level correction, auditing, typed target configuration and lifecycle rules remain necessary before exposing habit writes. Do not treat this partial schema as the completed habit engine.

## ADR-008: Exact counter target per habit version — 2026-11-26

Context: an initial measurable target needs deterministic precision and historical association without assuming targets for existing versions. Decision: a separate `habit_counter_targets` row belongs to one habit version; `CounterTarget` validates a positive integer and nonblank unit, and SQLite checks integer storage and positivity. Existing versions receive no inferred row during migration. Alternatives: floating-point quantities or unvalidated generic JSON. Consequences: counter quantities are whole signed 64-bit integers; decimal measurement targets need a separately documented representation. A low-level insert/read store exists but is not a user-facing editing workflow, audit mechanism or backdated correction authorization.

## ADR-009: Transactional counter version writes — 2026-11-26

Context: version writes must not silently rewrite history and must commit with local audit records. Decision: use a narrowly scoped `CounterHabitWriter` and schema version 4; create a habit/version/target/audit together, or close the latest open counter version and append a strictly future version with before/after audit snapshots in one transaction. Reject same-day and backdated edits until an explicit correction workflow exists. Alternative: expose the low-level target store directly or silently rewrite historical rows. Consequences: only counter creation and future append are supported, with injected local clock and caller-supplied IDs; raw SQL and the low-level store still bypass these safeguards. Audit is not tamper-proof and stores potentially sensitive names, units and quantities in unencrypted local storage. Privacy controls, permanent deletion, correction preview/confirmation, and recalculation must be designed before exposing this path to users.

## ADR-010: Historical correction requires an exact preview — 2026-11-26

Context: the present schema cannot preserve occurrence interpretation during a backdated change; historical records, audit, statistics and rewards must not be silently rewritten. Decision: design a typed preview/confirm flow tied to a snapshot of the full affected read set; revalidate inside one transaction, retain preimages and reconcile implemented derived data or reject the correction. Alternatives: overwrite versions or accept confirmation without checking concurrent changes. Consequences: no correction API or UI exists yet. Occurrence/event storage, immutable historical representation, privacy controls and reconciliation contracts must be designed and implemented before correction is enabled. Details and acceptance scenarios are in ARCHITECTURE.md and TEST_PLAN.md.

## ADR-011: Counter occurrence snapshots and events — 2026-11-26

Context: daily records must refer to the correct historical configuration and support multiple progress entries without creating fabricated failures. Decision: schema version 5 adds counter occurrences with unique habit/local-date keys, applicable-version and target-snapshot validation, plus multiple integer counter events with UTC timestamps. Triggers reject edits that would invalidate an existing occurrence. Alternatives: infer dates from event timestamps or derive old targets from mutable current configuration. Consequences: history is protected against those direct changes, but the schema alone does not implement schedules, lifecycle, occurrence generation, status, audited event corrections, privacy deletion or aggregates. Existing records are not populated during migration. Future correction/privacy workflows require explicit changes to these restrictions.

## ADR-012: Date-only recurrence evaluation — 2026-11-26

Context: schedule applicability must be deterministic across calendar boundaries without reinterpreting stored local dates on device time-zone changes. Decision: use validated Gregorian `LocalDate` components and pure daily/selected-ISO-weekday evaluators with an inclusive anchor and optional exclusive end. Alternatives: compare local midnight timestamps or consult the system clock during recurrence evaluation. Consequences: callers must select the relevant local date and combine the recurrence result with effective version and lifecycle state. At the time of this decision schedules were not persisted; low-level persistence was subsequently added in ADR-013. Monthly, interval and other recurrence rules need separate implementations.

## ADR-013: Version-scoped schedule persistence — 2026-11-26

Context: recurrence rules must remain associated with historical habit versions without inferring schedules for existing data. Decision: schema version 6 stores one daily or selected-weekday schedule per version, with validated ISO dates and a bounded seven-bit ISO weekday mask; absent rows remain unconfigured. A low-level store maps the typed evaluator to this representation. SQLite triggers refuse schedule writes on versions already referenced by occurrences. Alternatives: default existing versions to daily or store unvalidated generic JSON. Consequences: existing history is not silently assigned a schedule, but version creation, audit, lifecycle and recurrence checks are not yet integrated with this store; corrections and privacy deletion require explicit future workflows.

## ADR-014: Effective-dated lifecycle and three-way applicability — 2026-11-26

Context: pause, archive and delete must not become false failures, and migrated versions have no trustworthy lifecycle or schedule by default. Decision: schema version 7 adds append-oriented effective-dated lifecycle events with previous/new state, reason and UTC timestamp. An internal reader combines lifecycle, effective version and stored recurrence and returns `applicable`, `notApplicable` or `unknown`. Backdated and same-day duplicate transitions are rejected, and existing later occurrences block lifecycle inserts. Alternatives: a single mutable `isActive` flag or interpreting missing data as active. Consequences: missing configuration stays unknown; conservative restrictions require a future explicit correction/privacy deletion workflow. Direct SQL can bypass transition validation; lifecycle is not yet wired to notifications, habit creation, occurrence generation or UI.

## ADR-015: Complete initial counter creation — 2026-11-26

Context: a habit version without an explicit schedule and lifecycle event cannot be evaluated reliably. Decision: `CounterHabitWriter.create` requires a caller-supplied schedule and lifecycle event ID, and writes the habit, version, target, schedule, initial active event and audit snapshot in one transaction using one captured clock instant. The active event is effective on the selected habit start date; a future start is not applicable beforehand and no separate scheduled event is guessed. An already-ended schedule is rejected. Alternatives: infer a daily schedule or write configuration in separate transactions. Consequences: callers must explicitly supply a schedule; no defaults or occurrence records are created. The separate future-version path does not yet attach a schedule and is not a complete user-facing editing workflow.

## ADR-016: Explicit schedule on future counter versions — 2026-11-26

Context: a future version without its own schedule cannot be evaluated, and silently copying an older schedule could misrepresent the user's choice. Decision: require the caller to provide a schedule and write it in the existing future-version transaction, together with target, version boundaries and before/after audit snapshots. A missing previous schedule stays missing and is captured as null. Reject schedules ending on or before the new version starts. Alternatives: silently default to daily or copy the previous recurrence. Consequences: historical schedules and occurrences remain associated with their versions; callers must supply the full intended recurrence and anchor. Occurrence generation, UI and historical correction are still unimplemented. This supersedes the earlier statements that future-version creation does not attach a schedule.
