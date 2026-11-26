# Requirements and traceability

These are approved product requirements, not assertions of implementation. Milestone acceptance is defined in ROADMAP.md and TEST_PLAN.md. Each ID maps to the corresponding test scenario ID below; results must be recorded separately, never assumed.

| ID | Requirement and acceptance criterion | Test |
| --- | --- | --- |
| R-001 | Android-only offline local app; no backend, account, external data transfer, advertisements or AI. | T-001 |
| R-002 | Foundation navigation, theme, injected clock and local database initialize and persist on supported Android. | T-002 |
| R-003 | Create/edit dynamic typed habits, schedules and dated lifecycle; no pre-start or paused failures. | T-003 |
| R-004 | Preserve effective-dated historical configuration and audited confirmed backdated corrections. | T-004 |
| R-005 | Idempotent daily occurrences, multiple events, item statuses, explicit failure and bounded recovery without double counting. | T-005 |
| R-006 | Deterministic score, coverage, applicable-date history, reports and streaks; pending distinct from failure, no-data explicit. | T-006 |
| R-007 | Integer IDR wallets, validated transactions, atomic transfers, budgets and auditable corrections. | T-007 |
| R-008 | Optional journals/mood, goals and restart-safe focus sessions; no duplicated linked progress. | T-008 |
| R-009 | Versioned, idempotent XP and deterministic achievements reconciled on correction, respecting exclusions. | T-009 |
| R-010 | Optional local lock and private views, safe notifications, validated atomic backups and private-by-default exports. | T-010 |
| R-011 | Local dates remain stable across timezone changes; correct midnight and calendar boundaries using injected clock. | T-011 |
| R-012 | Usable accessible Material 3 UI, screen scaling, labeled statuses, Japanese dates and correct PDF glyphs. | T-012 |
| R-013 | Explicit tested non-destructive migrations, foreign keys, uniqueness and transaction integrity. | T-013 |
| R-014 | Optional legacy import must preview and resolve conflicts, preserve missing data and require confirmation. | T-014 |

Non-functional requirements: maintainable feature-first design, deterministic calculations, privacy by default, no fabricated records, no hidden failures, reproducible derived statistics, no destructive migration, sufficient accessibility and clear documentation of limitations. Developer placeholder application ID `com.example.hibi` must be confirmed before distribution. Full detailed rules are in BUSINESS_RULES.md and SECURITY_PRIVACY.md.
