# Spend credentials — OpenCode Go / Zen

`bp-spend.pl` reads Go and Zen quota by scraping the authenticated billing
page at `opencode.ai/workspace/{id}/billing` (no API, no CLI subcommand, no
usage header exists today — see the b36 spec, §0 and §3a). Reading that page
needs your browser's `opencode.ai` session cookie. This document is the whole
credential story: where it lives, how to get it in, and what happens when it
expires.

## The credential is a FILE, not an environment variable

As of the b36 reopen (operator ruling 2026-08-04), `OPENCODE_GO_AUTH_COOKIE`
and `OPENCODE_AUTH_COOKIE` are **no longer supported inputs**. `bp-jail.pl`
performs no environment isolation — a jailed worker's `exec()` inherits
`%ENV` wholesale — so the only way to structurally close that leak is to make
sure the cookie is never *in* `%ENV` in the first place. A file has a mode we
can refuse to read; an environment variable has no equivalent guardrail.

### The path

Each provider's credential path is `~/.claude/opencode-go.json` (Go) or
`~/.claude/opencode-zen.json` (Zen) — under the `claude-home` bind, so the
path survives a container rebuild. (`~` resolves via `$HOME`, or
`$USERPROFILE` on native Windows perl.) Each file at that path is a small
JSON object: `{"cookie": "<the session cookie value>"}`.

### The required mode

**The file must be mode `0600`** — owner read/write only, no group or world
access. `resolve_credential()` refuses to read a group- or world-readable
credential file outright: it names the offending path and the required mode
in its refusal rather than silently reading a file anyone on the box could
also read. If you ever see a "credential file … is group/world-readable"
diagnostic, the fix is:

```
chmod 0600 ~/.claude/opencode-go.json
```

`bp-spend-auth.pl` (below) always creates the file at `0600` from the moment
it is created — never `chmod`'d into that mode afterward, so there is no
window in which it is briefly world-readable.

## Setting the cookie: `bp-spend-auth.pl`

```
bp-spend-auth.pl --provider go              # cookie read from STDIN, never argv
bp-spend-auth.pl --provider go --from-firefox   # host-side extraction, see below
bp-spend-auth.pl --status [--provider go]    # is a credential present, and does it parse?
```

The cookie is **only ever accepted on STDIN**, never as a command-line
argument — argv is visible in `ps` output and shell history, and a
whole-session cookie is the broadest secret this system handles. Feed it in
however your shell supports piping a value in without putting it on the
command line, e.g.:

```
bp-spend-auth.pl --provider go
<paste the cookie value, then Enter, then Ctrl-D / Ctrl-Z>
```

`--status` reports whether a credential is present, its file mode, and
whether it parses as a usable credential — **never the value itself, not
even truncated.**

### Obtaining the cookie manually

1. Open `https://opencode.ai` in your browser and sign in.
2. Open DevTools → **Application** tab → **Cookies** → `https://opencode.ai`.
3. Copy the session cookie's value.
4. You also need your workspace id (the `{id}` segment of
   `opencode.ai/workspace/{id}/billing` — visible in the URL once you're on
   the billing page). Set it via `OPENCODE_GO_WORKSPACE_ID` /
   `OPENCODE_WORKSPACE_ID` (these are workspace identifiers, not secrets, and
   remain environment variables).
5. Run `bp-spend-auth.pl --provider go` (or `--provider zen`) and paste the
   cookie value on STDIN.

### `--from-firefox` — host-side extraction, and why expiry stops mattering

A session cookie's lifetime is server-controlled; we deliberately do not hold
credentials that could refresh it. But we do not need to refresh it — we can
**re-read** it. Firefox stores cookies in `cookies.sqlite` in your profile
directory; `httpOnly` blocks JavaScript from reading it, not a database
reader. Because the launcher already runs on the host and already spawns
PowerShell (for keep-awake), the machinery to do this host-side already
exists.

**Mechanism:** PowerShell using `winsqlite3.dll`, which ships with Windows
10/11 — no `DBD::SQLite`, no `sqlite3` CLI, no bundled binary required (the
same technique the operator's own
`github.com/andrecarini/emclient-offline-recovery` uses to read eM Client's
SQLite databases). The database is copied before reading — Firefox holds a
lock on the live file while running — and the copy is deleted afterward,
never left inside the repo.

**As long as your Firefox session stays alive, every launch picks up a
current cookie** — expiry stops being an event you have to notice and react
to, because `--from-firefox` re-reads rather than trying to refresh.

**This is Windows-only and best-effort.** On any non-Windows host, with no
Firefox profile, a locked database it cannot get a copy of, or no
`opencode.ai` cookie present in the profile, it **degrades**: it prints these
same manual instructions, exits non-zero, and — this is the part that
matters — **writes nothing**. No empty file, no partial file. A credential
file only ever appears once a real cookie value is available to put in it.

## What expiry looks like

A session cookie eventually stops working. When that happens, `bp-spend.pl`
does not crash and does not report zero spend: the fetch comes back
`status => 'unknown'` with a diagnostic that tells you to **re-copy the
cookie** (the exact wording matches `/re-?copy.*cookie/i`). In the TUI's
spend panel this renders as the "unreadable, re-copy the cookie" state,
distinct both from a healthy reading and from a provider that was never
configured at all (`absent`). Re-run `bp-spend-auth.pl --provider <name>`
(manually or via `--from-firefox`) to clear it.

## This is a scrape — the standing revisit note

There is no documented OpenCode API, CLI subcommand, or usage header for Go
or Zen quota today (spec §0). This whole mechanism — the billing-page HTML
scrape `bp-spend.pl` parses, and therefore this credential file it depends
on — is a workaround, not the destination. Every parse-failure diagnostic in
`bp-spend.pl` carries the revisit prompt: **before repairing the scrape,
check whether OpenCode now publishes a documented API/CLI/usage-header for
Go/Zen quota** — if one exists, replace the reader rather than patch a
regex, and this credential-file mechanism may simplify or disappear with it.
