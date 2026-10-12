# keep-awake.ps1 -- hold a Windows wake-lock for as long as THIS process lives,
# and NO LONGER than its lease.
#
# Started/killed by the sandbox dashboard's keep-awake (B5, KeepAwake.pm) and by
# butler's bp-keepawake.pl, gated by the orchestrator's busy-lease: spawned only
# while there is active work or a pending auto-resume, killed when idle.
#
# The host perl has no Win32::API, so we assert SetThreadExecutionState via
# P/Invoke from PowerShell. ES_CONTINUOUS ties the request to the calling thread,
# so the lock is released automatically the moment this process is killed -- no
# explicit "undo" call is needed (which is exactly why we run it as a dedicated
# child whose lifetime == the wake-lock's lifetime).
#
# We request ES_SYSTEM_REQUIRED. That was the whole request as of 2026-09-17;
# it no longer is -- see the EXECUTION POWER REQUEST block further down, which
# also holds a PowerRequestExecutionRequired Power Request alongside it,
# acquired right after SetThreadExecutionState succeeds and released from the
# `finally` block below (package 01, Decision 1).
#
# THIS BLOCK USED TO CLAIM ES_DISPLAY_REQUIRED WAS "the load-bearing flag on
# Modern Standby (S0 Low Power Idle) machines", on the reasoning that "those
# systems enter connected standby when the display turns off". MEASURED, and the
# premise is false on this class of machine. An eight-hour unattended run was
# lost, and Windows named the cause itself:
#
#   Kernel-Power 506, 06:04:57 local
#   "The system is entering connected standby.  Reason: Idle Timeout."
#
# IDLE TIMEOUT -- not display-off. The display request was held and refreshing on
# its normal two-minute cadence when that fired. So the flag was blocking a
# trigger that was not the trigger, while costing a lit screen through every
# unattended night. Dropped at the operator's instruction.
#
# WHAT THE REQUESTS ACTUALLY DO HERE, from `powercfg /requests` taken elevated
# while a lock was held:
#
#   DISPLAY:    [PROCESS] ...\powershell.exe     <- was registered, worked
#   SYSTEM:     [PROCESS] ...\powershell.exe     <- registered, works
#   EXECUTION:  None.                            <- the gap that mattered
#
# SetThreadExecutionState was never being ignored: Windows had both requests.
# Neither of them keeps a PROCESS RUNNING once the system is in connected
# standby -- that is PowerRequestExecutionRequired, which has no ES_* flag and
# cannot be expressed through this API at all. Work continued INSIDE standby for
# nearly four hours on DISPLAY+SYSTEM alone, then Desktop Activity Moderation
# suspended it.
#
# WE DO NOW HOLD AN EXECUTION POWER REQUEST TOO (package 01, Decision 1), and
# this paragraph used to argue against doing so -- superseded, not deleted, so
# the reasoning that led here stays legible. The gap this closes is real:
# PowerRequestExecutionRequired protects the CALLING PROCESS only, and one held
# by this PowerShell does nothing for the launcher, the orchestrator, or the
# agent process doing the actual work -- but this PowerShell is not incidental:
# it is the dedicated process whose lifetime the wake-lock already binds to
# (see the header above), so an execution request pinned to IT is exactly the
# shape the earlier reasoning was missing. The containerised case is still
# covered differently, since everything inside the WSL VM is one process
# (`vmmem`) to Windows.
#
# THE ACTUAL FIX IS TO LEAVE THE REGIME: disabling Modern Standby
# (PlatformAoAcOverride) restores classic S3 sleep, where ES_SYSTEM_REQUIRED is
# correct AND sufficient, because S3 is exactly the idle timer it targets. That
# is a machine-level change and is the operator's to make; this script is
# already correct for that world and costs nothing in the meantime.
#
# Caveats no software request can beat: closing the lid or the power button still
# forces standby, and battery power policy may override -- for a long unattended
# run, keep the machine on AC.
#
# THE LEASE, added 2026-08-14. Before this, the body was
# `while ($true) { Start-Sleep -Seconds 3600 }` with no owner check and no
# expiry: the ONLY release was the parent killing us. That fails in exactly the
# case that matters -- the parent dying unexpectedly (crash, forced restart, WSL
# VM kill, a session torn down mid-run). An orphan then held ES_DISPLAY_REQUIRED
# and kept the machine awake INDEFINITELY, with nothing left that knew to reap
# it. The -PidFile reaping path only helps if some LATER launcher happens to run
# in the same project and finds the file. The operator asked the right question:
# these should be refreshed against a timeout threshold.
#
# So the pid file is now a HEARTBEAT as well as an identity: the owning side
# touches it while it still wants the lock (see bp-keepawake.pl's apply(), which
# refreshes it on the very tick that finds a live lock and leaves it alone). We
# poll, and exit when any of
#   * the pid file is GONE      -- someone released us deliberately,
#   * it has not been touched within -LeaseSeconds -- nobody is left who wants
#     it (with a verified -OwnerWinPid: only if that owner has also exited), or
#   * the verified owner has exited (RELEASE reason=owner-gone).
# Exiting drops the wake-lock automatically, because ES_CONTINUOUS is bound to
# this thread. Worst case an abandoned lock now costs one lease period, not "until
# the next reboot". That promise holds for EVERY caller: -LeaseSeconds 0 without
# a verified owner falls back to a 60s lease (LEASE-FALLBACK), and with one the
# lock ends at the latest one poll after that owner exits. The one hold with no
# time bound is a verified owner that stays alive -- deliberate (Decision 3).
#
# -PidFile: we write our own Windows PID here at startup and remove it on exit,
# so a launcher that crashed while we were running can still reap us by pid.
#
# ASCII ONLY. This file previously carried em-dashes with no BOM; PowerShell 5.1
# reads a BOM-less file as CP1252, where the UTF-8 bytes for an em-dash decode to
# a sequence containing 0x94 -- a smart quote, which PowerShell treats as a STRING
# DELIMITER. It was harmless only because those bytes sat inside comments. Do not
# reintroduce non-ASCII here.
# THE LEASE IS OPT-IN, and that is deliberate. It is only safe for a caller that
# actually REFRESHES the heartbeat; a caller that spawns us and then never
# touches the pid file would have its lock reaped mid-run, letting the machine
# sleep during exactly the long unattended run the lock exists to protect.
#
# Today: butler's bp-keepawake.pl refreshes on every director tick and passes a
# lease. launcher.pl's dashboard holder does NOT refresh, so it passes no lease
# and instead names itself with -OwnerWinPid (its WINDOWS pid, read from
# /proc/$$/winpid; Decision 16): it holds until the launcher kills it, removes
# the pid file, or dies. If the launcher cannot read its WINPID it omits the
# flag and gets the bounded 60s fallback, never an unowned indefinite hold. Do
# not "helpfully" give that path a finite lease without also giving it a
# refresher (its heartbeat loop is the obvious home).
#
# -OwnerWinPid (package 02): the owner's WINDOWS pid. When given, a stale
# heartbeat no longer means "abandoned" by itself -- a live owner is QUIET and
# the lock is held (HOLD-QUIET); an exited owner is GONE and the lock is released
# at once (RELEASE reason=owner-gone). With -LeaseSeconds 0 and a verified owner,
# the owner's exit is the only automatic release; an unverifiable owner means
# OWNER-UNVERIFIABLE and the fallback lease. See the pinning block below the
# clamps.
#
# -OwnerStartTicks (package 05): an open process handle makes WINPID reuse
# impossible for our OWN lifetime, but the pin happens strictly after the
# caller already knows the owner's WINPID -- and in the gap between the
# owner dying and us reaching that pin, Windows can hand the same WINPID to
# an unrelated process that also happens to have started before us (so the
# existing started-after-helper heuristic alone would accept it). A caller
# that also knows the owner's own StartTime.ToFileTimeUtc() can pass it here;
# an exact mismatch at pin time means OWNER-UNVERIFIABLE reason=start-time-
# mismatch and the normal fallback, instead of silently pinning an impostor.
# 0 (the default) means no anchor was supplied -- today's behaviour. A
# probe-time re-check in Get-OwnerState (OWNER-REPLACED) is defence in depth
# for the same identity question, routed through the same seam,
# Get-KaOwnerStartTicks, which also accepts a test-only override via
# -SimulateOwnerStartTicksFile.
[CmdletBinding()]
param(
    [string]$PidFile,
    [int]$LeaseSeconds = 0,     # 0 = no lease: needs a verified -OwnerWinPid, else a 60s fallback
    [int]$PollSeconds  = 60,
    [string]$LogFile,
    [int]$OwnerWinPid = 0,      # WINDOWS pid of the owner; 0 = no owner identity (heartbeat only)
    [string]$OwnerDesc = '',    # owner's own description (package 04); default text when absent
    [switch]$SimulatePowerRequestFailure,
    [switch]$SimulatePowerRequestException,
    [long]$OwnerStartTicks = 0,              # owner's StartTime.ToFileTimeUtc(); 0 = not supplied
    [string]$SimulateOwnerStartTicksFile = '' # TEST-ONLY seam: see Get-KaOwnerStartTicks
)
$ErrorActionPreference = 'Stop'

