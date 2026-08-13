#!/usr/bin/env perl
# Regression oracle for the 2026-08-13 process storm.
#
# WHAT HAPPENED. The operator had to force-restart the machine: terminals stopped
# responding and the process list held "a zillion" powershell.exe and conhost.exe
# entries. Two defects in bp-keepawake.pl combined to produce it.
#
#   1. ps_available() answered "is powershell resolvable?" by SPAWNING
#      `powershell.exe -Command "exit 0"`. Windows attaches a conhost.exe to each
#      one, so merely ASKING the question cost two process creations.
#
#   2. apply() called that probe BEFORE its idempotence check. So the steady
#      state -- a keep-awake lock already alive, nothing whatsoever to do --
#      still paid the probe on every single call, and _pid_alive's tasklist on
#      top of it.
#
# The Stop hook runs the director on every turn end, so "every call" is a hot
# path, not a rare one.
#
# These assertions pin BOTH halves. They are behavioural where it matters: the
# ordering is proven through apply()'s own injectable seams, not by reading the
# source, because the source can be rearranged while staying wrong.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/bp-keepawake.pl";

# ---------------------------------------------------------------------------
# A1 -- the probe does not execute anything.
#
# Asserted against the source because "did not spawn a process" has no portable
# in-process observable. Narrow and specific: ps_available must not hand
# powershell.exe to system/exec/backticks. Nothing else in the file is
# constrained -- spawn() legitimately execs powershell, and that is the point.
# ---------------------------------------------------------------------------
my $src = do {
    open my $fh, '<:raw', "$S/bp-keepawake.pl" or die "read: $!";
    local $/; <$fh>;
};
ok(defined $src && length $src, 'A1: bp-keepawake.pl is readable');

my ($probe_body) = $src =~ /sub\s+ps_available\s*\{(.*?)\n\}/s;
ok(defined $probe_body, 'A1: ps_available() located in the source');

