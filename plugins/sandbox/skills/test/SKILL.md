---
name: test
description: Run the sandbox plugin's verification suite — proves the bind-mount honors O_APPEND + utimensat, blueprint application + .claude.json file bind work, runtime detection picks docker or podman, heartbeat-only container keep-alive behaves correctly, and the session picker works. Use when the user wants to verify the sandbox plugin works after changes to launcher.pl / bootstrap.pl / Containerfile / MountSpec.pm, or says things like "test the sandbox", "run sandbox tests", "verify the sandbox plugin", "sanity-check the launcher".
user-invocable: true
host-only: true
allowed-tools: Bash
---

# /sandbox:test

Runs `plugins/sandbox/tests/run-tests.pl` against the user's actual
container runtime (auto-detects Docker or Podman). Tests are real
integration tests — they spin up `debian:bookworm-slim` probe containers
and exercise the real mount paths, blueprint logic, and the
heartbeat-only container keep-alive. Expect 1–2 minutes total.

## Arguments

- `t/02-*.t` (optional) — restrict to a subset by glob. The runner
  resolves the glob relative to the current directory first, then falls
  back to the plugin root and the `t/` subdirectory, so the same glob
  works from both the repo root and `plugins/sandbox/`. Without args,
  runs the full suite.

## Steps

### 1. Pre-flight: confirm a container runtime is reachable

```bash
# Detect the runtime using the same fallback chain as the launcher:
# docker.exe → docker → podman.exe → podman (Windows probes .exe first).
RUNTIME=$(
  for _rt in docker.exe docker podman.exe podman; do
    if command -v "$_rt" > /dev/null 2>&1; then
      echo "$_rt"
      break
    fi
  done
)
if [ -z "$RUNTIME" ]; then
  echo "Neither docker nor podman is reachable."
  echo "Start Docker Desktop OR run 'podman machine start', then try again."
  exit 1
fi
$RUNTIME ps > /dev/null 2>&1 || {
  echo "Runtime '$RUNTIME' found but daemon is not running."
  echo "Start Docker Desktop OR run 'podman machine start', then try again."
  exit 1
}
```

### 2. Confirm the probe image is cached locally

```bash
$RUNTIME image inspect docker.io/library/debian:bookworm-slim > /dev/null 2>&1 || {
  echo "Pulling debian:bookworm-slim (one-time, ~78 MB)..."
  $RUNTIME pull docker.io/library/debian:bookworm-slim
}
```

### 3. Run the suite

```bash
perl "$HOME/.claude/ccpraxis/plugins/sandbox/tests/run-tests.pl" $ARGUMENTS
```

(If `$ARGUMENTS` is empty the runner picks all `t/*.t` files automatically.)

### 4. Report

The runner emits a per-file pass/fail line and a summary. On failure it
also dumps the full output of each failing file. Show that output to the
user verbatim — don't paraphrase failures.

If everything passed, a one-line confirmation is enough. Optionally point
out the headline tests:

- `01-bind-honors-append-and-utimensat.t` — proves the host bind mount is
  safe for claude's syscalls (the assumption underlying the whole
  bind-mount architecture)
- `02-launcher-bind-mount-shape.t` — confirms no volume-workaround
  residue snuck back in
- `04-runtime-detection.t` — confirms docker/podman detection is
  consistent across all three scripts (launcher, bootstrap, TestSandbox)

## When tests fail

A failed test isn't a redo signal — read its output. Specific failure
shapes mean specific things:

- **`01-bind-honors-…` fails on T1 (O_APPEND):** the current backend's
  host bind doesn't honor `O_APPEND` — likely a regression to a 9p-style
  share. Reintroduce the xfs-volume workaround OR switch to a healthier
  backend.
- **`01-bind-honors-…` fails on T2/T3 (utimensat):** same diagnosis as
  above but specific to `utimensat`. Bun's lock manager will wedge on
  this backend without a workaround.
- **`02-launcher-bind-mount-shape.t` fails:** someone partially
  reintroduced volume code. Check the mount layout in `launcher.pl`.
- **`04-runtime-detection.t` fails:** the `_detect_container_cli` helper
  drifted out of sync across files. Re-paste it.
- **`12-keepalive-heartbeat.t` fails:** the container's heartbeat-only
  keep-alive loop is broken (sentinel staleness not detected, or stays
  alive when it shouldn't). Risk: containers either die mid-session or
  orphan-leak forever. Fix before shipping.
