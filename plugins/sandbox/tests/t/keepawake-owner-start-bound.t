#!/usr/bin/env perl
# platform: any
#
# keep-awake.ps1 pins its owner by WINPID. If the owner dies between forking
# the helper and the helper's pin, Windows can hand that WINPID to an
# unrelated process, and the helper pins an impostor. Package 05 added an
# exact-start-time anchor (-OwnerStartTicks) but neither production caller
# passed it (todo 20261002-002528-33130000). Obtaining the exact start time
# needs a powershell.exe on the caller's spawn path, which was measured to
# break lease-refresher-hygiene.t's handover bounds under load, so the callers
# use -OwnerStartedBeforeTicks instead: their own clock, read in the parent
# before fork. A reused WINPID belongs to a process created after the owner
# died, so after that reading; the helper rejects it (started-after-spawn).
#
# This file pins:
#   1. BpKeepAwake::owner_started_before (pure)
#   2. both production callers (launcher.pl's start closure, via
#      BpKeepAwake::spawn; bp-keepawake.pl's own spawn) pass the bound,
#      computed before fork() -- static only, launcher.pl is never loaded
#   3. on Windows, a REAL helper: a current bound pins this process as owner;
#      a bound older than this process's own start is rejected with
#      reason=started-after-spawn. Each helper runs with a 60s lease and is
#      killed by this file (END + signals).
#
# 07-one-keepawake-helper, Decision 19 (spec section 7(1)): KeepAwake.pm's
# filetime_ticks is deleted by that package's DC2 and launcher.pl's own
# _keepawake_start (DC1) is deleted too, so every assertion here was moved
# onto BpKeepAwake -- see the per-section notes below for exactly what changed.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep time);
use FindBin qw($Bin);

$ENV{CCPRAXIS_NO_WAKELOCK} = 1;   # house opt-out; part 3 spawns the helper directly

my $SANDBOX_SCRIPTS = "$Bin/../../scripts";
my $BUTLER_SCRIPTS  = "$Bin/../../../butler/scripts";
my $SCRIPT          = "$SANDBOX_SCRIPTS/keep-awake.ps1";
unshift @INC, $SANDBOX_SCRIPTS;
require KeepAwake;
require "$BUTLER_SCRIPTS/bp-keepawake.pl";

sub slurp { my ($f) = @_; open(my $fh, '<:raw', $f) or return undef; local $/; my $s = <$fh>; close $fh; $s }

