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

## Repository Layout

```
cfst-web-panel/
├── public/
│   ├── index.html          # Frontend HTML, all CSS, tab layout
│   └── app.js              # Vanilla JS SPA (~1000 lines, no framework)
├── server.js               # Express backend (~1550 lines)
├── package.json            # express, cors, multer; terser (dev)
├── Dockerfile              # Multi-stage build, node:18-alpine
├── docker-compose.yml      # Named volume panel-data:/app
├── install.sh              # One-click install script
├── README.md               # Chinese user documentation
└── docs/ui-preview.png
```

## Architecture

This is a two-file application: `server.js` (Express backend) and `public/app.js` (vanilla JS SPA). There is no frontend build step required for development — the browser loads `public/app.js` directly; `public/min.js` is only the production artifact.

### Backend (`server.js`)

#### Runtime State

Seven module-level variables initialized at startup and never reset without a process restart:

- `dbData` — in-memory mirror of `database.json`. Schema: `{ saved_ips, settings, test_history, last_targets }`. All reads and writes go through `getSetting`/`setSetting`, which serializes to disk atomically via a tmp-file rename through a serial promise queue (`dbSaveQueue`). Settings keys: `cfst_config`, `dns_api`, `dns_staging`, `bestcf_sources`.
- `runningTasks` — active `cfst` child processes keyed by `taskId` (`{ child, watchdog, stoppedByUser }`).
- `progressClients` — `Map<taskId, Set<Response>>` for SSE fan-out.
- `lastProgress` — `Map<taskId, payload>` — last normalized payload, used to replay state to late-connecting SSE clients.
- `taskPhase` — `Map<taskId, phase>` — persists current phase across progress updates.
- `lastProgressKey` — `Map<taskId, string>` — deduplication key to suppress identical SSE writes.
- `coloCache` — `Map<ip, {region, expireAt}>` — TTL cache for Cloudflare datacenter lookups (24h success, 60s failure).

#### Key Constants

- `DEFAULT_PORT`: 3088 (from `process.env.PORT` or hardcoded); single fallback to 3089
- `CFST_BIN_NAME`: platform-aware (`cfst` vs `cfst.exe`)
- `MIN_NODE_MAJOR`: 18

#### Database Schema (`database.json`)

```json
{
  "saved_ips": [
    { "ip": "1.2.3.4", "region": "🇺🇸 洛杉矶", "ping": 15.5, "speed": 25.67,
      "tag": "US-Fast", "created_at": 1623456789000, "updated_at": 1623456890000 }
  ],
  "settings": {
    "cfst_config": "{\"n\":200,\"t\":4,...}",
    "dns_api": "{\"provider\":\"dnspod\",\"domain\":\"cdn.example.com\",...}",
    "dns_staging": "[{\"type\":\"A\",\"line\":\"default\",\"value\":\"1.2.3.4\",\"ttl\":600}]",
    "bestcf_sources": "[...]"
  },
  "test_history": {
    "1.2.3.4": [
      { "ts": 1623456789000, "ping": 15.5, "speed": 25.67, "loss": 0 }
    ]
  },
  "last_targets": []
}
```

`test_history` keeps a rolling window of 20 most recent tests per IP. `saved_ips` loss field is not persisted (only in `test_history`).

#### Test Lifecycle (`POST /api/start-test`)

1. Receives target IPs/domains, `taskId` (or generates UUID), and `runtimeOptions`.
2. In `ip` mode, validates all targets are pure IPs; in `cname` mode, resolves domains via `dns.promises` across three parallel DNS servers (8.8.8.8, 1.1.1.1, OpenDNS) with 16-way concurrency.
3. Writes resolved IPs to `ip_{taskId}.txt` (avoids shell arg length limits — critical on Android/Termux).
4. Spawns `cfst` via `child_process.spawn` with args from `getAdaptiveConfig` (reduces threads/counts on mobile; overrides `-dn 1` for single-IP targets).
5. Parses each stdout line with `parseProgressLine`, deduplicates via `lastProgressKey`, fans out to SSE clients via `sendProgress`.
6. After `cfst` exits, reads `result_{taskId}.csv`, enriches top-N results with Cloudflare datacenter region (HTTP probe to `speed.cloudflare.com/cdn-cgi/trace` with spoofed `Host` header, 20 concurrent workers).
7. Saves results to `test_history`, cleans up `ip_{taskId}.txt` and `result_{taskId}.csv`.

#### cfst Default Config

