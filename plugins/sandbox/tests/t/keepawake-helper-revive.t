#!/usr/bin/env perl
# platform: any
# A held wake-lock must have a live helper behind it.
#
# Bug report 20261031-225228-4eca: on 2026-10-31 a fleet's keep-awake helper vanished twenty
# minutes into the run (its pid file gone, no stop logged), and the launcher went on logging
# held=1 every two minutes for a machine with no wake-lock: KeepAwake set `running` at start and
# never looked again. The helper also ran with no -LogFile, so why it went is unknowable.
#
# Rewritten for 07-one-keepawake-helper (blueprint wake-and-pause-consolidation): the real
# spawn/liveness/stop/reap of the helper moved into BpKeepAwake (bp-keepawake.pl); the launcher
# only wires KeepAwake's revive/[r]-release lifecycle to BpKeepAwake's seams. This file now drives
# that lifecycle through BpKeepAwake, not through launcher.pl's own (deleted) helpers. Derived from
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/07-one-keepawake-helper-spec.md
# section 4, AC6-AC10 (the rest of the acceptance table lives in one-keepawake-helper.t):
#
# AC6  B8: revive() restarts a dead helper while the lock is wanted, reports the death once, waits
#      out $REVIVE_GAP_SECONDS, and never loops on a declined start -- all driven through
#      KeepAwake->new(alive => \&BpKeepAwake::child_alive, ...) with real forked sleepers and a
#      fixture clock.
# AC7  B6: BpKeepAwake::log_tail returns the helper's last log line, CRLF stripped; plus the
#      launcher logs a death with BpKeepAwake::log_tail's own value.
# AC8  the launcher's BpKeepAwake wiring (static, text-level): the alive seam, the revive-before-
#      probe-failed-gate ordering, the start closure's BpKeepAwake::spawn(lease_seconds=>0,
#      owner_winpid=>...) call, the stop closure's BpKeepAwake::stop_child(, and
#      load_bp_keepawake(...reap_orphan(...KeepAwake->new( ordering.
# AC9  [r] release goes through the holder ($KEEPAWAKE->release), never a bare _keepawake_stop().
# AC10 B3: BpKeepAwake::rotate_log rotates a log past 1 MB (every caller), plus bp-keepawake.pl's
#      own spawn() rotates before fork() and passes -LeaseSeconds via lease_seconds(...).
#
# No real keep-awake.ps1 helper is spawned and no wake-lock is touched: seams and plain forked perl
# sleepers only, killed in END/INT/TERM.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use strict;
use warnings;
use FindBin qw($Bin);
use POSIX ();
use Test::More;
use File::Temp qw(tempdir);
use lib "$Bin/../../scripts";
use KeepAwake ();

my $SANDBOX_SCRIPTS = "$Bin/../../scripts";
my $BUTLER_SCRIPTS  = "$Bin/../../../butler/scripts";
my $LAUNCHER        = "$SANDBOX_SCRIPTS/launcher.pl";
my $BP_KEEPAWAKE    = "$BUTLER_SCRIPTS/bp-keepawake.pl";

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:raw', $f) or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

my $LSRC = slurp($LAUNCHER);
ok(defined $LSRC, "precondition: $LAUNCHER is readable") or BAIL_OUT("cannot read launcher.pl");

require "$BP_KEEPAWAKE";