# -LogFile: THE QUESTION THIS EXISTS TO ANSWER. When the machine sleeps during an
# unattended run there are exactly two stories, and they need opposite fixes:
#
#   (a) the request WAS held and Windows slept anyway, or
#   (b) the request was already gone -- the lease reaped this helper first.
#
# Neither is recoverable after the fact. run.md carries no timestamps, the pid
# file's mtime history is overwritten on every heartbeat, and the helper leaves
# no trace at all once it exits. So on 2026-09-17 we had a Kernel-Power 506 and
# no way to say which story it belonged to, and a whole conclusion about
# ES_DISPLAY_REQUIRED was drawn on the assumption of (a) without testing it.
#
# Every line is stamped in LOCAL time to match Event Viewer, so a 506 can be
# correlated directly:
#   powershell "Get-WinEvent -FilterHashtable @{LogName='System';Id=506,507}"
# against this file. A HOLD line either brackets that timestamp or it does not.
#
# Logging must never be able to kill the wake-lock it is observing, so every
# write is best-effort and swallowed. No -LogFile means every call is a no-op.
$script:KA_LOG = $LogFile
function Write-KaLog {
    param([string]$Event, [string]$Detail = '')
    if (-not $script:KA_LOG) { return }
    try {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $script:KA_LOG -Encoding ascii `
                    -Value "$ts pid=$PID $Event $Detail" -ErrorAction SilentlyContinue
    } catch {}
}

if ($PidFile) {
    try { Set-Content -LiteralPath $PidFile -Value $PID -Encoding ascii -ErrorAction SilentlyContinue } catch {}
}

# -OwnerDesc sanitisation (package 04): applied before any use. Non-ASCII or
# control bytes become '?'; the value is trimmed and capped at 120 chars, so a
# caller's own cleaning (BpKeepAwake::owner_desc_clean, already stricter) is
# not the only thing standing between an odd string and this log/reason text.
$OwnerDesc = (($OwnerDesc -replace '[^\x20-\x7E]', '?').Trim())
if ($OwnerDesc.Length -gt 120) { $OwnerDesc = $OwnerDesc.Substring(0, 120) }

# The reason text: named after its owner when one was supplied, byte-identical
# to today's text otherwise (B-9). Logged once, before either power-request
# branch below, so every path -- real request, simulated failure, simulated
# exception -- logs the same line.
if ($OwnerDesc) {
    $KaReasonText = "ccpraxis keep-awake: execution required -- owner $OwnerDesc"
    if ($OwnerWinPid -gt 0) { $KaReasonText = "$KaReasonText winpid=$OwnerWinPid" }
} else {
    $KaReasonText = 'ccpraxis keep-awake: execution required'
}
Write-KaLog 'REASON' ("text=" + $KaReasonText)

Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);

[StructLayout(LayoutKind.Sequential)]
public struct POWER_REQUEST_CONTEXT {
    public uint Version;
    public uint Flags;
    [MarshalAs(UnmanagedType.LPWStr)] public string SimpleReasonString;
}

[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr PowerCreateRequest(ref POWER_REQUEST_CONTEXT Context);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool PowerSetRequest(IntPtr PowerRequest, int RequestType);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool PowerClearRequest(IntPtr PowerRequest, int RequestType);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool CloseHandle(IntPtr hObject);
'@

# String->uint32 casts avoid PowerShell parsing 0x80000000 as a (signed) int.
$ES_CONTINUOUS       = [uint32]'0x80000000'
$ES_SYSTEM_REQUIRED  = [uint32]'0x00000001'

# ES_DISPLAY_REQUIRED WAS DROPPED 2026-09-17, on measurement. See the header.
#
# It was here to block S0 connected-standby entry, on the stated premise that
# "those systems enter connected standby when the display turns off". The
# premise is false on this class of machine, and Windows said so itself:
#
#   Kernel-Power 506, 06:04:57
#   "The system is entering connected standby.  Reason: Idle Timeout."
#
# Idle timeout, not display-off -- with the display request held and refreshing
# normally at the time. The flag was chosen to block a trigger that was not the
# trigger, and it cost a lit screen every unattended night in exchange.
#
# Operator, 2026-09-17: "We don't need to hold the display lock anymore. I don't
# want to keep the display on forever."
#
# ES_SYSTEM_REQUIRED stays. It is the correct and sufficient request once Modern
# Standby is off and the machine uses classic S3 sleep, which is the direction
# this host is going -- and it costs nothing while S0 is still in force.
$r = [Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
if ($r -eq 0) {
    Write-KaLog 'ASSERT-FAILED' 'SetThreadExecutionState returned 0'
    Write-Error 'SetThreadExecutionState returned 0 (wake-lock not asserted)'
    exit 1
}
# The return value is the PREVIOUS execution state, so it is also the only
# in-process confirmation that the kernel recorded anything at all. Logged as hex
# because that is how the ES_* flags are documented and compared.
Write-KaLog 'ASSERTED' ("flags=ES_CONTINUOUS|ES_SYSTEM_REQUIRED prev=0x{0:X8} lease={1}s poll={2}s pidfile={3}" -f $r, $LeaseSeconds, $PollSeconds, $PidFile)

# EXECUTION POWER REQUEST -- see the header at the top of this file for why
# SetThreadExecutionState alone leaves the EXECUTION row in `powercfg
# /requests` as None. Acquired here, immediately after the existing
# SetThreadExecutionState success, and released from the finally block below.
#
# Invariant: $script:PowerRequestHandle is truthy IFF a Power Request was
# both successfully CREATED and successfully SET. Any other outcome (create
# failed, set failed, exception, simulated failure) leaves it $null, and a
# handle obtained but not fully set is closed immediately at the point of
# failure -- never left for the finally block to find.
$script:PowerRequestHandle = $null

$POWER_REQUEST_CONTEXT_VERSION       = 0        # Version field
$POWER_REQUEST_CONTEXT_SIMPLE_STRING = 1        # Flags field (uint)
$PowerRequestExecutionRequired       = 3        # POWER_REQUEST_TYPE enum value; passed as plain int, NOT OR'd with anything (not a bitmask)

if ($SimulatePowerRequestFailure) {
    # Test-only seam (-SimulatePowerRequestFailure). No real Win32 call is
    # made -- goes straight to the degrade branch as if the real API failed.
    Write-KaLog 'POWER-REQUEST-DEGRADED' 'reason=simulated-failure -- continuing on ES_SYSTEM_REQUIRED alone'
} else {
    # $handle is initialized here, OUTSIDE the try block, specifically so the
    # catch block below (same scope -- try/catch is not a scope boundary in
    # PowerShell) can still see whatever PowerCreateRequest last assigned to
    # it even when the exception is thrown by a LATER statement (PowerSetRequest).
    # Without this, a handle successfully created by PowerCreateRequest but
    # then orphaned by an exception from PowerSetRequest (interop failure,
    # not the ordinary boolean-false return -- see redteam-01.md MEDIUM
    # finding) would never be closed: $script:PowerRequestHandle stays $null,
    # so the `finally` block's own guard skips it too, and the real OS handle
    # leaks for the life of the process.
    $handle = [IntPtr]::Zero
    try {
        $context = New-Object Win32.Power+POWER_REQUEST_CONTEXT
        $context.Version = $POWER_REQUEST_CONTEXT_VERSION
        $context.Flags = $POWER_REQUEST_CONTEXT_SIMPLE_STRING
        $context.SimpleReasonString = $KaReasonText

        $handle = [Win32.Power]::PowerCreateRequest([ref]$context)
        if ($handle -eq [IntPtr]::Zero -or $handle.ToInt64() -eq -1) {
            Write-KaLog 'POWER-REQUEST-DEGRADED' 'reason=create-invalid-handle -- continuing on ES_SYSTEM_REQUIRED alone'
        } else {
            if ($SimulatePowerRequestException) {
                # Test-only seam (-SimulatePowerRequestException). Unlike
                # -SimulatePowerRequestFailure (which skips the real Win32
                # calls entirely), this seam makes a REAL PowerCreateRequest
                # call above (so $handle is a real, live OS handle) and then
                # simulates PowerSetRequest raising a CLR/interop exception
                # instead of returning $false, without making the real
                # PowerSetRequest call. This exercises the catch block's
                # handle-close path against a genuine handle.
                throw 'simulated PowerSetRequest exception (test seam)'
            }
            $ok = [Win32.Power]::PowerSetRequest($handle, $PowerRequestExecutionRequired)
            if (-not $ok) {
                [Win32.Power]::CloseHandle($handle) | Out-Null
                Write-KaLog 'POWER-REQUEST-DEGRADED' 'reason=set-request-failed -- continuing on ES_SYSTEM_REQUIRED alone'
            } else {
                $script:PowerRequestHandle = $handle
                Write-KaLog 'POWER-REQUEST-CREATED' ("handle=0x{0:X} type=PowerRequestExecutionRequired" -f $handle.ToInt64())
            }
        }
    } catch {
        if ($handle -ne [IntPtr]::Zero -and $handle.ToInt64() -ne -1) {
            # A real handle was created before the exception hit (thrown by
            # PowerSetRequest, or by the test seam above) -- close it here so
            # it is never left dangling; the `finally` block cannot reach it
            # because $script:PowerRequestHandle was never set.
            [Win32.Power]::CloseHandle($handle) | Out-Null
            Write-KaLog 'POWER-REQUEST-DEGRADED' ("reason=exception:{0} handle-closed=true -- continuing on ES_SYSTEM_REQUIRED alone" -f $_.Exception.Message)
        } else {
            Write-KaLog 'POWER-REQUEST-DEGRADED' ("reason=exception:{0} -- continuing on ES_SYSTEM_REQUIRED alone" -f $_.Exception.Message)
        }
    }
}

# Guard against a caller passing nonsense. -LeaseSeconds 0 is NOT nonsense: the
# param comment and the header have always said it means "no lease, hold until
# killed". This clamp used to turn 0 into 60 unconditionally, so the launcher's
# dashboard holder (which passed no lease and never refreshes) silently released
# after about a minute while KeepAwake.pm still reported it running (Decision 15).
# Only a positive lease below 60 is raised to 60 here; a negative one is 0. What
# 0 finally means depends on whether an owner is verified -- see LEASE-FALLBACK.
if ($LeaseSeconds -lt 0)    { $LeaseSeconds = 0 }
if ($LeaseSeconds -gt 0 -and $LeaseSeconds -lt 60) { $LeaseSeconds = 60 }
if ($PollSeconds  -lt 5)    { $PollSeconds  = 5 }
if ($LeaseSeconds -gt 0 -and $PollSeconds -gt $LeaseSeconds) { $PollSeconds = $LeaseSeconds }
if ($OwnerWinPid  -lt 0)    { $OwnerWinPid  = 0 }
if ($OwnerStartTicks -lt 0) { $OwnerStartTicks = 0 }

# One log line per event: an exception message can be multi-line (and localised).
function ConvertTo-KaOneLine {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '\r?\n', ' ') -replace '\s+', ' ').Trim()
}

