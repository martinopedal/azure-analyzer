# Viewer Architecture (Track V) — Design

Status: Draft (scaffold for #430). Foundation contract: #435.

This document specifies the four-tier report architecture and the auto-launching local viewer
that azure-analyzer ships for enterprise-scale tenants. Threat model lives in
[`viewer-threat-model.md`](viewer-threat-model.md) — read it before implementing any endpoint.

## 1. Why four tiers

A single-file HTML report does not survive enterprise scale. A tenant with 500k findings and
50k edges produces an HTML file most browsers cannot open, and Cytoscape.js degrades past
~5k nodes per canvas. The architecture picks the smallest viable tier per run; users never
have to think about tiering by default.

## 2. Tier matrix

| Tier | Name           | Findings cap   | Edges cap (sum across canvases) | Picker thresholds (post 1.25x headroom) | What ships                                                                 | What renders                                                                                                                                                  |
|------|----------------|----------------|---------------------------------|------------------------------------------|----------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1    | PureJson       | <10k           | <2500                           | findings<10k AND entities<5k AND edges<2500 | Single self-contained `report.html` with inline JSON                       | Full graph in browser, current behaviour. Cytoscape + dagre operate on the full edge set.                                                                     |
| 2    | EmbeddedSqlite | 10k-100k       | 2500-10k                        | any input crosses Tier 1 line             | Single `report.html` with base64-inlined `@sqlite.org/sqlite-wasm` payload | sql.js opens the inlined database in a Web Worker; UI lazy-queries findings + edges. Graph still in-browser but page-paginated.                               |
| 3    | SidecarSqlite  | 100k-500k      | 10k-50k                         | any input crosses Tier 2 line             | Summary `report.html` plus `findings.sqlite` sidecar fetched via `fetch()` | Summary cards rendered server-side; full findings + graph queries served from the sidecar via Web Worker. No DB ever lives in the JS heap.                    |
| 4    | PodeViewer     | >500k OR >50k edges | unbounded (server-paginated) | any input crosses Tier 3 line             | Summary `report.html` + auto-launched Pode runspace on `127.0.0.1:<port>`  | Browser fetches paginated JSON from `/api/...`; recursive-CTE traversals run in SQLite server-side. UI never holds more than 2k nodes / 5k edges per payload. |

### Headroom factor

`Select-ReportArchitecture` multiplies measured `findings`, `entities`, and `edges` by **1.25**
and picks the **MAX** tier any axis demands. Reasoning is logged and written to
`report-manifest.json` for support and empirical headroom tuning.

### Tier 1 edge cap

**2500 edges** total across the attack-paths, resilience, and policy canvases combined
(Round 2 amendment). Cytoscape's workable ceiling is per canvas.

### Escape hatch

Undocumented env var `AZUREANALYZER_FORCE_TIER=1|2|3|4` forces a tier. CI determinism +
debugging only. Never advertised to users.

## 3. Auto-upgrade ladder

```
render(Tier N) -> verify -> ok                 -> done
                          \-> fail -> render(Tier N+1) -> verify -> ok    -> rewrite manifest, done
                                                                  \-> fail -> hard error
```

- Verification per tier:
  - Tier 1: HTML parses + finding count matches measured count.
  - Tier 2: HTML parses + embedded SQLite header (`SQLite format 3`) decodes + row count matches.
  - Tier 3: HTML parses + sidecar SQLite passes `PRAGMA integrity_check` + row count matches.
  - Tier 4: Pode `/api/health` dry-start returns `200` within timeout.
- On upgrade, `report-manifest.json` is **rewritten** to reflect actual rendered tier and any
  declared degradations (Track F #434 parity contract).
- **Hard-error on feature drop**: if Tier N+1 cannot render a feature Tier N promised, the
  upgrade is rejected. We never ship a report that is less capable than the picker declared.

## 4. Single-command UX

```powershell
Invoke-AzureAnalyzer -Show
```

`-Show` (and the implicit default for interactive runs) does:

1. Run the analyzer pipeline.
2. Pick a tier via `Select-ReportArchitecture`.
3. Emit the artifact + `report-manifest.json`.
4. If Tier 4: pick a free port in **7000-7099** (random shuffle, first free wins),
   bind `127.0.0.1` only, mint a session GUID, write `.viewer-session.json` (mode 0600,
   8h TTL).
5. `Start-Process` the default browser at `http://127.0.0.1:<port>/?token=<sessionGuid>`.
6. Trap `Ctrl+C` -> `Stop-AzureAnalyzerViewer` (close runspace, delete session file).

`-NoLaunch` skips steps 5-6 (CI / headless).

### Reconnect

`.viewer-session.json` records `port`, `sessionToken`, `csrfToken`, `pid`, `expiresUtc`,
`manifestPath`. A subsequent `Invoke-AzureAnalyzer -Show -Reconnect` reads it; if the PID is
still alive and `expiresUtc > now`, browser is relaunched against the same instance.

## 5. Pode endpoints (Tier 4)

All endpoints require `?token=<sessionToken>` (GET) or `X-CSRF-Token` (POST/PUT/DELETE).
All bodies pass through `Remove-Credentials`. Hard pagination cap: **2k nodes / 5k edges** per
payload.

| Method | Path                          | Purpose                                                                                  |
|--------|-------------------------------|------------------------------------------------------------------------------------------|
| GET    | `/api/health`                 | Liveness probe. Returns `{ status: "ok", version, tier }`.                              |
| GET    | `/api/findings`               | Paginated finding list. Query: `severity`, `tool`, `entityType`, `q` (FTS5), `cursor`.  |
| GET    | `/api/findings/:entityId`     | Findings for a single entity. Path arg validated by `Test-EntityIdSafe`.                |
| GET    | `/api/graph/attack-paths`     | Recursive-CTE attack-path traversal from a seed entity (`?seed=`, `?maxDepth=`).        |
| GET    | `/api/graph/neighbors`        | One-hop neighbours of `?entityId=` for lazy expansion in the UI.                        |
| GET    | `/api/graph/resilience`       | Resilience graph slice (`?subscriptionId=`).                                            |
| GET    | `/api/graph/path`             | Shortest path between `?from=` and `?to=` via recursive CTE, capped at `maxDepth=8`.    |
| POST   | `/api/triage`                 | Persist a triage decision (`{ findingId, status, note }`). Requires CSRF.               |

### Recursive CTE pattern (server-side, never pre-enumerated)

```sql
WITH RECURSIVE walk(src, dst, depth, path) AS (
  SELECT src, dst, 1, src || '->' || dst
  FROM edges WHERE src = :seed
  UNION ALL
  SELECT e.src, e.dst, w.depth + 1, w.path || '->' || e.dst
  FROM edges e
  JOIN walk w ON e.src = w.dst
  WHERE w.depth < :maxDepth
    AND instr(w.path, e.dst) = 0   -- cycle break
)
SELECT * FROM walk LIMIT 5000;
```

The orchestrator never materialises the closure into JSON; the CTE runs per request, capped
by `maxDepth` + `LIMIT`. This is what lets Tier 4 scale.

## 6. Web-worker fetch pattern (Tier 3)

```js
// summary.html loads a single ES module:
const worker = new Worker('viewer-worker.js', { type: 'module' });
worker.postMessage({ kind: 'open', url: './findings.sqlite' });
// All UI components dispatch queries via the worker; no DB bytes touch the main thread.
```

The worker uses `@sqlite.org/sqlite-wasm` with OPFS off (sidecar lives next to the HTML).
Cursor-based pagination keeps memory bounded.

## 7. Auto-upgrade behaviour summary

1. Picker chooses initial tier from measured counts x 1.25 headroom.
2. Renderer emits artifact, verifier validates.
3. Verification fail -> upgrade once. Manifest rewritten. Feature-parity check enforced.
4. Second fail -> hard error with sanitized remediation (`Remove-Credentials` on the log).

## 8. Out of scope (this PR)

This scaffold lands the design + threat model + module signatures + `-Skip` Pester
placeholders only. Foundation (#435) owns:

- `Select-ReportArchitecture` implementation
- `report-manifest.json` schema + writer
- Vendoring of cytoscape, dagre, Pode, sqlite-wasm
- Verification stubs

Subsequent PRs: tier renderers, Pode server, viewer SPA, integration tests.
