# Concurrent-config-safety spike — decision doc

Blueprint: `sandbox-concurrent-session-safety` / package `01-spike-mount-mechanism`.

> ⚠️ **PARTIAL — authored host-side by `/butler:keep-going-solo` (2026-07-13).** The static
> analysis (§1, §2, and the candidate evaluation in §3) is complete and host-verified. The
> **in-container empirical evidence the done-criteria require (EBUSY repro, live `findmnt`,
> `CLAUDE_CONFIG_DIR` verification) is PENDING** — Decision #7 mandates it run in-container, and
> keep-going-solo runs on the host with no sandbox. Complete §1-repro, §2-live, and §3-verify inside
> a real `claude-sandbox`, then this doc satisfies the spike and unblocks package 02. Package 01 is
> **PARKED** until then.

## §1 — The EBUSY mechanism (root cause)

Claude Code persists `~/.claude.json` with an atomic **temp-file + `rename()`**. `rename()` over a
**single-file bind-mount target** fails with `EBUSY` on Linux, so Claude falls back to a non-atomic
in-place truncate+write; two concurrent in-container connectors tear the file to 0 bytes. On the host
`~/.claude.json` is an ordinary file, so atomic rename works and concurrent sessions are safe. The
project already hit and fixed this exact wall for `.credentials.json` (**Fix 1**, git `c18505b`) by
moving it out of a single-file bind into the directory bind — see the credentials-vs-`.claude.json`
comment at `launcher.pl:1920-1935`.

- **[HOST-CONFIRMED]** the mount that causes it: `launcher.pl:2030`
  `'-v', "${CLAUDE_DATA}/.claude.json:/root/.claude.json"` — a **writable single-file bind** at the
  home root, OUTSIDE the `/root/.claude` directory bind (`launcher.pl:2005`
  `'-v', "${CLAUDE_DATA}:/root/.claude"`).
