# claude-sandbox

A Docker- or Podman-based isolated dev container for Claude Code.
Per-project sandbox with explicit mounts for skills, plugins, and a
host-bind-mounted `.claude-data/` directory for live session storage.

> ## ⚠  Windows users: do NOT use the Hyper-V backend.
>
> **Hyper-V is unsupported and the bootstrap actively refuses it.** Microsoft's
> `Plan9FileServer` (the 9p host-share used by every Hyper-V-backed Linux
> VM, including podman-machine-on-hyperv and the older Docker Desktop
> "use Hyper-V" mode) silently breaks two syscalls claude depends on:
>
> - `O_APPEND` writes return EIO → `claude --resume` fails on every session
> - `utimensat` silently no-ops → Bun's lock manager wedges → TUI freezes
>   every ~60 seconds with no error
>
> There is no workaround we can ship from this side — the bugs are in
> closed-source Windows components and have been observed unchanged across
> Windows 10 + 11, Podman 4.x + 5.x, and multiple Hyper-V integration-tool
> versions over the course of 2026.
>
> **Use WSL2 instead** for whichever runtime you pick:
>
> - **Docker Desktop** uses WSL2 by default since 2021. Check Settings →
>   General → "Use the WSL 2 based engine" is ticked, and Settings →
>   Resources → WSL Integration has your distro enabled.
> - **Podman** needs `podman machine init --provider wsl` (NOT `--provider hyperv`).
>
> Prerequisites for WSL2 (admin PowerShell, then reboot):
> ```pwsh
> Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
> Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
> # reboot
> wsl --update
> wsl --set-default-version 2
> ```

## Quick start

```pwsh
cd C:\path\to\project
claude-sandbox
```

First run prompts for sandbox setup (bootstrap). On subsequent runs the
launcher dispatches by container state: if the container is not yet
running, this terminal becomes the **manager** — it runs the skill/plugin
selector and then sits in the heartbeat loop keeping the sandbox alive.
To start a claude session, open a **second terminal** in the same
project and run `claude-sandbox` there — that one enters **connector**
mode and drops into `claude` inside the container.

To run the test suite:

```pwsh
perl ~/.claude/ccpraxis/plugins/sandbox/tests/run-tests.pl
```

Or via the slash command: `/sandbox:test`.

## Runtime support

The launcher auto-detects which container runtime is installed and uses
whichever is present, in this preference order:

1. **Docker** (`docker.exe` on Windows, `docker` elsewhere) — Docker
   Desktop on Windows/macOS, Docker Engine on Linux.
2. **Podman** (`podman.exe` / `podman`) — Podman Desktop / Podman Machine
   on Windows/macOS, native podman on Linux.

Detection runs each time the launcher starts (`<cli> --version`). The
same helper lives in `launcher.pl`, `bootstrap.pl`, and
`tests/lib/TestSandbox.pm` (test `04-runtime-detection.t` pins this).

**On Windows, both runtimes require WSL2** (see the warning at the top of
this file). The bootstrap blocks `podman + hyperv` automatically; Docker
Desktop on Hyper-V isn't auto-detected (it requires manual user effort
to even configure) but the same fatal 9p bugs apply if you set it up
that way. Don't.

The historical Hyper-V investigation produced an xfs-volume + sync-sidecar
workaround that shipped in earlier versions of this sandbox — retired in
2026-06 when the project migrated to WSL2 universally. Test
`01-bind-honors-…` empirically pins the WSL2 host bind's correctness on
every test run; if a future backend ever fails that probe, restore the
workaround OR (better) switch off that backend.

---

## Architecture

