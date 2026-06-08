---
name: cfst-web-panel
description: Work with cfst-web-panel — a Node.js/Express web UI for the CloudflareSpeedTest (cfst) binary. Use when starting the dev server, debugging test runs, editing the frontend SPA, or managing DNSPod sync.
---

# cfst-web-panel

A two-file web panel (`server.js` + `public/app.js`) that wraps the `cfst` binary with a glassmorphism UI for Cloudflare IP speed testing, node management, and Tencent DNSPod sync.

## When to use

Use this skill when working on any task in the cfst-web-panel repository: running the server, debugging speed test lifecycle issues, editing the frontend, reviewing diffs, or understanding the architecture.

## Instructions

### Starting the server

1. Confirm `./cfst` exists and is executable (`chmod +x cfst` if needed; download from upstream CloudflareSpeedTest releases if missing).
2. Run `node server.js` (default port 3088, auto-falls back to 3089).
3. Open `http://localhost:3088` — verify all four tabs load: 速测, 收藏, DNS, 设置.

### Architecture rules — always follow these

- **Database writes**: only via `setSetting(key, JSON.stringify(value))`. Never mutate `dbData` directly and call `saveDb()` inline.
- **IP passthrough**: write large IP lists to `ip_{taskId}.txt`, pass with `-f` flag. Never pass as CLI args.
- **Task IDs**: all temp files must use the pattern `ip_{taskId}.txt` / `result_{taskId}.csv`.
- **Custom selects**: the custom `<select>` implementation (`initCustomSelects`) must not be replaced with native selects.
- **Progress phases**: Ping maps to 0–70%, download to 70–100% in `normalizeProgress`.
- **Port**: only one fallback port (3089) is attempted; don't add extra retry loops.

### Reviewing changes

Check diffs against the architecture rules above. Flag: shell injection via user-supplied IPs or task IDs, XSS in rendered output, direct `dbData` writes, native selects replacing custom ones, CLI arg length violations.

### Building for production

Run `npm run build:min` to minify `public/app.js` → `public/min.js` via terser.
