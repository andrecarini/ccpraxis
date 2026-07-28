# Concurrent-config-safety spike — decision doc

Blueprint: `sandbox-butler-overhaul` / package `s01-config-safety-spike`. `Decision #N`
references anywhere in this doc resolve to the archived `sandbox-concurrent-session-safety`
decision set (the "config-safety-track" decisions), reproduced in the blueprint's
**Appendix A** (`blueprint.md`, "Config-safety-track decisions").

> ✅ **COMPLETE — in-container evidence gathered 2026-07-25.** All done-criteria for this
> spike are now backed by pasted probe transcripts (§1, §2) and a decided mechanism (§3).
> **Decision: set `CLAUDE_CONFIG_DIR=/root/.claude` on the container and REMOVE the
> `${CLAUDE_DATA}/.claude.json:/root/.claude.json` single-file `-v`.** §4 records what this
> means for the previously-mandated migration as a **deviation from carried Decisions #6 and
> #10**, flagged for orchestrator/user confirmation — not silently applied.

**Evidence index** — claim class → source file (paths relative to the blueprint dir):

| Claim class | Evidence |
|---|---|
| EBUSY reproduction on the LIVE mount (cases A, B, D) | `reports/s01-config-safety-spike/probe-01-rename.out` |
| EBUSY corroboration on overlayfs + the 0-byte corruption chain (C1–C5) | `reports/s01-config-safety-spike/probe-02-replica.out` |
| Live mount inventory (`/proc/self/mountinfo`), scoped verdict | `reports/s01-config-safety-spike/probe-03-mountinfo.out` |
| `CLAUDE_CONFIG_DIR` empirical relocation behaviour | `reports/s01-config-safety-spike/probe-04-claude-config-dir.out` |
| Dual-path inode/dev/sha256 identity (makes the migration a no-op) | `reports/s01-config-safety-spike/probe-05-dualpath-identity.out` |
| CLI bundle resolvers (extracted from the shipped ELF) + method notes | ledger `packages/s01-config-safety-spike.md`, entry `2026-07-25T04:02Z` |

## §1 — The EBUSY mechanism (root cause), demonstrated

Claude Code persists `~/.claude.json` with an atomic **temp-file + `rename()`**. `rename()` over a
**single-file bind-mount target** fails with `EBUSY` on Linux, so Claude falls back to a non-atomic
in-place truncate+write; two concurrent in-container connectors tear the file to 0 bytes. On the host
`~/.claude.json` is an ordinary file, so atomic rename works and concurrent sessions are safe. The
project already hit and fixed this exact wall for `.credentials.json` (**Fix 1**, git `c18505b`) by
moving it out of a single-file bind into the directory bind — see the credentials-vs-`.claude.json`
comment at `launcher.pl:2421-2436`.

- the mount that causes it: `launcher.pl:2437`
  `'-v', "${CLAUDE_DATA}/.claude.json:/root/.claude.json",` — a **writable single-file bind** at the
  home root, OUTSIDE the `/root/.claude` directory bind (`launcher.pl:2412`
  `'-v', "${CLAUDE_DATA}:/root/.claude"`).

**Case A (live mountpoint, FAIL).** From `probe-01-rename.out`:

```
############ CASE A — rename() OVER the rw single-file bind ############
  target  : /root/.claude.json  (rw single-file bind)
  before  : size=39194 sha256=cd7c02659e6f5b9dc8cef09ba4df0ef49d714df6faf00ba1cf68f1850bc1698e
  source  : /root/.s01-probe-src.json size=39194 sha256=cd7c02659e6f5b9dc8cef09ba4df0ef49d714df6faf00ba1cf68f1850bc1698e  (byte-identical, same parent dir /root)
  syscall : rename(/root/.s01-probe-src.json, /root/.claude.json)
  result  : FAILED  errno=16  Device or resource busy
  after   : size=39194 sha256=cd7c02659e6f5b9dc8cef09ba4df0ef49d714df6faf00ba1cf68f1850bc1698e
  live cfg: UNCHANGED (safe)
  verdict : EBUSY as predicted — atomic rename is IMPOSSIBLE over a single-file bind
```

The `before` and `after` sha256 are identical
(`cd7c02659e6f5b9dc8cef09ba4df0ef49d714df6faf00ba1cf68f1850bc1698e`), captured before and after in
the same probe instant — the live fleet config was unharmed by the probe.

**Case B (dir bind, SUCCESS).** From `probe-01-rename.out`, the target this time is an ordinary file
inside the RW dir bind:

```
############ CASE B — rename() over a file INSIDE the dir bind ############
  target  : /root/.claude/.s01-probe-target.json  (ordinary file in the rw dir bind)
  before  : {"probe":"v1-original"}
  syscall : rename(/root/.claude/.s01-probe-src.json, /root/.claude/.s01-probe-target.json)
  result  : SUCCESS
  after   : {"probe":"v2-atomically-renamed"}
  src gone: yes
  verdict : SUCCESS — atomic temp+rename works inside the directory bind
```

**Corroboration on a second filesystem.** From `probe-02-replica.out` (an isolated `unshare -Urm`
replica):

```
=== /tmp filesystem ===
fstype=overlayfs
```

```
--- C1: raw rename() over the replica SINGLE-FILE bind (expect EBUSY) ---
rename(/tmp/s01-replica/home/new.tmp,/tmp/s01-replica/home/.claude.json) -> FAILED errno=16 (Device or resource busy)
```

```
--- C2: raw rename() over a file in the replica DIR bind (expect SUCCESS) ---
rename(/tmp/s01-replica/home/.claude/new.tmp,/tmp/s01-replica/home/.claude/config.json) -> SUCCESS errno=0 (-)
```

This matters because the live probe (Case A/B) ran on 9p/drvfs — the WSL2 host-bind filesystem —
while this replica runs on **overlayfs**, so the EBUSY result is shown to be a property of
single-file bind mounts in general, **not a 9p artifact**.

**The causal chain to 0-byte corruption.** From `probe-02-replica.out`, what `mv(1)` actually does
over the single-file bind:

