# Architecture

The intended design is feature-first with only the layers each feature needs. Presentation owns screens, interaction and UI state, and must not issue SQL. Riverpod providers/controllers coordinate operations and inject dependencies. Domain owns entities, calculations and rules, preferably pure Dart. Data owns repositories, Drift DAOs and mappings. Core contains shared database, clock, errors, security, services and widgets. Dependencies flow inward toward domain; avoid cycles, duplicated rules, God classes and needless abstractions.

The foundation uses Flutter, Material 3, Riverpod, GoRouter and Drift/SQLite as required by Milestone 0. Inject repositories, the clock and services for deterministic tests. Navigation groups planned features into Today, History, Finance, Growth and More. Features not yet built must not appear operational.

Path Provider supplies the local database directory. Future candidate packages include Intl, FL Chart, Table Calendar, Flutter Local Notifications, Local Auth, Flutter Secure Storage, File Picker, Share Plus, PDF and Printing. Add only when the active milestone requires them and compatibility has been checked; these are not claims that packages or features are installed. Flutter Test and Integration Test support appropriate tests. See DECISIONS.md and DATABASE_SCHEMA.md for decisions and persistence constraints.
