# Terminal minimize investigation

Spike package `s18-terminal-minimize-spike` (blueprint `sandbox-butler-overhaul`). Investigates an
operator report that their terminal window minimizes to the taskbar during a sandbox launch, with
no known trigger. This document renders the completed investigation
(`reports/s18-terminal-minimize-spike/scout-coordinator.md`) into the structure required by
`s18-terminal-minimize-spike-spec.md` §2.1–2.8. No new investigation was performed to produce this
document; every finding, line number, and count below is carried from that report.

## Reproduction status

Status: NOT-REPRODUCED
Reason: the symptom is structurally impossible to reproduce from this container.

The investigation ran inside the sandbox container, which has no Windows host, no GUI, and no
`podman` binary on `PATH`, and `$WINDOWS_FAMILY` evaluates false here. Every Windows-only code path
implicated by the candidates below — `_powershell_json` (`launcher.pl:4045-4052`), the keep-awake
spawn (`launcher.pl:3857-3883`), and `reset_terminal`'s escape-sequence emission — is therefore
inert in this environment: it cannot be executed, let alone observed to minimize a window. This is
a structural limit of the container, not a gap in effort; see the scout report's Limits section
(items 1–4), all four of which reduce to "needs a real Windows host / operator observation".

## Candidate verdicts

### Candidate 1 — keep-awake spawn and lifecycle

Verdict (content): EXCLUDED-BY-EVIDENCE
Verdict (spawn/lifecycle): UNVERIFIED-HYPOTHESIS

**Content, excluded.** `keep-awake.ps1` was read in full (60 lines, confirmed via `grep -c ''`).
Its entire Win32 surface is
one P/Invoke — `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`
(`keep-awake.ps1:37-47`) — followed by `while ($true) { Start-Sleep -Seconds 3600 }` (`:56`). There
is no `ShowWindow`, `SetForegroundWindow`, `SendKeys`, WScript.Shell call, or WinForms/WPF assembly
load anywhere in the file. The script cannot directly manipulate any window. This is excluded by
direct code evidence, not by assumption.

**Spawn/lifecycle, not excluded, but unverified.** `_keepawake_start` (`launcher.pl:3857-3883`)
fork+execs at `:3877-3878`:

```perl
exec('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
     '-WindowStyle', 'Hidden', '-File', $win_ps1, '-PidFile', $win_pid)
```

`-WindowStyle Hidden` is the only `-WindowStyle` usage anywhere in the tree (`grep -rn WindowStyle
plugins/sandbox/scripts/` returns exactly `launcher.pl:3878`). What is documented is that
`-WindowStyle Hidden` is unreliable at actually hiding anything — the console is widely reported to
still blink/flash before the style takes effect, which is why the standard workaround is a
P/Invoke of `ShowWindow(GetConsoleWindow(), SW_HIDE)` from inside the script. A transient console
flash is a documented behaviour of this flag.

What is **not** verified — and is not asserted as fact — is the stronger claim that when the child
inherits the parent's console, `-WindowStyle Hidden` resolves `GetConsoleWindow()` to the shared
window and hides the operator's own terminal. This was the report's first-draft claim, and it was
explicitly downgraded after the investigator found no authoritative source confirming that
`-WindowStyle` reaches an inherited parent console; the one closely-related report found describes
the opposite direction (windows spawned from a hidden `powershell.exe` appearing *behind* other
windows, because their parent is non-visible). That downgraded claim is carried here, deliberately,
as `UNVERIFIED-HYPOTHESIS` rather than upgraded back to confirmed or excluded.

