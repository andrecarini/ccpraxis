#!/usr/bin/env perl
# platform: any
# A held wake-lock must have a live helper behind it.
#
# Bug report 20261031-225228-4eca: on 2026-10-31 a fleet's keep-awake helper vanished twenty
# minutes into the run (its pid file gone, no stop logged), and the launcher went on logging
# held=1 every two minutes for a machine with no wake-lock: KeepAwake set `running` at start and
# never looked again. The helper also ran with no -LogFile, so why it went is unknowable.
#
# AC1  revive() restarts a dead helper while the lock is wanted, and reports the death once
# AC2  it leaves a live helper, a released lock, and an unjudgeable probe alone
# AC3  at most one restart per $REVIVE_GAP_SECONDS, without spawning through sync(1) meanwhile
# AC4  _keepawake_alive (extracted from launcher.pl) tells a running child from an exited one
# AC5  the launcher wires it: revive on every tick, the died event logged with the helper's last
#      line, and -LogFile always passed with rotation
#
# No helper is spawned and no wake-lock is touched: seams and a plain forked perl child only.
use strict;
use warnings;
use FindBin qw($Bin);
use POSIX ();
use Test::More;
use lib "$Bin/../../scripts";
use KeepAwake ();

sub holder {
    my (%o) = @_;
    my (@starts, @events);
    my $n = 100;
    my $alive = $o{alive} // {};
    my $clock = $o{clock} // \(my $t = 1000);
    my $ka = KeepAwake->new(
        start    => sub { push @starts, ++$n; $alive->{$n} = 1; $n },
        stop     => sub { delete $alive->{ $_[0] } },
        alive    => exists $o{alive_seam} ? $o{alive_seam} : sub { $alive->{ $_[0] } ? 1 : 0 },
        on_event => sub { push @events, { @_ } },
        now      => sub { $$clock },
    );
    return ($ka, \@starts, \@events, $alive, $clock);
}

# --- AC1 ---------------------------------------------------------------------------------------------
{
    my ($ka, $starts, $events, $alive) = holder();
    is($ka->sync(1), 'start', 'precondition: the lock is taken');
    is($ka->handle, 101, 'precondition: helper 101');
    delete $alive->{101};                                   # the helper dies behind our back
    is($ka->revive, 'restart', 'THE BUG: a dead helper under a held lock is restarted');
    is($ka->handle, 102, 'a new helper replaces it');
    ok($ka->running, 'the lock is still held');
    my @died = grep { $_->{kind} eq 'died' } @$events;
    is(scalar @died, 1, 'the death is reported');
    is($died[0]{handle}, 101, 'naming the helper that died');
    is($died[0]{restarting}, 1, 'and that it is being restarted');
}

# --- AC2 ---------------------------------------------------------------------------------------------
{
    my ($ka, $starts) = holder();
    $ka->sync(1);
    is($ka->revive, 'noop', 'a live helper is left alone');
    is(scalar @$starts, 1, 'no extra spawn');
    $ka->sync(0);
    is($ka->revive, 'noop', 'a released lock is not revived');

    my ($ka2, $starts2) = holder(alive_seam => sub { die "probe broke\n" });
    $ka2->sync(1);
    is($ka2->revive, 'noop', 'a probe that dies proves nothing: no restart');
    my ($ka3, $starts3) = holder(alive_seam => sub { undef });
    $ka3->sync(1);
    is($ka3->revive, 'noop', 'an undef probe proves nothing either');
    my ($ka4) = holder(alive_seam => undef);
    $ka4->sync(1);
    is($ka4->revive, 'noop', 'without an alive seam revive does nothing (old callers unchanged)');
}

# --- AC3 ---------------------------------------------------------------------------------------------
{
    my ($ka, $starts, $events, $alive, $clock) = holder();
    $ka->sync(1);                                           # helper 101
    delete $alive->{101};
    is($ka->revive, 'restart', 'first death: restarted');   # helper 102 at t=1000
    $$clock += 10;
    delete $alive->{102};                                   # dies again 10 s later
    is($ka->revive, 'died', 'second death inside the gap: recorded, not restarted');
    is($ka->revive, 'died', 'still inside the gap');
    ok($ka->running, 'the holder stays running on the dead handle');
    is($ka->sync(1), 'noop', 'so sync(1) does not spawn behind the gap');
    is(scalar @$starts, 2, 'only two spawns so far');
    is(scalar(grep { $_->{kind} eq 'died' && $_->{handle} == 102 } @$events), 1,
       'the second death is reported once, not every tick');
    $$clock += $KeepAwake::REVIVE_GAP_SECONDS;
    is($ka->revive, 'restart', 'after the gap: restarted');
    is($ka->handle, 103, 'helper 103');
    $ka->sync(0);
    ok(!$ka->running, 'a later release still releases');
}

