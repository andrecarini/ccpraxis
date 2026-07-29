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

**Content, excluded.** `keep-awake.ps1` was read in full (61 lines). Its entire Win32 surface is
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

Verdict: EXCLUDED-BY-EVIDENCE

A full census of periodic Windows-native spawns was taken (report Finding D):

- `_powershell_json` (`launcher.pl:4045-4052`) — `` powershell.exe -NoProfile -NonInteractive -Command "$cmd" 2>/dev/null ``,
  with **no window-suppression flag**. Driven by three probes (`cim_mem`, `cim_cpu`, `cim_disk`,
  `_ps_commands` at `launcher.pl:4009+`, wired at `:4083-4085`), so **3 `powershell.exe` spawns per
  Resources sample round**, gated by `Resources::should_sample` at `$SAMPLE_INTERVAL` = **23 s**
  (`Resources.pm:27`, `:315`), Windows-only (`return undef unless $WINDOWS_FAMILY`). By raw
  frequency this is the biggest offender (3 spawns / 23 s, roughly 470/hour).
- `$PODMAN inspect/exec/ps` backticks — many call sites, including the busy-lease probe
  (`launcher.pl:3385`) and the dashboard's ~10 s status tick.
- `wsl -d $machine -- sh -c ...` (`launcher.pl:1983`), `podman machine inspect` (`:1980`).
- `powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process ...)"` (`:3911`, in
  `_keepawake_reap_orphan`) and `taskkill.exe /PID <pid> /F /T` (`:3914`) — no window flag, but
  fires once per dashboard entry, not periodically.