```
--- C3: what mv(1) does over the single-file bind ---
mv: cannot move '/tmp/s01-replica/home/mv.tmp' to '/tmp/s01-replica/home/.claude.json': Device or resource busy
mv exit=1
content after  : {"probe":"store-v1"}
still a mount? : /tmp/s01-replica/home/.claude.json
NOTE: mv(1) FAILS outright (exit 1) and changes nothing. GNU mv only falls back to
      copy-then-unlink on EXDEV (cross-device), NOT on EBUSY. So the corruption does
      not come from mv -- it comes from an APPLICATION that, finding rename() denied,
      writes the config IN PLACE (open O_TRUNC + write). C4 shows what that costs.
```

Stated plainly: `mv(1)` over the single-file bind fails outright — exit 1, nothing changed. GNU `mv`
only falls back to copy-then-unlink on `EXDEV` (cross-device), **never on `EBUSY`**. The corruption
therefore is **not** attributable to `mv`; it comes from an application that, finding `rename()`
denied, writes the config **in place** (`open(O_TRUNC)` + write).

C4 (non-atomic in-place writer) vs C5 (atomic temp+rename), verbatim:

```
--- C4: the tear window — a reader sampling a non-atomic in-place writer ---
  reader: 309560 samples, 286219 zero-byte, 286219 unparseable, 0 open-errors  <-- CORRUPTION OBSERVED
  writer: 26013 non-atomic truncate+write cycles

--- C5: same load, but ATOMIC temp+rename inside the dir bind (expect 0 bad) ---
  writer: 12197 atomic temp+rename cycles
  reader: 267255 samples, 0 zero-byte, 0 unparseable, 0 open-errors  <-- should be all 0
```

One causal chain: single-file bind → `rename()` denied with `EBUSY` → application must write
in place → readers observe a 0-byte / unparseable config.

**Harness-honesty note.** Two harness bugs were found and fixed before any of the above numbers
were believed: (i) the replica's dir-bind mountpoint was never `mkdir`'d, so C2/C5 silently
no-op'd and C5's first-run "0 bad" was a **false green** — the readers now `die` on a missing
target and count `open-errors` separately; (ii) the original C3 note wrongly claimed `mv` "falls
back to copy" — corrected as above (`EXDEV` only, never `EBUSY`). This is recorded here because it
is the reason the C4/C5 numbers above are trustworthy.

## §2 — Inventory of shared writable claude-home mounts

**[HOST-CONFIRMED — static `-v` scan of `launcher.pl`]** Every single-file bind onto claude-home and
its mount kind:

| mount target (container) | source | kind | writable? | line |
|---|---|---|---|---|
| `/root/.claude` | `${CLAUDE_DATA}` | **directory bind** | RW (atomic rename OK) | 2412 |
| `/root/.claude/.launcher` | `${LAUNCHER_DIR}` | dir bind | **:ro** | 2420 |
| **`/root/.claude.json`** | `${CLAUDE_DATA}/.claude.json` | **single-file bind** | **RW ← the bug** | **2437** |
| `/root/.claude/statusline.pl` | `…/ccpraxis/scripts/statusline.pl` | single-file | :ro | 2438 |
| `/root/.claude/skills/<name>` | skill host paths | single-file | :ro | 1257 |
| `/root/.claude/plugins/…` | plugin host paths | single-file | :ro | 1351 |
| `/root/.claude/git-askpass.sh`, `git-pat`, `git-credential-pat.sh`, `git-ssh-command.sh` | `${CLAUDE_DATA}/…` | single-file | :ro | 1419-1442 |
| `/root/.config/git/config` | `${CLAUDE_DATA}/gitconfig` | single-file | :ro | 1438 |
| `/root/.claude/backpack.pl`, `auto-declare.pl` | backpack dir | single-file | :ro | 1488-1492 |

- **`.credentials.json`** is NOT a single-file bind — Fix 1 already made it a real file inside the
  `/root/.claude` dir bind. **[HOST-CONFIRMED]**
- **CONCLUSION (static): `/root/.claude.json` (line 2437) is the ONLY writable single-file bind onto
  claude-home state.** Every other single-file bind is `:ro`, so no concurrent-write corruption path.

**Live cross-check.** From `probe-03-mountinfo.out`, the three rows that matter:

```
/root/.claude                                        dir   rw  9p        /Users/André/ccpraxis-sandbox-workcopy/.ccpraxis-local-data/claude-home
/root/.claude.json                                   FILE  rw  9p        /Users/André/ccpraxis-sandbox-workcopy/.ccpraxis-local-data/claude-home/.claude.json
/root/.claude/.launcher                              dir   ro  9p        /Users/André/ccpraxis-sandbox-workcopy/.ccpraxis-local-data/claude-home/.launcher
```

The full-mount count block:

```
single-file mounts total                    : 9
  of those WRITABLE (rw)                    : 5
    -> onto claude-home (IN SCOPE)          : 1
    -> container-runtime files (out of scope): 4
```

```
VERDICT: CONFIRMED — /root/.claude.json is the ONLY writable single-file bind onto claude-home.
```

**Scoping paragraph.** The live enumeration counts 5 writable single-file mounts total, not 1,
because `/proc/self/mountinfo` also sees four writable single-file mounts that **podman itself**
injects into every container, independent of any launcher `-v` flag: `/etc/hosts`,
`/etc/resolv.conf`, `/etc/hostname`, and `/run/.containerenv`. `probe-03-mountinfo.out` lists them
explicitly:

```
Writable single-file mounts injected by the container runtime (NOT launcher `-v`,
no claude state, never written by a claude process — out of scope):
  - /etc/resolv.conf   [tmpfs]
  - /etc/hosts   [tmpfs]
  - /run/.containerenv   [tmpfs]
  - /etc/hostname   [tmpfs]
```

These four are **out of scope**: they are not launcher `-v` flags, hold no claude state, and are
never written by a claude process. The probe's first run returned NOT CONFIRMED *because* it
counted these four alongside `/root/.claude.json`; once scoped to claude-home, the verdict above is
CONFIRMED with exactly one offender. This is why "5 rw single-file mounts" and "only one" both
appear in the record and are not a contradiction — they answer different questions (Decision #9's
structural guard only needs to reach launcher-generated `-v` args onto claude-home).

The three read-only single-file binds under `/root/.claude/` — `statusline.pl`, `backpack.pl`,
`auto-declare.pl` — are harmless because they cannot be written, so cannot tear.

The live `/proc/self/mountinfo` enumeration and the static `-v` scan agree exactly: the same one
RW single-file bind (`/root/.claude.json`), the same set of RO single-file binds.

**Contrast block** — shared writable state that already rides the `/root/.claude` DIR bind as
ordinary files (atomic rename already works here), from `probe-03-mountinfo.out`:

