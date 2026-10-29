#!/usr/bin/env perl
# platform: any
# The macOS keep-awake helper (launcher.pl _keepawake_start_caffeinate) and
# the liveness seam KeepAwake::held() consults on macOS
# (_keepawake_child_alive).
#
# WHY. On macOS _keepawake_start used to fork and exec the Windows helper
# (powershell.exe), which does not exist there: the child died at exec, the
# holder kept its pid, and the dashboard reported a wake-lock as held while the
# Mac was free to sleep under a running fleet. The macOS helper is
# `caffeinate -i -s -w <launcher pid>`, which also exits by itself when the
# launcher does, so it cannot be orphaned.
#
# HOW, WITHOUT A REAL WAKE-LOCK. launcher.pl is never require'd by a test (it
# is a top-level script with side effects), so the two subs are sliced out of
# its source and eval'd into a scratch package -- the house technique, see
# launcher-console-liveness.t. The caffeinate path in the slice is replaced
# with a stub that records its argv and sleeps, so the test checks the exact
# command line and the process lifecycle while never asserting a real power
# assertion on the machine running it.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(sleep time);

plan skip_all => 'fork/exec process lifecycle is not exercised on native Windows perl'
    if $^O eq 'MSWin32';

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $fh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read $LAUNCHER: $!");
my $SRC = do { local $/; <$fh> };
close $fh;

sub sub_text {
    my ($name) = @_;
    my ($text) = $SRC =~ /(\nsub\s+\Q$name\E\s*\{.*?\n\}\n)/s;
    return $text;
}

my $start = sub_text('_keepawake_start_caffeinate');
my $alive = sub_text('_keepawake_child_alive');
my $entry = sub_text('_keepawake_start');
ok(defined $start, 'launcher.pl defines _keepawake_start_caffeinate');
ok(defined $alive, 'launcher.pl defines _keepawake_child_alive');
ok(defined $entry, 'launcher.pl defines _keepawake_start');
BAIL_OUT('cannot slice the subs under test') unless defined $start && defined $alive && defined $entry;

# ---- source-level contract --------------------------------------------------
like($start, qr{'/usr/bin/caffeinate'}, 'the helper is the system caffeinate, by absolute path');
like($start, qr/exec\(\$bin,\s*'-i',\s*'-s',\s*'-w',\s*\$owner\)/,
    'argv is exactly: -i -s -w <owner>');
like($start, qr/my \$owner = \$\$;/, 'the owner is the launcher process itself');
like($start, qr/unless \(-x \$bin\).*?return undef;.*?fork\(\)/s,
    'a missing caffeinate returns no handle BEFORE forking (no pid for a lock that never existed)');
like($entry, qr/return _keepawake_start_caffeinate\(\) if \$\^O eq 'darwin';/,
    '_keepawake_start dispatches darwin to the caffeinate helper');
like($entry, qr/unless \(\$WINDOWS_FAMILY\)\s*\{\s*log_ev\('keepawake_unsupported'.*?return undef;/s,
    'a host that is neither darwin nor Windows gets no helper at all (held() then reports 0)');
like($SRC, qr/alive => \\&_keepawake_child_alive/, 'the darwin holder is built with the alive seam');
like($SRC, qr/keepawake_held\s*=>\s*\(\$KEEPAWAKE && \$KEEPAWAKE->held\)/,
    'the dashboard renders held(), not running()');

# ---- behaviour, with a stub in caffeinate's place --------------------------
my $dir  = tempdir(CLEANUP => 1);
my $stub = "$dir/fake-caffeinate";
my $argv_out = "$dir/argv";
open my $sf, '>', $stub or die "stub: $!";
print {$sf} "#!/bin/sh\necho \"\$*\" > '$argv_out'\nexec sleep 30\n";
close $sf;
chmod 0755, $stub;

(my $start_stub = $start) =~ s{'/usr/bin/caffeinate'}{'$stub'};
our @events;
my $code = "package KaDarwinSlice; use strict; use warnings;\n"
         . "sub log_ev { push \@main::events, [\@_] }\n"
         . $start_stub . $alive . "1;\n";
my $ok = eval $code;
ok($ok, 'the sliced subs compile in isolation') or diag($@);

SKIP: {
    skip 'slice did not compile', 7 unless $ok;
    my $pid = KaDarwinSlice::_keepawake_start_caffeinate();
    ok(defined $pid && $pid > 0, 'start returns the helper child pid');
    my $deadline = time() + 10;
    sleep 0.05 until -s $argv_out || time() > $deadline;
    my $argv = do { open my $a, '<', $argv_out or die "argv: $!"; local $/; <$a> } // '';
    $argv =~ s/\s+\z//;
    is($argv, "-i -s -w $$", 'the helper was exec\'d with -i -s -w <launcher pid>');
    is(KaDarwinSlice::_keepawake_child_alive($pid), 1, 'a running helper reads alive');
    my ($started) = grep { $_->[0] eq 'keepawake_started' } @events;
    is($started && $started->[1]{helper}, 'caffeinate', 'keepawake_started is logged naming the helper');

    kill 'KILL', $pid;
    my $gone = 0;
    $deadline = time() + 10;
    until ($gone || time() > $deadline) {
        $gone = KaDarwinSlice::_keepawake_child_alive($pid) ? 0 : 1;
        sleep 0.05 unless $gone;
    }
    ok($gone, 'a helper that exited reads not-alive (and is reaped by the probe)');
    is(KaDarwinSlice::_keepawake_child_alive(undef), 0, 'no pid reads not-alive');
    is(KaDarwinSlice::_keepawake_child_alive('x1'), 0, 'a non-numeric pid reads not-alive');
}

done_testing();