```
HOST                                                  CONTAINER (docker OR podman)
─────────────────────────────────────────────────────────────────────────────────────
<project>/                                      ──►  /project                       (bind, RW)
<project>/.claude-data/                         ──►  /root/.claude                  (bind, RW)
<project>/.claude-data/.launcher/               ──►  /root/.claude/.launcher        (bind, RO overlay)
<project>/.claude-data/.launcher/credentials.json ──► /root/.claude/.credentials.json (file bind, RW)
<project>/.claude-data/.claude.json             ──►  /root/.claude.json             (file bind, RW)
~/.claude/ccpraxis/scripts/statusline.pl        ──►  /root/.claude/statusline.pl    (file bind, RO)
<each selected skill dir>                       ──►  /root/.claude/skills/<name>    (bind, RO)
~/.claude/plugins/cache + manifests             ──►  /root/.claude/plugins/...      (bind, RO)
```

**Host filesystem is the live state.** `<project>/.claude-data/` is the
container's `/root/.claude/` — claude's session jsonl, tasks/, lockfiles,
settings.json, and CLAUDE.md are all writable host files. No volume,
no sync sidecar, no `podman cp` round-trips.

### Mount layering

The launcher applies these in order during `podman create`:

1. **`.claude-data` → `/root/.claude` (RW)** — the bulk bind. Sessions,
   tasks, lockfiles, blueprint copies (`CLAUDE.md`, `settings.json`) all
   land here. `apply_blueprints_to_host_data` writes the canonicals
   from `.launcher/` to `.claude-data/` on container create so they
   appear at the standard paths inside.

2. **`.launcher` → `/root/.claude/.launcher:ro` (RO overlay)** — defends
   the launcher's metadata. The container can READ launcher state
   (statusline + skills) but CANNOT write to it. Without this overlay,
   a compromised in-container process could fake
   `backpack-trusted-hash` to bypass backpack approval, scribble the
   `selected-skills.json` snapshot, or corrupt cache hashes that gate
   blueprint re-application. Test `06-launcher-ro-protection.t` pins
   the kernel-level enforcement.

3. **`.launcher/credentials.json` → `/root/.claude/.credentials.json`
   (RW single-file bind)** — the OAuth file. Container DOES need to
   write here (mcpOAuth tokens during `claude mcp add` auth flows).
   Single-file bind from the canonical `.launcher/` location means
   writes persist across container rebuild without any sync step, and
   the rest of `.launcher/` stays RO.

4. **`.claude-data/.claude.json` → `/root/.claude.json` (RW single-file
   bind)** — claude-code's outside-`/root/.claude/` config file. Same
   reasoning as #3 (single file, must exist on host before mount —
   `ensure_claude_json_host_file` touches it if missing).

---

## Data durability

| Event | Host's `.claude-data/` state |
|-------|------------------------------|
| Container freshly created | Blueprint files written to host before mount; .claude.json placeholder ensured |
| claude session writes a turn | Host sees it immediately (bind mount) |
| claude exits cleanly | Host already has everything — no final sync needed |
| Container crashes | Host already has everything — no rescue needed |
| User deletes container | Re-create + bind mount gets the same `.claude-data/` back |
| User deletes `.claude-data/` | All sandbox state for this project is gone (this IS the storage) |
| Manager terminal closes or crashes | `/tmp/.launcher-alive` sentinel goes stale; container's heartbeat loop self-reaps within HB(300s)+GRACE(10s) — no orphan containers |

### Multi-session

Two `claude-sandbox` invocations on the same project share the SAME
container (the container name is deterministic per project path:
`claude-${project}-${path_hash}`). They share `/root/.claude` via the
bind mount → see each other's files at the filesystem level. Each
session has its own UUID → its own session jsonl and its own task-dir →
no per-session-file contention.

Test `18-multi-session-shared-state.t` pins this.

---

## Quirks and workarounds

These are real limitations or platform sharp edges still in place. Each
has a test pinning it so future "simplifications" can't silently
re-introduce a regression.

### Podman/Docker API socket (Windows)

| Quirk | Workaround | Test |
|-------|------------|------|
| `<cli> volume create` is NOT idempotent (exit 125 on collision) | The launcher no longer creates volumes (post-WSL2-migration); no current test creates volumes either | (test harness library) |

### MSYS2 / Git-for-Windows perl mount specs

