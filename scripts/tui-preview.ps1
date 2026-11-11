# tui-preview.ps1 -- run scripts/tui-preview.pl from PowerShell / Windows
# Terminal the way claude-sandbox.ps1 runs launcher.pl.
#
#   wt new-tab -d C:\Development\ccpraxis powershell -NoExit -ExecutionPolicy Bypass -File scripts\tui-preview.ps1 --scenario fleet
#
# What it adds over a bare `perl scripts/tui-preview.pl`:
#   - perl is located with the same resolver the launchers use
#     (_perl-path.ps1), so a PowerShell PATH without Git's perl still works;
#   - colour is forced on when Windows Terminal is the host (WT_SESSION set):
#     Theme only turns colour on from TERM / COLORTERM / WT_SESSION /
#     CCPRAXIS_COLOR, and a tab started some other way may carry none of
#     them, which renders the preview monochrome;
#   - MSYS2 argument conversion is disabled, as claude-sandbox.ps1 does.
# Every argument is passed through (--scenario fleet, --dump WxH, ...), except
# --keylog <path>, which sets CCPRAXIS_KEYLOG (see below).

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$perlPathLib = Join-Path $here '_perl-path.ps1'
if (-not (Test-Path $perlPathLib)) {
    $perlPathLib = "$env:USERPROFILE\.claude\ccpraxis\scripts\_perl-path.ps1"
}
$perl = $null
if (Test-Path $perlPathLib) {
    . $perlPathLib
    $perl = Get-PerlPath
}
if (-not $perl) {
    Write-Host "ERROR: perl not found. Install Git for Windows (which bundles perl) or add perl.exe to PATH." -ForegroundColor Red
    exit 1
}

if ($env:WT_SESSION -and -not $env:CCPRAXIS_COLOR -and -not $env:NO_COLOR) {
    $env:CCPRAXIS_COLOR = 'truecolor'
}
$env:MSYS2_ARG_CONV_EXCL = '*'

# --keylog <path>: the raw key log (CCPRAXIS_KEYLOG). Every raw console read
# (hex, ms timestamps), every assembled key sequence and every key -> action
# is appended to <path>. A CCPRAXIS_KEYLOG already in the environment is
# passed through to perl unchanged.
$rest = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--keylog' -and $i + 1 -lt $args.Count) {
        $env:CCPRAXIS_KEYLOG = $args[$i + 1]
        $i++
    } else {
        $rest += $args[$i]
    }
}

& $perl (Join-Path $here 'tui-preview.pl') @rest
exit $LASTEXITCODE