Every one of these spawns lacks `-WindowStyle`. A console child inheriting an existing console does
not normally create or flash a visible window of its own, and — decisively — none of these
instructs a `ShowWindow` call on the shared console the way `-WindowStyle Hidden` does. That
asymmetry is exactly what isolates `launcher.pl:3878` (Candidate 1's spawn) as the interesting site
and leaves the rest of this census merely frequent but inert with respect to window state. This is
excluded by an observed fact — the absence of any window-affecting flag across the entire spawn
census — not by assumption.

(Separately, `.ccpraxis-local-data/claude-home/.launcher/keepawake.pid` exists on disk right now —
a helper recorded its Windows PID and the file outlived it, consistent with a launcher exit that
skipped the normal `_keepawake_stop` unlink path at `launcher.pl:3895`. This is a housekeeping
artifact, not evidence of window manipulation, and does not change this verdict.)

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
land inside the escape sequence. Meanwhile there are 104 STDERR write sites in `launcher.pl`, and
STDERR is unbuffered; `s17-statusline-and-output-hygiene` exists precisely because STDERR bytes
already land inside the render stream on this exact channel — a known, already-ticketed defect, not
a hypothetical. A `CSI` parser mid-sequence that receives injected bytes can mis-read its
parameters; `\e[22;0t` losing one `2` becomes `\e[2;0t` — iconify. This could not be demonstrated
in-container (no Windows terminal to feed it to) and is not claimed to have happened; what is
claimed is that the emission, the buffering gap, and the interleaving defect all exist, and
together are the only mechanism found that could make Finding A fire more than once per run.

Net: this candidate is not excluded. It is bounded by two open questions that can only be answered
by the operator (Limits items 1 and 2 — console topology, and whether the operator's terminal
implements `CSI 2 t` at all) — see `## Operator requests` below.

### Candidate 4 — external Windows mechanism

Verdict: NOT-EXCLUDED

This is the report's leading candidate, built from **Finding E**, and reframes "external Windows
mechanism" from "not our bug" to "an external mechanism our own bug triggers".

`keep-awake.ps1` asserts `ES_DISPLAY_REQUIRED` (`keep-awake.ps1:47`) — it holds the **display**
awake, not just the system. Every interval in which the helper process is dead is an interval in
which Windows is free to power the display off. Measured directly from `keepawake_stopped` →
next `keepawake_started` timestamps across all 22 logged launches
(`.ccpraxis-local-data/claude-home/sandbox-logs{,-from-workcopy}/`, `LaunchLog.pm` JSON-lines,
2026-07-24T21:25Z → 2026-07-28T22:23Z):

```
launch-20260728T222227Z:  22:57:09Z -> 23:20:36Z = 1407 s (23.4 min)   <-- display can sleep
launch-20260728T222227Z:  23:31:39Z -> 23:31:51Z =   12 s ( 0.2 min)
launch-20260725T031526Z:  03:19:31Z -> 03:32:42Z =  791 s (13.2 min)   <-- display can sleep
launch-20260725T031526Z:  04:21:51Z -> 04:25:31Z =  220 s ( 3.7 min)
launch-20260725T135455Z:  14:29:28Z -> 14:29:32Z =    4 s ( 0.1 min)
launch-20260725T135455Z:  14:43:14Z -> 14:59:21Z =  967 s (16.1 min)   <-- display can sleep
launch-20260725T135455Z:  20:43:51Z -> 20:43:54Z =    3 s ( 0.1 min)
```

Three gaps of **13.2, 16.1 and 23.4 minutes**, each while the dashboard was open and the run was in
progress. Windows' default display-off timeout on AC is typically 10–15 minutes, so these gaps are
long enough for the display to actually power down; a display power transition — and the monitor
re-enumeration / DPI-and-topology change that can accompany it — is a well-known cause of Windows
windows being minimized or rearranged on wake. This is the only candidate that predicts
minimize-**to-the-taskbar** specifically (unlike Candidate 1's `SW_HIDE`, which vanishes rather than
minimizes), predicts **recurrence** (three long gaps across three of four multi-hour logs, versus
Candidate 3's entry/exit-only firing), and predicts **irregular** timing (gaps track fleet
idleness, not a fixed cadence) — all three properties the operator's report exhibits, without
needing an unverified premise.

The gaps are also, in part, a defect rather than pure idleness. Event totals across the same 22
logs: `keepawake_started` **11**, `keepawake_stopped` **10**, `keepawake` (action) **21**,
`heartbeat` 1194, `container_gone` **227**, `signal` 4, `keepawake_start_failed` **0**. Up to four
start/stop cycles occur within a single launch, e.g. `launch-20260725T135455Z-1335887.log`:

```
2026-07-25T13:58:08Z keepawake_started pid=1336234   action=start busy_age=5
2026-07-25T14:29:28Z keepawake_stopped pid=1336234   action=stop  busy_age=null
2026-07-25T14:29:32Z keepawake_started pid=1336903   action=start busy_age=4     <-- 4s later
```

The `busy_age=null` stops are spurious: `$BUSY_STALE` is 600 s (`launcher.pl:3288-3289`,
`:3578-3579`), and the lease age comes from `` `$PODMAN exec "$CONTAINER_NAME" stat -c %Y
/tmp/.butler-busy 2>/dev/null` `` (`launcher.pl:3385`). On any failure of that `podman exec`,
`$cached_busy_age = undef` (`:3393`); `should_stay_awake` returns 0 for an undefined age
(`KeepAwake.pm:37`), so `sync(0)` SIGKILLs the wake-lock helper (`_keepawake_stop`, `:3888-3896`) —
and the next tick, once the exec succeeds again, re-spawns it. The re-start ages above (4 s, 3 s,
5 s) rule out a genuinely stale lease (which would read ~600 s): the fleet was never idle. That the
probe does fail transiently is independently corroborated by `container_gone` appearing 227 times
in the same log set (owned by `s17`'s fork-frequency diagnosis). So a transient container-probe
failure, not idleness, is producing some of the display-sleep windows above — see sub-finding B2
under `## Follow-on packages`.

**Verdict rationale:** not excluded, and the leading candidate, but it is inference from measured
gap durations plus known Windows display-sleep behaviour, not a direct demonstration that a real
minimize happened inside one of these windows. What would settle it — a single observed minimize
timestamp checked against these gaps — is Limits item 4, requested below.

## Conclusion

Cause identified: NO

Narrowed to: the surviving candidates are Candidate 3 (window-manipulation escape sequences —
Findings A/C, `launcher.pl:3306`/`:3322`, `NOT-EXCLUDED`) and Candidate 4 (external Windows
mechanism triggered by our own wake-lock gaps — Finding E, `NOT-EXCLUDED` and the leading
candidate). Candidates 1 (content) and 2 are excluded by direct evidence; Candidate 1's
spawn/lifecycle half remains an unverified hypothesis that, even if true, does not by itself account
for minimize-to-taskbar (its mechanism, `SW_HIDE`, vanishes windows rather than minimizing them).

Evidence needed: a single operator-observed minimize event, timestamped, cross-checked against (a)
whether the operator's terminal actually implements `CSI 2 t` iconify at all (Limits item 2 — the
cheapest, most decisive test available; a negative result excludes Candidate 3 outright), and (b)
whether the timestamp falls inside or within roughly a minute of one of the measured wake-lock-absent
windows from Finding E (Limits item 4). Also needed, to fully resolve Candidate 1: which console
topology (conhost / ConPTY / mintty) the operator's terminal uses (Limits item 1), and whether
`-WindowStyle Hidden` visibly affects that operator's window at all (Limits item 3). None of these
four data points can be produced from this container; all four require either the operator's own
terminal or a real Windows host.

## Recommended fix

Recommendation: FIX
Files: launcher.pl, KeepAwake.pm
Mechanism: two independent hardening changes, both recommendations only (not implemented in this
package): (1) make the busy-lease probe at `launcher.pl:3385` distinguish "podman exec failed" from
"lease genuinely stale" — e.g. treat an exec failure as "unknown, assume busy" rather than feeding
`undef` into `should_stay_awake` (`KeepAwake.pm:37`), which currently collapses both cases to the
same SIGKILL-and-respawn behaviour and directly produces the wake-lock-absent windows measured in
Finding E; (2) balance the title-stack push (`launcher.pl:3306`) against its guarded, one-shot-only
pop (`:3320`) so re-entrant enter_raw/leave_raw cycles cannot leave an unbalanced XTPUSHTITLE on the
stack. Neither change is made here — both are out of this package's write set (`launcher.pl`,
`KeepAwake.pm` are excluded) and are scoped as the follow-on packages below.
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
Defect: B2 — the busy-lease probe (`launcher.pl:3385`)
cannot distinguish a transient `podman exec` failure from a genuinely stale lease, so
`should_stay_awake` (`KeepAwake.pm:37`) SIGKILLs the wake-lock helper on a transient failure alone,
and the re-spawn (`launcher.pl:3877-3878`, carrying `-WindowStyle Hidden`) occurs seconds later once
the probe succeeds again (re-start ages observed at 4s, 3s, 5s, ruling out genuine staleness), each
cycle opening a window in which `ES_DISPLAY_REQUIRED` is not asserted and the display can sleep.
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
   `-WindowStyle Hidden` spawn can affect your terminal's window at all.
2. In your own terminal, run `printf '\e[2t'` (or `printf '\033[2t'`) while watching the window, with
   nothing else running. This is the cheapest, most **decisive** test available: if the window
   minimizes, Candidate 3 (Findings A/C) is live in your terminal and worth pursuing further; if
   nothing happens, Candidate 3 is excluded outright regardless of any byte-corruption reasoning,
   and the investigation should focus on Candidate 4.
3. Separately, tell us whether launching the sandbox visibly flashes or otherwise disturbs your
   console window at the moment of launch (as opposed to minimizing later, mid-run). This
   distinguishes a `-WindowStyle Hidden`-driven flash (Candidate 1) from a later, unrelated
   minimize.
4. Next time the terminal minimizes unexpectedly, note the wall-clock time (to the minute) and tell
   us. The launch logs are already on disk, timestamped to the second, going back to 2026-07-24;
   the only missing datum to compute a correlation against the measured wake-lock-absent windows
   (Finding E: 13.2, 16.1, and 23.4-minute gaps) is the time of one observed minimize.