```
  /root/.claude/.credentials.json                exists (594 bytes)
  /root/.claude/.claude.json                     exists (39231 bytes)
  /root/.claude/settings.json                    exists (1846 bytes)
  /root/.claude/plugins/installed_plugins.json   exists (2417 bytes)
  /root/.claude/.config.json                     absent
```

The `.config.json` **absence** is load-bearing — see §3, candidate A, point 2.

## §3 — Candidate mechanisms and the recommendation

> **Set `CLAUDE_CONFIG_DIR=/root/.claude` on the container and REMOVE the
> `${CLAUDE_DATA}/.claude.json:/root/.claude.json` single-file `-v`.**

This is the one recommendation. No candidate below is left "to be verified" — each is resolved.

### Candidate A — `CLAUDE_CONFIG_DIR` — CHOSEN

1. **Bundle resolvers**, quoted verbatim from the ledger's `2026-07-25T04:02Z` entry (extracted
   from the shipped `claude` CLI, version **2.1.219**, a bun-compiled ELF at
   `/root/.local/share/claude/versions/2.1.219`):

   ```
   cv=Vr(()=>{if(existsSync(join(fn(),".config.json")))return join(fn(),".config.json");let e=`.claude${XUn()}.json`;return join(process.env.CLAUDE_CONFIG_DIR||homedir(),e)})
   ```
   ```
   function XUn(){...switch(QIl()){case"local":return"-local-oauth";case"staging":return"-staging-oauth";case"prod":return""}}
   ```
   ```
   fn=Vr(()=>(Ekl()??join(homedir(),".claude")).normalize("NFC"),Ekl)
   function Ekl(){return process.env.CLAUDE_CONFIG_DIR}
   ```
   ```
   d = CLAUDE_CONFIG_DIR ?? join(homedir(),".claude") ... join(d,".credentials.json")
   join(CLAUDE_CONFIG_DIR ?? join(homedir(),".claude"),"projects")
   ```

   `cv` is the config-**file** resolver, `XUn()` is the OAuth-environment suffix function (on
   `prod` the basename is exactly `.claude.json`, no suffix), `fn`/`Ekl` is the config-**dir**
   resolver (`CLAUDE_CONFIG_DIR` if set, else `~/.claude`), and the last block shows the
   credentials and `projects` resolvers reusing the same `fn()`/`CLAUDE_CONFIG_DIR` base.
   **Method:** these were recovered with `grep -a` on the ELF. **Correction:** the scout's Q3
   verdict of `UNRESOLVED-BY-STATIC-ANALYSIS` was **wrong** — it ran `grep -o` without `-a` and
   misread "Binary file matches" as meaning the strings were unreadable. This correction belongs
   in the record; the scout report remains available to s02 as an input, not as ground truth on
   this point.

2. `cv`'s first branch checks `${CLAUDE_CONFIG_DIR}/.config.json` and, if it exists, prefers it
   over `.claude.json` — a precedence branch that would matter if a future CLI version wrote that
   file. §2's live evidence shows `/root/.claude/.config.json` is currently **absent**, so the
   live branch taken today is the `.claude${XUn()}.json` one (i.e., plain `.claude.json` on prod).
   **Watch item for s02:** if a future CLI writes `.config.json`, it still lands inside the same
   `/root/.claude` dir bind, so it remains rename-safe — only the filename assumption changes.

   **A related resolver-semantics hazard, latent today, worth guarding against.** The config-**file**
   resolver (`cv`, quoted above) uses `||` — `CLAUDE_CONFIG_DIR||homedir()` — so an *empty* string is
   falsy and silently falls back to `~`. The config-**dir** resolver (`fn`/`Ekl`, quoted above) uses
   `??` — `Ekl()??join(homedir(),".claude")` — so an empty string is *not* nullish and is used as-is,
   producing `join("",".credentials.json")` = the **relative** path `.credentials.json`, resolved
   against whatever directory the process happens to run from. The two resolvers therefore diverge
   only when `CLAUDE_CONFIG_DIR` is **present but empty**: the config file would silently fall back to
   `/root/.claude.json` (now unbound to any mount post-fix, lost on recreate) while credentials,
   `projects/`, and other `fn()`-keyed state would be written **cwd-relative** — e.g. into a project's
   git working tree. Today's fixed, non-empty literal value never triggers this: it is a
   **regression-guard requirement for how s02 emits the var, not a live bug.** s02 must (a) emit the
   `-e` value as an uninterpolated **literal string**, never a variable substitution that could
   evaluate empty; (b) assert the generated arg list contains **exactly one** `-e
   CLAUDE_CONFIG_DIR=/root/.claude` and no later duplicate declaration of the same key (podman takes
   the last `-e` for a repeated key); and (c) add a cheap in-container guard that fails loudly if
   `$CLAUDE_CONFIG_DIR` is ever unset or not exactly `/root/.claude`.