# QUIET IS NOT GONE (package 02, Decision 3). The SUSPEND-DETECTED grace in the
# lease loop below covers "the whole machine froze", not "the owner is throttled
# while we keep running" -- and since we hold PowerRequestExecutionRequired, we
# are exactly the process that keeps polling while the owner is moderated. So a
# caller may name its owner with -OwnerWinPid, a WINDOWS pid (never an MSYS pid:
# the $$ of Git-for-Windows perl is a different namespace). We pin that process
# by holding a handle to it, which makes pid reuse impossible AFTER the pin --
# but not BEFORE it. Between the real owner dying and us reaching this block,
# Windows can hand the same WINPID to an unrelated process that also happens
# to have started before us, and the pre-existing started-after-helper
# heuristic alone would accept it as the owner. A caller that also knows the
# owner's own start time can close that gap by passing -OwnerStartTicks: an
# exact mismatch at pin time is rejected (OWNER-UNVERIFIABLE reason=start-
# time-mismatch) instead of silently pinning an impostor. Get-OwnerState
# below re-checks the same identity at every probe (OWNER-REPLACED) as
# defence in depth, in case a future change ever drops the handle pin. Once
# pinned, we ask the handle whether it has exited: still running means QUIET
# (hold), exited means GONE (release now). The probe is an in-process handle
# query; it spawns nothing. If the owner cannot be pinned, owner mode is off
# for good.
#
# Pinned here, after the pid file is written and before either wait loop, so the
# no-pid-file path honours the owner too.
# [long] UTC FILETIME ticks of $Process's start time. The ONE place the helper
# reads an owner's start time (pin and probe both call it). Test seam: when
# -SimulateOwnerStartTicksFile names an existing file whose first line,
# trimmed, is all digits, that number is returned instead. A missing file or
# a non-numeric first line means the real value is returned. Does not catch:
# a read error throws to the caller.
function Get-KaOwnerStartTicks {
    param([System.Diagnostics.Process]$Process)
    if ($SimulateOwnerStartTicksFile -and (Test-Path -LiteralPath $SimulateOwnerStartTicksFile)) {
        $raw = Get-Content -LiteralPath $SimulateOwnerStartTicksFile -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $raw -and "$raw".Trim() -match '^\d+$') { return [long]("$raw".Trim()) }
    }
    return [long]$Process.StartTime.ToFileTimeUtc()
}