There is also a discriminator against this candidate fully explaining the symptom: `SW_HIDE` makes
a window *vanish* (no taskbar button). The operator reports minimizing **to the taskbar**, which is
`SW_MINIMIZE`. `-WindowStyle Minimized` would produce that; `Hidden` should not. This is a real but
not decisive objection (the operator's phrasing may be loose), which is why the spawn/lifecycle
half is `UNVERIFIED-HYPOTHESIS` rather than excluded outright: whether it fires at all also depends
on console topology (conhost / ConPTY / mintty), which cannot be determined in-container (Limits
item 1, item 3).

Sub-finding B2 (spurious re-spawn) bears on how *often* this spawn — and its `-WindowStyle Hidden`
flag — fires, and is covered under Candidate 4 and `## Follow-on packages` below, since its effect
is on the wake-lock lifecycle that Candidate 4 depends on.

### Candidate 2 — native process spawn / console flash

Verdict: NOT-EXCLUDED

A census of periodic Windows-native spawns was taken (report Finding D):

- `_powershell_json` (`launcher.pl:4045-4052`) — `` powershell.exe -NoProfile -NonInteractive -Command "$cmd" 2>/dev/null ``,
  with **no window-suppression flag**. Driven by three probes (`cim_mem`, `cim_cpu`, `cim_disk`,
  `_ps_commands` at `launcher.pl:4016+`, wired at `:4083-4085`), so **3 `powershell.exe` spawns per
  Resources sample round**, gated by `Resources::should_sample` at `$SAMPLE_INTERVAL` = **23 s**
  (`Resources.pm:27`, `:322`), Windows-only (`return undef unless $WINDOWS_FAMILY`). By raw
  frequency this is the biggest offender (3 spawns / 23 s, roughly 470/hour).
- `` `$PODMAN …inspect` `` backticks — **eleven** call sites, not the six that earlier notes in this
  investigation stated (that six-site figure was independently re-checked and found stale — it
  resolved to `sub _tx`, `sub _write_file`, a bare `};`, a comment, an `if` condition and a hash
  literal, none of which are `podman inspect` calls). The verified eleven are `launcher.pl:797`,
  `:1090`, `:1137`, `:1385`, `:1419`, `:1443`, `:1526`, `:1980` (`podman machine inspect`), `:2497`,
  `:3374`, `:3812`. Of these, `:3374` is the one that matters most for a *recurring* symptom: it
  sits inside the dashboard's `gather` closure, throttled to fire at most once per ~10 s
  (`launcher.pl:3369-3374`) — the same cadence as the busy-lease probe (`:3385`).
- `wsl -d $machine -- sh -c ...` (`launcher.pl:1983`), `podman machine inspect` (`:1980`).
- `powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process ...)"` (`:3911`, in
  `_keepawake_reap_orphan`) and `taskkill.exe /PID <pid> /F /T` (`:3914`) — no window flag, but
  fires once per dashboard entry, not periodically.

(This census is not, and does not claim to be, a "full" enumeration of every Windows-native spawn in
the tree: `_spawn_session` (`launcher.pl:4187`, wired at `:3474` as `spawn => \&_spawn_session`) also
spawns `powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SANDBOX_PS1 --session $PROJECT_PATH`
with no `-WindowStyle` either, but see the dedicated `wt.exe` sub-finding immediately below: it is
excluded from this census, and from this candidate's periodic mechanism, on operator-verified
grounds, not merely because it is out of scope by construction.)

**Sub-finding: `wt.exe -w new` (new operator evidence).**

Verdict (wt.exe / spontaneous minimize): EXCLUDED-BY-EVIDENCE
Verdict (wt.exe / window elsewhere stealing focus): UNTESTED

`_spawn_session` is the dashboard's launch-claude hotkey (`launcher.pl:4177`: *"`_spawn_session` —
the dashboard's launch-claude hotkey: open a NEW Windows…"*, wired at `:3474`). It calls
`Dashboard::spawn_argv('wt', ...)` (`Dashboard.pm:1829`: `return ['wt.exe', '-w', 'new', @cmd] if
$mode eq 'wt';`), executed via `system(@$argv)` at `launcher.pl:4214`. This is real and
log-evidenced — `"mode":"wt"` appears in the `launch_session` event across 8 of the logged launches
— but it is **hotkey-only, not periodic**: it fires exclusively on the `[c]` keypress via `spawn =>
\&_spawn_session`, never on a timer, so it cannot by itself explain a *spontaneous* minimize (one
with no action on the operator's part).

Two independent grounds exclude it as that cause:

1. **Operator testimony.** Asked directly whether a second window appears on top when the terminal
   goes away, the operator was explicit: *"No window is appearing on top of it."*
2. **The mechanism requires a keypress.** When `[c]` fires, the operator is deliberately opening a
   window and would plainly see it — the opposite of "no known trigger, nothing visibly in front
   afterwards."

This is a verdict, not a hedge — but it is not proven harmless in every respect, so one residual
sub-case is left explicitly `UNTESTED`: a transient window appearing **elsewhere** (off-screen,
behind another monitor, or briefly in the foreground before losing focus) could still steal focus
and trigger some other minimize path without itself appearing "on top of" the terminal — the
operator was asked only about a window on top, not about one appearing elsewhere, and explicitly
said they could not speak to that case.

Every one of these spawns lacks `-WindowStyle`. The original draft of this section treated that
absence as decisive on its own — reasoning that "a console child inheriting an existing console does
not normally create or flash a visible window of its own" and therefore none of this census could
affect window state. That premise was uncited, and on inspection this document's own evidence cuts
against it rather than supporting it: `launcher.pl:3846` states plainly that "the host perl is
Git-for-Windows (cygwin) perl with no Win32::API", and the file is saturated with
Cygwin/MSYS2-specific workarounds for exactly this boundary (`MSYS2_ARG_CONV_EXCL`, `:122`, `:3876`,
`:3910`, `:4035`). A Cygwin/MSYS2 process spawning a native, non-Cygwin Win32 console executable —
every spawn in this census is one — does not straightforwardly "inherit" a native console the way a
plain Win32 parent/child pair does, because the Cygwin/MSYS pty layer is not itself a native Win32
console; this is the exact boundary `winpty` exists to paper over for interactive Cygwin/MSYS
console-app spawning. That means Windows allocating a **new** console for the child — independent of
any `-WindowStyle` flag, because none of these call sites pass one — is a live possibility for this
runtime, not something the absence-of-flag observation rules out.

To be precise about what is and is not being claimed here: this document does **not** now assert
that a console is confirmed to flash, only that the reasoning previously used to exclude it does not
hold, so the honest verdict is `NOT-EXCLUDED`, not a new confirmation. Whether an allocated console
is ever actually **visible** (as opposed to allocated-and-immediately-obscured, or never rendered at
all under the operator's actual terminal host) is unverified from this container and depends on
console topology — classic conhost, ConPTY-backed Windows Terminal, or Git Bash's mintty (Limits item
1) — each of which sits in a different relationship to a natively-spawned child's console. If the
operator runs Windows Terminal over ConPTY specifically, the topology differs again from the
mintty/winpty case the Cygwin literature describes, so this candidate's fate is genuinely undecided
pending that operator input, not merely awaiting confirmation of a foregone conclusion.

This is now the **strongest surviving lead** (superseding Finding E — see `## Conclusion`), for two
reasons beyond raw frequency. First, `_powershell_json` alone fires roughly 3 spawns / 23 s, or
**~470 spawns/hour**, versus Finding E's handful of multi-hour gaps (three gaps across four
multi-hour logs) — a large margin even before the wt.exe exclusion above removes the one other
candidate that could have competed with it on a "one-shot, hotkey-driven" basis. Second,
`s17-statusline-and-output-hygiene`'s **verified fork diagnosis is directly relevant**: that package
independently confirms perl's `Can't fork, trying again in 5 seconds` retry message actually appears
in captured launcher output, and a `` ` ``-backtick expression (Perl's own mechanism for these
`$PODMAN inspect` calls) forks internally to run its child, so a failing/retrying fork at exactly
this cadence is a plausible source of repeated, transient console activity — the same ~10 s cadence
as the `:3374` gather-tick site identified above. A console flash that steals focus and leaves
nothing visibly in front afterwards, with no action on the operator's part, fits everything the
operator reports. If Cygwin-spawn console allocation is visible on the operator's actual setup, this
candidate fits "recurring, no known trigger" markedly better than Finding E does, on frequency and
on this cross-reference to `s17` alike — see `## Conclusion` below.

(Separately, `.ccpraxis-local-data/claude-home/.launcher/keepawake.pid` exists on disk right now —
a helper recorded its Windows PID and the file outlived it, consistent with a launcher exit that
skipped the normal `_keepawake_stop` unlink path at `launcher.pl:3895`. This is a housekeeping
artifact, not evidence of window manipulation one way or the other, and does not change this
verdict.)

### Candidate 3 — window-manipulation escape sequences

Verdict: NOT-EXCLUDED

This is the sharpened, code-grounded form of candidate 3, built from report **Finding A** and
**Finding C**.

**Finding A.** `launcher.pl` speaks the `CSI <Ps> t` (XTWINOPS) escape family, whose member `CSI 2 t`
is literally "iconify (minimize) the window". Two sites emit members of this family:

| site | literal | meaning |
|---|---|---|
| `launcher.pl:3306` | `\e[22;0t` | XTPUSHTITLE — push icon+window title onto the terminal's title stack |
| `launcher.pl:3322` | `\e[23;0t` | XTPOPTITLE — restore the pushed title |

Both sit inside `Dashboard::run`'s `enter_raw` / `leave_raw` seams. An exhaustive census of every
escape sequence emitted by `launcher.pl` + `Dashboard.pm` found these are the **only**
window-manipulation (`t`-final) sequences anywhere in the codebase; everything else is SGR colour,
erase, cursor visibility, alt-screen (`?1049`), synchronised-output (`?2026`), or LNM (`\e[20h`,
benign line-feed mode, unrelated to windows). `\e[22;0t` is correct XTPUSHTITLE usage, not a
mis-encoded `CSI 2 t` — but it is **one lost or mangled `2` away** from `\e[2;0t`, which a CSI
parser dispatching on the first parameter would read as iconify.

Two facts bound how much this can explain: `enter_raw` fires once per dashboard run
(`Dashboard.pm:2906`) and `leave_raw` once (`:3173`), plus on the INT/TERM handlers
(`Dashboard.pm:2963-2964`). So these bytes hit the terminal on dashboard **entry and exit only**,
never on a cadence. A one-shot minimize at entry is consistent with this; a *recurring* minimize
during a run is not, absent corruption of the byte stream.

Sub-finding A2 (title-stack push/pop imbalance, `launcher.pl:3301`/`:3320`) is a real, separate
defect in this same code path — see `## Follow-on packages` — but it does not itself change this
verdict; it is cited here because it lives in the same seam as Finding A.

**Finding C — the corruption channel that would make Finding A recurrable.** `launcher.pl` never
sets `$| = 1` on its own STDOUT (verified: no `$| = 1`, `STDOUT->autoflush`, or `select(STDOUT)` at
file or dashboard scope; the only `local $| = 1` is inside `reset_terminal`), so STDOUT to a tty is
line-buffered and none of `\e[22;0t`, `\e[?1049h\e[?25l`, or the OSC title at `:3306-3308` contains
a newline — they can sit in the buffer until something else flushes it, and a flush boundary can
land inside the escape sequence. Meanwhile there are **97** STDERR write sites in `launcher.pl`
(96 `print STDERR` + 1 `printf STDERR`; a prior count of 104 was wrong), and STDERR is unbuffered;
`s17-statusline-and-output-hygiene` exists precisely because STDERR bytes already land inside the
render stream on this exact channel — a known, already-ticketed defect, not a hypothetical.

This channel, however, cannot deliver the mutation Finding A needs, and the mechanism as previously
stated here is wrong. Finding A needs `\e[22;0t` to become `\e[2;0t` — a **byte deletion**. Neither
half of this channel deletes bytes: a line-buffer flush boundary *splits* the stream (a CSI parser
is a state machine and reassembles across `write()` boundaries; both halves still arrive, in order),
and interleaved unbuffered STDERR *inserts* bytes rather than removing any — per ECMA-48, an
unexpected byte inside a parameter string **aborts** the CSI sequence back to ground, so
interleaving yields "nothing happens," not iconify. There is one narrower path that does reach
iconify: a flush boundary that falls **exactly between the two `2`s** of `22;0`, *and* whose
injected bytes begin with a CSI-terminating `t` (so the tail reads `\e[2t`). Both conditions holding
together are far less likely than "one lost `2`" implies, so this **weakens** Candidate 3 rather
than strengthening it — Finding C was its only route to an actual iconify, since the emitted bytes
themselves are correct XTPUSHTITLE, not a mis-encoding. What survives is narrower: this could not be
demonstrated in-container (no Windows terminal to feed it to) and is not claimed to have happened;
what remains open is the operator's terminal's own XTWINOPS implementation (mintty, ConPTY and
conhost each implement a different subset of `CSI <Ps> t`, and a terminal that mis-parses a
multi-digit `Ps` is a live, separate possibility from any byte-corruption channel).

Net: this candidate stays `NOT-EXCLUDED`, but on the honest ground that the operator's terminal's
XTWINOPS implementation is unknown — not on the ground of a byte channel that, on inspection,
cannot delete bytes. It is bounded by two open questions that can only be answered by the operator
(Limits items 1 and 2 — console topology, and whether the operator's terminal implements `CSI 2 t`
at all) — see `## Operator requests` below.

### Candidate 4 — external Windows mechanism

Verdict: NOT-EXCLUDED

Built from **Finding E**, and reframes "external Windows mechanism" from "not our bug" to "an
external mechanism our own bug triggers". This candidate remains genuinely `NOT-EXCLUDED`, but it
is **no longer the leading candidate** — see Candidate 2 above and `## Conclusion` below — and
several of the arguments previously made for it here did not survive scrutiny; this section states
plainly what is and is not still standing.

What the operator's report (R-01, `packages/s18-terminal-minimize-spike.md:24-26`) actually says,
quoted in full: *"while the sandbox is running, the terminal window itself minimizes to the taskbar
on its own. It is not a TUI layout change and not a fall-back to the plain heartbeat loop … Host is
Windows."* That is all R-01 states. It does **not** say the minimize is recurring, and it does not
say the timing is irregular — those were properties this document previously read into the report
rather than found in it, and they are marked below as unconfirmed rather than given.

`keep-awake.ps1` asserts `ES_DISPLAY_REQUIRED` (`keep-awake.ps1:47`) — it holds the **display**
awake, not just the system. Every interval in which the helper process is dead is an interval in
which Windows is free to power the display off. This premise is solid and code-read. Measured
directly from `keepawake_stopped` → next `keepawake_started` timestamps across all 22 logged
launches (`.ccpraxis-local-data/claude-home/sandbox-logs{,-from-workcopy}/`, `LaunchLog.pm`
JSON-lines, 2026-07-24T21:25Z → 2026-07-28T22:23Z), together with each gap's **preceding stop's**
`busy_age`:

```
launch-20260728T222227Z:  22:57:09Z -> 23:20:36Z = 1407 s (23.4 min)   busy_age=601  <-- display can sleep
launch-20260728T222227Z:  23:31:39Z -> 23:31:51Z =   12 s ( 0.2 min)   busy_age=null
launch-20260725T031526Z:  03:19:31Z -> 03:32:42Z =  791 s (13.2 min)   busy_age=602  <-- display can sleep
launch-20260725T031526Z:  04:21:51Z -> 04:25:31Z =  220 s ( 3.7 min)   busy_age=null
launch-20260725T135455Z:  14:29:28Z -> 14:29:32Z =    4 s ( 0.1 min)   busy_age=null
launch-20260725T135455Z:  14:43:14Z -> 14:59:21Z =  967 s (16.1 min)   busy_age=602  <-- display can sleep
launch-20260725T135455Z:  20:43:51Z -> 20:43:54Z =    3 s ( 0.1 min)   busy_age=null
```

**This table cuts against a claim this document previously made, and the claim is retracted.** All
three of the display-sleep-capable gaps (23.4, 13.2, 16.1 min) follow a stop whose preceding
`busy_age` is **601 or 602 s** — a lease genuinely older than `$BUSY_STALE` = 600 s
(`launcher.pl:3288-3289`, `:3578-3579`), i.e. the **designed** release this codebase already
documents as arguably-correct-by-design. Every `busy_age=null` gap (the ones previously attributed
to defect B2, a transient probe failure) is only 3, 4, 12 or 220 s — one to two orders of magnitude
too short to reach any plausible display timeout. **B2 contributes zero of the three windows this
candidate rests on.** Do not read the follow-on fix for B2 (below) as a mitigation for Finding E —
it corrects a real but separate ambiguity in the busy-lease probe, on its own merits, and would
prevent none of these three gaps. If the gaps are ever to be shortened, the lever is `$BUSY_STALE`
itself or the orchestrator's lease-refresh cadence, neither of which this document proposes
touching.

Separately, `busy_age=null` is downgraded from "spurious" to unresolved: `KeepAwake.pm:24-27`
documents `undef` as meaning "the lease is absent / unreadable", and the most parsimonious reading
of a `stat` failure on `/tmp/.butler-busy` is that **the file does not exist because no butler run
is active** — which makes those stops *correct*, not spurious. The logs cannot distinguish
lease-absent from a transient `podman exec` failure from a genuinely-gone container; all three
collapse to the same `undef`. (A previous argument here — that restart ages of 4 s/3 s/5 s "rule
out a genuine staleness" — is withdrawn: it is circular, since the helper only ever restarts once
`should_stay_awake` returns 1, which is definitionally soon after any refresh, genuinely-stale or
not; the three restarts that actually followed the genuinely-stale 601/602 s stops read 3 s, 9 s and
1 s, indistinguishable from the null-stop restarts.)

**The gap census itself was also incomplete, and the corrected picture undercuts the candidate
further.** The method above (`keepawake_stopped` → **next** `keepawake_started`) silently drops any
stop that is never followed by a start — exactly the intervals that run to end-of-log, which are
the *longest* ones:

```
launch-20260725T031526Z:  04:37:10Z -> end of log             = 9 h 17 m
launch-20260725T135455Z:  23:37:06Z -> end of log             = 2 h 25 m
launch-20260725T020839Z:  02:57:26Z -> end of log             =     5 m
launch-20260728T114234Z:  whole run, zero keepawake events    = 2 h 32 m (100%)
```

The launcher heartbeated normally throughout all of these (the system did not sleep), but they are
real launcher-alive time with **no wake lock held** — the same condition Finding E's premise names.
Aggregated across the four completed multi-hour logs: **54,284 s absent out of 94,300 s alive =
57.6%**. That reframes the headline "settling experiment" this document previously proposed —
checking whether an observed minimize timestamp falls inside one of the measured gaps — as having
roughly a **coin-flip hit rate by chance alone**, not something that would settle anything. A test
that actually discriminates would instead require the minimize to fall within a *bounded* interval
(e.g. 2 minutes) of a `keepawake_started` event that *ends* a gap — the moment a slept display would
actually wake — and evaluate the (much lower) base rate for that narrower window.

Event totals across the same 22 logs: `keepawake_started` **11**, `keepawake_stopped` **10**,
`keepawake` (action) **21**, `heartbeat` **1214** (at time of counting — the log set is still being
appended to), `container_gone` **227**, `signal` **4**, `keepawake_start_failed` **0**. Up to four
start/stop cycles occur within a single launch, e.g. `launch-20260725T135455Z-1335887.log`:

```
2026-07-25T13:58:08Z keepawake_started pid=1336234   action=start busy_age=5
2026-07-25T14:29:28Z keepawake_stopped pid=1336234   action=stop  busy_age=null
2026-07-25T14:29:32Z keepawake_started pid=1336903   action=start busy_age=4     <-- 4s later
```

That `container_gone` appears 227 times in the same log set (owned by `s17`'s fork-frequency
diagnosis) independently corroborates that the busy-lease probe does fail transiently — but,
per the table above, none of the three long display-sleep-capable gaps trace to one of those
failures; they trace to the designed 600 s release. See sub-finding B2 under
`## Follow-on packages` for the probe-ambiguity fix on its own merits.

**Verdict rationale:** not excluded — nothing found rules Finding E out, and its premise
(`ES_DISPLAY_REQUIRED` held only while the helper lives) is solid — but it rests on inference from
measured gap durations plus an unmeasured assumption about the display's actual timeout (see
`## Operator requests` item on `powercfg`), not a direct demonstration that a real minimize happened
inside one of these windows. It is **not** the leading candidate on current evidence; Candidate 2
(see above and `## Conclusion`) fits better on frequency, on the wt.exe exclusion, and on the
cross-reference to `s17`'s fork diagnosis. What would help settle Finding E specifically: the
per-host `powercfg` display-timeout value, whether the operator was away from the machine for the
requisite interval, and — if pursued at all — a bounded-interval correlation test rather than the
near-coin-flip one this document previously proposed.

