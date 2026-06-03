---
name: test
description: Run the sandbox plugin's verification suite — proves the 9p O_APPEND workaround, named-volume mount strategy, host↔volume sync round-trips, and the session picker still behave correctly. Use when the user wants to verify the sandbox plugin works after changes to launcher.pl / select-session.pl / sync-sidecar.pl, or says things like "test the sandbox", "run sandbox tests", "verify the sandbox plugin", "sanity-check the launcher".
user-invocable: true
host-only: true
allowed-tools: Bash
---

# /sandbox:test

Runs `plugins/sandbox/tests/run-tests.pl` against the user's actual Podman + machine. Tests are real integration tests — they spin up debian:bookworm-slim probe containers and exercise the real mount paths, podman volumes, and sync scripts. Expect 1–2 minutes total.

## Arguments

- `t/02-*.t` (optional) — restrict to a subset by glob. Without args, runs the full suite.

## Steps

### 1. Pre-flight

Confirm Podman is reachable. If not, the tests will all 125-error — better to fail loudly here:

```bash
podman.exe ps -a > /dev/null 2>&1 || {
  echo "Podman is not reachable. Start the machine (admin PowerShell: 'podman machine start') and try again."
  exit 1
}
```

### 2. Confirm the probe image is cached locally

```bash
podman.exe image exists docker.io/library/debian:bookworm-slim || {
  echo "Pulling debian:bookworm-slim (one-time, ~78 MB)..."
  podman.exe pull docker.io/library/debian:bookworm-slim
}
```

### 3. Run the suite

```bash
perl "$HOME/.claude/ccpraxis/plugins/sandbox/tests/run-tests.pl" $ARGUMENTS
```

(If `$ARGUMENTS` is empty the runner picks all `t/*.t` files automatically.)

### 4. Report

The runner emits a per-file pass/fail line and a summary. On failure it also dumps the full TAP output of each failing file. Show that output to the user verbatim — don't paraphrase failures.

If everything passed, a one-line confirmation is enough. Optionally point out the headline tests:

- `02-volume-supports-append.t` — proves the workaround's core claim
- `06-sidecar-periodic-sync.t` — proves the crash-loss safety net works

## What the tests cover

| File | Claim |
|---|---|
| `01-9p-confirms-append-bug.t` | Sanity: 9p host bind rejects O_APPEND |
| `02-volume-supports-append.t` | Critical: named volume accepts O_APPEND |
| `03-volume-create-idempotency.t` | `podman volume create` is NOT idempotent (pins the inspect-first pattern) |
| `04-volume-persists-rm.t` | Volume survives `podman rm` of the container |
| `05-seed-and-sync-roundtrip.t` | Host → volume seed + container append + volume → host sync preserves data |
| `06-sidecar-periodic-sync.t` | sync-sidecar.pl mirrors on interval + self-exits when container stops |
| `10-select-session-empty-dir.t` | Picker emits NEW when no sessions exist |
| `11-select-session-parses.t` | Picker handles real-shape JSONL; "Start a new session" is option 1 |

## When tests fail

A failed test isn't a redo signal — read its output. Specific failure shapes mean specific things:

- **`01-9p-confirms-append-bug.t` PASSES (i.e. appends succeed):** the 9p bug got fixed upstream. Investigate before treating that as "everything's still fine" — the workaround may be removable.
- **`02-volume-supports-append.t` fails:** something fundamental broke; the entire mount strategy is dead. Don't paper over it.
- **`06` fails specifically on the "self-exited" assertion:** the sidecar isn't detecting parent/container death cleanly — risk of leaked processes in production. Fix before shipping.
