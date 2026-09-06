# ccpraxis.ps1 -- thin dispatcher shim for steward's host-side scripts.
#
# WHY THIS EXISTS. The skills that drive these scripts spell out a
# 70-character absolute path on every invocation:
#
#   perl ~/.claude/ccpraxis/plugins/steward/scripts/update-research.pl gather
#
# That works, and the skill file carries it so nothing is being remembered --
# but it is brittle prose. Any move of the tree edits every skill that names
# it, and a typo surfaces as "file not found" rather than anything
# diagnosable. One shim, one PATH entry, paths in exactly one place.
#
# ASCII ONLY, deliberately. The Write tool saves UTF-8 without a BOM and
# PowerShell 5.1 reads a BOM-less script as CP1252, so a character like an
# em dash decodes into stray bytes -- one of which (0x94) is a smart quote
# that PowerShell treats as a STRING DELIMITER. That opens a phantom string,
# swallows the following braces, and reports a missing brace far from the
# real line. Use -- and -> here, never the typographic forms.

# Locate perl from PowerShell (its PATH typically lacks Git Bash's perl). The
# resolver lives in _perl-path.ps1 -- single source of truth, dot-sourced --
# so the shims cannot drift apart.
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

$steward = "$env:USERPROFILE\.claude\ccpraxis\plugins\steward\scripts"

function Show-Usage {
    Write-Host "ccpraxis -- dispatcher for ccpraxis host-side tools"
    Write-Host ""
    Write-Host "  ccpraxis research     <args>   update-research.pl      (release research + store)"
    Write-Host "  ccpraxis vault-sync   <args>   vault-namespace-sync.pl (commit+push one vault namespace)"
    Write-Host "  ccpraxis usage-audit  <args>   usage-audit.pl          (token spend across transcripts)"
    Write-Host "  ccpraxis binary       <args>   claude-binary-backup.pl (binary snapshots / restore)"
    Write-Host "  ccpraxis sensitive    <args>   sensitive-check.pl      (secret scan)"
    Write-Host ""
    Write-Host "Anything after the subcommand is passed through unchanged."
    exit 2
}

if ($args.Count -lt 1) { Show-Usage }

$sub  = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }

switch ($sub) {
    'research'    { $script = "$steward\update-research.pl" }
    'vault-sync'  { $script = "$steward\vault-namespace-sync.pl" }
    'usage-audit' { $script = "$steward\usage-audit.pl" }
    'binary'      { $script = "$steward\claude-binary-backup.pl" }
    'sensitive'   { $script = "$steward\sensitive-check.pl" }
    'help'        { Show-Usage }
    '-h'          { Show-Usage }
    '--help'      { Show-Usage }
    default {
        Write-Host "ccpraxis: unknown subcommand '$sub'" -ForegroundColor Red
        Show-Usage
    }
}

if (-not (Test-Path $script)) {
    Write-Host "ERROR: $script not found." -ForegroundColor Red
    Write-Host "       Re-run the ccpraxis installer (perl ~\.claude\ccpraxis\install.pl --confirm)." -ForegroundColor Red
    exit 1
}

& $perl $script @rest
exit $LASTEXITCODE
