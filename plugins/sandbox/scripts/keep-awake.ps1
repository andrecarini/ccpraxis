# keep-awake.ps1 — hold a Windows wake-lock for as long as THIS process lives.
#
# Started/killed by the sandbox dashboard's keep-awake (B5, KeepAwake.pm), gated
# by the orchestrator's busy-lease: the dashboard spawns this only while there is
# active work or a pending auto-resume, and kills it when idle or only-parked.
#
# The host perl has no Win32::API, so we assert SetThreadExecutionState via
# P/Invoke from PowerShell. ES_CONTINUOUS ties the request to the calling thread,
# so the lock is released automatically the moment this process is killed — no
# explicit "undo" call is needed (which is exactly why we run it as a dedicated
# child whose lifetime == the wake-lock's lifetime).
#
# We request ES_SYSTEM_REQUIRED + ES_DISPLAY_REQUIRED. ES_DISPLAY_REQUIRED is the
# load-bearing flag on Modern Standby (S0 Low Power Idle) machines: those systems
# enter "connected standby" when the display turns off, and ES_SYSTEM_REQUIRED
# alone does NOT hold them out of it (it targets the legacy S1-S3 idle timer,
# which Modern-Standby boxes don't even expose). A live display request keeps the
# machine in the S0 working state so an unattended run / auto-resume actually
# proceeds. The cost is the screen staying lit with no human watching — accepted,
# because the alternative (what we hit in testing) is the host sleeping and the
# whole run dying. Caveats no software request can beat: closing the lid or the
# power button still forces standby, and battery power policy may override — for a
# long unattended run, keep the machine on AC with the lid open.
#
# -PidFile: write our own Windows PID here at startup (and remove it on exit) so a
# launcher that crashed while we were running can reap us (the orphaned wake-lock)
# on its next start via taskkill. The normal stop path kills our child PID
# directly and doesn't depend on this file.
[CmdletBinding()]
param([string]$PidFile)
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

# Block until killed. The wake-lock holds for the lifetime of this thread; the
# parent (the dashboard) kills this process to release it.
try {
    while ($true) { Start-Sleep -Seconds 3600 }
}
finally {
    if ($PidFile) { try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {} }
}