| Quirk | Workaround | Test |
|-------|------------|------|
| MSYS2 silently mangles `-v HOST:CONTAINER` mount specs (treats `:` as PATH separator, re-joins with `;`) | `MSYS2_ARG_CONV_EXCL=*` env var disables conversion; launcher emits `--mount type=...` form instead of `-v` | 07, 22 |
| `-v vol:/path` with bare volume name gets treated as bind by naïve translation | `MountSpec::v_to_mount` detects path-vs-volume by source pattern | 07 |
| Cygwin perl `Cwd::abs_path` doesn't recognize `C:/...` as absolute, prepends CWD | `dirname(__FILE__)` with backslash normalization (no abs_path) | 08 |
| Cygwin perl `FindBin::$Bin` unreliable with Windows-style `$0` from .ps1 shim | same — `dirname(__FILE__)` | 08 |

### Container lifecycle

| Quirk | Workaround | Test |
|-------|------------|------|
| Container needs to survive across multiple `claude` sessions and across the gap between launcher start and first claude attach | Heartbeat-only keep-alive — container watches `/tmp/.launcher-alive` mtime, dies if >5 min stale. The manager-mode launcher refreshes the sentinel every 2 minutes from its own terminal. | 12 |
| User prompts AFTER `podman start` let user-think-time burn through keep-alive → "container state improper" on next `podman exec` | All user interaction (skill selector, rebuild prompt, backpack approval) happens BEFORE `podman start` | 09 |
| `podman stop` from one launcher would kill concurrent claude sessions in the same container | Don't `podman stop` from connector mode; let the container's heartbeat-only loop shut down naturally when the manager terminal closes | (no test — would need 2-process orchestration) |
| Ctrl+C from PowerShell kills the host-side `<cli>.exe` client but the disconnect does NOT propagate through conmon to the in-container claude — claude stays alive, keeps refreshing its `.lock.lock` files in `/root/.claude/`, and any NEW claude session in the same container blocks indefinitely waiting for those orphan locks | Launcher's `find_orphan_claudes` + `kill_orphan_claudes_if_user_confirms` runs at startup of every connector. Heuristic: claude alive >30s + zero `rchar` growth over 2s == orphan. User confirms before kill. Manual fallback: `<cli> exec <container> pkill claude` | (no automated test — relies on Bun-specific runtime conditions) |
| Windows console mode flags get clobbered when a sibling `podman.exe` in the same console runs non-interactively (e.g. a per-60s heartbeat). Symptom: typed keys vanish into the local line-input buffer, claude's TUI escape codes render as literal `^[[…]` text. | **Split launcher into manager + connector modes**, dispatched by container state. Manager runs the heartbeat from its own terminal; connectors run `podman exec -it claude` from theirs. Two consoles, no cross-contamination. | (structural — covered by manual two-terminal smoke check, not a `.t`) |

### If the TUI freezes (input dead, output alive)

The historical symptom was caused by a per-60s heartbeat sidecar
process sharing the same Windows console as the interactive
`podman exec -it claude` session. Each tick spawned `podman.exe` as a
sibling in the user's terminal, which fiddled with `SetConsoleMode`
flags (`ENABLE_LINE_INPUT`, `ENABLE_VIRTUAL_TERMINAL_PROCESSING`)
and left them desynced from what the interactive session needed.
Symptom: typed keys buffered locally instead of reaching claude;
claude's VT output rendered as literal `^[[…]` text.

**The fix is the manager + connector split documented above.** The
heartbeat now lives in the manager's terminal, and the interactive
claude lives in connector terminals — different consoles, no
cross-contamination by construction.

If you still see this symptom on the current launcher, first verify:

