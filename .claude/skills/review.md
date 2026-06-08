---
name: review
description: Review pending changes in cfst-web-panel for correctness, security, and consistency with the project's architecture conventions.
---

Review the current diff (staged and unstaged changes) against the cfst-web-panel architecture conventions documented in CLAUDE.md.

Check for:
1. **Database writes** — all writes must go through `setSetting(key, JSON.stringify(value))`, never direct `dbData` mutation + inline `saveDb()`.
2. **IP file passthrough** — large IP lists must be written to `ip_{taskId}.txt` and passed via `-f` flag, not as CLI arguments.
3. **Task ID scoping** — temp files must follow the `ip_{taskId}.txt` / `result_{taskId}.csv` pattern.
4. **Custom selects** — never replace the custom `<select>` implementation with native selects.
5. **Progress normalization** — Ping phase maps to 0–70%, download to 70–100%.
6. **Security** — no shell injection via user-supplied IPs or task IDs, no XSS in rendered output.
7. **Port handling** — server only attempts one fallback port (3089); don't add extra retry loops.

Report findings as a short bulleted list grouped by severity: blocking issues first, then minor suggestions.
