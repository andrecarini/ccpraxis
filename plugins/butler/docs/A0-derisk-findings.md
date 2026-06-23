# A0 — De-risk Spike Findings

> Blueprint: `unattended-run-overhaul` · Package: **A0-derisk-spike** · Author run: 2026-06-22 → 2026-06-24
> Purpose: prove (PASS w/ evidence) or fall back (FAIL w/ documented fallback) the undocumented dependencies the
> deterministic orchestrator (A3), judges (A5), reporter (A7), and the new preflight/contract-guard (A8) ride on.
> **Every assumption below is mirrored, machine-readably, in [`assumptions.json`](./assumptions.json)** — the
> source A8's preflight + contract-drift guard consume (Decisions #29/#31).

**Environment proven in:** Windows 10 host (`win32`), cygwin perl 5.42, curl 8.19 (Schannel), Claude Code **2.1.170**;
podman 5.8.3 with image `localhost/claude-sandbox:2.1.170` for the Linux-sandbox surface. Anything outside this set is
**unsupported until A8's preflight is extended** — and must fail loud, not silently proceed (Decision #31).

---

## Probe 1 — `GET /api/oauth/usage` (usage telemetry) — ✅ PASS

- **Request:** `GET https://api.anthropic.com/api/oauth/usage`
  - `Authorization: Bearer <claudeAiOauth.accessToken>` (from `~/.claude/.credentials.json`)
  - `anthropic-beta: oauth-2025-04-20`
  - `User-Agent: claude-code/<version>` (e.g. `claude-code/2.1.170`)
  - `Accept: application/json`
- **Result:** HTTP **200**. Unauthenticated/invalid → **429** (anti-abuse; NOT 401 — do not treat 429 as auth failure).
- **Response contract (the fields A3 needs):**
  ```jsonc
  {
    "five_hour":  { "utilization": 58, "resets_at": "2026-06-22T05:59:59.764433+00:00",
                    "limit_dollars": null, "remaining_dollars": null, "used_dollars": null },
    "seven_day":  { "utilization": 7,  "resets_at": "2026-06-22T17:59:59.764454+00:00", ... },
    "seven_day_opus":   { "utilization": 0, ... },
    "seven_day_sonnet": { "utilization": 0, ... },
    "limits": [ { "kind":"session",     "percent":58, "resets_at":"…", "severity":"normal", "is_active":true  },
                { "kind":"weekly_all",  "percent":7,  "resets_at":"…", "severity":"normal", "is_active":false },
                { "kind":"weekly_scoped","percent":0, "scope":{"model":{"display_name":"Sonnet"}}, ... } ],
    "spend": { "enabled": false, "percent": 0, ... }
    // plus null-valued internal codenames (amber_ladder, cinder_cove, tangelo, …) — ignore.
  }
  ```