$script:Owner = $null
$script:PinnedOwnerStartTicks = [long]0
$requestedNoLease = ($LeaseSeconds -eq 0)
if ($requestedNoLease) {
    $unverifiedTail = '-- no verified owner, so lease 0 falls back to the 60s lease'
} else {
    $unverifiedTail = '-- lease falls back to heartbeat only'
}
if ($OwnerWinPid -gt 0) {
    try {
        $p = [System.Diagnostics.Process]::GetProcessById($OwnerWinPid)
        # Reading .Handle opens AND CACHES the process handle for the life of
        # this object -- that is the pin. HasExited alone opens and closes a
        # fresh handle per call, which pins nothing.
        $null       = $p.Handle
        $exited     = $p.HasExited
        $started    = $p.StartTime                                   # kept, used only for the OWNER line's display
        $startTicks = Get-KaOwnerStartTicks $p                       # seam
        $selfStartTicks = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()  # never via seam
        if ($exited) {
            Write-KaLog 'OWNER-UNVERIFIABLE' ("winpid={0} reason=exited-at-start {1}" -f $OwnerWinPid, $unverifiedTail)
            try { $p.Dispose() } catch {}
        } elseif ($OwnerStartTicks -gt 0 -and $startTicks -ne $OwnerStartTicks) {
            # The caller supplied an anchor and the process found at this
            # WINPID does not match it -- either the WINPID was reused
            # between the owner dying and this pin (the real race this
            # package fixes), or a test seam is simulating exactly that.
            # Reject rather than silently pinning an impostor.
            Write-KaLog 'OWNER-UNVERIFIABLE' ("winpid={0} reason=start-time-mismatch expected={1} actual={2} {3}" -f $OwnerWinPid, $OwnerStartTicks, $startTicks, $unverifiedTail)
            try { $p.Dispose() } catch {}
        } elseif ($startTicks -gt $selfStartTicks) {
            # A process that began after us cannot be the one that spawned us:
            # the pid was reused.
            Write-KaLog 'OWNER-UNVERIFIABLE' ("winpid={0} reason=started-after-helper {1}" -f $OwnerWinPid, $unverifiedTail)
            try { $p.Dispose() } catch {}
        } else {
            $script:Owner = $p
            $script:PinnedOwnerStartTicks = $startTicks
            Write-KaLog 'OWNER' ("winpid={0} name={1} started={2}" -f $OwnerWinPid, $p.ProcessName, $started.ToString('yyyy-MM-dd HH:mm:ss'))
        }
    } catch {
        Write-KaLog 'OWNER-UNVERIFIABLE' ("winpid={0} reason={1} {2}" -f $OwnerWinPid, (ConvertTo-KaOneLine $_.Exception.Message), $unverifiedTail)
        $script:Owner = $null
    }
}