## Conclusion

Cause identified: NO

Narrowed to: **Candidate 2 (native process spawn / console flash under Cygwin/MSYS2 — Finding D,
`NOT-EXCLUDED`) is now the strongest surviving lead** — its ~470 spawns/hour dwarfs Candidate 4's
handful of multi-hour gaps, the one competing one-shot mechanism (`wt.exe -w new`) is now excluded
as the cause of a *spontaneous* minimize on operator testimony and its hotkey-only wiring (see
Candidate 2's wt.exe sub-finding), and `s17`'s verified fork-retry diagnosis lands on the same ~10 s
cadence as the `:3374` gather-tick site, giving this candidate a concrete recurring mechanism Finding
E lacks. Candidate 3 (window-manipulation escape sequences — Findings A/C, `launcher.pl:3306`/
`:3322`, `NOT-EXCLUDED`) survives on the honest ground that the operator's terminal's XTWINOPS
implementation is unknown, not on the byte-corruption mechanism this document previously proposed
(that mechanism cannot delete bytes and is withdrawn). Candidate 4 (external Windows mechanism
triggered by our own wake-lock gaps — Finding E, `NOT-EXCLUDED`) is **no longer the leading
candidate**: its causal link to defect B2 is severed (all three long gaps follow the *designed*
`$BUSY_STALE` release, not a probe failure), two of the three properties it was credited with
(recurrence, irregular timing) are not in the operator's report at all, and the fuller gap census
(57.6% of launcher-alive time is wake-lock-absent) makes its proposed settling experiment a
near-coin-flip. Candidate 1 (content) alone is excluded by direct evidence; Candidate 1's
spawn/lifecycle half remains an unverified hypothesis that, even if true, does not by itself account
for minimize-to-taskbar (its mechanism, `SW_HIDE`, vanishes windows rather than minimizing them). That
`keep-awake.ps1` cannot itself manipulate a window (Candidate 1, content) does not remove the script
from the causal story: its `ES_DISPLAY_REQUIRED` contract (`keep-awake.ps1:47`) is the mechanism
behind Candidate 4, so the two verdicts describe different causal routes through the same file, not a
dismissal of it.

Evidence needed: the single narrowest next step is whether the minimize coincides with something the
operator did (a keypress, pressing `[c]` to launch a connector) or happens while the dashboard sits
idle — an idle-time minimize points at Candidate 2's periodic native spawns and away from everything
hotkey-driven, and a bounded (~2 min) correlation against a `keepawake_started` event would properly
test Candidate 4 in place of the near-vacuous whole-gap test this document previously proposed. Also
needed: whether the operator's terminal actually implements `CSI 2 t` iconify at all (Limits item 2
— the cheapest, most decisive test available; a negative result excludes Candidate 3 for that
terminal configuration), the operator's `powercfg` display-timeout value (replaces this document's
previously unsourced "10–15 minutes" assumption and can exclude Candidate 4 outright), and whether
the operator was away from the machine long enough for that timeout to matter. Also needed, to fully
resolve Candidates 1 and 2: which console topology (conhost / ConPTY / mintty) the operator's
terminal uses (Limits item 1) — this single fact both settles whether `-WindowStyle Hidden` can
affect Candidate 1's spawn and whether a Cygwin-spawned native console (Candidate 2) is ever
rendered visible under that topology — and whether `-WindowStyle Hidden` visibly affects that
operator's window at all (Limits item 3). None of these data points can be produced from this
container; all require either the operator's own terminal or a real Windows host.

