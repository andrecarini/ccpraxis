# _perl-path.ps1 — single source of truth for locating perl from PowerShell.
#
# Dot-sourced by the ccpraxis .ps1 launchers (claude-sandbox.ps1,
# claude-beacon.ps1) so the resolver lives in ONE place, not copied per launcher.
# PowerShell's PATH typically does not include Git Bash's perl (usr\bin), so we
# search the usual install locations. This is the *bootstrap* resolver: it runs
# before / independently of the perl-on-PATH shim, so it must not depend on it.
#
# NOTE: the perl install hook (host-tools/ccpraxis-install.pl) does NOT use this
# — it resolves from $^X (the perl actually running the installer), which is
# authoritative and unavailable to PowerShell. Two methods for two runtime
# moments, by necessity; there is no shared candidate list to keep in sync.

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
    foreach ($candidate in @(
        "$env:ProgramFiles\Git\usr\bin\perl.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\perl.exe",
        'C:\Strawberry\perl\bin\perl.exe',
        'C:\Perl64\bin\perl.exe'
    )) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}
