# claude-beacon — TUI for selecting and resuming a beaconed Claude Code session.
# All logic lives in claude-beacon.pl; this script just locates the plugin and
# execs perl with the args forwarded.
#
# Locate perl from PowerShell. The resolver is shared with claude-sandbox.ps1 —
# single source of truth, dot-sourced from scripts/_perl-path.ps1 — so the two
# launchers can't drift apart.
$perlPathLib = "$env:USERPROFILE\.claude\ccpraxis\scripts\_perl-path.ps1"
if (-not (Test-Path $perlPathLib)) {
    Write-Host "ERROR: $perlPathLib not found. Re-run the ccpraxis installer (perl ~\.claude\ccpraxis\install.pl --confirm)." -ForegroundColor Red
    exit 1
}
. $perlPathLib

$PerlExe = Get-PerlPath
if (-not $PerlExe) {
    Write-Host "ERROR: perl not found. Install Git for Windows (which bundles perl) or add perl.exe to PATH." -ForegroundColor Red
    exit 1
}

$Script = "$env:USERPROFILE\.claude\ccpraxis\plugins\beacon\scripts\claude-beacon.pl"
if (-not (Test-Path $Script)) {
    Write-Host "ERROR: $Script is missing. Is the beacon plugin installed?" -ForegroundColor Red
    exit 1
}

& $PerlExe $Script @args
exit $LASTEXITCODE