## Recommended fix

Recommendation: FIX
Files: launcher.pl, KeepAwake.pm
Mechanism: two independent hardening changes, both recommendations only (not implemented in this
package): (1) make the busy-lease probe at `launcher.pl:3385` distinguish "podman exec failed" from
"lease genuinely stale" — e.g. treat an exec failure as "unknown, assume busy" rather than feeding
`undef` into `should_stay_awake` (`KeepAwake.pm:37`), which currently collapses lease-absent,
container-gone and exec-failed into the same SIGKILL-and-respawn behaviour. This is a correctness
fix for that ambiguity **on its own merits** — it is not, and should not be sold as, a mitigation
for Finding E: the measured long display-sleep-capable gaps all follow the designed `$BUSY_STALE`
release (`busy_age` 601/602 s), not a probe failure (see Candidate 4 above), so this change would
prevent none of them; (2) balance the title-stack push (`launcher.pl:3306`) against its guarded,
one-shot-only pop (`:3320`) so re-entrant enter_raw/leave_raw cycles cannot leave an unbalanced
XTPUSHTITLE on the stack. Neither change is made here — both are out of this package's write set
(`launcher.pl`, `KeepAwake.pm` are excluded) and are scoped as the follow-on packages below.
Risk: the busy-lease change touches the same code path `s17` is already diagnosing (fork frequency,
`container_gone`), so it must be sequenced with or reviewed against that package to avoid two
in-flight changes to the same probe; a naive "treat exec failure as busy" fix could also mask a
genuinely dead container and delay legitimate shutdown, so it needs a bounded retry/backoff rather
than an unconditional busy assumption. The title-stack fix is lower risk (a counter reset, purely
additive) but touches a seam (`enter_raw`/`leave_raw`) shared with the INT/TERM handlers, so it
needs testing against the second-Ctrl-C teardown case the current one-shot guard was added for.

