# claude-sandbox.ps1 -- thin shim. All launcher logic lives in
# ~/.claude/ccpraxis/plugins/sandbox/scripts/launcher.pl. This file only
# locates perl + the script, then invokes it with passthrough args.

# PowerShell PATH typically does not include Git Bash's perl, so search
# the usual install locations. Resolving here means a missing perl fails
# loudly rather than producing CommandNotFoundException later.
function Get-PerlPath {
    $cmd = Get-Command perl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitCmdDir = Split-Path $git.Source -Parent
        $gitRoot   = Split-Path $gitCmdDir -Parent
        $candidate = Join-Path $gitRoot 'usr\bin\perl.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    foreach ($p in @(
        "$env:ProgramFiles\Git\usr\bin\perl.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\perl.exe",
        'C:\Strawberry\perl\bin\perl.exe',
        'C:\Perl64\bin\perl.exe'
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

$perl = Get-PerlPath
if (-not $perl) {
    Write-Host "ERROR: perl not found. Install Git for Windows (which bundles perl) or add perl.exe to PATH." -ForegroundColor Red
    exit 1
}

$launcher = "$env:USERPROFILE\.claude\ccpraxis\plugins\sandbox\scripts\launcher.pl"
if (-not (Test-Path $launcher)) {
    Write-Host "ERROR: launcher.pl not found at $launcher" -ForegroundColor Red
    Write-Host "       Re-run the ccpraxis installer (perl ~\.claude\ccpraxis\install.pl --confirm)." -ForegroundColor Red
    exit 1
}

# Hard-disable MSYS2 argument-path conversion for the launcher process tree.
# MSYS2 silently mangles `podman -v HOST:CONTAINER` mount specs (splits on
# `:`, runs each side through POSIX->Windows conversion, re-joins with `;`)
# — podman then bind-mounts a `;C`-suffixed path, breaking onboarding /
# CLAUDE.md / settings.json mounts. launcher.pl also sets this internally,
# but doing it here means the guarantee survives even if someone edits the
# perl side. See global CLAUDE.md for the full failure mode.
$env:MSYS2_ARG_CONV_EXCL = '*'

& $perl $launcher @args
exit $LASTEXITCODE
