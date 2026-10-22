#!/usr/bin/env perl
# platform: any
# bp-answer-escalation.pl / bp-ledger.pl follow-ups:
#
#   41890000  every lock wait in the answer path is bounded; a stuck holder
#             makes the answer exit 6 (deferred) instead of hanging the
#             orchestrator's tick loop forever
#   ed3a0000  answering the last queued turn-starved escalation lifts the
#             turn-starved manual pause (and only that pause)
#   8ff50000  a direct --package answer archives the sibling escalations it
#             clears instead of deleting them
#
# Every fixture is a tempdir; nothing touches a real almanac store.
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX ();
use Time::HiRes ();
use Cwd qw(abs_path);

my $ENV_TMP = tempdir(CLEANUP => 1);
$ENV{$_} = $ENV_TMP for qw(HOME USERPROFILE ALMANAC_HOME CLAUDE_CONFIG_DIR BUTLER_STATE_DIR CCPRAXIS_DATA_DIR);
delete $ENV{CLAUDE_PROJECT_DIR};
delete $ENV{$_} for qw(BP_ANSWER_LOCK_TIMEOUT BP_LEDGER_LOCK_TIMEOUT BP_WRITEGUARD_LOCK_TIMEOUT);

my $BUTLER = abs_path("$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-answer-escalation.pl";
my $LEDGER = "$BUTLER/scripts/bp-ledger.pl";
require $SCRIPT;   # BpOrch + main::update_next_action_with_note

my $J = JSON::PP->new->canonical;

sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "$p: $!";
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }

# run_bounded($secs, \%env, @cmd) -> ($exit, $output, $took, $timed_out).
# Never hangs this test: a child still running at the deadline is killed.
sub run_bounded {
    my ($secs, $env, @cmd) = @_;
    my $out = File::Temp->new(UNLINK => 1);
    my $outp = $out->filename;
    my $t0 = Time::HiRes::time();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        $ENV{$_} = $env->{$_} for keys %$env;
        open(STDOUT, '>', $outp) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
        { no warnings 'exec'; exec { $cmd[0] } @cmd; }
        POSIX::_exit(127);
    }
    my $deadline = $t0 + $secs;
    my $timed_out = 0;
    while (waitpid($pid, POSIX::WNOHANG()) != $pid) {
        if (Time::HiRes::time() > $deadline) { kill 'KILL', $pid; waitpid($pid, 0); $timed_out = 1; last; }
        Time::HiRes::sleep(0.1);
    }
    my $exit = $timed_out ? -1 : ($? >> 8);
    return ($exit, slurp($outp), Time::HiRes::time() - $t0, $timed_out);
}

sub hold_lock {
    my ($path) = @_;
    my $ready = "$path.held-ready";
    unlink $ready;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(my $fh, '>>', $path) or POSIX::_exit(1);
        flock($fh, LOCK_EX) or POSIX::_exit(1);
        if (open(my $r, '>', $ready)) { close $r; }
        sleep 600;
        POSIX::_exit(0);
    }
    my $deadline = time + 15;
    Time::HiRes::sleep(0.05) until -e $ready || time > $deadline;
    return $pid;
}
sub release_lock { my ($pid) = @_; kill 'KILL', $pid; waitpid($pid, 0); }

sub mk_bp {
    my (%o) = @_;
    my $pkg   = $o{pkg}  // 'alpha';
    my $bpdir = tempdir(CLEANUP => 1);
    for my $p ($pkg, @{ $o{extra_pkgs} || [] }) {
        write_file("$bpdir/packages/$p.md",
            "---\npackage: $p\nblueprint: bp\nstatus: " . ($o{status} // 'blocked') . "\nwrite_set: p/$p/\n"
          . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $p\n\n"
          . "## Next action\n\nSTALE\n\n## Decisions & attempt log\n\n_(none yet)_\n\n"
          . "## Pipeline\n\n- [ ] 1. do it\n\n## Outputs\n\n_(none yet)_\n\n## Escalation\n\n_(none)_\n");
    }
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { map { $_ => { status => 'blocked', attempt => 3 } } ($pkg, @{ $o{extra_pkgs} || [] }) } }));
    return ($bpdir, $pkg);
}
sub queue_esc {
    my ($bpdir, $id, %f) = @_;
    write_file("$bpdir/runs/escalations/$id.json",
        $J->encode({ blueprint => 'bp', question => 'Decide.', context => 'c', created_at => 10, %f }));
}
sub answer {
    my ($bpdir, $env, @args) = @_;
    return run_bounded(60, $env, $^X, $SCRIPT, 'bp', '--bp-dir', $bpdir, @args);
}
sub json_of { my ($out) = @_; my ($j) = $out =~ /(\{.*\})/s; return $j ? eval { $J->decode($j) } : undef; }