This is a recommendation only; neither `launcher.pl`, `Dashboard.pm`, `KeepAwake.pm`, nor
`keep-awake.ps1` was edited to produce this document, per this package's write-set boundary.

## Follow-on packages

### Follow-on: keep-awake-probe-failure-handling
Defect: B2 — the busy-lease probe (`launcher.pl:3385`) returns `undef` identically for three
distinct cases: the lease file genuinely absent (no run active — the common, correct-idle case,
per `KeepAwake.pm:24-27`), a transient `podman exec` failure, and a container that is actually gone.
`should_stay_awake` (`KeepAwake.pm:37`) SIGKILLs the wake-lock helper for all three alike
(`_keepawake_stop`), and once the probe next succeeds the helper re-spawns
(`launcher.pl:3877-3878`, carrying `-WindowStyle Hidden`). This is a real ambiguity worth fixing on
its own merits — the logs cannot currently tell "correctly idle" apart from "probe failed" — but it
is **not**, on the evidence measured for this document, the cause of the long display-sleep-capable
gaps in Finding E (see Candidate 4 above): each of those gaps traces to the designed `$BUSY_STALE`
release, not to one of these `undef` cases.
Fix sketch: on `podman exec` failure at `launcher.pl:3385`, retain the last-known busy age (or treat
as "unknown, assume busy") instead of setting `$cached_busy_age = undef`, and only fall through to
"stop" after a bounded number of consecutive probe failures, coordinating with `s17`'s existing
fork-frequency diagnosis on the same probe.
Files: launcher.pl, KeepAwake.pm