```javascript
{
  n: 200,              // Ping threads
  t: 4,                // Tests per IP
  tp: 443,             // Test port
  url: 'https://speed.cloudflare.com/__down?bytes=20000000',
  mode: 'tcp',         // tcp or http
  httpingCode: 200,
  cfcolo: '',          // Region filter (IATA codes)
  dt: 5,               // Download duration (sec)
  dn: 10,              // IPs for download test
  dnSingle: 1,         // Single-IP download count
  tl: 9999,            // Latency upper limit (ms)
  tll: 0,              // Latency lower limit (ms)
  tlr: 1,              // Packet loss ratio limit (0-1)
  sl: 0,               // Speed lower limit (MB/s)
  disableDownload: false,
  allip: false,
  debug: false,
  topN: 50,
  parseTimeoutSec: 25,
  totalTimeoutSec: 900
}
```

#### Progress Normalization

`parseProgressLine(line)` strips ANSI codes and extracts: IP (IPv4/IPv6), speed (all units → normalized to MB/s), average speed, progress ratio, and phase.

`normalizeProgress(taskId, payload)` maps phases to percent ranges:
- `Ping 测试` → 0–70%
- `下载测速` → 70–100%
- `目标扫描` → 0–100%
- Messages truncated to 120 chars.

#### Real-time Progress

SSE primary channel: `GET /api/progress/:taskId` — sends `lastProgress` immediately to late clients.
Polling fallback: `GET /api/progress-state/:taskId` — returns snapshot JSON; frontend switches to this if SSE fails.

#### DNSPod Integration

Settings stored under `dns_api`: `{ provider, domain, tokenId, tokenKey, token, line }`.

Supports two credential types (auto-detected):
- **Legacy DNSPod token**: `tokenId,tokenKey` pair
- **Tencent Cloud API**: `tokenId` starts with `AKID` → uses TC3-HMAC-SHA256 signing

DNS staging buffer (`dns_staging` setting): records are added/edited locally, then batch-published to Tencent DNSPod via `POST /api/cf/dns/sync`.

#### Cloudflare Colo Detection

`getColo(ip)` probes `speed.cloudflare.com/cdn-cgi/trace` with spoofed `Host` header, using both HTTP (2s timeout) and HTTPS (2.5s timeout) in parallel. Parses `colo=XXX` from response and maps IATA code via `cfColoMap` (100+ locations). Falls back to `"❓ 超时/失败"`.

#### System Maintenance Endpoints

- `POST /api/system/update-engine` — Downloads cfst binary (multi-URL fallback: ghproxy → gh-proxy → GitHub direct). Platform detection: darwin arm64/x64 (.zip), linux arm64/amd64 (.tar.gz), windows amd64 (.zip).
- `POST /api/system/update-ips` — Fetches official CF IP ranges (`cloudflare.com/ips-v4`, `/ips-v6`), writes to `ip.txt` and `ipv6.txt`.
- `POST /api/system/fetch-bestcf` — Syncs 35+ hardcoded bestcf source groups; saves to `dns_staging`.
- `POST /api/system/fetch-bestcf-all` — Aggregates IPs from all saved sources (40 concurrent workers, IPv4 only).

### API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST` | `/api/start-test` | Launch speed test; accepts file upload or JSON body |
| `GET` | `/api/progress/:taskId` | SSE stream (primary progress channel) |
| `GET` | `/api/progress-state/:taskId` | JSON snapshot (polling fallback) |
| `POST` | `/api/stop-test` | Kill running test (`SIGKILL`) |
| `GET` | `/api/saved-ips` | List favorited IPs |
| `POST` | `/api/save-ips` | Add/update favorites |
| `DELETE` | `/api/delete-ips` | Remove favorites |
| `GET` | `/api/settings/cfst` | Get test parameters |
| `POST` | `/api/settings/cfst` | Save test parameters |
| `POST` | `/api/settings/cfst/reset` | Restore defaults |
| `GET` | `/api/settings/cf` | Get DNSPod credentials |
| `POST` | `/api/settings/cf` | Save DNSPod credentials |
| `GET` | `/api/cf/dns` | List live DNS A/AAAA records |
| `POST` | `/api/cf/dns/add` | Create DNS record |
| `DELETE` | `/api/cf/dns/:id` | Delete DNS record |
| `POST` | `/api/cf/dns/:id/update` | Modify DNS record |
| `POST` | `/api/cf/dns/sync` | Batch sync staging → live (`replaceAll` flag) |
| `GET` | `/api/dns/staging` | Get local staging buffer |
| `POST` | `/api/dns/staging` | Append to staging (deduplicates with live) |
| `PUT` | `/api/dns/staging` | Replace all staging records |
| `DELETE` | `/api/dns/staging` | Clear staging |
| `POST` | `/api/regions` | Batch colo lookup (5 concurrent workers) |
| `POST` | `/api/system/update-engine` | Download cfst binary |
| `POST` | `/api/system/update-ips` | Fetch CF IP ranges |
| `POST` | `/api/system/fetch-bestcf` | Sync bestcf source list |
| `GET` | `/api/settings/bestcf-sources` | Get saved bestcf sources |
| `POST` | `/api/system/fetch-bestcf-all` | Aggregate IPs from all sources |