# NO HELPER HOLDS FOREVER UNOWNED (Decision 16). "Hold until killed" is only safe
# while something is certain to end us, and a hard-killed caller (WSL VM kill,
# forced restart, a window closed without teardown) is certain of nothing --
# that is the orphan the lease was introduced to end. So lease 0 means "hold
# until killed, until the pid file is removed, or until the owner is gone" ONLY
# with a verified owner. Without one (no -OwnerWinPid, or it could not be
# pinned) it falls back to the pre-02 behaviour: a 60s lease.
if ($requestedNoLease -and -not $script:Owner) {
    $LeaseSeconds = 60
    if ($PollSeconds -gt $LeaseSeconds) { $PollSeconds = $LeaseSeconds }
    Write-KaLog 'LEASE-FALLBACK' ("requested lease=0s but no verified owner -- using lease={0}s so an unowned helper cannot hold forever" -f $LeaseSeconds)
}

# 'alive' | 'gone' | 'unknown'. Never throws; a failed probe is 'unknown', which
# falls back to the heartbeat-only rule for that poll.
function Get-OwnerState {
    if (-not $script:Owner) { return 'unknown' }
    try {
        $script:Owner.Refresh()
        if ($script:Owner.HasExited) { return 'gone' }
        $probeTicks = Get-KaOwnerStartTicks $script:Owner                     # seam, defence in depth
        if ($probeTicks -ne $script:PinnedOwnerStartTicks) {
            Write-KaLog 'OWNER-REPLACED' ("winpid={0} pinned_start={1} probed_start={2} -- start time changed since pin, treating owner as gone" -f $OwnerWinPid, $script:PinnedOwnerStartTicks, $probeTicks)
            return 'gone'
        }
        return 'alive'
    } catch {
        Write-KaLog 'OWNER-PROBE-FAILED' ("owner={0} reason={1}" -f $OwnerWinPid, (ConvertTo-KaOneLine $_.Exception.Message))
        return 'unknown'
    }
}

