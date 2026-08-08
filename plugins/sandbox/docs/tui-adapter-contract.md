# TUI adapter contract

A **panel adapter** is one of the `sub _gather_*` subroutines in
`plugins/sandbox/scripts/launcher.pl` (~4,850 lines; it is a script, not a module). Each adapter is
called, by name, from the dashboard's render/state tick — the same loop that draws the frame. There
are seven of them today: `_gather_runs`, `_gather_backpack`, `_gather_oauth_expiry`,
`_gather_tokens`, `_gather_resources`, `_gather_orchestrator_events`, `_gather_spend`. This document
is the doctrine every one of them — and any adapter added later — must follow, plus the mechanics of
how that doctrine is enforced.

The worked example is `_gather_spend` (launcher.pl:4711, header comment at launcher.pl:4684-4710). Its
comment already states the rule this whole document generalises, almost word for word: *"THIS
DELIBERATELY MAKES NO NETWORK CALL … BpSpend::fetch reaches for bp-http.pl … a SUBPROCESS, i.e. a
fork, and this runs on the dashboard render tick … So the launcher is a READER only. The fleet polls
on its own cadence … and the TUI renders whatever it last wrote."* `_gather_spend` reads one
host-visible file that some other process (the butler run) has already written, and degrades to
absent — never a fabricated number — when that file does not exist yet. Every rule below is that
same idea, spelled out so it applies uniformly rather than living as one comment on one sub.

The counter-example, and the reason this document exists rather than being unnecessary, is
`_gather_resources` (launcher.pl:4571). Its own body is a single delegating call —
`return Resources::gather(_resources_probes(), { ... });` — with no spawn construct visible at that
call site. But the closure it reaches is not clean: `_resources_probes` (launcher.pl:4550-4563)
contains three backtick command substitutions —
`` scalar `$PODMAN stats --no-stream --format json 2>/dev/null` `` at launcher.pl:4552,
`` scalar `$PODMAN system df --format json 2>/dev/null` `` at launcher.pl:4553, and a third gated on
Windows — and it also calls `_powershell_json` (launcher.pl:4521-4529), which itself backtick-spawns
`powershell.exe` at launcher.pl:4528. That adapter runs podman and PowerShell probes on the render
tick today. It is a live, on-the-record violation of Rule 1 below, currently held under an explicit,
named, expiring waiver (see Waivers) rather than silently tolerated.

## Rule 1 — Never fork, spawn, or block on the render tick

An adapter's body — **and everything that body reaches by calling it, transitively, no matter how
many hops away** — must never fork, spawn a subprocess, or block waiting on one. Concretely: no
backticks, no `readpipe` (the named operator backticks are literal sugar for — it spawns exactly the
same subprocess, just spelled differently, so it counts identically), no `qx`, no `system(...)`, no
`exec(...)`, no `fork`, no `CORE::`-qualified form of any of those four (`CORE::system`,
`CORE::exec`, `CORE::fork`, `CORE::readpipe`), no piped `open` in any of its ordinary spellings —
`-|` / `|-`, 2-arg or 3-arg, a layered mode such as `-|:encoding(UTF-8)`, or a `qq{}`-delimited mode
string — no `open2`/`open3`/`IPC::Open2`/`IPC::Open3`. It does not matter whether the forbidden
construct sits in the adapter's own body or three helper calls deep: the render tick pays for
whatever the whole call graph does, not just what the top-level sub's source text happens to contain.
This is the whole reason the guard (see Enforcement) walks the transitive same-file call closure
instead of scanning each `sub _gather_*` body in isolation — a body-local scan of `_gather_resources`
finds nothing, because its own body is one delegating call; the fork risk lives in
`_resources_probes` and `_powershell_json`, reached only by following calls. **Moving a backtick out
of the adapter and into a same-file helper it calls does not satisfy this rule** — it moves the
violation, it does not remove it, and the guard is built specifically so that move does not go
undetected. The render-tick budget is roughly 0.2s every render cycle; a blocking subprocess call —
podman, PowerShell, curl, anything that forks — can stall that frame for the length of a timeout, and
on this platform forking has independently been observed to fail outright ("Can't fork, trying again
in 5 seconds"), which is exactly what s17 spent a whole package removing from `_gather_spend`'s path.
An adapter may run entirely inline on the render tick — reading a file, formatting a struct — as long
as none of that inline work forks, spawns, or blocks on something that does.

## Rule 2 — Read state something else maintains

A conforming adapter is a **reader**, never a producer. The data it renders was written by some other
process on its own cadence — a background sampler, a fleet poller, the butler run itself — and the
adapter's only job on the render tick is to read the most recent thing that process already wrote and
hand it to the panel. `_gather_spend` is the model: it locates the active run and reads one
host-visible snapshot file; it does not itself fetch anything over the network. `_gather_tokens` and
`_gather_backpack` follow the same shape — they read state a prior step maintains rather than
computing or fetching it fresh on every tick. The adapter must never become the thing that maintains
that state: if a value needs computing, fetching, or probing, that work belongs in a process with its
own cadence, and the adapter's role is limited to reading whatever that process last wrote to disk (or
to an in-process struct another component already built). An adapter that writes the very state it
then reads back on the next tick is not a reader and does not satisfy this rule, even if the write
itself is fast.