# ---------------------------------------------------------------- part 1: pure
#
# 07-one-keepawake-helper, Decision 19 / spec section 7(1): KeepAwake::filetime_ticks
# is deleted by that package's DC2, so every call here goes through
# BpKeepAwake::owner_started_before (self-owned: owner_winpid == self) instead of
# comparing against the sub that is about to disappear.
{
    is(BpKeepAwake::owner_started_before({ owner_winpid => 900 }, 900, 0), '116444736000000000',
       'owner_started_before(..,0) is the 1601->1970 offset');
    is(BpKeepAwake::owner_started_before({ owner_winpid => 900 }, 900, 1), '116444736010000000',
       'one second is 10^7 ticks');
    my $t = BpKeepAwake::owner_started_before({ owner_winpid => 900 }, 900, 1_792_674_309.5);
    ok(defined $t && abs($t - 134_371_479_095_000_000) < 1000, 'fractional seconds kept (to within a double\'s precision)')
        or diag($t // 'undef');
    # undef is deliberately NOT in this list: owner_started_before's own,
    # unchanged contract (spec 2.2: "no behaviour change") defaults an undef
    # $now to Time::HiRes::time() for the one-argument production call shape
    # -- it is not a refusal case, unlike every other malformed value here.
    for my $bad ('', -1, 'x', '1e9', [1]) {
        is(BpKeepAwake::owner_started_before({ owner_winpid => 900 }, 900, $bad), undef,
           "owner_started_before refuses a bad clock: '$bad'");
    }

    is(BpKeepAwake::owner_started_before({ owner_winpid => 900 }, 900, 0), '116444736000000000',
       'owner == self: our clock, as FILETIME');
    is(BpKeepAwake::owner_started_before({ owner_winpid => 900 }, 900, 1_000_000_000), '126444736000000000',
       'pinned literal (what filetime_ticks(1_000_000_000) computed, before its deletion)');
    is(BpKeepAwake::owner_started_before({ owner_winpid => 901 }, 900, 0), undef,
       'owner != self: no bound (our clock says nothing about a foreign pid)');
    is(BpKeepAwake::owner_started_before({}, 900, 0), undef, 'no owner -> no bound');
    is(BpKeepAwake::owner_started_before(undef), undef, 'undef owner -> undef');
    is(BpKeepAwake::owner_started_before({ owner_winpid => 900 }, 900, 'soon'), undef, 'bad clock -> undef');
}

# ---------------------------------------------------------------- part 2: both callers pass it, before fork
{
    my $ps1 = slurp($SCRIPT) // '';
    like($ps1, qr/\[long\]\$OwnerStartedBeforeTicks\s*=\s*0/, 'keep-awake.ps1 declares [long]$OwnerStartedBeforeTicks = 0');
    like($ps1, qr/reason=started-after-spawn/, 'keep-awake.ps1 logs the started-after-spawn rejection');
    ok($ps1 !~ /[^\x00-\x7f]/, 'keep-awake.ps1 stays pure ASCII');

    # package 08 (host-awake-actuator), Decision 23 (G2): the launcher owns no
    # helper of its own any more -- it PUBLISHES a registry entry (through
    # KeepAwake::registry_seams/HostAwake::publish) and the continuity
    # refresher daemon is the single remaining actuator that calls
    # BpKeepAwake::spawn. So launcher.pl must call BpKeepAwake::spawn( NOWHERE
    # (the owner-pinning it used to do inline no longer applies to it at
    # all), and the existing no--OwnerStartedBeforeTicks guard still holds.
    my $lsrc = slurp("$SANDBOX_SCRIPTS/launcher.pl") // '';
    ok(length($lsrc), 'launcher.pl is readable');
    unlike($lsrc, qr/BpKeepAwake::spawn\s*\(/,
        'launcher.pl no longer calls BpKeepAwake::spawn( anywhere (package 08: it owns no helper)');
    unlike($lsrc, qr/-OwnerStartedBeforeTicks/,
        "launcher.pl contains no '-OwnerStartedBeforeTicks' of its own -- the bound is now computed inside BpKeepAwake::spawn");

    my $bsrc = slurp("$BUTLER_SCRIPTS/bp-keepawake.pl") // '';
    my ($spawn) = $bsrc =~ /\nsub\s+spawn\s*\{(.*?)\n\}\n/s;
    ok(defined $spawn, 'bp-keepawake.pl has spawn');
    $spawn //= '';
    like($spawn, qr/'-OwnerStartedBeforeTicks'/, 'bp-keepawake spawn passes -OwnerStartedBeforeTicks');
    my $bb = $spawn =~ /owner_started_before\s*\(/ ? $-[0] : undef;
    my $bf = $spawn =~ /\bfork\s*\(/ ? $-[0] : undef;
    ok(defined $bb && defined $bf && $bb < $bf, 'bp-keepawake reads the bound before fork()');
    my ($osb) = $bsrc =~ /\nsub\s+owner_started_before\s*\{(.*?)\n\}\n/s;
    unlike($osb // '', qr/powershell|`/, 'owner_started_before spawns nothing');
}

# ---------------------------------------------------------------- part 3: a real helper agrees
SKIP: {
    skip 'real keep-awake.ps1 round trip is Windows-only', 6 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    skip "keep-awake.ps1 missing at $SCRIPT", 6 unless -f $SCRIPT;
    my $self = BpKeepAwake::self_winpid();
    skip 'cannot read /proc/$$/winpid', 6 unless defined $self;

    my $tmp = $ENV{TEMP} || $ENV{TMP} || 'C:/Windows/Temp';   # see keepawake-lease-liveness.t on /tmp
    my @helpers;   # [pidfile, winpid]
    my $kill_all = sub {
        for my $h (@helpers) {
            my $w = $h->[1];
            if (!defined $w && open(my $fh, '<', $h->[0])) { ($w) = (<$fh> // '') =~ /(\d+)/; close $fh }
            next unless defined $w && $w =~ /^\d+$/;
            local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
            system('taskkill', '/F', '/PID', $w);
        }
        @helpers = ();
    };
    local $SIG{INT}  = sub { $kill_all->(); exit 1 };
    local $SIG{TERM} = sub { $kill_all->(); exit 1 };
    END { $kill_all->() if $kill_all }

    my $run = sub {
        my ($bound) = @_;
        my $dir = tempdir(DIR => $tmp, CLEANUP => 1);
        my ($pidfile, $logfile) = ("$dir/keepawake.pid", "$dir/keepawake.log");
        push @helpers, [ $pidfile, undef ];
        open(my $fh, '-|', 'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
             '-File', $SCRIPT, '-PidFile', $pidfile, '-LogFile', $logfile,
             '-PollSeconds', 5, '-LeaseSeconds', 60,
             '-OwnerWinPid', $self, '-OwnerStartedBeforeTicks', $bound) or return '';
        my $log = '';
        my $deadline = time() + 60;
        while (time() < $deadline) {
            $log = slurp($logfile) // '';
            last if $log =~ /\bOWNER(?:-UNVERIFIABLE)?\b/;
            sleep 0.25;
        }
        $kill_all->();
        close $fh;
        return $log;
    };

    my $now_bound = BpKeepAwake::owner_started_before({ owner_winpid => $self });
    ok(defined $now_bound, 'production bound computed for ourselves');
    my $log = $run->($now_bound);
    like($log, qr/ OWNER winpid=\Q$self\E /, 'a current bound: the real helper pins us as owner');
    unlike($log, qr/OWNER-UNVERIFIABLE/, '...and does not call us unverifiable');

    # A bound an hour before now is earlier than this process's own start
    # (plus the 2s slack) -- exactly what a reused WINPID looks like.
    # 07-one-keepawake-helper, Decision 19: via BpKeepAwake::owner_started_before,
    # not the deleted KeepAwake::filetime_ticks.
    my $old_bound = BpKeepAwake::owner_started_before({ owner_winpid => $self }, $self, int(time()) - 3600);
    $log = $run->($old_bound);
    like($log, qr/OWNER-UNVERIFIABLE winpid=\Q$self\E reason=started-after-spawn/,
         'an owner created after the bound is rejected: started-after-spawn');
    unlike($log, qr/ OWNER winpid=/, '...and never pinned');
    ok(1, 'helpers were killed by this file');
}

done_testing();
