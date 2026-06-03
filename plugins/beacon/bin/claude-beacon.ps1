# claude-beacon — TUI for selecting and resuming a beaconed Claude Code session.
# All logic lives in claude-beacon.pl; this script just locates the plugin and
# execs perl with the args forwarded.
#
# Locate perl the same way claude-sandbox.ps1 does (Git for Windows ships one).
function Get-PerlPath {
    $cmd = Get-Command perl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitCmdDir = Split-Path $git.Source -Parent
        $gitRoot = Split-Path $gitCmdDir -Parent
        $candidate = Join-Path $gitRoot "usr\bin\perl.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    foreach ($candidate in @(
        "$env:ProgramFiles\Git\usr\bin\perl.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\perl.exe",
        "C:\Strawberry\perl\bin\perl.exe",
        "C:\Perl64\bin\perl.exe"
    )) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

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
