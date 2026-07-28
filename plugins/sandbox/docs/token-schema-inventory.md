# Token credentials schema inventory

Blueprint: `sandbox-butler-overhaul` / package `s08-token-panel`. `Decision #N`
references resolve to the archived `sandbox-launcher-tui-ux-improvements`
decision set (the "Sandbox-TUI-track decisions" reproduced in the blueprint's
Appendix A).

## Spike gate — CONFIRMED 2026-07-16

Before this inventory, the code only ever *saw* `{accessToken, refreshToken,
expiresAt(ms), scopes}` — that's the fixture shape used by
`t/33-credentials-degrade.t`, not a confirmed real-world schema. The spike
gate closed this gap: André logged in inside a live sandbox container and the
resulting `$SANDBOX_CREDENTIALS_FILE` (`claudeAiOauth` key) was inspected
directly, values masked. **Confirmed fields present:**

| Field | Type | Notes |
|---|---|---|
| `accessToken` | string | Never rendered or logged in full — token material. |
| `refreshToken` | string | Never rendered or logged in full — token material. |
| `expiresAt` | integer, **milliseconds** | Access-token expiry, epoch-ms. Matches `_gather_oauth_expiry`'s existing `/1000` conversion. |
| `scopes` | array of strings | OAuth scopes granted. |
| `subscriptionType` | string | Account-tier context (e.g. plan type). **Optional** — see below. |
| `rateLimitTier` | string | Account-tier context. **Optional** — see below. |

**No refresh-token-expiry field exists anywhere in the schema.** This was the
central open question the spike gate was designed to answer, and the answer
is negative — the live file has no `refreshTokenExpiresAt` (or equivalent)
key. Consequence for design: `TokenInfo.pm` must show the refresh token's
expiry as `n/a — not stored`, never fabricate or estimate one.

## `subscriptionType` / `rateLimitTier` are optional, not universal

`plugins/butler/scripts/bp-token-keeper.pl`'s `atomic_writeback` (the other
writer of this file, used by the butler token-refresh path) only sets/requires
`accessToken`, `refreshToken`, and `expiresAt` on write-back (`scopes` is
updated when the refresh response carries a `scope` string). It never writes
`subscriptionType` or `rateLimitTier`. Those two fields are populated by the
Claude Code CLI's own writes when a real user has authenticated interactively
— a keeper-only-touched or fixture-only file will lack them. `TokenInfo.pm`
must therefore treat both as optional pass-through account context: present
when available, silently absent otherwise (never inferred, never defaulted to
a placeholder that could be mistaken for real data).

## Design implications for `TokenInfo.pm`

- **Access token:** presence + valid/expired classification + seconds-left,
  all derived from `expiresAt` (ms → s) compared against "now".
- **Refresh token:** presence only, plus a short, stable **fingerprint**
  (a hash of the token, NOT the token itself) so repeated renders show the
  "same" refresh token consistently without ever exposing token material.
- **Refresh-token expiry:** always `n/a — not stored` — this is a confirmed
  fact about the schema, not a placeholder for missing implementation.
- **Last-refreshed:** the credentials file's **mtime** (Decision #7) — chosen
  because it is party-agnostic: both the Claude Code CLI and
  `bp-token-keeper.pl` rewrite this same file on refresh, so mtime reflects
  either writer without needing to distinguish them.
- **Never emit token material.** `accessToken`/`refreshToken` raw strings
  must never appear in `TokenInfo.pm`'s return struct, in any rendered panel
  text, or in any log line. This mirrors the existing discipline in
  `_gather_oauth_expiry`, which reads `accessToken`/`refreshToken` out of the
  decoded JSON but never returns them — only `expiresAt`-derived data leaves
  that function today.

## Source references

- Live-schema evidence: package ledger `packages/s08-token-panel.md`, entries
  `2026-07-16` and `2026-07-16` (spike gate RESOLVED, Decision #18).
  Decision #7 (last-refreshed = mtime): same ledger, entry `2026-07-16`.
- `bp-token-keeper.pl` write shape: `atomic_writeback`, this repo's
  `plugins/butler/scripts/bp-token-keeper.pl` (required-fields assertion
  `defined $o->{$_} or die ... for qw(accessToken refreshToken expiresAt)`).
- Existing precedent for "read but never return token material":
  `_gather_oauth_expiry`, `plugins/sandbox/scripts/launcher.pl`.
- Fixture shape used by tests today (pre-dates this inventory, kept for
  contrast): `plugins/sandbox/tests/t/33-credentials-degrade.t`.