unlike($probe_body, qr/\bsystem\s*\(/,
    'A1: ps_available does not call system() -- asking must not cost a process');
unlike($probe_body, qr/\bexec\s*\(/,
    'A1: ps_available does not call exec()');
unlike($probe_body, qr/`/,
    'A1: ps_available does not shell out via backticks');
like($probe_body, qr/\$ENV\{PATH\}/,
    'A1: ps_available answers from PATH, which is readable without executing anything');

# It must still give a usable answer on this host.
SKIP: {
    skip 'not Windows -- ps_available is a documented no-op off-Windows', 1
        unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    is(BpKeepAwake::ps_available(), 1,
        'A1: powershell.exe is still detected on this host (the cheap probe works)');
}

# ---------------------------------------------------------------------------
# A2 -- THE ORDERING. A live lock means apply() does nothing at all.
#
# This is the assertion that would have caught the storm. With a lock already
# alive, apply() must return before probing and before spawning. A probe call
# here is the defect, even though the end state (no new spawn) looks correct.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    # Our own pid: _pid_alive short-circuits on kill(0) for a process perl owns,
    # so this is a genuinely-live lock on every platform without spawning one.
    open my $fh, '>', "$dir/keepawake.pid" or die $!;
    print {$fh} "$$\n";
    close $fh;

    my ($probed, $spawned, $killed) = (0, 0, 0);
    BpKeepAwake::apply('active', $dir, {
        powershell_available => sub { $probed++;  1 },
        spawn                => sub { $spawned++; 4242 },
        kill_pid             => sub { $killed++ },
    });

    is($spawned, 0, 'A2: a live lock is not doubled');
    is($probed,  0,
        'A2: and the availability probe is NOT called -- idempotence is checked FIRST');
    is($killed,  0, 'A2: a live lock is not killed while the phase still wants it');
}

# ---------------------------------------------------------------------------
# A3 -- the probe is still consulted when it can actually change the outcome.
#
# The fix must not become "never probe": with no lock present, apply() is about
# to spawn, and an unavailable powershell must still veto that.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my ($probed, $spawned) = (0, 0);
    BpKeepAwake::apply('active', $dir, {
        powershell_available => sub { $probed++; 1 },
        spawn                => sub { $spawned++; 4242 },
    });
    is($probed,  1, 'A3: with no lock, the probe IS consulted (exactly once)');
    is($spawned, 1, 'A3: and the lock is spawned');
}
{
    my $dir = tempdir(CLEANUP => 1);
    my ($probed, $spawned) = (0, 0);
    BpKeepAwake::apply('active', $dir, {
        powershell_available => sub { $probed++; 0 },   # powershell absent
        spawn                => sub { $spawned++; 4242 },
    });
    is($probed,  1, 'A3: an unavailable powershell is still detected');
    is($spawned, 0, 'A3: and it vetoes the spawn -- the probe retains its power');
}

# ---------------------------------------------------------------------------
# A4 -- releasing still works, and does not probe either.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/keepawake.pid" or die $!;
    print {$fh} "4242\n";
    close $fh;

    my ($probed, $killed) = (0, 0);
    BpKeepAwake::apply('settled', $dir, {
        powershell_available => sub { $probed++; 1 },
        spawn                => sub { die "must not spawn while settling\n" },
        kill_pid             => sub { $killed++ },
    });
    is($killed, 1, 'A4: settling kills the recorded lock');
    ok(!-e "$dir/keepawake.pid", 'A4: and removes the pid file');
    is($probed, 0,
        'A4: releasing never needs the availability probe -- no process spent to release');
}

# ---------------------------------------------------------------------------
# A5 -- the release path stays free of liveness probing.
#
# Considered and rejected on 2026-08-14: checking _pid_alive before the kill, to
# avoid killing a pid Windows has recycled. Rejected because perl cannot signal a
# native Windows process it did not create (the same asymmetry _pid_alive exists
# to work around), so the unconditional kill is close to a no-op against a
# recycled pid -- while _pid_alive costs the very tasklist spawn this file was
# just fixed to stop paying. t/111 and t/17 both pin the current contract.
#
# Pinned here so the idea is not re-implemented as an "obvious" hardening without
# re-deriving the trade-off.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/keepawake.pid" or die $!;
    print {$fh} "424242\n";                 # synthetic, not running
    close $fh;

    my @killed;
    BpKeepAwake::apply('settled', $dir, {
        powershell_available => sub { die "release must not probe\n" },
        spawn                => sub { die "must not spawn while settling\n" },
        kill_pid             => sub { push @killed, $_[0] },
    });
    is(scalar @killed, 1, 'A5: the recorded pid is passed to kill_pid unconditionally');
    is($killed[0], '424242', 'A5: even when it is not a running process');
}

# ---------------------------------------------------------------------------
# A6 -- a TEST must never spawn a real, immortal OS wake-lock.
#
# Measured on the operator machine 2026-08-14, mid-session: 67 live
# powershell.exe, 53 of them keep-awake.ps1 helpers whose -PidFile pointed into
# TEST fixture dirs (bp/, bp2/, bp-orphan/, bp-done/). bp-orchestrator.pl calls
# apply() with only a `log` seam -- no `spawn` seam -- so the REAL spawn runs,
# and t/06-orchestrator.t drives that path. Each butler-suite run leaked several
# helpers that then slept forever; repeated runs filled the machine.
#
# Same rule CLAUDE.md already states for launcher.pl, one level over: a test may
# not create an OS process that outlives it.
# ---------------------------------------------------------------------------
{
    my $src = do {
        open my $fh, q{<:raw}, qq{$S/bp-keepawake.pl} or die qq{read: $!};
        local $/; <$fh>;
    };
    my ($body) = $src =~ /sub\s+spawn\s*\{(.*?)\n\}/s;
    ok(defined $body, q{A6: spawn() is locatable});
    like($body // q{}, qr/\$0\s*=~/,
        q{A6: spawn() refuses when $0 is a .t -- a test cannot leak a real wake-lock});
    like($body // q{}, qr/CCPRAXIS_NO_WAKELOCK/,
        q{A6: and honours an explicit opt-out env var});

    # Behavioural: we ARE a .t, so the real spawn must decline.
    my $dir = tempdir(CLEANUP => 1);
    my $rc = BpKeepAwake::spawn(qq{$dir/keepawake.pid});
    ok(!defined $rc, q{A6: calling the REAL spawn from inside a test returns undef, spawning nothing});
    ok(!-e qq{$dir/keepawake.pid}, q{A6: and writes no pid file});
}

done_testing();