my @ALL_KIDS;
sub reap_all_kids {
    local $?;
    for my $pid (@ALL_KIDS) {
        next unless defined $pid;
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
    @ALL_KIDS = ();
}
END { reap_all_kids() }
$SIG{INT}  = sub { reap_all_kids(); exit 1 };
$SIG{TERM} = sub { reap_all_kids(); exit 1 };

# =====================================================================
# AC6 [B8]: revive() through BpKeepAwake::child_alive, real forked sleepers,
# a fixture clock.
# =====================================================================
{
    my $has = defined &BpKeepAwake::child_alive;
    ok($has, 'AC6 precondition: BpKeepAwake::child_alive is defined');
    SKIP: {
        skip 'BpKeepAwake::child_alive not defined yet', 16 unless $has;

        my @events;
        my $clock = \(my $t = 1000);
        my $ka = KeepAwake->new(
            start => sub {
                my $pid = fork();
                die "fork: $!" unless defined $pid;
                if ($pid == 0) { sleep 60; POSIX::_exit(0) }
                push @ALL_KIDS, $pid;
                return $pid;
            },
            stop     => sub { },
            alive    => \&BpKeepAwake::child_alive,
            on_event => sub { push @events, { @_ } },
            now      => sub { $$clock },
        );

        is($ka->sync(1), 'start', 'AC6 precondition: the lock is taken');
        my $first = $ka->handle;
        ok(defined $first, 'AC6 precondition: a real child pid is the handle');

        kill('KILL', $first);
        my $deadline = time() + 10;
        my $result;
        while (time() < $deadline) {
            $result = $ka->revive;
            last if defined $result && $result eq 'restart';
            select(undef, undef, undef, 0.2);
        }
        is($result, 'restart', 'AC6 (1): revive restarts once child_alive reports the old child dead');
        my $second = $ka->handle;
        ok(defined $second && $second != $first, 'AC6 (1): the handle changes to a new child');
        my @died = grep { $_->{kind} eq 'died' } @events;
        is(scalar @died, 1, 'AC6 (1): the death is reported once');
        is($died[0]{handle}, $first, 'AC6 (1): naming the old pid');
        is($died[0]{restarting}, 1, 'AC6 (1): and that it is being restarted');

        kill('KILL', $second);
        # Wait for child_alive to actually see it dead before advancing the fixture
        # clock -- otherwise the "second death inside the gap" below would be timing
        # against a child that has not exited yet.
        $deadline = time() + 10;
        while (time() < $deadline) {
            my $v = BpKeepAwake::child_alive($second);
            last if defined $v && $v == 0;
            select(undef, undef, undef, 0.2);
        }
        $$clock += 10;
        is($ka->revive, 'died', 'AC6 (2): a second death inside the gap is recorded, not restarted');
        is($ka->revive, 'died', 'AC6 (2): still inside the gap');
        is($ka->sync(1), 'noop', 'AC6 (2): sync(1) does not spawn behind the gap');
        is(scalar(grep { $_->{kind} eq 'died' && $_->{handle} == $second } @events), 1,
           'AC6 (2): the second death is reported once, not every tick');

        $$clock += $KeepAwake::REVIVE_GAP_SECONDS;
        is($ka->revive, 'restart', 'AC6 (3): after the gap, revive restarts');
        my $third = $ka->handle;
        ok(defined $third && $third != $second, 'AC6 (3): a fresh handle replaces it');
        if (defined $third) {
            kill('KILL', $third);
            my $wait_deadline = time() + 10;
            while (time() < $wait_deadline) {
                my $r = waitpid($third, POSIX::WNOHANG());
                last if $r == $third;
                select(undef, undef, undef, 0.2);
            }
            @ALL_KIDS = grep { !defined $_ || $_ != $third } @ALL_KIDS;
        }

        # AC6 (4): a declined start (undef handle) is unjudgeable -- revive never
        # loops respawning it.
        my @events2;
        my @start_calls;
        my $ka2 = KeepAwake->new(
            start    => sub { push @start_calls, 1; return undef },
            stop     => sub { },
            alive    => \&BpKeepAwake::child_alive,
            on_event => sub { push @events2, { @_ } },
            now      => sub { $$clock },
        );
        $ka2->sync(1);
        is($ka2->revive, 'noop', 'AC6 (4): an undef handle from a declined start is unjudgeable -- revive is noop');
        is($ka2->revive, 'noop', 'AC6 (4): and stays noop on a second call');
        is(scalar(@start_calls), 1, 'AC6 (4): start is never called again (no respawn loop)');
    }
}

# =====================================================================
# AC7 [B6]: BpKeepAwake::log_tail, plus the launcher's died-event wiring.
# =====================================================================
{
    my $has = defined &BpKeepAwake::log_tail;
    ok($has, 'AC7 precondition: BpKeepAwake::log_tail is defined');
    SKIP: {
        skip 'BpKeepAwake::log_tail not defined yet', 2 unless $has;
        # m4 (reviewer-step6.md): a fixture under $Bin stays behind in the
        # source tree if anything dies between open and unlink. A
        # File::Temp tempdir (CLEANUP => 1) is removed even on a mid-test
        # death, and never lands in plugins/sandbox/tests/t/.
        my $dir = tempdir(CLEANUP => 1);
        my $f = "$dir/keepawake-revive-tail.log";
        open my $o, '>:raw', $f or die $!;
        print $o "2026-10-31 22:30:07 pid=1 ASSERTED x\r\n2026-10-31 22:41:07 pid=1 RELEASE reason=pidfile-gone (deliberate release)\r\n";
        close $o;
        is(BpKeepAwake::log_tail($f),
           '2026-10-31 22:41:07 pid=1 RELEASE reason=pidfile-gone (deliberate release)',
           "AC7: log_tail is the helper's last line, CRLF stripped");
        unlink $f;
        is(BpKeepAwake::log_tail("$f.none"), undef, 'AC7: a missing log gives undef');
    }
}
like($LSRC, qr/log_ev\('keepawake_died', .{0,300}?helper_last => BpKeepAwake::log_tail\(/s,
     "AC7: a death is logged with BpKeepAwake::log_tail's own last line");

# =====================================================================
# AC8: launcher.pl's BpKeepAwake wiring (static, text-level).
# =====================================================================
like($LSRC, qr/alive\s*=>[^\n]*\\&BpKeepAwake::child_alive/,
     'AC8: the launcher hands KeepAwake the BpKeepAwake::child_alive seam');
like($LSRC, qr/my \$rv = \$KEEPAWAKE->revive;/, 'AC8: and revives on every tick');
{
    my ($tick) = $LSRC =~ /(my \$rv = \$KEEPAWAKE->revive;.*?if \(\$probe_state ne 'probe-failed'\))/s;
    ok(defined $tick, 'AC8: the revive call is before the probe-failed gate (a held-through probe failure is covered too)');
}
{
    my $spawn_pos = $LSRC =~ /BpKeepAwake::spawn\s*\(/ ? $-[0] : undef;
    ok(defined $spawn_pos, 'AC8: the start closure calls BpKeepAwake::spawn(');
    my $window = defined $spawn_pos ? substr($LSRC, $spawn_pos, 400) : '';
    like($window, qr/lease_seconds\s*=>\s*0/, 'AC8: ...with lease_seconds => 0 in the same call');
    like($window, qr/owner_winpid\s*=>/, 'AC8: ...and owner_winpid => in the same call');
}
like($LSRC, qr/BpKeepAwake::stop_child\(/, 'AC8: the stop closure calls BpKeepAwake::stop_child(');
{
    my $load_pos = $LSRC =~ /KeepAwake::load_bp_keepawake\(/ ? $-[0] : undef;
    my $reap_pos = $LSRC =~ /BpKeepAwake::reap_orphan\(/     ? $-[0] : undef;
    my $new_pos  = $LSRC =~ /KeepAwake->new\(/                ? $-[0] : undef;
    ok(defined($load_pos) && defined($reap_pos) && defined($new_pos)
        && $load_pos < $reap_pos && $reap_pos < $new_pos,
       'AC8: KeepAwake::load_bp_keepawake precedes BpKeepAwake::reap_orphan, which precedes KeepAwake->new')
        or diag(sprintf('load=%s reap=%s new=%s',
            map { defined $_ ? $_ : 'undef' } ($load_pos, $reap_pos, $new_pos)));
}

# =====================================================================
# AC9: [r] release goes through the holder, never a bare _keepawake_stop().
# =====================================================================
{
    my ($relaunch) = $LSRC =~ /(sub _relaunch_self \{.*?\n\})/s;
    ok(defined $relaunch, 'AC9 precondition: _relaunch_self is extractable');
    like($relaunch // '', qr/\$KEEPAWAKE->release if \$KEEPAWAKE/,
         'AC9: [r] releases the helper through the holder');
    unlike($LSRC, qr/_keepawake_stop\(/, 'AC9: no _keepawake_stop( call survives anywhere in launcher.pl');
}

# =====================================================================
# AC10 [B3]: BpKeepAwake::rotate_log, plus spawn()'s own rotation/lease wiring.
# =====================================================================
{
    my $has = defined &BpKeepAwake::rotate_log;
    ok($has, 'AC10 precondition: BpKeepAwake::rotate_log is defined');
    SKIP: {
        skip 'BpKeepAwake::rotate_log not defined yet', 7 unless $has;

        my $dir = tempdir(CLEANUP => 1);

        my $big = "$dir/big.log";
        open(my $fh, '>', $big) or die $!;
        print {$fh} ('x' x (1024 * 1024 + 1));
        close $fh;
        is(BpKeepAwake::rotate_log($big), 1, 'AC10: a 1,048,577-byte log is rotated (returns 1)');
        ok(!-e $big, 'AC10: the original path no longer exists');
        ok((-s "$big.1") == 1024 * 1024 + 1, 'AC10: the content is preserved at .1');

        my $old1 = "$dir/old.log.1";
        open(my $ofh, '>', $old1) or die $!;
        print {$ofh} "stale\n";
        close $ofh;
        my $fresh = "$dir/old.log";
        open(my $ffh, '>', $fresh) or die $!;
        print {$ffh} ('y' x (1024 * 1024 + 1));
        close $ffh;
        is(BpKeepAwake::rotate_log($fresh), 1, 'AC10: an existing .1 is replaced');
        open(my $rfh, '<', $old1) or die $!;
        my $content = do { local $/; <$rfh> };
        close $rfh;
        unlike($content, qr/stale/, 'AC10: ...the stale .1 content is gone');

        my $exact = "$dir/exact.log";
        open(my $efh, '>', $exact) or die $!;
        print {$efh} ('z' x (1024 * 1024));
        close $efh;
        is(BpKeepAwake::rotate_log($exact), 0, 'AC10: a log of exactly 1,048,576 bytes is left alone (returns 0)');

        is(BpKeepAwake::rotate_log("$dir/does-not-exist.log"), 0, 'AC10: a missing log returns 0');
    }
}
{
    my $has = defined &BpKeepAwake::rotate_log;
    SKIP: {
        skip 'BpKeepAwake::rotate_log not defined yet', 1 unless $has;
        is(BpKeepAwake::rotate_log(undef), 0, 'AC10: undef returns 0');
    }
}
{
    my $BPSRC = slurp($BP_KEEPAWAKE);
    my ($spawn_body) = $BPSRC =~ /\nsub\s+spawn\s*\{(.*?)\n\}\n/s;
    ok(defined $spawn_body, 'AC10 precondition: bp-keepawake.pl has sub spawn');
    $spawn_body //= '';
    my $rot_pos  = $spawn_body =~ /rotate_log\s*\(/ ? $-[0] : undef;
    my $fork_pos = $spawn_body =~ /\bfork\s*\(/      ? $-[0] : undef;
    ok(defined($rot_pos) && defined($fork_pos) && $rot_pos < $fork_pos,
       'AC10: spawn() rotates the log before fork()');
    like($spawn_body, qr/'-LogFile'/, 'AC10: spawn() still passes -LogFile');
    like($spawn_body, qr/'-LeaseSeconds',\s*lease_seconds\(/,
         'AC10: -LeaseSeconds is the lease_seconds(...) value');
}

done_testing();