### Follow-on: title-stack-push-pop-balance
Defect: A2 — `launcher.pl:3301` declares `my $left_raw = 0;` outside `Dashboard::run`, and `:3320`
guards the XTPOPTITLE pop with the one-shot `if (!$left_raw++)`. That guard is correct for its
original purpose (a re-entrant second-Ctrl-C teardown) but is never reset, while `enter_raw`'s push
at `:3306` is unconditional, so any control flow that leaves raw mode and re-enters it pushes a
second title-stack entry that can never be popped. Latent today (each seam fires exactly once per
`Dashboard::run`), but structurally unbalanced rather than balanced-by-construction.
Fix sketch: scope `$left_raw` (or an equivalent guard) per raw-mode session instead of once per
process, so each `enter_raw`/`leave_raw` pair pushes and pops exactly once regardless of how many
times the pair executes across a single launcher invocation.
Files: launcher.pl

## Operator requests

1. Report which terminal/console topology you run the sandbox from — classic conhost, Windows
   Terminal (ConPTY), or Git Bash's mintty. This single fact fully resolves whether Candidate 1's
   `-WindowStyle Hidden` spawn can affect your terminal's window at all, and bears on whether a
   Cygwin-spawned native console (Candidate 2) is ever rendered visible under your topology.
2. In your own terminal, run `printf '\033[22;0t'` immediately followed by `printf '\033[23;0t'` —
   this is what the code actually emits (`launcher.pl:3306`/`:3322`), not a hypothetical corrupted
   form. Then, separately, run `printf '\033[2t'` (the true iconify sequence) while watching the
   window, with nothing else running. This is the cheapest, most **decisive** test available: if the
   window minimizes on the `22;0t`/`23;0t` pair, Candidate 3 (Findings A/C) is live in your terminal
   exactly as emitted; if only the plain `2t` form minimizes, note that but do not treat it as
   confirming Candidate 3, since the code never emits that exact sequence. If nothing happens on any
   of them, Candidate 3 is excluded **for this terminal configuration** (not "outright" — window
   manipulation is commonly gated behind a terminal setting, e.g. xterm's `allowWindowOps` defaults
   to off, so "nothing happens" may mean "disabled" rather than "unimplemented").
