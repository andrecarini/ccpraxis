# B0 — TUI Viability Spike Findings

> Blueprint: `unattended-run-overhaul` · Package: **B0-tui-spike**
> Purpose: prove a raw-ANSI TUI works from PowerShell-invoked perl into Windows
> Terminal / conhost (the path the `claude-sandbox` dashboard will use), or record
> a fallback. Probe: [`b0-tui-probe.pl`](./b0-tui-probe.pl).
>
> **STATUS: PREPARED — awaiting an interactive run.** The probe + this doc are
> written; the four interactive checks below can only be sealed by running the
> probe in a real terminal (a TTY a non-TTY tool call cannot provide). The
> static/module findings are already filled in.

## How to run

In a **real terminal**, via **PowerShell** (NOT Git Bash — the console type is the
whole point of the spike), ideally both in Windows Terminal and a plain conhost
window:

```
perl C:\Users\André\.claude\ccpraxis\plugins\sandbox\docs\b0-tui-probe.pl
```

Keys while it runs: `q` quit · `c` cycle the color test · any other key echoes.
It auto-exits after 60s. On exit it prints a `=== B0 PROBE SUMMARY ===` block —
**paste that block into the "Probe summary output" section below**, and fill the
PASS/FAIL verdicts from what you observed on screen.

## Static findings (already determined — host perl, 2026-06-24)

- **perl:** Git-for-Windows perl **v5.42.2** (cygwin/msys build). This is the perl
  the launcher invokes; `claude-sandbox` runs perl from PowerShell using the same
  binary on PATH.
- **Module availability** (`perl -M<mod> -e1`):
  | module | available? | matters for |
  |--------|-----------|-------------|
  | `Term::ReadKey` | ✅ yes | non-blocking keypress + `GetTerminalSize` (resize) |
  | `Time::HiRes` | ✅ yes | sub-second render tick |
  | `POSIX` | ✅ yes | — |
  | `Win32::Console` | ❌ MISSING | (alt input/size path; not needed if Term::ReadKey works) |
  | `Win32::Console::ANSI` | ❌ MISSING | conhost VT auto-enable (Windows Terminal needs none) |
  | `Win32::API` | ❌ **MISSING** | **B5 keep-awake** — see implication below |
- **⚠️ B5 implication (important):** `Win32::API` is **not** available in this perl,
  so B5's keep-awake **cannot** call `SetThreadExecutionState` in-process. B5 must
  hold the wake-lock via a **persistent PowerShell helper** (a `powershell.exe`
  child that calls `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)` and
  stays alive while the lease is fresh), not an in-process Win32 call. Record this
  in the B5 package when it starts. (Decision #16 already allows "a persistent
  helper held by the dashboard process" as the alternative to in-process Win32.)

## Interactive checks — fill after running the probe

Each: **PASS w/ evidence** or **FAIL w/ fallback**.

1. **Alt-screen enter/leave** (`\e[?1049h` / `\e[?1049l`) — screen swaps to a blank
   alt buffer on start and the original scrollback is restored intact on exit.
   - Windows Terminal: ⬜ TODO
   - conhost: ⬜ TODO
2. **24-bit color** (`\e[38;2;r;g;bm`) — the truecolor gradient renders as a smooth
   blue→orange ramp (not banded to 16 colors). Also note 256-color + basic-16.
   - Windows Terminal: ⬜ TODO
   - conhost: ⬜ TODO
3. **Non-blocking keypress** (`Term::ReadKey` `cbreak` + `ReadKey(-1)`) — keys
   register **without pressing Enter**, and the loop keeps ticking when no key is
   pressed (summary shows `non-blocking poll: WORKING`). This is the load-bearing
   uncertainty: does cygwin-perl's Term::ReadKey raw mode work through a *native*
   Windows console (PowerShell), not just a Git-Bash pty?
   - Windows Terminal: ⬜ TODO
   - conhost: ⬜ TODO
   - **If FAILED:** fallback = a bounded blocking-read loop, or a PowerShell input
     shim feeding keys to perl over a pipe. Record which.
4. **Resize reaction** (`GetTerminalSize` polled each tick) — resizing the window
   makes `resizes detected` climb and the size readout update.
   - Windows Terminal: ⬜ TODO
   - conhost: ⬜ TODO
   - **If FAILED:** fallback = the ANSI `\e[18t` window-size query (parse the
     `\e[8;rows;cols t` reply), or a fixed redraw cadence. Record which.

## Probe summary output

```
<paste the === B0 PROBE SUMMARY === block here, once per terminal tried>
```

## Verdict

- Overall B0: ⬜ TODO (PASS if 1–4 all pass in at least Windows Terminal; otherwise
  PASS-with-fallbacks, listing each fallback the dashboard (B2) must adopt).
- Carry-forward to B2: ⬜ (input model, resize model, min terminal assumed).
- Carry-forward to B5: keep-awake via **PowerShell helper** (Win32::API absent) —
  already determined above.