## Rule 3 — Declare a freshness model and surface staleness

Every adapter that reads state written by something else must be explicit about how old that state is
allowed to be, and the panel must show the user when the data has gone stale rather than silently
rendering an old snapshot as if it were current. That means: know the write cadence (or read a
timestamp/mtime alongside the payload), compare it against "now," and decide — visibly, in the
rendered panel — whether the data is fresh enough to trust as-is or old enough that the user should be
told. A panel that never distinguishes "written 200ms ago" from "written 20 minutes ago because the
writer died" is hiding a real failure behind a stale-but-plausible-looking number. This does not
require a single shared mechanism across all seven adapters — a fleet-cadence adapter and a
file-mtime adapter can each declare a freshness model appropriate to how their source is produced —
but it does require that a model exists and that its result (fresh vs. stale, and by how much,
whether measured by an explicit timestamp, an mtime, or an inferred age) is something the panel can
and does surface, not something the adapter silently discards after reading it.

## Rule 4 — Absence must be distinguishable from broken

An adapter faces at least four distinct situations reading state it did not write, and the panel must
render each one differently rather than collapsing them into the same blank cell or the same zero:
"no data yet" (the writer has not produced its first snapshot), "stale" (the writer produced
something once but has since gone quiet — see Rule 3), "not applicable" (this platform/mode does not
have this metric at all — see `_resources_probes`' Windows-only `cim_mem`/`cim_cpu`/`cim_disk`
keys, which are simply absent, not zero, off Windows), and "failed" (the read itself errored). None of
those four is a fabricated zero, and none of them should look identical to a healthy small number. The
worked example is `_gather_spend`'s own documented gap: until its writer persists a snapshot, the
adapter returns `undef` and the Spend panel is simply absent from the render — "never wrong, never a
fabricated zero," in the sub's own header comment. A reader that cannot distinguish "nothing has been
written" from "something broke while reading" from "this metric doesn't apply here" is not
conforming, even if it never actually forks — this rule is about honesty of the rendered state, not
just about Rule 1's subprocess concern.

## Rule 5 — Anything that takes over the render loop still owes the heartbeat

The container is kept alive by the host manager touching `/tmp/.launcher-alive`. `Dashboard::run`'s
loop is what does the touching, and `container/heartbeat.sh` reaps the container — cleanly, exit 0 —
once that sentinel is `HB` seconds stale (600 at time of writing; read the live value there, never a
number quoted in a comment). So **a modal screen, a confirm prompt, a picker, a progress view, or any
other flow that suspends the dashboard's tick is a liveness hazard**, not merely a rendering choice.
Suspend the loop for longer than `HB` and the operator returns to a container that shut itself down
with nothing to explain why.

