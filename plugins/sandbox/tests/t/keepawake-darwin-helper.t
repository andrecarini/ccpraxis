#!/usr/bin/env perl
# platform: any
# The macOS keep-awake helper (launcher.pl _keepawake_start_caffeinate), the
# liveness seam KeepAwake::held() consults on macOS (_keepawake_child_alive),
# and the one macOS assertion both wake-lock owners share (KeepAwake.pm).
#
# WHY. On macOS _keepawake_start used to fork and exec the Windows helper
# (powershell.exe), which does not exist there: the child died at exec, the
# holder kept its pid, and the dashboard reported a wake-lock as held while the
# Mac was free to sleep under a running fleet. Then the launcher and butler's
# managed wake-lock each built their own caffeinate and drifted (-i -s here,
# -i there). Now both run KeepAwake's holder, which follows the operator's
# rule (2026-10-30): `caffeinate -i -w <holder pid>` and nothing more, so a
# closed lid always sleeps the Mac, and only while the Mac is on AC power.
#
# HOW, WITHOUT A REAL WAKE-LOCK. launcher.pl is never require'd by a test (it
# is a top-level script with side effects), so the subs are sliced out of its
# source and eval'd into a scratch package -- the house technique, see
# launcher-console-liveness.t. KeepAwake.pm is loaded for real; its
# CCPRAXIS_CAFFEINATE_BIN seam points caffeinate at a stub that records its
# argv and sleeps, and the AC-loss watch's CCPRAXIS_AC_PROBE_FILE seam stands
# in for the power source, so the test checks the exact command line and the
# process lifecycle while never asserting a real power assertion.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(sleep time);

plan skip_all => 'fork/exec process lifecycle is not exercised on native Windows perl'
    if $^O eq 'MSWin32';

require "$Bin/../../scripts/KeepAwake.pm";

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $fh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read $LAUNCHER: $!");
my $SRC = do { local $/; <$fh> };
close $fh;

sub sub_text {
    my ($name, $src) = @_;
    $src //= $SRC;
    my ($text) = $src =~ /(\nsub\s+\Q$name\E\s*\{.*?\n\}\n)/s;
    return $text;
}

my $start  = sub_text('_keepawake_start_caffeinate');
my $alive  = sub_text('_keepawake_child_alive');
my $entry  = sub_text('_keepawake_start');
my $assert = sub_text('_keepawake_asserting');
ok(defined $start,  'launcher.pl defines _keepawake_start_caffeinate');
ok(defined $alive,  'launcher.pl defines _keepawake_child_alive');
ok(defined $entry,  'launcher.pl defines _keepawake_start');
ok(defined $assert, 'launcher.pl defines _keepawake_asserting');
BAIL_OUT('cannot slice the subs under test') unless defined $start && defined $alive && defined $entry && defined $assert;

# ---- source-level contract --------------------------------------------------
like($start, qr/my \$bin = KeepAwake::caffeinate_bin\(\);/, 'the helper binary comes from KeepAwake::caffeinate_bin');
like($start, qr/KeepAwake::holder_argv\(pid_file => \$pidfile,.*?lease => 0, owner_pid => \$owner\)/s,
    'the launcher runs KeepAwake\'s holder, owned by itself, with no lease (the dashboard stops it)');
like($start, qr/exec\(\@argv\)/, 'exec\'d as a list, no shell');
unlike($start, qr{/usr/bin/caffeinate|'-[isdumwt]'}, 'the launcher spells neither the binary path nor a caffeinate flag itself');
like($start, qr/my \$owner = \$\$;/, 'the owner is the launcher process itself');
like($start, qr/unless \(defined \$bin && -x \$bin\).*?return undef;.*?fork\(\)/s,
    'a missing caffeinate returns no handle BEFORE forking (no pid for a lock that never existed)');
like($entry, qr/return _keepawake_start_caffeinate\(\$pidfile\) if \$\^O eq 'darwin';/,
    '_keepawake_start dispatches darwin to the caffeinate helper');