3. **Empirical confirmation**, from `probe-04-claude-config-dir.out`:

   ```
   === is the relocated global config file named exactly .claude.json? ===
     YES -> /tmp/ccd-probe/.claude.json (389 bytes)
     top-level keys:
       - firstStartTime
       - hasResetAutoModeOptInForDefaultOffer
       - machineID
       - migrationVersion
       - opusProMigrationComplete
       - seenNotifications
       - sonnet1m45MigrationComplete
       - userID
   ```

   `CLAUDE_CONFIG_DIR=/tmp/ccd-probe claude mcp list` created `/tmp/ccd-probe/.claude.json`
   (389 b) carrying real global keys, plus a `backups/.claude.json.backup.<epoch_ms>` the CLI
   writes itself (`/tmp/ccd-probe/backups/.claude.json.backup.1784951670769`, 50 b).

   **Accuracy requirement.** This does **not** prove the live config was untouched. The
   transcript's own control:

   ```
   === control: did the LIVE /root/.claude.json get touched? ===
     live sha256: 2450a9515e4df42fb3e4fab063d45d191e4cd7e72f9c1a6625c7d2fc52377e14
     (compare against cd7c02659e6f5b9dc8cef09ba4df0ef49d714df6faf00ba1cf68f1850bc1698e from probe-01)
   ```

   shows a live sha256 (`2450a951…`) that **differs** from probe-01's (`cd7c0265…`) — because the
   running fleet writes that file continuously, not because probe-04 touched it. That comparison
   is inconclusive on its own. The live-file safety claim rests on **probe-01 Case A alone**,
   whose before/after sha256 are identical within one probe instant (see §1). What probe-04
   actually proves, scoped correctly: with `CLAUDE_CONFIG_DIR` set, the CLI reads/writes the
   global config **at `$CLAUDE_CONFIG_DIR/.claude.json`**.

   **Analyzing, not just quoting, the `backups/` artefact probe-04 shows.** probe-04 shows the CLI
   writes `backups/.claude.json.backup.<epoch_ms>` (50 b) *inside* `$CLAUDE_CONFIG_DIR`, alongside
   the relocated config, when the var is **set**. No probe ran the same check with the var
   **unset**, so where this file lands *today* is not directly evidenced. Reasoned inference (not a
   demonstrated fact, using the same "`fn()` already defaults identically" logic §4 relies on for
   the no-op finding): if `backups/` is keyed off the same config-**dir** resolver as credentials and
   projects, then because that resolver already defaults to `/root/.claude` today, `backups/` would
   already sit at `/root/.claude/backups/` pre-fix too — not a new artefact at all. This doc cannot
   confirm that inference from the four transcripts alone (it would need a probe with the var
   deliberately unset). Recorded as a **watch item, not a settled claim**: s02 should confirm on
   first real use whether `backups/` is new post-fix, and either way should expect it to grow inside
   claude-home — unbounded in count, but a corruption-recovery artefact landing in claude-home
   (recoverable) is a net improvement over the same artefact landing in the container's ephemeral
   layer (lost on recreate).

4. **A's real costs** (all gated on `CLAUDE_CONFIG_DIR` being set; all from the same bundle
   extraction), each with a one-line sandbox impact:
   - `claude … service install` **exits 1** ("service install only supports the default config
     dir") — no impact; the sandbox never runs this.
   - background-daemon helpers `Ecf()` / `Acf()` short-circuit to false — no impact; no systemd
     in-container.
   - the secure-storage account key gains a `-<sha256 prefix>` suffix — no impact; no
     in-container keychain is used.
   - Codex / Gemini user-scope config detection changes — no impact; the sandbox doesn't run
     those tools' user-scope detection paths.
   - `sessionStore` warns when a subprocess's `CLAUDE_CONFIG_DIR` differs from its parent's — no
     impact in practice, because the CLI explicitly re-propagates the var to children, so the
     sandbox satisfies this by construction.

   **Judgement:** none of these five costs are used by the sandbox (no systemd, no
   in-container keychain), but they are real behavioural deltas of setting `CLAUDE_CONFIG_DIR`
   and belong on the record. Candidate A is **not** presented as cost-free.

### A residual concern the mechanism does not remove: the launcher, and the relocated lockfile

**The launcher itself is also a writer of this file, and stays non-atomic and un-locked.**
`ensure_claude_json_onboarded` (§5 row 5) writes via `_write_file`, which is a plain
`open('>:raw')` truncate-then-rewrite — non-atomic, unlocked, no fsync. It runs at manager setup,
pre-create, and at `enter_dashboard` (which includes bare-attach to an already-running container).
Post-fix, in-container `claude` writers become atomic (temp-file + `rename()`) and take Claude
Code's own cross-process `<config>.lock` before writing (re-reading under the lock, refusing the
write if the re-read lost auth state). The launcher does **neither**. So after the fix the launcher
is the **only remaining writer capable of reproducing the exact failure this spike exists to
eliminate**: an interrupted launcher write (Ctrl-C, host crash, `podman` teardown mid-write) can
leave the shared config 0-byte permanently, and because the launcher never takes the CLI's lock, it
can silently clobber a write a `claude` process is mid-merge on. This is why §5 row 5 is now a
**CHANGE**, not a VERIFY-ONLY: s02 must rewrite that write to a temp-file + `rename()` inside
`$CLAUDE_DATA`, taking a `mkdir`-based `$host_json.lock` (with staleness takeover) so it
interoperates with the CLI's own lock — sequenced **after** the container-shape check below (§4),
per the sequencing hazard there.