### Frontend (`public/app.js` + `public/index.html`)

Single-page app with four tabs: **Test** (速测) / **Favorites** (收藏) / **DNS** / **Settings** (设置). All tab state is managed by `switchTab(view)`.

#### Global State Variables

- `testTableData`, `favTableData` — Result row arrays for each table.
- `parsedTargets` — Validated IP/domain list parsed from the textarea.
- `currentTaskId` — UUID for the active or last-run test.
- `currentView` — Active tab name (`'test'`, `'favorites'`, `'dns'`, `'settings'`).
- `progressSource` — `EventSource` for SSE connection.
- `progressPollTimer` — `setInterval` ID for fallback polling.
- `dnsStagingRecords` — Local buffer of DNS records before publishing.

#### Result Row Object

```javascript
{
  ip: '1.2.3.4',
  region: '🇺🇸 洛杉矶',
  ping: 15.5,
  speed: 25.67,
  loss: 0,
  tag: 'US-Fast',
  deltaSpeed: 2.50,      // vs previous test (null if no history)
  deltaPing: -0.5,
  created_at: 1623456789000,
  updated_at: 1623456890000
}
```

#### DNS Staging Record

```javascript
{
  source: 'staging' | 'live',
  type: 'A' | 'AAAA',
  line: 'default' | 'telecom' | 'unicom' | 'mobile',
  value: '1.2.3.4',
  ttl: 600,
  id: undefined  // only present for live records
}
```

#### Custom Select Dropdown

The frontend has a custom `<select>` implementation (`initCustomSelects`, `closeAllCustomSelects`) because native selects cannot be styled consistently across mobile and desktop. **Do not replace these with native `<select>` elements.** The custom implementation auto-adjusts position to prevent viewport overflow and repositions on scroll.

#### Theming

CSS custom properties on `:root` (light) and `body.dark` (dark). `applyTheme(mode)` switches the body class and persists to `localStorage`. Glassmorphism design (30px blur backdrop filter). Speed color-coding: green >20 MB/s, blue 5–20 MB/s, gray <5 MB/s.

#### Input Parsing (`extractAndUpdateInput`)

Strictly validates IPv4 and IPv6 with full regexes, strips ports, deduplicates, limits to 100k entries. Updates `ipInput.value` with normalized list.

#### Progress Channel Lifecycle

1. Frontend opens `EventSource` to `/api/progress/:taskId`.
2. If SSE fails (e.g., network proxy strips chunked encoding), falls back to polling `/api/progress-state/:taskId` every 1.2s via `startProgressPolling`.
3. On task completion or stop, calls `closeProgressStream()` and `stopProgressPolling()`.

## Key Conventions

- **Task IDs**: All speed test operations are scoped to a `taskId` (UUID). Temp files follow `ip_{taskId}.txt` / `result_{taskId}.csv`.
- **Database writes**: Always go through `setSetting(key, JSON.stringify(value))` — never write `dbData` directly and call `saveDb()` inline. The serial save queue (`dbSaveQueue`) prevents corruption under concurrent writes.
- **Atomic DB saves**: `saveDb()` writes to `database.json.tmp` then renames — never partially-written DB files.
- **Progress normalization**: `normalizeProgress` maps raw `cfst` output to phases. The percent calculation differs by phase: Ping → 0–70%, download → 70–100%.
- **IP file passthrough**: Never pass large IP lists as CLI args — always write to `ip_{taskId}.txt` and use the `-f` flag. This avoids E2BIG on Android/Termux.
- **Port**: Default is 3088 via `process.env.PORT` or the constant; the server attempts one fallback port (3089). If both are occupied, startup fails.
- **No frontend framework**: `public/app.js` is intentional vanilla JS. Do not introduce React, Vue, or any bundler.
- **Concurrency helpers**: Use `mapWithConcurrency(items, limit, mapper)` for controlled parallel async operations — do not use `Promise.all` for large arrays that hit external services.
- **Private IP guard**: `isPrivateIP(hostname)` checks RFC 1918 ranges and localhost variants before making outbound connections.

## Deployment

### Requirements

- Node.js >= 18
- `cfst` binary in project root with execute permissions (non-Windows)
- Write access to project directory (for `database.json` and temp files)
- `PORT` environment variable (optional, defaults to 3088)

### Docker

Multi-stage build on `node:18-alpine`. Downloads platform-specific `cfst` binary during build (parametrized `ARCH`: `amd64` or `arm64`). Named volume `panel-data:/app` provides persistence across container restarts.

```bash
docker-compose up -d
```

### Startup Checks (`ensureLocalRuntimeReady`)

1. Verifies Node.js version >= 18.
2. Checks `cfst` binary exists.
3. Verifies execute permissions on `cfst` (non-Windows).
4. Loads `database.json` into `dbData` (creates if missing).
