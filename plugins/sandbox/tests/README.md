# sandbox plugin tests

Verification suite for the `/sandbox` launcher's mount strategy, runtime
detection, and container-lifecycle invariants. Run from the project root
or anywhere — paths are anchored via `FindBin`.

```bash
perl ~/.claude/ccpraxis/plugins/sandbox/tests/run-tests.pl
# or, for a subset:
perl ~/.claude/ccpraxis/plugins/sandbox/tests/run-tests.pl tests/t/02-*.t
```

Each test file (`t/*.t`) is independent — owns its containers and temp
dirs, and cleans up via the END block in `lib/TestSandbox.pm`. Concurrent
runs are safe (resources tagged with `claude-sandbox-test-$$-…`).

## What's covered

| File | Claim |
|---|---|
| `01-bind-honors-append-and-utimensat.t` | Current container backend's host bind mount honors O_APPEND, utimensat UTIME_NOW, utimensat explicit timestamp — the assumption replacing the retired xfs-volume workaround |
| `02-launcher-bind-mount-shape.t` | Launcher mounts `/root/.claude` from `.ccpraxis-local-data/claude-home` (host bind, not a volume) + single-file bind for `/root/.claude.json`; no `CLAUDE_DATA_VOLUME` residue |
| `03-claude-json-file-bind.t` | Single-file bind of `.ccpraxis-local-data/claude-home/.claude.json` → `/root/.claude.json` works RW from both sides; mount target is a file, not an auto-created directory |
| `04-runtime-detection.t` | Same `_detect_container_cli` helper is present in all three scripts (launcher.pl, bootstrap.pl, TestSandbox.pm); the detected CLI responds to `--version` |
| `06-launcher-ro-protection.t` | `.launcher` RO overlay enforced at kernel mount level (container reads succeed, writes blocked); `.credentials.json` is a rename-safe real file in the `claude-home` dir bind (in-place AND atomic temp+rename writes land + persist to the host — proves in-container OAuth refresh works); `.claude.json` single-file bind remains RW |
| `07-mountspec-volume-vs-bind.t` | `MountSpec::v_to_mount` correctly classifies path-shaped sources as `type=bind` and bare-identifier sources as `type=volume` |
| `08-launcher-loads-from-any-cwd.t` | Launcher resolves its own path correctly regardless of caller's cwd |
| `09-no-stdin-after-podman-start.t` | Structural: all user interaction (skill selector, rebuild prompt, backpack approval) is BEFORE `podman start` — keep-alive window doesn't burn on user-think-time |
| `10-select-session-empty-dir.t` | Picker emits NEW when no sessions exist (no menu shown) |
| `11-select-session-parses.t` | Picker handles real-shape JSONL without crashing; "Start a new session" is option 1 |
| `12-keepalive-heartbeat.t` | Container's ENTRYPOINT heartbeat-only keep-alive loop respects the `/tmp/.launcher-alive` staleness window |
| `13-install-pass-heartbeat.t` | Backpack install pass keeps the container alive past the HB window via a parallel heartbeat subshell (`trap EXIT` cleanup); control case proves the refresher is load-bearing |
| `18-multi-session-shared-state.t` | Two concurrent claudes in the same container, sharing `/root/.claude` via bind mount, write to per-session paths without corruption; host filesystem reflects both in real time |
| `21-select-session-multiple.t` | Picker correctly handles multiple sessions; ordering + numbering stable |
| `22-mountspec-edge-cases.t` | `MountSpec::v_to_mount` handles drive-letter sources, `:ro` options, paths with embedded `:` |
| `30-connector-hold.t` | `ConnectorHold::should_hold_window` holds a connector's Windows Terminal tab open ONLY on a lost container (nonzero exit + not running), never on a clean quit or a claude error while the container lives; `lost_message` names the container + tells the user the conversation is safe and how to resume |
| `31-plugin-merge.t` | Fix 2 copy model: `materialize-plugins` / `materialize-known-marketplaces` refresh host-selected entries, preserve sandbox installs (incl. the "notion trap" — an unselected host plugin installed in-sandbox is kept, via the copy-plan MANIFEST not the host registry), drop deselected host entries, and emit the copy-plan manifest |
| `32-plugin-sync.t` | Fix 2 `PluginSync::reconcile_copy_plan`: copies selected host plugins in (host authoritative — reverts in-sandbox tampering), preserves sandbox-installed dirs never in a manifest, removes deselected/host-removed dirs with empty-parent pruning (no zombies), handles version bumps |

## Requirements

- A container runtime reachable: `docker.exe ps` OR `podman.exe ps` works (tests auto-detect)
- `docker.io/library/debian:bookworm-slim` image cached locally (small, the probe image)
- Perl with `Test::More` (core module — always present)

## Adding tests

- New tests go in `t/`, named `NN-short-slug.t`
- Use `TestSandbox` helpers for any container objects so cleanup is automatic
- Number prefix groups tests by domain: `0x` = filesystem facts / bind-mount
  correctness / runtime detection, `1x` = container lifecycle / session
  management, `2x` = mount-spec parsing. Pick the next free slot in the
  appropriate decade. (Note: `12` and `13` are lifecycle tests in the `1x`
  group; `22` is a `2x` parsing test — the decade is the guide, the exact
  slot within it is arbitrary.)

## Running a subset

Pass glob patterns to `run-tests.pl`. Patterns are resolved cwd-relative
first; if no files match the cwd, the runner falls back to paths anchored at
its own directory (and at its own `t/` subdirectory). This means the same
invocation works from the repo root or from `plugins/sandbox/`:

```bash
perl plugins/sandbox/tests/run-tests.pl plugins/sandbox/tests/t/12-*.t
# or from plugins/sandbox/:
perl tests/run-tests.pl t/12-*.t
```

Exit code 2 = no matching test files found (pattern mismatch).

## Manual tests

`tests/manual/longrun-freeze-check.sh` — an empirical 5–8 minute sanity
check that launches claude inside a container (using the launcher's real
bind-mount shape) and verifies claude stays alive and processing throughout.
It is NOT part of the automated suite — it requires a container runtime and
takes minutes to run.

```bash
bash tests/manual/longrun-freeze-check.sh [PROJECT_DIR]
```

`PROJECT_DIR` is an optional path to an existing project directory whose
`.ccpraxis-local-data/claude-home/` and `.ccpraxis-local-data/claude-home/.claude.json` are bound into the container
exactly as the launcher does. If omitted, a scratch project is created under
`$HOME/.cache/sandbox-tests/` and removed on exit.

Control the run duration with `DURATION=<seconds>` (default 480).

## Historical (pre-WSL2-migration)

A previous version of this suite pinned a podman xfs-volume workaround
for Hyper-V's 9p O_APPEND / utimensat bugs (tests 01–06, 13, 14).
That workaround was retired when the sandbox migrated to the WSL2 backend
(2026-06) — those tests were deleted. If a future backend (e.g. macOS via
qemu/virtiofs) reintroduces a 9p-style file-share, run `01-bind-honors-…`
on that backend first; if it fails, restore the volume workaround.