- **[IN-CONTAINER — PENDING]** Demonstrate: inside a running sandbox, paste the command + error for
  `python3 -c "import os,tempfile; ...; os.rename(tmp, '/root/.claude.json')"` (or a shell
  `mv`/`rename` equiv) → expect `EBUSY`; AND the SUCCESS case for the same atomic rename onto a file
  INSIDE the dir bind, e.g. `/root/.claude/probe.json`. (Decision #7, done-criteria (1).)

## §2 — Inventory of shared writable claude-home mounts

**[HOST-CONFIRMED — static `-v` scan of `launcher.pl`]** Every single-file bind onto claude-home and
its mount kind:

| mount target (container) | source | kind | writable? | line |
|---|---|---|---|---|
| `/root/.claude` | `${CLAUDE_DATA}` | **directory bind** | RW (atomic rename OK) | 2005 |
| `/root/.claude/.launcher` | `${LAUNCHER_DIR}` | dir bind | **:ro** | 2013 |
| **`/root/.claude.json`** | `${CLAUDE_DATA}/.claude.json` | **single-file bind** | **RW ← the bug** | **2030** |
| `/root/.claude/statusline.pl` | `…/ccpraxis/scripts/statusline.pl` | single-file | :ro | 2031 |
| `/root/.claude/skills/<name>` | skill host paths | single-file | :ro | 1257 |
| `/root/.claude/plugins/…` | plugin host paths | single-file | :ro | 1351 |
| `/root/.claude/git-askpass.sh`, `git-pat`, `git-credential-pat.sh`, `git-ssh-command.sh` | `${CLAUDE_DATA}/…` | single-file | :ro | 1419-1442 |
| `/root/.config/git/config` | `${CLAUDE_DATA}/gitconfig` | single-file | :ro | 1438 |
| `/root/.claude/backpack.pl`, `auto-declare.pl` | backpack dir | single-file | :ro | 1488-1492 |

- **`.credentials.json`** is NOT a single-file bind — Fix 1 already made it a real file inside the
  `/root/.claude` dir bind. **[HOST-CONFIRMED]**
- **CONCLUSION (static): `/root/.claude.json` (line 2030) is the ONLY writable single-file bind onto
  claude-home state.** Every other single-file bind is `:ro`, so no concurrent-write corruption path.
- **[IN-CONTAINER — PENDING]** cross-check the static conclusion against the live mount table:
  `findmnt -o TARGET,SOURCE,FSTYPE | grep -E '/root/\.claude'` and `/proc/self/mountinfo` inside a
  running container — confirm exactly one RW single-file bind (`.claude.json`) and that the rest are
  ro/dir. (done-criteria (2).)

## §3 — Candidate relocation mechanisms (Decision #5)

Goal: make `.claude.json` a real file inside a bind-mounted DIRECTORY (atomic `rename()` works),
matching the host and the `.credentials.json` precedent, WITHOUT reintroducing a writable single-file
bind (Decision #9 structural guard) and WITHOUT serializing/isolating connectors (Decision #2).

**⚠️ The mechanism CANNOT be finalized host-side** — Claude Code's exact handling of `.claude.json`
relocation is not reliably documented (a `claude-code-guide` research pass this session produced
*unreliable/hallucinated* citations — e.g. it wrongly treated ccpraxis as an official Anthropic
repo — so its specifics are NOT trusted here). The blueprint (Terms & conventions) already mandates
confirming empirically in-container. Candidates to VERIFY in-container:

- **A. `CLAUDE_CONFIG_DIR` env var** — *IF* it relocates the global `.claude.json` itself (not just
  the `.claude/` dir) into a writable directory, this is the cleanest fix (no home-root file at all).
  **[VERIFY IN-CONTAINER]** set `CLAUDE_CONFIG_DIR=/root/.claude` (or a fresh dir bind), launch
  claude, and check WHERE it reads/writes the global config (`strace`/`lsof`/just observe the file
  that changes). Confirm the exact filename it uses there. If it works, package 02 = drop the `:2030`
  single-file `-v`, set the env, migrate the old file into the new location.
- **B. Symlink-into-dir-bind** — `/root/.claude.json` → symlink to a real file inside the
  `/root/.claude` dir bind (e.g. `/root/.claude/claude.json`). Whether Claude's atomic
  temp+`rename()` follows the symlink and lands the rename on the dir-bind file (EBUSY-free) is the
  open question. **[VERIFY IN-CONTAINER]** create the symlink, run the §1 rename probe THROUGH it,
  and confirm no EBUSY. Risk: Claude may `rename()` onto the symlink path itself (replacing the link),
  not its target.
- **C. Whole-`$HOME` (or `/root`) directory bind / HOME relocation** — bind a writable directory at
  `$HOME` so `.claude.json` is just a file inside a dir bind. Most host-like, but the broadest change;
  interacts with everything else mounted under `/root`. **[VERIFY IN-CONTAINER]**

**Recommended order to test:** A (cleanest if it works) → B (smallest change if A doesn't) → C
(fallback). Whichever passes the §1 EBUSY-free rename + a concurrency probe becomes the decision.

## §4 — Migration shape (Decision #6, #10) — for package 02

Existing sandboxes have config only at `claude-home/.claude.json`. On first post-fix launch:
**COPY** it to the new location, then rename the old file to
`.claude.json.pre-relocation-bak-<ts>` so the old launcher path no longer holds a live
single-file-bind target (non-destructive, idempotent). "Intact" = new file parses as JSON and its
`hasCompletedOnboarding`/`oauthAccount`/`userID`/`projects` match the backup; launch shows no
onboarding wizard. Follow the `.claude-data → claude-home` migration precedent (search `launcher.pl`
for the one-time migration block ~line 380+).

## §5 — Files package 02 will change (authoritative once §3 is decided)

- `launcher.pl` — the mount-arg block `~:2003-2031`: **remove the `.claude.json` single-file `-v`
  (:2030)**; add the chosen mechanism (env var / symlink setup / dir bind) + the one-time migration.
  Repoint `ensure_claude_json_onboarded` / `ensure_claude_json_host_file` (`~:1577-1610`) at the new
  path.
- `ClaudeConfig.pm` — repoint the self-heal (`heal_claude_json`) at the new `.claude.json` location
  (Decision #4/#12 — self-heal STAYS).
- `MountSpec.pm` — only if the chosen mechanism needs mount-spec logic (candidate, per Decision #12).
- `container/` — only if the mechanism needs a container-side change (e.g. an entrypoint symlink).
- `tests/t/` — update `t/02-launcher-bind-mount-shape.t` (`:42-44`) + `t/03-claude-json-file-bind.t`
  to the new mount shape; add the Decision #9 structural guard (no writable single-file bind); add a
  NEW `t/35-shared-claude-json-concurrency.t` (Decision #8/#11 threshold, **in-container**); leave
  `t/18` unmodified.

---

**Status:** §1-static, §2-static, §3-candidates, §4, §5 = DONE (host). §1-repro, §2-live, §3-verify =
PENDING (in-container). Package 01 PARKED; package 02 blocked on it. See the package ledgers.