like($entry, qr/unless \(\$WINDOWS_FAMILY\)\s*\{\s*log_ev\('keepawake_unsupported'.*?return undef;/s,
    'a host that is neither darwin nor Windows gets no helper at all (held() then reports 0)');
like($SRC, qr/alive => \\&_keepawake_child_alive/, 'the darwin holder is built with the alive seam');
like($SRC, qr/keepawake_held\s*=>\s*\(\$KEEPAWAKE && \$KEEPAWAKE->held && _keepawake_asserting\(\$ka_pidfile\)\)/,
    'the dashboard renders held() AND really asserted: a holder standing by on battery is not shown as held');

# ---- the one macOS assertion ------------------------------------------------
is_deeply([KeepAwake::caffeinate_argv('/bin/caf', 4242)], ['/bin/caf', '-i', '-w', '4242'],
    'KeepAwake::caffeinate_argv: -i -w <owner> only (no -s/-d/-u/-m: nothing that overrides a closed lid)');
is_deeply([KeepAwake::caffeinate_argv('/bin/caf', undef)], [], 'no owner pid: nothing to exec (an unowned assertion could be orphaned)');
is_deeply([KeepAwake::caffeinate_argv('/bin/caf', 0)],     [], 'owner pid 0: nothing to exec');
is_deeply([KeepAwake::caffeinate_argv(undef, 4242)],      [], 'no binary: nothing to exec');
{
    local $ENV{CCPRAXIS_CAFFEINATE_BIN} = '/some/fake';
    is(KeepAwake::caffeinate_bin(), '/some/fake', 'caffeinate_bin honours the CCPRAXIS_CAFFEINATE_BIN test seam');
}
{
    my @a = KeepAwake::holder_argv(pid_file => '/x/keepawake.pid', log_file => '/x/keepawake.log',
                                   lease => 0, owner_pid => 77);
    is_deeply([@a[2 .. $#a]], ['hold', '--pid-file', '/x/keepawake.pid', '--log-file', '/x/keepawake.log',
                               '--lease', 0, '--owner-pid', 77], 'holder_argv: perl KeepAwake.pm hold ...');
    like($a[1], qr{/KeepAwake\.pm\z}, 'holder_argv: runs this very module');
    is_deeply([KeepAwake::holder_argv(lease => 0)], [], 'holder_argv: no pid file, nothing to run');
}
# butler's managed wake-lock runs the SAME holder: its `hold` entry delegates
# to KeepAwake::hold_main and spells no caffeinate flag of its own.
{
    my $bpk = "$Bin/../../../butler/scripts/bp-keepawake.pl";
    open my $bh, '<:raw', $bpk or BAIL_OUT("cannot read $bpk: $!");
    my $bsrc = do { local $/; <$bh> };
    close $bh;
    my $hold = sub_text('hold_main', $bsrc);
    ok(defined $hold, 'bp-keepawake.pl defines hold_main');
    like($hold // '', qr/return KeepAwake::hold_main\(\@argv\);/, 'butler\'s holder IS KeepAwake::hold_main');
    unlike($bsrc, qr/'-[isdumwt]'/, 'bp-keepawake.pl spells no caffeinate flag anywhere');
    like($bsrc, qr{sandbox/scripts/KeepAwake\.pm}, 'bp-keepawake.pl loads the sandbox plugin\'s KeepAwake.pm');
}

# ---- behaviour: the launcher's helper, against a stub caffeinate -----------
my $dir  = tempdir(CLEANUP => 1);
my $stub = "$dir/fake-caffeinate";
my $argv_out = "$dir/argv";
open my $sf, '>', $stub or die "stub: $!";
print {$sf} "#!/bin/sh\necho \"\$*\" > '$argv_out'\nexec sleep 30\n";
close $sf;
chmod 0755, $stub;
$ENV{CCPRAXIS_CAFFEINATE_BIN} = $stub;
my $power = "$dir/power";
$ENV{CCPRAXIS_AC_PROBE_FILE} = $power;
sub set_power { open my $p, '>', $power or die $!; print {$p} "$_[0]\n"; close $p }
set_power('ac');
my $pidfile = "$dir/keepawake.pid";
my $logfile = "$dir/keepawake.log";

our @events;
my $code = "package KaDarwinSlice; use strict; use warnings;\n"
         . "sub log_ev { push \@main::events, [\@_] }\n"
         . $start . $alive . $assert . "1;\n";
my $ok = eval $code;
ok($ok, 'the sliced subs compile in isolation') or diag($@);

sub slurp { my ($p) = @_; open my $h, '<', $p or return ''; local $/; my $x = <$h>; close $h; $x // '' }
sub wait_for {
    my ($cond, $secs) = @_;
    my $end = time() + $secs;
    while (time() < $end) { return 1 if $cond->(); sleep 0.05 }
    return $cond->() ? 1 : 0;
}

SKIP: {
    skip 'slice did not compile', 12 unless $ok;
    my $pid = KaDarwinSlice::_keepawake_start_caffeinate($pidfile);
    ok(defined $pid && $pid > 0, 'start returns the holder child pid');
    ok(wait_for(sub { -s $argv_out }, 10), 'on AC the holder starts caffeinate');
    my $argv = slurp($argv_out);
    $argv =~ s/\s+\z//;
    is($argv, "-i -w $pid", 'caffeinate runs as -i -w <holder pid>: owned by the holder, which the launcher owns');
    ok(wait_for(sub { slurp($logfile) =~ /pid=$pid ASSERTED .*lease=0s owner=$$/ }, 5),
        'the holder logs ASSERTED, no lease, owner = the launcher');
    is(KaDarwinSlice::_keepawake_child_alive($pid), 1, 'a running holder reads alive');
    is(KaDarwinSlice::_keepawake_asserting($pidfile), 1, 'on AC the dashboard may say asserted');
    my ($started) = grep { $_->[0] eq 'keepawake_started' } @events;
    is($started && $started->[1]{helper}, 'caffeinate', 'keepawake_started is logged naming the helper');

    set_power('dc');
    ok(wait_for(sub { slurp($logfile) =~ /pid=$pid STANDBY reason=battery caffeinate-stopped=/ }, 6),
        'on battery the holder stops caffeinate (and keeps standing by)');
    if ($^O eq 'darwin') {
        is(KaDarwinSlice::_keepawake_asserting($pidfile), 0, 'on battery the dashboard does not render the lock as held');
    } else {
        pass('(only a darwin launcher consults the holder state)');
    }

    kill 'KILL', $pid;
    my $gone = 0;
    my $deadline = time() + 10;
    until ($gone || time() > $deadline) {
        $gone = KaDarwinSlice::_keepawake_child_alive($pid) ? 0 : 1;
        sleep 0.05 unless $gone;
    }
    ok($gone, 'a helper that exited reads not-alive (and is reaped by the probe)');
    is(KaDarwinSlice::_keepawake_child_alive(undef), 0, 'no pid reads not-alive');
    is(KaDarwinSlice::_keepawake_child_alive('x1'), 0, 'a non-numeric pid reads not-alive');
}

done_testing();
