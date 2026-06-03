# sandbox plugin tests

Verification suite for the `/sandbox` launcher's mount strategy and the
9p O_APPEND workaround. Run from the project root or anywhere — paths
are anchored via `FindBin`.

```bash
perl ~/.claude/ccpraxis/plugins/sandbox/tests/run-tests.pl
# or, for a subset:
perl ~/.claude/ccpraxis/plugins/sandbox/tests/run-tests.pl tests/t/02-*.t
```

Each test file (`t/*.t`) is independent — owns its containers, volumes,
and temp dirs, and cleans up via the END block in `lib/TestSandbox.pm`.
Concurrent runs are safe (resources tagged with `claude-sandbox-test-$$-…`).

## What's covered

| File | Claim |
|---|---|
| `01-9p-confirms-append-bug.t` | Sanity: 9p host bind rejects O_APPEND on Podman/HyperV |
| `02-volume-supports-append.t` | Critical: named volume accepts O_APPEND (the workaround's premise) |
| `03-volume-create-idempotency.t` | `podman volume create` is NOT idempotent — pins the inspect-first pattern |
| `04-volume-persists-rm.t` | Volume contents survive `podman rm` of the container |
| `05-seed-and-sync-roundtrip.t` | Host → volume seed + container append + volume → host sync preserves data |
| `06-sidecar-periodic-sync.t` | `sync-sidecar.pl` mirrors data on its interval + self-exits when container stops |
| `10-select-session-empty-dir.t` | Picker emits NEW when no sessions exist (no menu shown) |
| `11-select-session-parses.t` | Picker handles real-shape JSONL without crashing; "Start a new session" is option 1 |

## Requirements

- Podman reachable (`podman.exe ps` works)
- `docker.io/library/debian:bookworm-slim` image cached locally (small,
  used as the probe image so we don't bake on the heavy `claude-sandbox`
  image for every test)
- Perl with `Test::More` (core module — should always be present)

## Adding tests

- New tests go in `t/`, named `NN-short-slug.t`
- Use `TestSandbox` helpers for any podman objects so cleanup is automatic
- Number prefix groups tests semantically: `0x` = filesystem facts, `1x` =
  CLI-level behavior, etc. Pick the next free slot.
