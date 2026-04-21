# Viewer Threat Model (Track V) — HARD REQUIREMENT

Status: Draft (scaffold for #430). This is the most important deliverable in the scaffold PR.
Goldeneye blocker. Every defense below is binding on the implementation PR.

## 1. Adversary model

The viewer binds a Pode HTTP server on `127.0.0.1` and serves findings from a local SQLite
file. The realistic adversaries are **not** a remote network attacker; they are:

| Adversary                              | Capability                                                                            |
|----------------------------------------|---------------------------------------------------------------------------------------|
| Hostile webpage in the user's browser  | Can issue cross-origin requests to `http://127.0.0.1:<port>` while the viewer is up.  |
| Hostile process on the same host       | Can scan loopback ports and probe endpoints with arbitrary headers.                   |
| DNS rebinding attacker                 | Can serve a domain that resolves first to a public IP, then to `127.0.0.1`.           |
| Curious co-tenant on a shared host     | Can read world-readable files in the user's profile.                                  |
| Local malware with the user's UID      | Out of scope. If the attacker has user-level code execution, the game is over.        |

## 2. Why SSL is not required

Browsers treat `http://127.0.0.1` as a **secure context** (Fetch / Mixed Content specs).
Loopback traffic never leaves the host. Issuing a TLS cert for `127.0.0.1` would force the
user through a self-signed-cert warning with no security benefit. The real threats are
**DNS rebinding** and **cross-process probes** — defended below.

## 3. Defense layers

Each defense lists: *why*, *implementation note*, *negative-test outline*. The implementation
PR must ship one Pester test per negative case.

### D1. Bind 127.0.0.1 only (never 0.0.0.0)

- **Why**: 0.0.0.0 exposes the viewer to the LAN.
- **Impl**: Pode `Add-PodeEndpoint -Address 127.0.0.1 -Port $port -Protocol Http`.
  `Test-LoopbackBind` asserts no listener exists on any non-loopback interface.
- **Negative test**: start viewer, attempt to connect from `0.0.0.0:<port>` via a second
  socket bound to a non-loopback IP — must refuse.

### D2. Random port 7000-7099 per launch

- **Why**: Defeats predictable-port probes and makes port-squatting attacks non-trivial.
- **Impl**: `Get-Random -InputObject (7000..7099 | Sort-Object {Get-Random})`, take first
  free port (TCP bind probe). Persisted to `.viewer-session.json`.
- **Negative test**: launch 5 times in sequence and assert the port set is non-constant.

### D3. Host header check

- **Why**: First line of defense against DNS rebinding. A rebinding attacker's request
  carries the attacker's hostname in `Host`, not `127.0.0.1`.
- **Impl**: Middleware rejects unless `Host` matches `^(127\.0\.0\.1|localhost):<port>$`
  (port string templated per launch). Returns `421 Misdirected Request`.
- **Negative test**: issue request with `Host: evil.com` -> expect 421.

### D4. Origin header check

- **Why**: Blocks cross-origin browser requests even before CORS preflight semantics matter.
- **Impl**: Middleware rejects any request whose `Origin` header is present and not
  `http://127.0.0.1:<port>` or `http://localhost:<port>`. Same-origin GETs (no `Origin`)
  pass. Returns `403 Forbidden`.
- **Negative test**: issue request with `Origin: https://evil.com` -> expect 403.

### D5. CORS explicitly disabled (no wildcard)

- **Why**: A wildcard CORS header would unwind D4.
- **Impl**: No `Access-Control-Allow-Origin` header is emitted. No `OPTIONS` route is
  registered. Pode default CORS plugin is **not** loaded.
- **Negative test**: assert response headers contain no `Access-Control-*` keys.

### D6. CSRF token on POST/PUT/DELETE

- **Why**: Even with D3/D4, defense in depth against an Origin-spoofing bug.
- **Impl**: Random GUID minted per launch, returned in the initial HTML payload, required as
  `X-CSRF-Token` on all state-changing methods. `Test-CsrfToken` constant-time compares.
- **Negative test**: POST `/api/triage` without token -> 403; with wrong token -> 403.

### D7. Session token GET-required

- **Why**: Prevents drive-by GETs from a malicious page that guesses the port.
- **Impl**: Random GUID per launch, written to `.viewer-session.json`, required as
  `?token=` query string OR `Authorization: Bearer <token>` header on every GET.
- **Negative test**: GET `/api/findings` with no token -> 401; wrong token -> 401.

### D8. Entity-ID regex validator

- **Why**: Entity IDs flow into SQL parameters and HTML; a path-traversal or HTML-injection
  payload here is the highest-impact bug we can ship.
- **Impl**: `Test-EntityIdSafe` enforces `^[a-zA-Z0-9:_\-\/\.]+$`, max 512 chars. **Never**
  used in file path construction; lookups go through allowlisted SQL queries with bound
  parameters.
- **Negative test**: `?entityId=../../etc/passwd` -> 400; `?entityId=<script>` -> 400;
  `?entityId=` (empty) -> 400; 513-char payload -> 400.

### D9. No arbitrary file read

- **Why**: A single `Get-Content $userInput` would bypass everything above.
- **Impl**: Routes serving files map allowlisted *logical* names (e.g. `findings.sqlite`,
  `report.html`) to fixed absolute paths resolved at startup. Any other name -> 404. No
  path-join with request data ever.
- **Negative test**: GET `/files/..%2f..%2fetc%2fpasswd` -> 404; GET `/files/unknown` -> 404.

### D10. `.viewer-session.json` mode 0600

- **Why**: Prevents co-tenants on a shared host from reading the session token.
- **Impl**: On Windows, `Set-Acl` strips inherited ACEs and grants only
  `NT AUTHORITY\SYSTEM` + the current user `FullControl`. On *nix, `chmod 600`. TTL 8h
  (`expiresUtc`). File regenerated per launch (existing file deleted first).
- **Negative test**: assert file ACL has exactly two principals and no `Everyone` /
  `Authenticated Users` ACE.

### D11. `Remove-Credentials` on every API response body

- **Why**: Belt-and-braces. A finding row that accidentally carries a token from a wrapper
  must not echo back to the browser.
- **Impl**: Pode response middleware pipes every response body (JSON + HTML) through
  `Remove-Credentials` from `modules/shared/Sanitize.ps1`. Non-byte-identical bodies are
  fine; redaction is the goal.
- **Negative test**: seed an in-memory finding with a synthetic token-shaped string, GET
  the finding, assert the token pattern is absent from the response.

### D12. Rate-limit on token validation

- **Why**: Blocks a process-on-host brute-force of `?token=`.
- **Impl**: In-memory sliding window, `5 failed attempts / 60s / source IP` -> 429 with
  `Retry-After: 60`. Resets on success. Per-launch window; no persistence required.
- **Negative test**: issue 6 wrong tokens within 60s, assert 6th -> 429.

## 4. Defense-to-test mapping

The implementation PR ships these Pester `Describe` blocks (placeholders land in this PR
with `-Skip`):

| Defense | Pester `Describe`                         |
|---------|-------------------------------------------|
| D1      | `Viewer.Security.LoopbackBind`            |
| D2      | `Viewer.Security.RandomPort`              |
| D3      | `Viewer.Security.HostHeader`              |
| D4      | `Viewer.Security.OriginHeader`            |
| D5      | `Viewer.Security.CorsDisabled`            |
| D6      | `Viewer.Security.CsrfToken`               |
| D7      | `Viewer.Security.SessionToken`            |
| D8      | `Viewer.Security.EntityIdValidation`      |
| D9      | `Viewer.Security.NoArbitraryFileRead`     |
| D10     | `Viewer.Security.SessionFileAcl`          |
| D11     | `Viewer.Security.ResponseSanitization`    |
| D12     | `Viewer.Security.TokenRateLimit`          |

## 5. Out of scope

- TLS / cert-pinning (see section 2)
- Authn beyond the per-launch token (single-user local tool)
- Audit logging beyond the existing `Remove-Credentials`-scrubbed run log
- Multi-user concurrent viewer instances (one viewer per user session)