**A new shared artefact the relocation creates: the config lockfile moves too.** Claude Code takes
a cross-process lockfile at `<configpath>.lock` before writing (mtime-liveness based: if the file's
mtime advances unexpectedly between acquire and use, the lock reports itself compromised). Today
that lockfile is `/root/.claude.json.lock`, on the container's ephemeral overlay; post-fix it is
`/root/.claude/.claude.json.lock`, a new file on the 9p/drvfs host bind, shared across sessions and
surviving past container removal. This is a new shared-state hazard not previously named anywhere in
this doc: (a) a container killed mid-write can leave a stale lock artefact on the host (the lock
self-heals via mtime staleness takeover, so this degrades rather than deadlocks); (b) the lock's
freshness check depends on mtime updates being reliably observed on the host bind, and this project
has already hit a mtime-related 9p bug elsewhere (`t/01`'s `utimensat` probe exists for that reason)
— if mtime updates are lossy or coarse on this mount, ordinary writes could spuriously report the
lock compromised; (c) 9p round-trip latency could push lock acquisition past the CLI's own 100 ms
contention threshold, surfacing a user-visible "another Claude instance may be running" warning even
on ordinary single-session use. **s02 must add an in-container assertion inside the new concurrency
test (§5 row 13) that exercises this lock on the real bind:** `mkdir` of `<config>.lock` succeeds,
its mtime measurably advances under `utimes`, acquisition latency is reasonable, and a pre-planted
stale lock does not wedge a subsequent write beyond the staleness window. There is no environment
variable to relocate the lock independently of the config file, so this must be measured before s02
ships the change, not assumed afterward.

### Candidate B — symlink-into-dir-bind — EMPIRICALLY DISQUALIFIED

From `probe-01-rename.out`, Case D:

```
############ CASE D — rename() through a symlink into the dir bind ############
  (candidate mechanism: /root/.claude.json as a symlink -> a real file in the dir bind)
  link    : /root/.s01-symlink.json -> /root/.claude/.s01-symlink-target.json
  tgt pre : {"probe":"dirbind-target-v1"}
  syscall : rename(/root/.s01-symlink-src.json, /root/.s01-symlink.json)
  result  : SUCCESS
  link now: *** NO LONGER A SYMLINK — it is now a regular file ***
  tgt post: {"probe":"dirbind-target-v1"}
  at link : {"probe":"v2-written-through-the-symlink"}
  verdict : rename SUCCEEDED; payload landed in the EPHEMERAL container fs at the link path (symlink REPLACED — host never sees it)
```

The `rename()` onto the link path **succeeded but replaced the symlink with a regular file**; the
dir-bind target still held `dirbind-target-v1` while the payload landed at the link path in the
container's **ephemeral** filesystem. Conclusion: config writes through this scheme would silently
leave the host bind and **vanish on container recreate** — a worse failure mode than the one being
fixed, because it fails silently instead of loudly. General rule behind the result:
`rename(2)` does not follow a symlink at the destination, and nothing in the mechanism can make it.
This is a settled, empirical result, not an open question or a fallback candidate.

### Candidate C — whole-`$HOME` / HOME-relocation bind — REJECTED on blast radius

This is a **judgement**, not an experiment — candidate C was not probed. Binding a writable
directory at `$HOME` would put every other thing mounted under `/root` inside one writable bind
(credentials, plugins, skills, `.launcher`, git helpers, etc.), for no benefit over candidate A,
which is a two-line change (one `-e`, one removed `-v`). Rejected by reasoning; a reader should be
able to tell this conclusion is judgement, not a disproved-by-probe result the way B is.

### Attacked and survived — recorded so s02 does not re-litigate settled ground

Two vectors were independently attacked and both held (**judgement about the attack's findings,
not a new probe** — no new evidence file was produced, nothing here contradicts the four-transcript
discipline):

- **Credential blast radius.** Every path this doc already relies on as `fn()`-keyed
  (`.credentials.json`, `projects/`) was checked for orphaning or relocation risk under the fix;
  none was found — the default the var replaces is byte-identical to the value being set, so
  nothing moves and nothing is orphaned.
- **`.config.json` precedence.** The attack looked for an asymmetry between the pre-fix and
  post-fix probe and found none — confirming this doc's own reasoning in point 2 above: with the
  var unset, `fn()` already equals `/root/.claude`, so the `.config.json` existence check probes the
  identical path before and after the change. The residual risk (an in-container process planting
  `.config.json` to hijack the global config) is unchanged by this fix and pre-existing; it is
  already recorded as the watch item at point 2.

Both are negative results (no new risk found), which is itself worth keeping on the record: s02
does not need to re-investigate either vector.

## §4 — Migration shape → NO-OP, and the deviation from Decisions #6/#10

`/root/.claude.json` and `/root/.claude/.claude.json` are the **same host file**
(`claude-home/.claude.json`) seen through the single-file bind and the dir bind respectively.
From `probe-05-dualpath-identity.out`:

```
=== 2. stat both paths ===
  /root/.claude.json
    inode=9288674232328321 dev=43 size=39231 links=1 mode=777 mtime=1784952358
  /root/.claude/.claude.json
    inode=9288674232328321 dev=43 size=39231 links=1 mode=777 mtime=1784952358

=== 3. identity assertions ===
  inode match : YES  (9288674232328321 vs 9288674232328321)
  device match: YES  (43 vs 43)
```

```
=== 4. content identity (two reads, back to back) ===
  /root/.claude.json             sha256=fa1d755eaec8f295396a1c6fdb5dec78fa778f8b5d9427f7d790c0a9a8b00d01
  /root/.claude/.claude.json     sha256=fa1d755eaec8f295396a1c6fdb5dec78fa778f8b5d9427f7d790c0a9a8b00d01
  sha256 match: YES
```

Identical inode (`9288674232328321`), dev (`43`), size, mtime, and same-instant sha256. **Re-check
a reviewer can run:** `stat` both paths and compare inode+dev.

`/root/.claude/.claude.json` is **not itself a mountpoint** — confirmed both by
`probe-03-mountinfo.out` (§2's contrast block lists it as an ordinary file inside the dir bind, not
among the mount rows) and directly by `probe-05-dualpath-identity.out`:

```
=== 5. is the dir-bind path itself a mountpoint? (it must NOT be) ===
  NO — an ordinary file inside the dir bind, so probe-01 case B's atomic
       rename result applies to this exact path
```

So probe-01 **Case B** applies to it: atomic temp+`rename()` there works.

What the post-fix resolver computes, from `probe-05-dualpath-identity.out`:

```
=== 6. what the post-fix resolver will compute ===
  CLI global-config file = join(CLAUDE_CONFIG_DIR || homedir(), '.claude.json')
  with CLAUDE_CONFIG_DIR=/root/.claude  ->  /root/.claude/.claude.json
  which is:                                 /root/.claude/.claude.json
  backed by host file:                      claude-home/.claude.json
  which is ALSO what the launcher already writes as $CLAUDE_DATA/.claude.json
```

Because `fn()` evaluates to `/root/.claude` **both before and after** the change, nothing else
moves either — for `credentials` and `projects` this is **directly evidenced**: both resolvers are
quoted verbatim in §3 (`join(CLAUDE_CONFIG_DIR ?? join(homedir(),".claude"), …)`), so they keep
their current paths. `settings`, `teams`, and `todos` are **not** directly evidenced anywhere in the
four probe transcripts or the ledger's extracted snippets — probe-03's contrast block only confirms
that `settings.json` **exists** at `/root/.claude/settings.json` today, not how its path is
resolved, and `teams`/`todos` appear in no probe or ledger entry at all. It is a **reasoned
inference**, not a demonstrated fact, that they follow the same `fn()`-keyed pattern as
credentials/projects; this doc records that distinction rather than asserting all five with equal
confidence.

**Therefore: no copy, no timestamped backup, no file move, no onboarding-wizard risk.** The
one-time-migration precedent at `launcher.pl:544-604` is **not** reused.

`ensure_claude_json_onboarded`'s `my $host_json = "$CLAUDE_DATA/.claude.json";` (`launcher.pl:2028`)
is **already the correct post-fix path**.

### Scope of the no-op — the host FILE, not the container SHAPE

The NO-OP finding above is about the host **file** only — it survived every attack (the dual-path
identity above; a fresh sandbox create; a container rebuild; and both rollback directions, old-code
against new-home and new-code against old-home, each resolving to the same host file).

It is **NOT a no-op about the container shape.** `CLAUDE_CONFIG_DIR` is applied via `-e` at `podman
create` (§5 row 3); podman env is baked into a container at create time and is never retroactively
applied to a container that already exists. So **an already-created sandbox container keeps the old
single-file-bind shape — the `-v` bind at row 1, and no `CLAUDE_CONFIG_DIR` — until that container
is recreated.** Editing `launcher.pl` changes nothing about a container that is already running;
only a fresh `podman create` picks up the new args.

**What s02 must do about it.** Add a shape check that inspects an *existing* container (e.g.
`podman inspect`) for either (a) a mount whose destination is `/root/.claude.json`, or (b) a
missing/incorrect `CLAUDE_CONFIG_DIR=/root/.claude` in the container's env, and on a mismatch
**force a recreate** through the launcher's existing rebuild/recreate path rather than relying on
the declinable staleness prompt (whose default is to continue as-is, and which returns "continue"
on EOF in every non-interactive launch). Without a forced-recreate path, the regression suite —
which only ever builds fresh probe containers — will report green while the deployed fleet silently
keeps the old, bug-carrying shape indefinitely. See §5 row 22.

**Sequencing hazard — order the two changes.** Making the launcher's own config write atomic
(temp-file + `rename()`, required regardless — see the residual-writer note in §3) must **not** be
applied while an old-shape container is still attached. `rename()` over the host file replaces the
inode; a container still holding the old single-file bind keeps following the now-unlinked,
directory-less old inode. From that point the in-container `claude` reads and writes a ghost file
with no directory entry: every further mutation is invisible to the host and to any future
container, and it is destroyed the moment that container is removed — total, silent, unrecoverable
config loss for exactly the sandbox that declined the rebuild. **s02 must land the shape-check/
forced-recreate step (row 22) first**, and only make the launcher's write atomic (row 5) once no
old-shape container can still be attached to. Doing it in the other order — or in the same commit
without ordering the check first — reintroduces, for any sandbox that has not yet recreated, the
identical failure class this whole spike exists to eliminate.

**Atomicity requirement — not optional, not a footnote.** Row 1 (delete the `-v` single-file bind)
and row 3 (add `-e CLAUDE_CONFIG_DIR=/root/.claude`) **must land in the same commit and be asserted
by the same test.** Doing either alone is a regression:
- `-v` removed, `-e` **not** added: the config resolver falls back to `homedir()` = `/root/.claude.json`,
  which now has **no bind at all** — it lives in the container's ephemeral overlay, works all
  session, and is silently lost on every recreate. This is candidate B's disqualified failure mode
  (§3), reached by omission instead of by design.
- `-e` added, `-v` **not** removed: the single-file bind is still present, but
  `CLAUDE_CONFIG_DIR=/root/.claude` redirects the CLI to read/write `/root/.claude/.claude.json`
  instead (per the resolver already quoted in §3), leaving the old bind an inert, unused mount —
  exactly the shape Decision #9's structural guard (§5 row 11) is written to forbid.

**Other watch items for s02, briefly (found while attacking the mechanism; none change the
recommendation; see §5 rows 5, 9 for the concrete file-level instructions).** `ensure_claude_json_onboarded`
has no symlink/directory guard on `$host_json`, unlike its sibling `ensure_credentials_json_host_file`;
the in-container CLI itself follows symlinks at the config path by design, so a planted symlink
would post-fix silently write into the ephemeral layer. `heal_claude_json`'s reseed-on-unparseable
path returns the bare template on any unparseable read — a total wipe of the user's real config,
un-ironically also the launcher's own failure response to its own torn write, before that write is
fixed. And several new host-side artefacts appear inside claude-home for the first time post-fix:
the CLI's own atomic-write staging files `.tmp.<pid>.<hex>` (left behind on some error paths, by
design, so content can be recovered) and the relocated `.claude.json.lock` (above). None of these
are bugs — landing in claude-home (recoverable) rather than the container's ephemeral layer (lost)
is strictly better than today — but any claude-home enumeration/hash/sweep logic should tolerate
and/or reap stale `.tmp.*` and `.lock` entries rather than treating them as unexpected files.