- **Design notes for A3:**
  - `utilization` is an **integer percent** → compare directly to the `BP_CEIL_5H=85` / `BP_CEIL_7D=90` ceilings.
  - `resets_at` is **ISO-8601 with microseconds + `+00:00` offset**, NOT epoch. A3 must parse it (the existing
    `statusline.pl` `time_until` helper handles ISO+epoch). The `runs/.paused` contract stores it as epoch — convert.
  - Two representations agree: `five_hour.utilization` == `limits[kind=session].percent`. Prefer the named
    `five_hour`/`seven_day` objects (Decision #7); the richer `limits[]` is a bonus (has `severity`).
  - **Contract-drift guard (A8):** validate `five_hour.utilization` (int 0–100) and `five_hour.resets_at` (parseable)
    are present on every poll; a missing/renamed field ⇒ alarm + graceful-pause, never proceed on bad data (#29).

## Probe 2 — OAuth token refresh + atomic write-back — ⚠️ CONDITIONAL (mechanism PROVEN; live `200` not yet observed)

Reverse-engineered from Claude Code's own bundle (function `okH`), so the request is **authoritative** — it is byte-for-byte
what Claude Code itself sends.

- **Refresh request:**
  ```
  POST https://platform.claude.com/v1/oauth/token            (note: claude.com domain, NOT console.anthropic.com)
  Content-Type: application/json
  body: { "grant_type": "refresh_token", "refresh_token": "<refreshToken>",
          "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",   // overridable via $CLAUDE_CODE_OAUTH_CLIENT_ID
          "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload" }
  ```
- **Response (200):** `{ access_token, refresh_token (defaults to old if absent), expires_in }`.
  Mapping to creds: `accessToken=access_token`, `refreshToken=refresh_token||old`,
  `expiresAt = now_ms + expires_in*1000` (epoch **ms**), `scopes = split(' ', scope)`. Leave `subscriptionType`,
  `rateLimitTier` untouched.
- **Creds file:** `~/.claude/.credentials.json` → `{ "claudeAiOauth": { accessToken, refreshToken, expiresAt(ms),
  scopes[], subscriptionType, rateLimitTier } }`. Host reports mode `644` (cygwin/NTFS cosmetic); the Linux sandbox
  reports `600` — preserve whatever `stat` reports.
- **Atomic write-back — ✅ PROVEN against a fixture** (Decision #11 properties): `flock` + **re-read stand-down**
  (if `refreshToken` changed underneath, do NOT overwrite) + **temp + `rename`** (atomic replace; confirmed
  `rename`-over-existing IS atomic on cygwin/Windows) + **JSON-validate** the serialized output + **preserve mode**.
  Reference implementation lives in the probe scripts; A3 should lift it verbatim.
- **Live refresh — ❌ blocked by 429 (repeatable, two attempts 2 days apart):**

  ### Refresh-attempt log (Decision #30 — refreshing + result is logged)
  | when (local) | endpoint | result | creds modified? | interpretation |
  |---|---|---|---|---|
  | 2026-06-22 06:20:33 | `POST platform.claude.com/v1/oauth/token` | **429** `rate_limit_error` | NO (die before write-back) | premature refresh (token had ~5h life) |
  | 2026-06-24 01:38:20 | same | **429** `rate_limit_error` | NO (die before write-back) | premature refresh (token had ~8h life) |

  - The 429 carries a structured `{"error":{"type":"rate_limit_error"}}` body → the request **shape is correct**
    (not 400/401); we are purely **throttled**.
  - **Indirect proof the refresh works in this env:** the live token visibly **rotated** between sessions
    (`expiresAt` 2026-06-22T09:10:30Z → 2026-06-24T07:36:17Z) — Claude Code itself refreshed it successfully. Our
    request is identical, so it would too.
  - **Root cause:** the refresh endpoint rate-limits **premature** refreshes; a manual refresh while the token is far
    from expiry (and while CC keeps it fresh) collides → 429. This **validates** Decision #11 ("refresh only in the
    1–2h-remaining band; retry across the runway") and #12 (abuse-detection caution).
  - **Fallback / forward (A3 + A8):** token-keeper MUST treat 429 as expected → exponential backoff, retry across the
    runway, and graceful-pause if the 1h floor is crossed unrefreshed. It must NOT refresh speculatively. **A8 actively
    VERIFIES the refresh** by exercising one real in-band refresh near expiry and asserting a `200` + valid contract
    (Decision #29) — we never assume it works on faith. A real `200` from our code remains the one open item, closeable
    only in-band (~1–2h before expiry).

## Probe 3 — Do `PreToolUse` hooks fire for Task **subagent** tool calls? — ✅ CONFIRMED (docs + structural) → self-asserted at runtime

- **Authoritative docs (verbatim):** *"Hooks from the main session settings propagate to subagents by default.
  `PreToolUse`, `PostToolUse`, and other tool-event hooks fire for both main-agent and subagent tool calls."*
  (code.claude.com/docs/en/hooks — "Subagent Hook Considerations → Hook Inheritance"). The hook input carries
  `agent_id` / `agent_type` precisely to distinguish a subagent's call from the main thread's (`agent_id:"main"`).
  → **A plugin CAN enforce a `PreToolUse` policy (e.g. deny an out-of-scope Write) on a subagent's tool calls.**
- **Structural corroboration (this repo):** `plugins/butler/hooks/guard-writes.sh` already implements worker-role
  separation (lines 52–65) keyed off the `active-worker` marker written by `track-dispatch.sh` (PreToolUse on `Task`).
  That logic is only meaningful if `guard-writes` fires during a **worker subagent's** edit — i.e. the deployed design
  already assumes this. ✓ consistent.
- **Caveat (why it's not "just trust the docs"):** two independent doc lookups initially gave *different* readings of
  the inheritance section; Claude Code behavior can also change across versions. Per Decision #31 this assumption is
  **promoted to a runtime self-assert**: A8's preflight runs a tiny self-test (dispatch a throwaway worker that attempts
  an out-of-scope edit; assert it is **denied**) and **fails loud** if containment is silently not firing. This is what
  makes A4's graceful-gate safe to depend on.
- **Empirical sandbox run:** a ready-to-run, jq-free probe (`hook.sh` + project `.claude/settings.json` + a
  subagent-dispatch prompt) is parked under the temp probe set; run it inside a real `claude-sandbox` session (or fold
  into A6's harness) for an independent empirical seal. Not blocking — the A8 self-assert is the durable proof.

## Probe 4 — Reporter-wake: does a long-blocking background command's completion re-invoke the session? — ✅ PASS

- **Mechanism PROVEN empirically.** A deterministic, token-free Perl watcher (`bp-wait-for-decision` prototype) blocks
  polling `runs/needs-you/` for a *new* `*.json`, exiting `0` + `DECISION:<file>` when one appears, or `2` + `TIMEOUT`
  after a bounded `max_wait`. Launched detached, then a decision file was queued; the watcher detected it (`DECISION:
  A3--probe4test.json`), exited 0, and the harness delivered a **completion notification that re-invoked this session**.
- **This is exactly the reporter auto-announce loop (Decision #27):** reporter arms the watcher → idle, zero Claude
  tokens while it blocks → woken on completion → announces → re-arms. **It resolves the auditor's open concern**
  (audit item 1f/8: "wake mechanism may not be mechanically achievable") — it is.
- **Bounded long-poll + re-arm:** the watcher caps at `~9 min` (under the 10-min harness command ceiling) and exits
  `TIMEOUT` to be re-armed — so it is robust even if indefinite blocking is ever capped. Pre-existing files are
  correctly ignored (only NEW decisions wake it).

---

## Assumptions registry (human view; machine view = `assumptions.json`)

| id | what | expected contract | supported envs | drift/preflight action |
|----|------|-------------------|----------------|------------------------|
| `os` | host platform | `win32` (host) or sandbox `linux` | win32, sandbox-linux | preflight: halt-loud if other; name the gap |
| `bin.curl` | HTTP transport | `curl` present, TLS backend trusts system store | win32 (Schannel), linux | preflight: assert present + HTTPS works |
| `bin.perl` | scripting + HTTPS | perl ≥5.x with `HTTP::Tiny`+`IO::Socket::SSL`+`JSON::PP` | both | preflight: assert modules loadable |
| `bin.jq` | hook JSON parsing | `jq` present (hooks fail-closed without it) | sandbox-linux | preflight (sandbox): assert present |
| `tls.ca` | perl CA bundle | a CA file exists (`/usr/ssl/certs/ca-bundle.crt` on host) | both | preflight: assert resolvable |
| `creds.path` | credentials file | `~/.claude/.credentials.json`, `0600`/`0644` | both | preflight: assert exists + parseable |
| `creds.shape` | creds JSON shape | `claudeAiOauth.{accessToken,refreshToken,expiresAt(ms),scopes[]}` | both | contract-guard: validate each use |
| `api.usage` | usage endpoint | `GET /api/oauth/usage` → `five_hour/seven_day.{utilization:int, resets_at:ISO}` | both | contract-guard: validate each poll |
| `api.refresh` | refresh endpoint | `POST platform.claude.com/v1/oauth/token` JSON → `{access_token,expires_in[,refresh_token]}` | both | contract-guard + active in-band verify |
| `oauth.client_id` | public client id | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (or `$CLAUDE_CODE_OAUTH_CLIENT_ID`) | both | preflight: assert resolvable |
| `hooks.subagent` | PreToolUse fires for subagent tool calls | settings/plugin PreToolUse fires for subagent Edit/Write; `agent_id`/`agent_type` present | both | preflight **self-test**: out-of-scope worker edit is denied |
| `harness.wake` | background completion re-invokes session | detached cmd completion delivers a re-invoking notification | both | bounded long-poll (~9min) + re-arm fallback |
| `runtime.container` | container runtime | podman (or docker) present; sandbox image tag matches CLI version | win32 (sandbox surface) | preflight: assert present + image tag |

## Design implications (consumed by later packages)

- **A3:** usage `utilization` is int%; parse ISO `resets_at`; lift the proven atomic write-back verbatim; treat refresh
  429 as expected (backoff, in-band only, never speculative); log every refresh/poll/pause (#30).
- **A4:** the graceful-gate firing inside subagents is **valid** (Probe 3) — safe to build on.
- **A5/A7:** the reporter wake loop (Probe 4) is real — `bp-wait-for-decision` is a bounded long-poll + re-arm.
- **A8:** this doc's registry is the manifest; preflight asserts env support (halt-loud on unsupported), the
  contract-guard validates every Anthropic-side response + creds shape (alarm + pause on drift), and it **actively
  verifies** the refresh in-band. Decisions #29/#30/#31.