3. Separately, tell us whether launching the sandbox visibly flashes or otherwise disturbs your
   console window (a) at the moment the container starts, versus (b) at the moment you press `[c]`
   to launch a connector session. These are two different mechanisms — (a) would point at a
   `-WindowStyle Hidden`-driven flash (Candidate 1), while (b) is `wt.exe -w new` opening a new,
   visible window (already excluded above as the cause of a *spontaneous* minimize, but still worth
   confirming it behaves as expected) — and a single undifferentiated "yes" cannot tell them apart.
4. **[Headline next step]** Does the minimize coincide with something you did — a keypress, or
   pressing `[c]` to launch a connector — or does it happen while the dashboard sits idle with no
   action taken on your part? This is now the single most useful next data point: an idle-time
   minimize points at the periodic native spawns (Candidate 2) and away from anything hotkey-driven
   (`wt.exe`, Candidate 1), while an action-coincident minimize points the other way. This supersedes
   this document's earlier ask to simply note the wall-clock time of the next minimize and correlate
   it against Finding E's gaps — once the full wake-lock-absent census is counted (see
   `## Conclusion`), that correlation turns out to hit at a base rate near a coin flip and would not
   be decisive on its own. Two further, cheap and orthogonal asks that bear specifically on Finding
   E: (a) run `powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE` (and `powercfg /a`) and report the
   output — this is your actual measured display-sleep timeout, replacing this document's previously
   unsourced "10–15 minutes" assumption, and a value of `Never` or anything above ~23 minutes
   excludes Finding E outright; (b) tell us whether you were away from the machine for more than
   ~10 minutes immediately before it minimized — active input resets the idle timer, so if you were
   typing or watching at the time, Finding E is excluded entirely, independent of (a).