---

> **DEVIATION from carried Decisions #6 and #10 — needs orchestrator/user confirmation.**

Decision #6 mandates: "Existing sandboxes (old single-file bind, config at
`claude-home/.claude.json`) must migrate to the new location on first post-fix launch with no loss
of config state, following the `.claude-data → claude-home` migration precedent." Decision #10
mandates the shape of that migration: **COPY** the existing `claude-home/.claude.json` to the new
location, then **rename the old file to a timestamped backup**
(`.claude.json.pre-relocation-bak-<ts>`).

The evidence above makes both **unnecessary and actively undesirable**:
- unnecessary, because the "new location" and the "old location" are the same host file — there
  is nothing to copy;
- actively undesirable, because performing the migration literally would (a) COPY the file onto
  itself (creating a spurious second read of a file that, per §1, is already safe to
  atomic-rename in place — at best a no-op, at worst a race with itself), and then (b) rename the
  **only** copy of the config to a `-bak` name, at the very path both the old resolver
  (`$CLAUDE_DATA/.claude.json`) and the new resolver (`$CLAUDE_CONFIG_DIR/.claude.json` = the same
  path) read. That would leave the sandbox with **no** `.claude.json` at all — the "migration"
  would itself be the outage.

This spike does **not** unilaterally drop Decisions #6/#10. It flags them for orchestrator/user
confirmation; **until confirmed, s02 treats the no-op (do nothing, verify the path) as the plan of
record.**

Decision #10's definition of "intact" — the new file parses as JSON; `hasCompletedOnboarding` /
`oauthAccount` / `userID` / `projects` are preserved; launch shows no onboarding wizard — is
**retained as an s02 post-change assertion**, even though no migration step runs to produce it:
s02 should assert this holds true of `/root/.claude/.claude.json` after the fix, as a regression
check, not as the output of a copy step.

> **DEVIATION from carried Decision #12 — needs orchestrator/user confirmation.**

Decision #12 mandates that s02's self-heal obligation "includes repointing `ClaudeConfig`/
`ensure_claude_json_onboarded` at the new path and verifying it." The evidence above shows there is
no new path to repoint to: `ensure_claude_json_onboarded`'s `$host_json = "$CLAUDE_DATA/.claude.json"`
(`launcher.pl:2028`) is already the correct post-fix path, and `ClaudeConfig.pm`'s `heal_claude_json`
(§5 row 9) constructs no paths at all — there is nothing in either file for a repoint to touch. This
doc therefore does not perform a repoint and instructs s02 not to either (§5 rows 5, 9). As with
#6/#10, this is flagged rather than silently applied: a reader checking this doc against Appendix
A's Decision #12 would otherwise see an unexplained contradiction with no signpost that it is
deliberate and evidence-based. Until confirmed, s02 treats "verify the path is correct, do not
repoint" (§5 rows 5, 9) as the plan of record for this clause, exactly as it does for #6/#10's
no-op migration above.

