# B0 — TUI Viability Spike Findings

> Blueprint: `unattended-run-overhaul` · Package: **B0-tui-spike**
> Purpose: prove a raw-ANSI TUI works from PowerShell-invoked perl into Windows
> Terminal / conhost (the path the `claude-sandbox` dashboard will use), or record
> a fallback. Probe: [`b0-tui-probe.pl`](./b0-tui-probe.pl).
>
> **STATUS: ✅ PASS (Windows Terminal) — 2026-06-24.** The user ran the probe in
> Windows Terminal; all four interactive checks pass (see below). One caveat
> surfaced — flicker from a full-screen-clear redraw — captured as a HARD
> carry-forward to B2. conhost was not separately tested (optional follow-up).
> The static/module findings were already filled in.

## How to run

In a **real terminal**, via **PowerShell** (NOT Git Bash — the console type is the
whole point of the spike), ideally both in Windows Terminal and a plain conhost
window. **Bare `perl` is not on the PowerShell PATH** on this host (Git-for-Windows
keeps perl in `usr\bin`, which isn't on PATH — only `cmd` is), so invoke perl by
full path:

```
& "C:\Program Files\Git\usr\bin\perl.exe" "C:\Users\André\.claude\ccpraxis\plugins\sandbox\docs\b0-tui-probe.pl"
```

(The `claude-sandbox.ps1` shim resolves perl this same way via `Get-PerlPath`, so
the launcher itself is unaffected — this only bites ad-hoc `perl` from a prompt.)

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
   - Windows Terminal: ✅ PASS — alt-screen engaged; restored on exit, no leftover artifacts reported.
   - conhost: ➖ not separately tested (optional).
2. **24-bit color** (`\e[38;2;r;g;bm`) — the truecolor gradient renders as a smooth
   blue→orange ramp (not banded to 16 colors). Also note 256-color + basic-16.
   - Windows Terminal: ✅ PASS — user: "colors working great"; truecolor + 256 + 16 all rendered.
   - conhost: ➖ not separately tested (optional).
3. **Non-blocking keypress** (`Term::ReadKey` `cbreak` + `ReadKey(-1)`) — keys
   register **without pressing Enter**, and the loop keeps ticking when no key is
   pressed (summary shows `non-blocking poll: WORKING`). This is the load-bearing
   uncertainty: does cygwin-perl's Term::ReadKey raw mode work through a *native*
   Windows console (PowerShell), not just a Git-Bash pty?
   - Windows Terminal: ✅ PASS — 53 keys registered without Enter; `non-blocking poll: WORKING`. **The load-bearing uncertainty is RESOLVED: cygwin-perl Term::ReadKey cbreak + ReadKey(-1) works through a native Windows console.**
   - conhost: ➖ not separately tested (optional).
   - Fallback (not needed): a bounded blocking-read loop, or a PowerShell input
     shim feeding keys to perl over a pipe.
4. **Resize reaction** (`GetTerminalSize` polled each tick) — resizing the window
   makes `resizes detected` climb and the size readout update.
   - Windows Terminal: ✅ PASS — 17 resizes detected via `GetTerminalSize` polling.
   - conhost: ➖ not separately tested (optional).
   - Fallback (not needed): the ANSI `\e[18t` window-size query (parse the
     `\e[8;rows;cols t` reply), or a fixed redraw cadence.

## Caveat found — redraw flicker (HARD carry-forward to B2)

The probe **flickers**: the whole screen visibly blanks and repaints each tick.
Root cause is the probe's deliberately-naive render — it emits `\e[2J` (erase
entire display) + `\e[H` every frame, so there is a blank instant before each
repaint; at the probe's ~12.5 fps that reads as constant flashing.

**B2 (the dashboard) must NOT clear-the-world each frame.** Fixes, preferred first:
1. **No full-screen erase.** Home the cursor (`\e[H`) and overwrite, clearing each
   line's tail with `\e[K` as it's written — the screen never goes fully blank.
2. **Synchronized output:** wrap each frame in `\e[?2026h` … `\e[?2026l` (DEC
   private mode 2026, supported by Windows Terminal) so the terminal presents the
   frame atomically — kills tearing/flicker even on a full redraw.
3. **Diff / double-buffer** (what mature TUIs do): emit only the cells changed
   since the previous frame.
Recommended for B2: (1) + (3), with (2) as belt-and-suspenders.

## Probe summary output

Windows Terminal (WT_SESSION set), 2026-06-24:

```
perl=5.42.2 os=cygwin windows_terminal=yes
modules: Term::ReadKey=yes, Time::HiRes=yes, Win32::API=no, Win32::Console=no, Win32::Console::ANSI=no
alt-screen entered/left : yes (restored cleanly)
raw/cbreak mode         : engaged
non-blocking keypoll     : working (ReadKey(-1) returned without blocking)
keys registered          : 53  (last: q (0x71))
resize detected          : 17 time(s)  -> GetTerminalSize tracks resize
color                    : truecolor + 256 + 16 all rendered (user: "colors working great")
implication for B5      : Win32::API NOT available -> keep-awake needs a PowerShell helper, not in-process Win32::API
```

conhost: not separately tested (optional follow-up).

## Verdict

- **Overall B0: ✅ PASS** — all four checks pass in Windows Terminal. The one
  caveat (redraw flicker) is a render-strategy carry-forward to B2, not a
  viability blocker. conhost not separately tested (optional).
- **Carry-forward to B2:**
  - **Input model:** `Term::ReadKey` `ReadMode('cbreak')` + `ReadKey(-1)`
    non-blocking poll — WORKS through a native Windows console (PowerShell).
  - **Resize model:** poll `Term::ReadKey::GetTerminalSize()` each tick — WORKS.
  - **Render model:** do NOT `\e[2J` per frame — use `\e[H` + per-line `\e[K`
    (ideally inside synchronized-output `\e[?2026h`/`\e[?2026l`) to avoid flicker.
  - **Min terminal:** Windows Terminal confirmed; conhost unverified (assume WT).
- **Carry-forward to B5:** keep-awake via **PowerShell helper** (Win32::API
  absent) — already determined above.