A screen that takes over the loop must therefore keep the sentinel warm — take a `heartbeat` seam
like every other I/O boundary, default it to a no-op so the module stays pure and unit-testable, and
tick it once per iteration. Bounding the takeover with a tick cap is not a substitute: it only moves
the surprise from "the container died" to "my screen closed itself".

This rule exists because the same failure has now arrived from two unrelated directions. On
2026-08-08 a fleet was left running, the host entered connected standby for 5h40m, and the container
reaped itself two seconds after the resume — fixed in `heartbeat.sh` by detecting the suspend
(`suspend_detected`) and opening a post-wake grace window. Hours later, in the same session, package
`07`'s backpack modal reintroduced the identical outcome by suspending the loop with no time bound at
all. Neither author was careless; the contract simply was not written down anywhere a screen author
would look. It is now.

Note the interaction with Rule 1: a modal that shells out (package `07`'s `backpack.pl remove`) is
blocking the tick *and* not touching the sentinel for the duration of the subprocess. Bound the
subprocess, capture its output rather than streaming it into a raw-mode frame, and tick the heartbeat
either side of it.

## Enforcement

`plugins/sandbox/tests/t/62-tui-adapter-contract.t` is the automated guard for the **fork/spawn half**
of Rule 1. Rule 1's "or block" clause — a `sleep`, a blocking `waitpid`, a blocking `flock`, a socket
read with a long timeout — is **not** mechanically detected by anything in this guard (it is not a
decidable static property of source text the way a subprocess construct is), and remains doctrine
enforced by review, exactly like Rules 2-4. It discovers every `sub _gather_*` in `launcher.pl` by
scanning the source — there is no hardcoded enforcement list, so an eighth adapter is picked up
automatically — and for each one it computes the **transitive same-file call closure**: starting from
the adapter, it follows every call to another sub defined in the same file, and the sub after that, and
so on, with a cycle-safe `%seen` guard, until no new same-file sub is reachable. It then scans every
body in that closure for a forbidden spawn construct — backticks, `readpipe` (the named operator
backticks are literal sugar for, so it is caught by its own dedicated detector rather than relying on
the backtick pattern), `qx`, `system`, `exec`, `fork`, the `CORE::`-qualified form of any of those four
builtins (`CORE::system`/`CORE::exec`/`CORE::fork`/`CORE::readpipe`, which would otherwise bypass every
other detector's lookbehind), piped `open` (including a layered I/O-discipline mode such as
`-|:encoding(UTF-8)`, a `qq{}`-delimited mode string, and — flagged conservatively rather than
statically resolved, since it cannot be — a bare-scalar mode or command argument, i.e. `open my $fh,
$mode, ...`), or `open2`/`open3`/`IPC::Open2`/`IPC::Open3` — and fails naming the adapter, the
construct, the specific sub in the closure where the construct actually lives, and its
`launcher.pl:<line>` — not a bare count. This is why the guard finds `_gather_resources`'s violation
even though `_gather_resources`'s own body has no spawn construct in it: the closure reaches
`_resources_probes` and `_powershell_json`, where the backticks live.

**Heredoc bodies are blanked before analysis.** A `<<'TAG'`, `<<"TAG"`, `<<TAG`, or `<<~TAG` heredoc's
content is data, never Perl, so every line of it is blanked to empty before the brace-counting,
comment-stripping, and spawn-detection passes run. This exists because an unmatched column-0 `}`
inside heredoc content previously desynchronised brace-counting and truncated the extracted sub body
silently — everything after the truncation point, including any spawn construct and any call edge,
simply vanished from analysis with no failure of any kind. `launcher.pl:3493-3503` is the live,
in-repo example of the shape that triggers this: a bash-script heredoc inside `sub s03_run_launch_gate`
(which opens at `launcher.pl:3260`). That heredoc is not in any adapter's closure today, and its
content happens to contain no stray column-0 `}`, so it does not currently misbehave — but the same
shape, written inside a `_gather_*` closure, is exactly the kind of code a background sampler
(package `03`) plausibly writes.

**Known limit, stated honestly rather than hidden.** The call graph the guard walks is **same-file
only**. A spawn hidden behind a module boundary — for example if a helper were moved into
`Resources.pm` or `RunState.pm` and called as `Resources::gather(...)` or `RunState::something(...)`
— is **not detected**, because a qualified call is deliberately not treated as a call edge (it is what
keeps `Resources::gather(` from spuriously linking to an unrelated same-file `sub gather`). Likewise a
spawn reached only through a coderef stored in a variable and invoked as `$cb->()`, rather than by a
literal named call, is not detected unless the sub that defines that coderef's body is *also* reached
by an ordinary named call elsewhere in the closure. Doctrine — Rule 1 — still forbids both of those;
this guard's reach is a same-file, named-call approximation of Rule 1, not a complete proof of it. A
cross-file call graph was considered and deliberately declined for this package: it needs a
module-resolution layer that nothing in this package's done-criteria requires, and the one real,
current violation is already caught by the same-file closure.

## Waivers

The guard is allowed to keep the suite green in the face of a **known, already-scheduled-to-be-fixed**
violation, via an explicit `%WAIVED` hash that lives at the top of
`plugins/sandbox/tests/t/62-tui-adapter-contract.t` itself — not in this document, and not in a
separate data file, because this package's write set is exactly this doc and that test, and the
package that removes the one current entry (package `03-resources-reader-model`, "package `03`" for
short) has that test in its own write set too. A waiver is not a pardon and it is not silent: each
entry's value is a reason string that must name the package responsible for removing it, and the test
enforces that hygiene mechanically (the reason must be at least 20 characters and mention `03`).

**Every `%WAIVED` key must be named in this section, and the test enforces that mechanically.**
Widening the waiver list is meant to be a documented act, not a one-line edit to the test alone: adding
a new entry to `%WAIVED` without also naming that adapter here fails the suite. Today's sole waiver,
`_gather_resources`, is named directly in this paragraph and the next. This corroboration requirement
does not restrain package `03` emptying `%WAIVED` down to nothing — removing an entry needs no
corresponding doc edit, and zero entries is itself the success state.

The mechanics that keep a waiver from rotting into a permanent hole: as long as `_gather_resources`
is genuinely still violating Rule 1, its waiver entry keeps the suite green and the test still reports
every finding via `diag`, so the violation stays visible even while waived. The moment
`_gather_resources` produces zero spawn findings across its closure while its `%WAIVED` entry is still
present, the suite goes **red** as a stale waiver — but that red is a **prompt to verify, not a
certificate that the fix landed**. The guard's call graph is same-file only (see Enforcement), so zero
findings is **necessary but not sufficient** evidence the violation is actually gone: the exact same
refactor that makes the guard go quiet — moving `_resources_probes`'s and `_powershell_json`'s bodies
into `Resources.pm` and calling them as `Resources::probe_stats(...)` — produces zero findings while
the fork is still very much on the render tick, merely relocated behind a module boundary this
same-file guard cannot see. Deleting the `%WAIVED` entry is therefore valid only *together with*
package `03-resources-reader-model`'s own done-criteria evidence, specifically its criterion 1 (the
sampler writes a snapshot; `_gather_resources` only reads, and performs no spawn of any kind) and
criterion 4 (probe starvation proven off the render tick, by that package's own slow-probe test) — not
on this test's silence alone. Deleting a waiver for an adapter that has not met that standard is the
mirror failure: a real, undisguised violation now going unwaived. The test asserts nothing about
`%WAIVED`'s size or emptiness, so package `03` emptying it entirely, leaving zero entries, is itself
the success state and leaves the suite green.