1. **You DID open `claude-sandbox` in a second terminal** for claude — the manager terminal shouldn't be the one running claude.
2. **No background processes share your connector's console.** From the stuck console, in a parallel PowerShell:
   ```pwsh
   # Replace 9232 with the podman.exe PID of your stuck claude session.
   $procs = New-Object uint32[] 32
   [Con3]::AttachConsole(9232) | Out-Null
   $n = [Con3]::GetConsoleProcessList($procs, 32)
   [Con3]::FreeConsole() | Out-Null
   $procs[0..($n-1)]
   ```
   You should see exactly: PowerShell → perl(launcher) → perl(fork-emul) → podman.exe. Anything else sharing that console is a regression — file an issue.
3. **If the symptom genuinely persists with no spurious console-sharers, escalate to the upstream `containers/podman` repo** — at that point we're looking at a podman/conmon attach-stdin race independent of our architecture. See the closely-related #4397, #24370, #25344, #26951.

### Bun/claude

| Quirk | Workaround | Test |
|-------|------------|------|
| Bun treats SIGUSR1 as an inspector signal — sending it crashes claude | Don't send SIGUSR1 for diagnostic probes; use SIGWINCH if you need a no-op signal | (notebook entry, no test) |
| claude's process `comm` is `claude` (not `node` or `bun`), so `pgrep -x claude` matches reliably | Orphan detection in `find_orphan_claudes` uses `pgrep -x claude` inside the container; the heartbeat keep-alive is sentinel-based, not process-based | 12 |

### TestSandbox harness

| Quirk | Workaround | Test |
|-------|------------|------|
| `system("$PODMAN ...")` uses /bin/sh under cygwin perl; double-quote wrapping expands `$VAR` in scripts passed to containers | `_arg_quote` uses single-quote wrapping by default (POSIX literal) | (test harness library) |
| Git-Bash `/tmp` isn't always on the WSL2 share/container fs view → bind-mount fails | `new_temp_dir` anchors under `$HOME/.cache/sandbox-tests/` (HOME IS reachable from inside the container) | (test harness library) |

---

## Test suite

15 files under `tests/t/`. Each is independent — owns its containers,
temp dirs, and cleans up via END blocks. Tagged with the test PID so
concurrent runs are safe.

See `tests/README.md` for the per-file claim table.

Plus `tests/manual/longrun-freeze-check.sh` — non-suite, 5–8 minute
empirical sanity run that spawns claude in a probe container and verifies
it stays alive + processing throughout.

---

## File layout reference

```
~/.claude/ccpraxis/plugins/sandbox/
├── README.md                          # this file
├── bin/
│   ├── claude-sandbox.ps1             # PowerShell shim → launcher.pl
│   └── claude-sandbox.sh              # Bash shim → launcher.pl
├── container/
│   ├── Containerfile                  # debian:bookworm-slim + claude install
│   ├── CLAUDE.md                      # blueprint copied into each container
│   └── settings.json                  # blueprint copied into each container
├── scripts/
│   ├── launcher.pl                    # main entrypoint (manager + connector modes)
│   ├── MountSpec.pm                   # mount-spec parsing (bind vs volume)
│   ├── select-session.pl              # picker TUI (used in connector mode)
│   ├── bootstrap.pl                   # first-time .claude-data setup
│   └── skills.pl                      # discovery + selection state
├── skills/
│   ├── setup/                         # /sandbox:setup
│   └── test/                          # /sandbox:test
└── tests/
    ├── README.md                      # test-suite specifics
    ├── run-tests.pl                   # driver
    ├── lib/TestSandbox.pm             # harness helpers
    ├── manual/                        # non-suite empirical tests
    └── t/                             # 15 .t files
```

## Related references

- `.ccpraxis-local-data/blueprints/_archive/sandbox-wsl2-migration/` — 2026-06 migration to the
  WSL2 backend, including the workaround #1 (volume + sync-sidecar)
  retirement
- `.ccpraxis-local-data/blueprints/_archive/sandbox-9p-volume-redesign/` — the now-superseded
  volume-redesign plan from the Hyper-V era
- `.ccpraxis-local-data/blueprints/_archive/sandbox-project-scope-strategy/` — earlier strategy
  doc (scope partitioning, OAuth via socat)
