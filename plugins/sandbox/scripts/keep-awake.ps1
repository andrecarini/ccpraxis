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
# We request ES_SYSTEM_REQUIRED + ES_DISPLAY_REQUIRED. ES_DISPLAY_REQUIRED is the
# load-bearing flag on Modern Standby (S0 Low Power Idle) machines: those systems
# enter "connected standby" when the display turns off, and ES_SYSTEM_REQUIRED
# alone does NOT hold them out of it (it targets the legacy S1-S3 idle timer,
# which Modern-Standby boxes don't even expose). A live display request keeps the
# machine in the S0 working state so an unattended run / auto-resume actually
# proceeds. The cost is the screen staying lit with no human watching -- accepted,
# because the alternative (what we hit in testing) is the host sleeping and the
# whole run dying. Caveats no software request can beat: closing the lid or the
# power button still forces standby, and battery power policy may override -- for
# a long unattended run, keep the machine on AC with the lid open.
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
# poll, and exit when either
#   * the pid file is GONE      -- someone released us deliberately, or
#   * it has not been touched within -LeaseSeconds -- nobody is left who wants it.
# Exiting drops the wake-lock automatically, because ES_CONTINUOUS is bound to
# this thread. Worst case an abandoned lock now costs one lease period, not "until
# the next reboot".
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
# lease. launcher.pl's dashboard holder does NOT refresh, so it passes none and
# keeps the previous hold-until-killed behaviour. Giving that path a refresher
# (its heartbeat loop is the obvious home) is what would let it opt in too --
# until then, do not "helpfully" default this to a finite value.
[CmdletBinding()]
param(
    [string]$PidFile,
    [int]$LeaseSeconds = 0,     # 0 = no lease (hold until killed)
    [int]$PollSeconds  = 60
)
$ErrorActionPreference = 'Stop'

if ($PidFile) {
    try { Set-Content -LiteralPath $PidFile -Value $PID -Encoding ascii -ErrorAction SilentlyContinue } catch {}
}

Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

# String->uint32 casts avoid PowerShell parsing 0x80000000 as a (signed) int.
$ES_CONTINUOUS       = [uint32]'0x80000000'
$ES_SYSTEM_REQUIRED  = [uint32]'0x00000001'
$ES_DISPLAY_REQUIRED = [uint32]'0x00000002'   # required to block S0 connected standby

$r = [Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
if ($r -eq 0) {
    Write-Error 'SetThreadExecutionState returned 0 (wake-lock not asserted)'
    exit 1
}

# Guard against a caller passing nonsense that would disable the lease entirely.
if ($LeaseSeconds -lt 60)   { $LeaseSeconds = 60 }
if ($PollSeconds  -lt 5)    { $PollSeconds  = 5 }
if ($PollSeconds  -gt $LeaseSeconds) { $PollSeconds = $LeaseSeconds }

try {
    if (-not $PidFile) {
        # No heartbeat file to watch: fall back to the old behaviour rather than
        # exiting immediately, but still cap it so it cannot outlive a session
        # by days. A caller with no pid file cannot reap us by pid either.
        $deadline = (Get-Date).AddSeconds($LeaseSeconds)
        while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds $PollSeconds }
    }
    else {
        while ($true) {
            Start-Sleep -Seconds $PollSeconds

            # Released deliberately: the file is our reason to exist.
            if (-not (Test-Path -LiteralPath $PidFile)) { break }

            # Lease expired: nobody has touched it, so nobody still wants the
            # lock. Do not keep the machine awake on behalf of a dead run.
            try {
                $age = ((Get-Date) - (Get-Item -LiteralPath $PidFile).LastWriteTime).TotalSeconds
                if ($age -gt $LeaseSeconds) { break }
            }
            catch {
                # Unreadable/vanished between the two calls -- treat as released.
                break
            }
        }
    }
}
finally {
    if ($PidFile) { try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {} }
}
