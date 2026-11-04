#!/usr/bin/env perl
# platform: windows
#
# ps-analysis-cache-pinned.t -- todo 20261104-035939-482d0000: a stray
# Microsoft/Windows/PowerShell/ModuleAnalysisCache kept appearing at the repo
# root during test runs.
#
# Windows PowerShell 5.1 writes its module-analysis cache under the
# LocalApplicationData known folder, which it expands from %USERPROFILE%. When
# $USERPROFILE/AppData/Local does not exist (every harness that hands a child a
# throwaway home), the folder resolves to "" and the cache path comes out
# RELATIVE -- written into the powershell's cwd, on a timer about ten seconds
# after the first module load. So only a powershell that lives that long
# leaves the stray; the long-lived keep-awake helper was the one that did.
#
# BpKeepAwake::pin_ps_analysis_cache() sets PSModuleAnalysisCachePath to an
# absolute directory exactly when PowerShell's own fallback would be broken.
# PART 1 unit-tests that decision. PART 2 spawns real ~14 s powershells from
# throwaway cwds under a throwaway USERPROFILE: an UNPINNED control (which
# must leave the stray, or PART 2 proves nothing on this host), one through
# BpPowerJournal::run_bounded and one through BpContinuityLease::_run_detached
# (both must not).
#
# ISOLATION: CCPRAXIS_NO_WAKELOCK=1 at BEGIN. Nothing here calls spawn() or
# any wake-lock actuator; the powershells started only sleep and exit.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(getcwd);
use POSIX ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

plan skip_all => 'Windows PowerShell module-analysis cache behaviour; Windows only'
    unless $^O =~ /^(MSWin32|msys|cygwin)$/;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
require "$S/bp-keepawake.pl" unless defined &BpKeepAwake::spawn;   # BpContinuityLease loads it already
require "$S/BpPowerJournal.pm" unless defined &BpPowerJournal::run_bounded;

my $ABS_WIN = qr{\A(?:[A-Za-z]:[\\/]|[\\/]{2})};
my $HAVE_PIN = defined &BpKeepAwake::pin_ps_analysis_cache;
ok($HAVE_PIN, 'BpKeepAwake::pin_ps_analysis_cache exists');

sub PIN { return $HAVE_PIN ? scalar eval { BpKeepAwake::pin_ps_analysis_cache() } : undef }
sub W   { my ($p) = @_; my $w = BpKeepAwake::_winify_translate($p); $w =~ s{\\}{/}g; $w }