try {
    if (-not $PidFile) {
        # No heartbeat file to watch: fall back to the old behaviour rather than
        # exiting immediately, but still bound it. A caller with no pid file
        # cannot reap us by pid either. With a positive lease the bound is the
        # lease; with lease 0 (only reachable here with a verified owner, see
        # LEASE-FALLBACK above) it is the owner's lifetime. Either way a verified
        # owner that exits ends us at the next poll.
        $deadline = $null
        if ($LeaseSeconds -gt 0) { $deadline = (Get-Date).AddSeconds($LeaseSeconds) }
        while (($null -eq $deadline) -or ((Get-Date) -lt $deadline)) {
            Start-Sleep -Seconds $PollSeconds
            if ((Get-OwnerState) -eq 'gone') {
                Write-KaLog 'RELEASE' ("reason=owner-gone lease={0}s owner={1}" -f $LeaseSeconds, $OwnerWinPid)
                break
            }
        }
    }
    else {
        # A SUSPENDED OWNER IS NOT AN ABSENT OWNER. Added 2026-09-17 after this
        # lock dropped during an eight-hour unattended run.
        #
        # The lease asks "has anyone touched the pid file recently", and treats
        # no as "nobody still wants the lock". Under Modern Standby that
        # inference is wrong: Desktop Activity Moderation suspends the owner, the
        # owner cannot touch anything while suspended, and this loop then
        # concludes it was abandoned and EXITS -- dropping the wake-lock at
        # exactly the moment the machine is going under. Standby throttles the
        # owner, the lease expires, the lock drops, the machine sleeps properly.
        # Self-reinforcing, and measured: three hours of silence starting 09:00.
        #
        # Without an owner identity we cannot ask the owner whether it is alive
        # -- the pid file holds OUR pid, not theirs. But we can notice that WE
        # were suspended: a Start-Sleep that was asked for $PollSeconds and took
        # very much longer means wall time passed that no process on this
        # machine was running through. The owner could not have heartbeated
        # during it, so that interval is not evidence of anything.
        #
        # On detecting it, grant ONE further lease period from the moment of
        # waking. Bounded on purpose: a genuinely dead owner still releases the
        # lock, just one lease later. The alternative -- forgiving the whole
        # suspended interval -- grows without limit across repeated sleeps, which
        # is how an orphan comes to hold a machine awake indefinitely, the exact
        # failure the lease was introduced to end. With a verified owner the
        # probe decides instead (HOLD-QUIET / owner-gone; see the pinning block
        # above the try), and GRACE is only the fallback for a probe that failed.
        Write-KaLog 'WATCH' ("effective lease={0}s poll={1}s" -f $LeaseSeconds, $PollSeconds)
        $resumeGraceUntil = $null
        while ($true) {
            $before = Get-Date
            Start-Sleep -Seconds $PollSeconds
            $actualSleep = ((Get-Date) - $before).TotalSeconds

            # 3x the requested sleep plus 30s of slack: scheduler jitter and a
            # loaded host never reach it; a suspend passes it by orders of
            # magnitude (186 and 204 minutes, measured).
            if ($actualSleep -gt (($PollSeconds * 3) + 30)) {
                # This line is the direct evidence that THIS PROCESS was frozen:
                # a sleep asked for $PollSeconds that took orders of magnitude
                # longer. Paired with a Kernel-Power 506/507 it shows the machine
                # went under WHILE the lock was asserted -- story (a).
                Write-KaLog 'SUSPEND-DETECTED' ("slept={0:N0}s requested={1}s grace={2}" -f $actualSleep, $PollSeconds, $(if ($LeaseSeconds -gt 0) { "$($LeaseSeconds)s" } else { 'n/a (no lease; the owner probe decides)' }))
                if ($LeaseSeconds -gt 0) { $resumeGraceUntil = (Get-Date).AddSeconds($LeaseSeconds) }
            }

            # Released deliberately: the file is our reason to exist.
            if (-not (Test-Path -LiteralPath $PidFile)) {
                Write-KaLog 'RELEASE' 'reason=pidfile-gone (deliberate release)'
                break
            }

            # Lease expired: nobody has touched it, so nobody still wants the
            # lock. Do not keep the machine awake on behalf of a dead run.
            try {
                $age = ((Get-Date) - (Get-Item -LiteralPath $PidFile).LastWriteTime).TotalSeconds
                if ($LeaseSeconds -eq 0) {
                    # No lease: the heartbeat never expires. Reachable only with
                    # a verified owner (LEASE-FALLBACK turns an unowned 0 into
                    # 60s), so the ends are the pid file going away (above),
                    # being killed, or that owner exiting.
                    if ((Get-OwnerState) -eq 'gone') {
                        Write-KaLog 'RELEASE' ("reason=owner-gone age={0:N0}s lease={1}s owner={2}" -f $age, $LeaseSeconds, $OwnerWinPid)
                        break
                    }
                    Write-KaLog 'HOLD' ("heartbeat_age={0:N0}s slept={1:N0}s" -f $age, $actualSleep)
                    continue
                }
                if ($age -gt $LeaseSeconds) {
                    # Stale heartbeat. With a pinned owner, silence alone is
                    # not evidence of absence: ask whether it has exited.
                    $ownerState = Get-OwnerState
                    if ($ownerState -eq 'alive') {
                        Write-KaLog 'HOLD-QUIET' ("heartbeat_age={0:N0}s lease={1}s owner={2} -- owner alive, holding" -f $age, $LeaseSeconds, $OwnerWinPid)
                        continue
                    }
                    if ($ownerState -eq 'gone') {
                        Write-KaLog 'RELEASE' ("reason=owner-gone age={0:N0}s lease={1}s owner={2}" -f $age, $LeaseSeconds, $OwnerWinPid)
                        break
                    }
                    if ($resumeGraceUntil -and (Get-Date) -lt $resumeGraceUntil) {
                        Write-KaLog 'GRACE' ("lease expired (age={0:N0}s) but a suspend was seen -- holding" -f $age)
                        continue
                    }
                    # THE OTHER STORY, (b): the lock is about to stop being
                    # asserted because nobody refreshed the heartbeat. A 506 after
                    # this line is a machine sleeping with NO request held, which
                    # says nothing about whether ES_SYSTEM_REQUIRED works.
                    Write-KaLog 'RELEASE' ("reason=lease-expired age={0:N0}s lease={1}s" -f $age, $LeaseSeconds)
                    break
                }
                # The steady state, and the line that makes absence meaningful: a
                # gap in HOLD lines is itself evidence, so they must be emitted
                # unconditionally rather than only when something changes.
                Write-KaLog 'HOLD' ("heartbeat_age={0:N0}s slept={1:N0}s" -f $age, $actualSleep)
            }
            catch {
                # Unreadable/vanished between the two calls -- treat as released.
                Write-KaLog 'RELEASE' 'reason=pidfile-unreadable'
                break
            }
        }
    }
}
finally {
    # ES_CONTINUOUS is bound to this thread, so process exit IS the release. This
    # is the last moment the lock is asserted, and the log has to say so -- an
    # entry that just stops with no EXIT line means the process was KILLED rather
    # than having released, which is a third story again.
    if ($script:PowerRequestHandle) {
        try {
            [Win32.Power]::PowerClearRequest($script:PowerRequestHandle, $PowerRequestExecutionRequired) | Out-Null
            [Win32.Power]::CloseHandle($script:PowerRequestHandle) | Out-Null
            Write-KaLog 'POWER-REQUEST-RELEASED' 'handle cleared and closed'
        } catch {}
    }
    if ($script:Owner) { try { $script:Owner.Dispose() } catch {} }
    Write-KaLog 'EXIT' 'wake-lock released (process exiting)'
    # The delete cmdlet used below, with -LiteralPath, fails on PowerShell 5.1
    # against an 8.3 short-name path (measured: "An object at the specified
    # path C:\Users\ANDR~1 does not exist." for a file under $env:TEMP, which
    # Windows hands out in short form), leaving a stale pid file behind.
    # Test-Path/Get-Item resolve it fine, so fall back to a direct .NET delete
    # whenever the file survived the cmdlet.
    if ($PidFile) {
        # IDENTITY-CHECKED (package 04): delete only if the file still names US.
        # A replace() (bp-keepawake.pl) overwrites this file with a successor's
        # pid before killing this process; without this check, this process's
        # own cleanup on exit would delete the SUCCESSOR's pid file.
        $ownsPidFile = $false
        try {
            if (Test-Path -LiteralPath $PidFile) {
                $curContent = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($curContent -and $curContent.Trim() -eq "$PID") { $ownsPidFile = $true }
            }
        } catch {}
        if ($ownsPidFile) {
            try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {}
            try {
                if (Test-Path -LiteralPath $PidFile) { [System.IO.File]::Delete($PidFile) }
            } catch {}
        }
    }
}
