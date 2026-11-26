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