# ===========================================================================
# 41890000 -- bounded lock waits.
# ===========================================================================
{
    my ($bpdir, $pkg) = mk_bp();
    queue_esc($bpdir, "$pkg--a1", package => $pkg, kind => 'stuck-package', category => 'product');
    my $ledger = "$bpdir/packages/$pkg.md";
    my $before = slurp($ledger);
    my $h = hold_lock("$ledger.lock");
    my ($exit, $out, $took, $to) = answer($bpdir, { BP_ANSWER_LOCK_TIMEOUT => 1, BP_WRITEGUARD_LOCK_TIMEOUT => 1 },
        '--decision', "$pkg--a1", '--action', 'relaunch', '--note', 'try the other approach');
    release_lock($h);
    ok(!$to, "4189: an answer whose ledger lock is held does not hang (took ${took}s)");
    is($exit, 6, '4189: it exits 6 (deferred)') or diag($out);
    is((json_of($out) // {})->{refused}, 'lock-timeout', '4189: refused: lock-timeout on stdout');
    is(slurp($ledger), $before, '4189: nothing was written to the ledger');
    ok(-e "$bpdir/runs/escalations/$pkg--a1.json", '4189: the decision stays queued for the retry');

    # The retry, once the holder is gone, applies normally.
    my ($exit2, $out2) = answer($bpdir, {}, '--decision', "$pkg--a1", '--action', 'relaunch', '--note', 'try the other approach');
    is($exit2, 0, '4189: the same answer succeeds once the lock is free') or diag($out2);
}
{
    my ($bpdir, $pkg) = mk_bp();
    queue_esc($bpdir, "$pkg--n1", package => $pkg, kind => 'stuck-package', category => 'product');
    my $file = "$bpdir/runs/escalations/$pkg--n1.json";
    my $h = hold_lock("$file.lock");
    my ($exit, $out, $took, $to) = answer($bpdir, { BP_ANSWER_LOCK_TIMEOUT => 1 },
        '--decision', "$pkg--n1", '--action', 'not-mine', '--note', 'yours');
    release_lock($h);
    ok(!$to, "4189: not-mine behind a held escalation lock does not hang (took ${took}s)");
    is($exit, 6, '4189: not-mine exits 6 (deferred)') or diag($out);
}
{
    my ($bpdir, $pkg) = mk_bp();
    my $ledger = "$bpdir/packages/$pkg.md";
    my $h = hold_lock("$ledger.lock");
    my ($exit, $out, $took, $to) = run_bounded(60, { BP_LEDGER_LOCK_TIMEOUT => 1 },
        $^X, $LEDGER, 'set-next-action', '--ledger', $ledger, '--body', 'new');
    release_lock($h);
    ok(!$to, "4189: bp-ledger.pl with BP_LEDGER_LOCK_TIMEOUT set does not wait forever (took ${took}s)");
    is($exit, 4, '4189: a lock timeout is an io_error exit (4)');
    like($out, qr/lock-timeout:/, '4189: and names itself as a lock timeout');

    # In-process: update_next_action_with_note reports the timeout distinctly.
    local $main::LOCK_WAIT_SECS = 1;
    my $h2 = hold_lock("$ledger.lock");
    my $r = main::update_next_action_with_note($bpdir, $pkg, 'note', 'relaunch');
    release_lock($h2);
    is($r, 'lock-timeout', '4189: update_next_action_with_note returns lock-timeout, not a plain failure');
}

# ===========================================================================
# ed3a0000 -- answering turn-starved lifts the turn-starved pause.
# ===========================================================================
sub starved_fixture {
    my (%o) = @_;
    my ($bpdir, $pkg) = mk_bp(status => 'in_progress', extra_pkgs => ['beta']);
    queue_esc($bpdir, "$pkg--ts1", package => $pkg, kind => 'turn-starved', category => 'scoping');
    BpOrch::write_paused("$bpdir/runs", { reason => $o{reason} // "turn-starved: $pkg exhausted turns 3x with no progress",
        manual => 1, created_at => time });
    return ($bpdir, $pkg);
}
{
    my ($bpdir, $pkg) = starved_fixture();
    my ($exit, $out) = answer($bpdir, {}, '--decision', "$pkg--ts1", '--action', 'relaunch');
    is($exit, 0, 'ed3a: the turn-starved answer applies') or diag($out);
    ok(!-e "$bpdir/runs/.paused", 'ed3a: and lifts the turn-starved pause');
    ok((json_of($out) // {})->{cleared_pause}, 'ed3a: cleared_pause is reported true');
}
{
    my ($bpdir, $pkg) = starved_fixture();
    queue_esc($bpdir, 'beta--ts2', package => 'beta', kind => 'turn-starved', category => 'scoping');
    my ($exit, $out) = answer($bpdir, {}, '--decision', "$pkg--ts1", '--action', 'relaunch');
    is($exit, 0, 'ed3a: answering one of two starved packages applies') or diag($out);
    ok(-e "$bpdir/runs/.paused", 'ed3a: but the pause holds while another turn-starved record is queued');
}
{
    my ($bpdir, $pkg) = starved_fixture(reason => 'reauth: token expired');
    my ($exit, $out) = answer($bpdir, {}, '--decision', "$pkg--ts1", '--action', 'relaunch');
    is($exit, 0, 'ed3a: the answer applies under a different manual pause') or diag($out);
    ok(-e "$bpdir/runs/.paused", 'ed3a: a pause with any other reason is never lifted');
}

# ===========================================================================
# 8ff50000 -- direct --package mode archives what it clears.
# ===========================================================================
{
    my ($bpdir, $pkg) = mk_bp();
    queue_esc($bpdir, "$pkg--s1", package => $pkg, kind => 'stuck-package', category => 'product');
    queue_esc($bpdir, "$pkg--s2", package => $pkg, kind => 'harvest-failure', category => 'product');
    my ($exit, $out) = answer($bpdir, {}, '--package', $pkg, '--action', 'reset');
    is($exit, 0, '8ff5: a direct --package reset applies') or diag($out);
    is((json_of($out) // {})->{decisions_cleared}, 2, '8ff5: both siblings are cleared');
    ok(!-e "$bpdir/runs/escalations/$pkg--$_.json" && -e "$bpdir/runs/resolved-escalations/$pkg--$_.json",
        "8ff5: sibling $_ is archived, not deleted (the fleet thread will not log it as answered)") for qw(s1 s2);
}

done_testing();
