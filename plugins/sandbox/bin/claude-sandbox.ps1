# claude-sandbox.ps1 -- thin shim. All launcher logic lives in
# ~/.claude/ccpraxis/plugins/sandbox/scripts/launcher.pl. This file only
# locates perl + the script, then invokes it with passthrough args.

# Locate perl from PowerShell (its PATH typically lacks Git Bash's perl). The
# resolver is shared with claude-beacon.ps1 — single source of truth, dot-sourced
# from scripts/_perl-path.ps1 — so the two launchers can't drift apart.
$perlPathLib = "$env:USERPROFILE\.claude\ccpraxis\scripts\_perl-path.ps1"
if (-not (Test-Path $perlPathLib)) {
    Write-Host "ERROR: $perlPathLib not found. Re-run the ccpraxis installer (perl ~\.claude\ccpraxis\install.pl --confirm)." -ForegroundColor Red
    exit 1
}
. $perlPathLib

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
