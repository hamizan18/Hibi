# UI and UX guidelines

Use a calm, Japanese-inspired dark interface with soft green accents, rounded cards and subtle borders. Prefer a lightweight layered appearance over expensive blur effects. Use straightforward English, clear labels and spacing; keep less frequent controls available without overwhelming daily logging.

Five planned navigation destinations: Today (routine logging and summaries), History (calendar and records), Finance (wallets, transactions, categories, budgets), Growth (analytics, goals, focus, XP, levels and achievements), More (habits, journal, settings, privacy, backup, restore and export). Clearly mark unavailable functionality; do not imply placeholders work.

Use English UI with Japanese-style local dates such as `2026年11月26日(木)`; render Japanese correctly in UI and PDF reports. Support font scaling, contrast, accessible touch targets, small screens, keyboard, scrolling and informative empty states. Do not use color alone: add status icons and accessible labels. Routine logging should be quick. Private content must not leak into previews, notifications, search or drill-downs.

The History calendar uses responsive, selectable date tiles with readable scores and an explanation of N/A. Tile columns adapt to screen width and text scale; status is conveyed by text as well as color. The Android launcher icon depicts a sprout and rising sun, representing small daily growth.

The habit builder groups existing options into labeled sections with short explanations and responsive fields. Tab changes use immediate route transitions; local data is still loaded asynchronously and may show a brief textual loading state. Do not replace unknown data with fabricated values or hide database errors.

In Habit Builder, separate fields sufficiently for floating labels, keep the create action inside system safe areas, and change preference values only from their switches (not by tapping the adjacent label). Switches retain accessible labels.
