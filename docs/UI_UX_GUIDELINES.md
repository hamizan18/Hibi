# UI and UX guidelines

Use a calm Japanese-minimalist, modern dashboard; default dark theme. Tokens: background `#101512`, surface `#19211C`, sage primary `#A3BFA8`, primary text `#E7EDE8`, secondary text `#929F96`, border `#2D3A31`, success `#81B896`, recovered `#D5B579`, failed `#D77F7F`. Use consistent typography and spacing, rounded cards and subtle borders; avoid excessive effects and use animation only when useful.

Five planned navigation destinations: Today (routine logging and summaries), History (calendar and records), Finance (wallets, transactions, categories, budgets), Growth (analytics, goals, focus, XP, levels and achievements), More (habits, journal, settings, privacy, backup, restore and export). Clearly mark unavailable functionality; do not imply placeholders work.

Use English UI with Japanese-style local dates such as `2026年11月26日(木)`; render Japanese correctly in UI and PDF reports. Support font scaling, contrast, accessible touch targets, small screens, keyboard, scrolling and informative empty states. Do not use color alone: add status icons and accessible labels. Routine logging should be quick. Private content must not leak into previews, notifications, search or drill-downs.