## §5 — Authoritative file/line list for s02

Line numbers are as verified on disk 2026-07-25. Standing caveat: **anchor by the named
sub/comment text, the file drifts** — do not trust a bare line number without re-reading the
named anchor first.

| # | File | Line(s) | Label | What |
|---|---|---|---|---|
| 1 | `plugins/sandbox/scripts/launcher.pl` | 2437 | **CHANGE** | Delete `'-v', "${CLAUDE_DATA}/.claude.json:/root/.claude.json",` — the writable single-file bind. **Must land in the same commit as row 3, asserted by the same test (§4's atomicity requirement)** — removing this alone without row 3 reproduces candidate B's disqualified failure mode. |
| 2 | `plugins/sandbox/scripts/launcher.pl` | 2421–2436 | **CHANGE** | The credentials-vs-`.claude.json` comment block. Lines 2432–2436 currently *explain why* `.claude.json` gets its own single-file bind; that rationale is now inverted and must be rewritten to state why it does **not**. Keep the `.credentials.json` history (2421–2431) — it is the precedent. |
| 3 | `plugins/sandbox/scripts/launcher.pl` | 2392 | **CHANGE** | Add `'-e', 'CLAUDE_CONFIG_DIR=/root/.claude',` to the `podman create` env block, next to the existing `'-e', 'CLAUDE_SANDBOX=1',`. **Must be an uninterpolated literal string** (§3's resolver-semantics note) — must land in the same commit as row 1, and s02 must assert the generated arg list contains exactly one such `-e` for this key with no later duplicate. |
| 4 | `plugins/sandbox/scripts/launcher.pl` | 2412 | **VERIFY-ONLY** | `'-v', "${CLAUDE_DATA}:/root/.claude"` — the dir bind that carries the file after the fix. Unchanged; must still be RW. |
| 5 | `plugins/sandbox/scripts/launcher.pl` | 2027–2037 | **CHANGE** | `ensure_claude_json_onboarded`. `$host_json = "$CLAUDE_DATA/.claude.json"` (2028) is already the correct path — no repoint needed (resolves Decision #12's clause for this function; see §4's dedicated deviation block). The `chmod 0600` (2036) stays. **Now CHANGE, not VERIFY-ONLY, for four reasons:** (1) its write (via `_write_file`) is non-atomic and unlocked — rewrite to temp-file + `rename()` inside `$CLAUDE_DATA` plus a `mkdir`-based `$host_json.lock`, sequenced **after** row 22's container-shape check (§4's sequencing hazard); (2) add the same symlink/directory guard `ensure_credentials_json_host_file` already has, in the same commit as removing the single-file bind; (3) back up unparseable bytes (e.g. to `$CLAUDE_DATA/.claude.json.corrupt-<ts>`) before letting `heal_claude_json` reseed the bare template; (4) rewrite the stale rationale comments per row 8. |
| 6 | `plugins/sandbox/scripts/launcher.pl` | 2041 | **VERIFY-ONLY** | `ensure_claude_json_host_file` alias. Still needed: the host file must exist and be valid before create so the in-container claude never sees a 0-byte config. Its *reason* changes (no longer "so the mount doesn't auto-create a directory") → see row 8. |
| 7 | `plugins/sandbox/scripts/launcher.pl` | 544–604 | **VERIFY-ONLY** | The `.claude-data → claude-home` one-time migration precedent. Cited by Decisions #6/#10 as the pattern to follow; per §4 it is **not** reused. Listed so s02 does not go looking for it. Do not modify. |
| 8 | `plugins/sandbox/scripts/launcher.pl` | 1976–1978, 2020–2022, 2039–2040 | **CHANGE (comments only)** | Three prose sites that assert `.claude.json` is a single-file bind: the Host-data-layout block (1976–1978), the `ensure_claude_json_onboarded` preamble (2020–2022, "so the single-file bind doesn't auto-create a directory"), and the alias comment (2039–2040, "guarantee the single-file-bind source exists"). Stale on merge; must be corrected in the same commit. |
| 9 | `plugins/sandbox/scripts/ClaudeConfig.pm` | 59–88 | **VERIFY-ONLY** | `heal_claude_json($cur,$tpl) -> $new_bytes \| undef`. Pure decision logic; **constructs no paths** (scout Q4, re-verified). Decision #4 keeps it as defence-in-depth. **Nothing to repoint** — resolves Decision #12's clause for this file specifically: there was never a path here to repoint (§4's dedicated deviation block; row 5 covers the `ensure_claude_json_onboarded` half of the same clause). The unparseable-bytes backup (row 5, reason 3) belongs in the caller, not here — this function stays pure. |
| 10 | `plugins/sandbox/scripts/ClaudeConfig.pm` | 2–3, 56–58 | **CHANGE (comments only)** | Header says the file "is bind-mounted to /root/.claude.json"; 56–58 justifies the `undef` return by "because .claude.json is a single-file bind mount". Both become false. |
| 11 | `plugins/sandbox/tests/t/02-launcher-bind-mount-shape.t` | 42–44 | **CHANGE** | The assertion at :43 must **invert**: `like(... single-file bind ...)` → an `unlike` that no `:/root/.claude.json` single-file bind is generated, mirroring the existing `.credentials.json` (:37–40) and `installed_plugins.json` (:62–65) "no single-file bind" pairs. Plus the Decision #9 **structural guard**: no writable single-file bind onto ANY claude-home file. Header comment at :4 also stale. **This guard must not be a source-text regex** — it is vacuous against interpolated mount-target strings, and it must run **after** `convert_v_to_mount` (which rewrites `-v HOST:CONTAINER` into `--mount type=bind,...,readonly`), or a guard shaped for `-v` text misses an equivalent `--mount` added directly. Assert instead over the **generated arg list** (or `podman inspect` the resulting container's `Mounts`), matching: container-destination `^/root/\.claude(\.json|/)` ∧ host-source-is-a-file ∧ not read-only. This same assertion, re-run against a **running** container, is what row 22's shape check needs. |
| 12 | `plugins/sandbox/tests/t/03-claude-json-file-bind.t` | 3, 29–30, 33–49 | **CHANGE** | Its whole premise is the single-file bind (:30 builds a probe container with `-v "$host_json:/root/.claude.json"`). Must be reshaped to the dir-bind + `CLAUDE_CONFIG_DIR` shape, asserting bidirectional RW **and** an EBUSY-free atomic temp+`rename()` at the new location — the s02 regression test for probe-01 Case A/B. |
| 13 | `plugins/sandbox/tests/t/<next-free-number>-shared-claude-json-concurrency.t` | — | **NEW** | Decisions #8/#11 concurrency proof, **in-container** (Decision #7): ≥2 writers doing claude's read-modify-write cycle against the shared config concurrently for ≥10 s **or** ≥500 total writes, with a concurrent reader sampling. PASS = zero 0-byte/unparseable observations **and** valid JSON at the end. `probe-02-replica.out` C4/C5 is the reference shape (C5 is the expected profile). **Numbering correction: `t/35` is NOT free** — `t/35-port-alloc.t` exists; `t/36`–`t/41` are also taken; the next free number is **`t/42`**. Decision #11's `t/35-…` was illustrative ("e.g."). **Residual the stated PASS criterion does not catch:** zero 0-byte/unparseable-plus-valid-JSON-at-the-end is **blind to lost updates** — a run where 499 of 500 writes are silently dropped still ends in valid, non-zero JSON and passes. Strengthen the oracle: each writer stamps its own marker key (`w<i>: <counter>`) and the final assertion checks every writer's last-written counter survived; include the launcher's `ensure_claude_json_onboarded` as one of the concurrent writers (§3's residual-writer note); make at least one writer the real `claude` binary (e.g. repeated `claude mcp add`/`remove` against a scratch `CLAUDE_CONFIG_DIR`) so the CLI's actual write-plus-lock path is exercised, not only a synthetic harness. Also fold in the lockfile assertions from §3's lockfile note (`mkdir`, mtime-advance, pre-planted-stale-lock recovery). |
| 14 | `plugins/sandbox/tests/t/18-multi-session-shared-state.t` | — | **VERIFY-ONLY** | Decision #11: stays unmodified. |
| 15 | `plugins/sandbox/tests/t/34-claude-json-seed.t` | — | **VERIFY-ONLY** | Unit-tests the pure `heal_claude_json` decision; path-agnostic. Expected to pass untouched — a canary that Decision #4's self-heal survived. |
| 16 | `plugins/sandbox/tests/t/06-launcher-ro-protection.t` | 19, 35, 51, 94 | **VERIFY** | Builds its **own** probe container including `-v "$host_data/.claude.json:/root/.claude.json"` (:51) and writes through it (:94). Not launcher-generated, so it may keep passing — but it re-creates the forbidden shape and its comments (:19, :35) assert it as current. s02 must run it, then decide: align to the new shape or annotate why the probe keeps the old one. |
| 17 | `plugins/sandbox/scripts/MountSpec.pm` | — | **NOT IN SCOPE** | Resolves the Decision #12 candidate superset: zero occurrences of `claude` in the file; mechanism A needs no mount-spec logic. |
| 18 | `plugins/sandbox/container/` (incl. `Containerfile` ENV block, lines 32–46) | — | **NOT IN SCOPE** | No container-side change needed: no entrypoint symlink (candidate B is dead), and the env var goes on `podman create` (row 3), **not** image-level `ENV`, so existing sandboxes need no image rebuild and the var stays per-create like `CLAUDE_SANDBOX=1`. The doc states this choice and its reason; s02 may revisit only with a recorded reason. |
| 19 | `plugins/sandbox/README.md` | 100, 150 | **CHANGE (docs)** | Both describe `/root/.claude.json` as an RW single-file bind in the mount-layout tables. |
| 20 | `plugins/sandbox/tests/README.md` | 22, 23 | **CHANGE (docs)** | The `t/02` and `t/03` row descriptions both name the single-file bind. |
| 21 | `plugins/sandbox/tests/manual/longrun-freeze-check.sh` | 19, 103 | **VERIFY** | Manual (non-`prove`) harness that hand-builds the single-file bind at :103. Not in the gated suite; s02 should align it or annotate it. Flagged so it does not silently rot. |

| 22 | `plugins/sandbox/scripts/launcher.pl` | new site; model on the existing forced-reap precedent | **NEW** | **Container-shape check, required before row 5 lands (§4's sequencing hazard).** Before create/attach, inspect the *existing* container (e.g. `podman inspect`) for either (a) a mount whose destination is `/root/.claude.json`, or (b) a missing/incorrect `CLAUDE_CONFIG_DIR=/root/.claude` in its env; on a mismatch, force a recreate (`podman rm -f` + create) through the existing rebuild path, bypassing the declinable staleness prompt (default "continue", and "continue" on EOF in non-interactive launches). Without this, an already-created sandbox keeps the old shape indefinitely and the fix never reaches it; applying row 5's atomic-write rewrite while such a container is still attached destroys its config via a `rename()`-replaces-the-inode race. Assert this pair (env present ∧ no `/root/.claude.json` mount) against a **running** container in `t/02` (row 11), not only against launcher source. |

Rows 1–3, 5, 11–13, and 22 are the **minimum** write set for s02 to satisfy its own done-criteria
(row 22's shape-check must land **before** row 5's atomicity rewrite — §4's sequencing hazard —
and rows 1/3 must land together, in the same commit and the same test — §4's atomicity
requirement); rows 8, 10, 19, 20 are the same-commit staleness sweep; rows 4, 6–7, 9, 14–16, 21 are
verification duties; rows 17–18 are explicit closures of open candidates.

---

**Status:** COMPLETE. §1 (EBUSY mechanism), §2 (inventory), and §3 (mechanism decision) are all
backed by in-container evidence pasted above from `probe-01-rename.out`, `probe-02-replica.out`,
`probe-03-mountinfo.out`, `probe-04-claude-config-dir.out`, and `probe-05-dualpath-identity.out`.
§4's migration-shape conclusion (NO-OP) carries one open item — the DEVIATION from carried
Decisions #6/#10 — flagged above for orchestrator/user confirmation. Package 02 is unblocked to
consume §5 once that confirmation lands. See the package ledger
(`packages/s01-config-safety-spike.md`) for the full attempt log.
