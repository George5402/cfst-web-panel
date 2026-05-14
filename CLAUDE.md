# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Start development server (default port 3088, auto-falls back to 3089)
node server.js
# or
npm start

# Build minified frontend (app.js → min.js via terser)
npm run build:min

# No test suite configured
npm test  # no-op
```

The server requires a `cfst` binary in the project root (`./cfst` on Linux/macOS, `.\cfst.exe` on Windows) with execute permissions before it will start. Node.js >= 18 is required.

## Architecture

This is a two-file application: `server.js` (Express backend, ~1550 lines) and `public/app.js` (vanilla JS SPA, ~1000 lines). There is no frontend build step required for development — the browser loads `public/app.js` directly; `public/min.js` is only the production artifact.

### Backend (`server.js`)

**Runtime state** is held in six module-level Maps/variables that are initialized once at startup and never reset without a process restart:

- `dbData` — in-memory mirror of `database.json`. Schema: `{ saved_ips, settings, test_history, last_targets }`. All reads and writes go through `getSetting`/`setSetting`, which serializes to disk atomically via a tmp-file rename through a serial promise queue (`dbSaveQueue`). Settings keys: `cfst_config`, `dns_api`, `dns_staging`.
- `runningTasks` — active `cfst` child processes keyed by `taskId`.
- `progressClients` / `lastProgress` / `taskPhase` / `lastProgressKey` — SSE fan-out state per `taskId`.
- `coloCache` — TTL cache for Cloudflare datacenter lookups (24h on success, 60s on failure).

**Test lifecycle** (`POST /api/start-test`):

1. Receives target IPs/domains and a `taskId` (or generates one).
2. In `ip` mode, validates all targets are pure IPs; in `cname` mode, resolves domains to IPs via `dns.promises` with concurrency control (`resolveTargets`).
3. Writes resolved IPs to a temp file `ip_{taskId}.txt` to avoid shell arg length limits (important on Android/Termux).
4. Spawns `cfst` binary via `child_process.spawn` with args derived from `getAdaptiveConfig` (which adjusts thread counts based on target count).
5. Parses each stdout line with `parseProgressLine`, deduplicates via `lastProgressKey`, and fans out to SSE clients via `sendProgress`.
6. After `cfst` exits, reads `result_{taskId}.csv`, enriches top-N results with Cloudflare datacenter region (via HTTP probe to `speed.cloudflare.com/cdn-cgi/trace` with spoofed `Host` header), and returns final data.
7. Cleans up `ip_{taskId}.txt` and `result_{taskId}.csv`.

**Real-time progress** uses SSE (`GET /api/progress/:taskId`) as the primary channel and a polling fallback (`GET /api/progress-state/:taskId`) that the frontend switches to if SSE fails.

**DNSPod integration**: Settings page stores `{ provider, domain, tokenId, tokenKey, token, line }` under `dns_api`. The DNS tab has a "staging" buffer (`dns_staging` setting) — records are added/edited locally first, then batch-published to Tencent DNSPod (`POST /api/cf/dns/sync`). The server also supports Tencent Cloud API credentials (detected by `tokenId` starting with `AKID`) with TC3-HMAC-SHA256 signing.

**System maintenance endpoints** (`/api/system/update-engine`, `/api/system/update-ips`) download the `cfst` binary and official Cloudflare IP ranges from GitHub releases.

### Frontend (`public/app.js` + `public/index.html`)

Single-page app with four tabs: **Test** (速测) / **Favorites** (收藏) / **DNS** / **Settings** (设置). All tab state is managed by `switchTab(view)`. Global state lives in module-level variables: `testTableData`, `favTableData`, `parsedTargets`, `currentTaskId`, `progressSource` (SSE EventSource), `progressPollTimer`.

The frontend has a custom `<select>` implementation (`initCustomSelects`, `closeAllCustomSelects`) because native selects cannot be styled consistently across mobile and desktop — don't replace these with native selects.

Theming uses CSS custom properties on `:root` (light) and `body.dark` (dark). The `applyTheme` function switches the class and persists to `localStorage`.

## Key Conventions

- **Task IDs**: All speed test operations are scoped to a `taskId` (UUID). Temp files follow the pattern `ip_{taskId}.txt` / `result_{taskId}.csv`.
- **Database writes**: Always go through `setSetting(key, JSON.stringify(value))` — never write `dbData` directly and call `saveDb()` inline. The serial save queue prevents corruption under concurrent writes.
- **Progress normalization**: `normalizeProgress` maps raw `cfst` output to phases (`Ping 测试`, `下载测速`, `目标扫描`). The percent calculation differs by phase: Ping maps to 0–70%, download to 70–100%.
- **IP file passthrough**: Never pass large IP lists as CLI args — always write to `ip_{taskId}.txt` and use `-f` flag.
- **Port**: Default is 3088 via `process.env.PORT` or the constant; the server only attempts one fallback port (3089). If both are occupied, startup fails.
