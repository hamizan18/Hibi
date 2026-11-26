# Security and privacy

## Threat model and current limitation

Hibi is offline and single-user; sensitive data must never be sent to external services. Device theft, unlocked-device access, backups, notification previews, exported files, logs and recent-app previews can disclose data. The foundation's SQLite database is **not encrypted at rest**. Android device protections are not a guarantee against a compromised or unlocked device. App lock, when built, is not database encryption. Do not represent planned safeguards as operational.

The local `habit_version_audit` table stores habit names, target units, counts and schedule details for complete creations and future-version writes in unencrypted snapshots; lifecycle events may contain optional user-provided reasons. They are not tamper-proof, have no private-view access controls or privacy deletion workflow yet, and are not exposed in the UI. Those controls must be implemented before a privacy milestone can be accepted.

## Planned privacy milestone

Provide optional local PIN, supported device biometrics, automatic and resume locking, and private visibility controls. Never store plaintext PIN or biometric data; use a suitable salted PIN verifier, secure storage and platform biometrics. Define forgotten-PIN recovery without insecure bypass or fictitious account recovery. Evaluate vetted database encryption and encrypted backups before accepting this milestone; never invent cryptography.

Protect private identity and values in dashboard, history, analytics and aggregate drill-down, notifications, search, reports, exports, backups and recent-app previews where supported. Use generic private notification text by default; require explicit permission to expose sensitive names or journal text. Exclude private records from ordinary human-readable exports by default and warn about unencrypted CSV, PDF and JSON. Logs must omit secrets and sensitive security values. Audit is local change history, not tamper-proof forensics; permanent privacy deletion must remove or anonymize related sensitive audit and derived data.

Backups should use supported encryption by default. Never export biometric credentials or security secrets. Validate structure, schema/version compatibility, required fields, relationships and integrity; preview and confirm full replacement, create a recoverable pre-restore backup where feasible, then restore atomically. Invalid files must not partially overwrite current data. Do not implement ambiguous merge without a conflict-resolution design.