# --- AC4 ---------------------------------------------------------------------------------------------
my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
my $SRC = do { open my $fh, '<:raw', $LAUNCHER or die $!; local $/; <$fh> };
my ($alive_sub) = $SRC =~ /(sub _keepawake_alive \{.*?\n\})/s;
my ($tail_sub)  = $SRC =~ /(sub _keepawake_log_tail \{.*?\n\})/s;
ok(defined $alive_sub && defined $tail_sub, 'precondition: both launcher helpers are extractable')
    or do { done_testing(); exit };
ok(eval "package KaUnderTest; use strict; use warnings; use POSIX (); $alive_sub $tail_sub 1;", 'they compile alone')
    or diag($@);
{
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) { sleep 30; POSIX::_exit(0) }
    is(KaUnderTest::_keepawake_alive($pid), 1, 'a running child reads alive');
    kill 'KILL', $pid;
    my $deadline = time + 10;
    my $v;
    while (time < $deadline) { $v = KaUnderTest::_keepawake_alive($pid); last unless $v; select(undef, undef, undef, 0.1) }
    is($v, 0, 'once it has exited, it reads dead');
    is(KaUnderTest::_keepawake_alive(undef), undef, 'no handle: undef (nothing to judge)');
}
{
    my $f = "$Bin/keepawake-tail-$$.log";
    open my $o, '>:raw', $f or die $!;
    print $o "2026-10-31 22:30:07 pid=1 ASSERTED x\r\n2026-10-31 22:41:07 pid=1 RELEASE reason=pidfile-gone (deliberate release)\r\n";
    close $o;
    is(KaUnderTest::_keepawake_log_tail($f), '2026-10-31 22:41:07 pid=1 RELEASE reason=pidfile-gone (deliberate release)',
       'the log tail is the helper\'s last line, CRLF stripped');
    unlink $f;
    is(KaUnderTest::_keepawake_log_tail("$f.none"), undef, 'no log: undef');
}

# --- AC5 ---------------------------------------------------------------------------------------------
like($SRC, qr/alive\s*=>\s*\\&_keepawake_alive/, 'the launcher hands KeepAwake the alive seam');
like($SRC, qr/my \$rv = \$KEEPAWAKE->revive;/, 'and revives on every tick');
my ($tick) = $SRC =~ /(my \$rv = \$KEEPAWAKE->revive;.*?if \(\$probe_state ne 'probe-failed'\))/s;
ok(defined $tick, 'before the probe-failed gate, so a held-through probe failure is covered too');
like($SRC, qr/log_ev\('keepawake_died', .{0,300}?helper_last => _keepawake_log_tail/s,
     'a death is logged with the helper\'s own last line');
my ($start) = $SRC =~ /(sub _keepawake_start \{.*?\n\})/s;
like($start // '', qr/\@log_args = \('-LogFile', native_path\(\$logfile\)\)/, 'the helper always gets -LogFile');
like($start // '', qr/rename\(\$logfile, "\$logfile\.1"\) if defined \$sz && \$sz > 1024 \* 1024/, 'rotated past 1 MB');
like($start // '', qr/\@owner_args, \@log_args\)/, 'and the log args reach the exec');

# --- [r] re-exec -------------------------------------------------------------------------------------
# _relaunch_self used to call _keepawake_stop() with no arguments, a silent no-op: every [r] left the
# old helper running beside the new process's own (found 2026-11-02).
my ($relaunch) = $SRC =~ /(sub _relaunch_self \{.*?\n\})/s;
ok(defined $relaunch, '_relaunch_self is extractable');
like($relaunch // '', qr/\$KEEPAWAKE->release if \$KEEPAWAKE/, '[r] releases the helper through the holder');
unlike($relaunch // '', qr/_keepawake_stop\(\s*\)/, 'no argument-less _keepawake_stop() left');

done_testing();