my $ROOT = tempdir('ps-pin-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ROOT_W = W($ROOT);
like($ROOT_W, $ABS_WIN, "fixture root translates to drive-letter form ($ROOT_W)");

my $REAL_HOME  = "$ROOT/home-real";   make_path("$REAL_HOME/AppData/Local");
my $THROW_HOME = "$ROOT/home-throw";  make_path($THROW_HOME);
my $TEMP_A     = "$ROOT/temp-a";      make_path($TEMP_A);
my $ORIG_CWD   = getcwd();

# ---------------------------------------------------------------- PART 1 ---
{
    local %ENV = %ENV;
    $ENV{USERPROFILE} = W($REAL_HOME);
    delete $ENV{PSModuleAnalysisCachePath};
    is(PIN(), undef, 'U1: unset, USERPROFILE has AppData/Local -> nothing pinned');
    ok(!exists $ENV{PSModuleAnalysisCachePath}, 'U1: ...and the variable stays unset');
}
for my $v ('C:/x/ModuleAnalysisCache', 'D:\\y\\ModuleAnalysisCache', '//srv/share/ModuleAnalysisCache') {
    local %ENV = %ENV;
    $ENV{USERPROFILE} = W($THROW_HOME);
    $ENV{PSModuleAnalysisCachePath} = $v;
    is(PIN(), undef, "U2: already absolute ($v) -> left alone");
    is($ENV{PSModuleAnalysisCachePath}, $v, 'U2: ...value unchanged');
}
for my $empty (0, 1) {
    local %ENV = %ENV;
    $ENV{USERPROFILE} = W($THROW_HOME);
    $ENV{TEMP} = W($TEMP_A);
    if ($empty) { $ENV{PSModuleAnalysisCachePath} = '' } else { delete $ENV{PSModuleAnalysisCachePath} }
    my $tag = $empty ? 'empty' : 'unset';
    my $got = PIN();
    my $want = W($TEMP_A) . '/ccpraxis-ps-analysis-cache/ModuleAnalysisCache';
    is($got, $want, "U3: $tag + throwaway USERPROFILE -> pinned under TEMP");
    is($ENV{PSModuleAnalysisCachePath}, $want, "U3: $tag: ...and exported in %ENV");
    ok(-d "$TEMP_A/ccpraxis-ps-analysis-cache", "U3: $tag: ...and its parent directory exists");
}
{
    local %ENV = %ENV;
    $ENV{USERPROFILE} = W($REAL_HOME);           # a real profile does not save a relative value
    $ENV{TEMP} = W($TEMP_A);
    $ENV{PSModuleAnalysisCachePath} = 'rel/ModuleAnalysisCache';
    is(PIN(), W($TEMP_A) . '/ccpraxis-ps-analysis-cache/ModuleAnalysisCache',
       'U4: a RELATIVE value is replaced even under a real profile');
}
{
    local %ENV = %ENV;
    $ENV{USERPROFILE} = W($THROW_HOME);
    $ENV{PSModuleAnalysisCachePath} = "$ROOT/posix/ModuleAnalysisCache";
    my $got = PIN();
    is($got, "$ROOT_W/posix/ModuleAnalysisCache", 'U5: a POSIX-absolute value is rewritten to drive-letter form');
}
{
    # TEMP/TMP relative -- and existing relative to cwd, so only the
    # absoluteness check can reject them -- falls through to LOCALAPPDATA\Temp.
    local %ENV = %ENV;
    my $cwd = "$ROOT/cwd-u6"; make_path("$cwd/reltemp");
    my $lad = "$ROOT/lad";    make_path("$lad/Temp");
    chdir $cwd or die "chdir $cwd: $!";
    $ENV{USERPROFILE} = W($THROW_HOME);
    delete $ENV{PSModuleAnalysisCachePath};
    $ENV{TEMP} = 'reltemp';
    $ENV{TMP}  = 'reltemp';
    $ENV{LOCALAPPDATA} = W($lad);
    my $got = PIN();
    chdir $ORIG_CWD;
    is($got, W($lad) . '/Temp/ccpraxis-ps-analysis-cache/ModuleAnalysisCache',
       'U6: relative TEMP/TMP are never used; LOCALAPPDATA\\Temp is next');
    ok(!-e "$cwd/reltemp/ccpraxis-ps-analysis-cache", 'U6: ...and nothing was created under the relative TEMP');
}
{
    # No TEMP/TMP/LOCALAPPDATA/SYSTEMROOT at all: File::Spec->tmpdir() (MSYS
    # form, via TMPDIR) is translated, never passed through as /tmp/...
    local %ENV = %ENV;
    $ENV{USERPROFILE} = W($THROW_HOME);
    delete $ENV{$_} for qw(PSModuleAnalysisCachePath TEMP TMP LOCALAPPDATA SYSTEMROOT);
    my $td = "$ROOT/tmpdir"; make_path($td);
    $ENV{TMPDIR} = $td;
    my $got = PIN();
    like($got // '', $ABS_WIN, 'U7: last-resort tmpdir is still absolute drive-letter form');
    like($got // '', qr{/ccpraxis-ps-analysis-cache/ModuleAnalysisCache\z}, 'U7: ...under the shared cache dir');
}

# ---------------------------------------------------------------- PART 2 ---
# Three ~14 s powershells, concurrently: unpinned control, run_bounded,
# _run_detached. Each gets its own throwaway cwd.
SKIP: {
    my $ps_ok = eval { BpKeepAwake::ps_available() };
    skip 'powershell.exe not available', 6 unless $ps_ok;

    local %ENV = %ENV;
    $ENV{USERPROFILE} = W($THROW_HOME);
    $ENV{HOME}        = $THROW_HOME;
    $ENV{TEMP} = $ENV{TMP} = W($TEMP_A);
    delete $ENV{PSModuleAnalysisCachePath};

    my $script = q{Get-CimInstance Win32_OperatingSystem | Out-Null; try { Nope-Cmd } catch {}; Start-Sleep 14; }
               . q{Write-Output ('CACHE=' + $env:PSModuleAnalysisCachePath); Write-Output $PID};
    my @argv = ('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $script);
    my @argv_pid = (@argv[0 .. 3], q{Get-CimInstance Win32_OperatingSystem | Out-Null; try { Nope-Cmd } catch {}; Start-Sleep 14; Write-Output $PID});

    my %cwd = map { $_ => "$ROOT/cwd-$_" } qw(control bounded detached);
    make_path(values %cwd);

    # Unpinned control: a plain fork+exec, nothing in between.
    my $ctl = fork();
    die "fork: $!" unless defined $ctl;
    if ($ctl == 0) {
        chdir $cwd{control} or POSIX::_exit(126);
        open(STDIN, '<', '/dev/null'); open(STDOUT, '>', '/dev/null'); open(STDERR, '>', '/dev/null');
        { local $ENV{MSYS2_ARG_CONV_EXCL} = '*'; exec(@argv) or POSIX::_exit(127); }
    }
    # _run_detached in its own child (it blocks on the powershell's output).
    my $det = fork();
    die "fork: $!" unless defined $det;
    if ($det == 0) {
        chdir $cwd{detached} or POSIX::_exit(126);
        my $r = eval { BpContinuityLease::_run_detached(\@argv_pid) };
        POSIX::_exit(defined $r ? 0 : 1);
    }
    chdir $cwd{bounded} or die "chdir: $!";
    my $res = eval { BpPowerJournal::run_bounded(\@argv, 40) } || {};
    chdir $ORIG_CWD;
    waitpid($ctl, 0);
    waitpid($det, 0);
    my $det_rc = $? >> 8;

    ok(-d "$cwd{control}/Microsoft",
       'P0 control: an UNPINNED ~14 s powershell under this throwaway USERPROFILE leaves '
       . 'Microsoft/ in its cwd (otherwise this host does not reproduce and P1/P2 prove nothing)');
    is($res->{status} // '', 'ok', 'P1: run_bounded powershell ran to completion');
    my ($cache) = ($res->{out} // '') =~ /^CACHE=(.*?)\s*$/m;
    like($cache // '', $ABS_WIN, 'P1: ...and saw an absolute PSModuleAnalysisCachePath');
    ok(!-e "$cwd{bounded}/Microsoft", 'P1: ...and left no Microsoft/ in its cwd');
    is($det_rc, 0, 'P2: _run_detached powershell ran to completion and printed its pid');
    ok(!-e "$cwd{detached}/Microsoft", 'P2: ...and left no Microsoft/ in its cwd');
}

done_testing();
