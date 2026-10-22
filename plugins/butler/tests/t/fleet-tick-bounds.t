#!/usr/bin/env perl
# platform: any
# bp-orchestrator.pl tick-loop bounds and fleet-thread hygiene. One file for
# the follow-up todos that all live in the same tick path:
#
#   489b0000  fleet-thread tick: per-call lock wait capped, per-tick budget,
#             unsent work left for the next tick
#   72f40000  escalation ids validated before they are logged or seeded
#   74f30000  triage-owned records not re-read every tick (mtime/size cache)
#   d7f70000  escalations already queued at startup are observed at setup
#   41890000  _run_bounded: the answer seam's wall-clock backstop
#   ed3a0000  F2 extended to turn-starved under a manual pause
#   1dba0000  broken-env self-check auto-resumes, bounded
#
# No test spawns launcher.pl, podman or claude. Every store is a tempdir.
use strict;
use warnings;
no warnings 'once';   # BpOrch tunables are set from here only
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp ();
use File::Path qw(make_path);
use File::Spec ();
use File::Find ();
use Fcntl qw(:flock);
use POSIX ();
use Time::HiRes ();

# ASCII-only temp base (see fleet-thread.t's header: a non-ASCII project root
# trips a byte-upgrade bug in Almanac::Thread that is not under test here).
my $ASCII_TMP_BASE = (-d 'C:/Windows/Temp' && -w 'C:/Windows/Temp') ? 'C:/Windows/Temp' : File::Spec->tmpdir;
sub tempdir { return File::Temp::tempdir(DIR => $ASCII_TMP_BASE, CLEANUP => 1); }

my $ENV_TMP = tempdir();
$ENV{$_} = $ENV_TMP for qw(HOME USERPROFILE ALMANAC_HOME CLAUDE_CONFIG_DIR BUTLER_STATE_DIR CCPRAXIS_DATA_DIR);
delete $ENV{CLAUDE_PROJECT_DIR};
delete $ENV{ALMANAC_LOCK_TIMEOUT_MS};
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

require "$Bin/../../scripts/bp-orchestrator.pl";   # package BpOrch
use lib "$Bin/../../../almanac/scripts";
require Almanac::Thread;

my $J = JSON::PP->new->canonical;

sub slurp { local $/; open my $f, '<', shift or return undef; <$f> }
sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) if length($d) && !-d $d;
    open my $f, '>:raw', $p or die "write $p: $!";
    print {$f} $c;
    close $f;
}
sub write_json { my ($p, $h) = @_; write_file($p, $J->encode($h)); }
sub log_events {
    my ($bpdir) = @_;
    my $raw = slurp("$bpdir/runs/orchestrator.log");
    return [] unless defined $raw;
    return [ grep { ref $_ eq 'HASH' } map { my $l = $_; eval { $J->decode($l) } } grep { length } split /\n/, $raw ];
}
sub thread_log { my ($name, $P) = @_; return eval { Almanac::Thread::log_entries($name, root => $P) } || []; }

sub mk_fleet {
    my (%o) = @_;
    my $bp = $o{bp} // 'fx';
    my $P  = tempdir();
    my $bpdir = "$P/.ccpraxis-local-data/blueprints/$bp";
    make_path("$bpdir/packages", "$bpdir/runs");
    write_file("$bpdir/blueprint.md",
        "# $bp\n\n## Package status\n\n| pkg | deliverable | depends_on | model |\n|--|--|--|--|\n"
      . "| 01-a | d | \xe2\x80\x94 | sonnet |\n");   # em dash, as UTF-8 bytes
    write_file("$bpdir/packages/01-a.md",
        "---\npackage: 01-a\nblueprint: $bp\nstatus: in_progress\nwrite_set: p/01-a/\n"
      . "test_paths: p/01-a/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# 01-a\n\n## Next action\n\ngo\n");
    write_json("$bpdir/runs/registry.json", { packages => {} });
    return ($P, $bpdir, $bp);
}
sub seed_esc {
    my ($bpdir, $id, %f) = @_;
    write_json("$bpdir/runs/escalations/$id.json", { created_at => time, context => {}, %f });
}
sub setup_ctx {
    my ($bpdir, $bp) = @_;
    return BpOrch::_fleet_thread_setup({ blueprint => $bp, bp_dir => $bpdir,
        runs => "$bpdir/runs", log => "$bpdir/runs/orchestrator.log" });
}

# hold_lock($path) -> $pid: a CHILD process takes an exclusive flock on $path
# and keeps it until killed -- a stand-in for a suspended/hung lock holder.
sub hold_lock {
    my ($path) = @_;
    my $ready = "$path.held-ready";
    unlink $ready;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(my $fh, '>>', $path) or POSIX::_exit(1);
        flock($fh, LOCK_EX) or POSIX::_exit(1);
        if (open(my $r, ">", $ready)) { close $r; }
        sleep 600;
        POSIX::_exit(0);
    }
    my $deadline = time + 15;
    Time::HiRes::sleep(0.05) until -e $ready || time > $deadline;
    return $pid;
}
sub release_lock { my ($pid) = @_; kill 'KILL', $pid; waitpid($pid, 0); }

sub find_thread_lock {
    my ($P, $name) = @_;
    my $hit;
    File::Find::find({ no_chdir => 1, wanted => sub {
        $hit = $File::Find::name if !$hit && $File::Find::name =~ m{/thread/\Q$name\E\.thread\.lock\z};
    } }, "$P/.ccpraxis-local-data");
    return $hit;
}

# ===========================================================================
# 489b0000 -- a hung lock holder costs at most the tick budget, and the
# writes it blocked are retried, not lost.
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'tb');
    my $ctx = setup_ctx($bpdir, $bp);
    ok($ctx, '489b: fleet thread set up') or BAIL_OUT('no fleet thread ctx');
    my @ids = map { "01-a--b$_" } 1..6;
    seed_esc($bpdir, $_, package => '01-a', kind => 'stuck-package', category => 'product', question => 'q') for @ids;

    my $lock = find_thread_lock($P, $ctx->{name});
    ok(defined $lock && -e $lock, '489b: the thread lock file exists') or diag("no lock file under $P");
    local $BpOrch::FLEET_THREAD_LOCK_TIMEOUT_MS = 300;
    $ctx->{tick_budget_s} = 1;
    my $holder = hold_lock($lock);
    my $t0 = Time::HiRes::time();
    BpOrch::_fleet_thread_tick($ctx, { paused => undef, meta => { '01-a' => {} }, now => time });
    my $took = Time::HiRes::time() - $t0;
    release_lock($holder);
    cmp_ok($took, '<', 5, "489b: a tick behind a hung lock holder returns within the budget (took ${took}s; "
                        . 'six writes at the 10s default would take a minute)');
    my @unsent = grep { !$ctx->{sent}{$_} } @ids;
    ok(scalar(@unsent) > 0, '489b: writes past the budget are left unsent: ' . scalar(@unsent) . ' of 6');
    is(scalar(grep { $_->{type} eq 'fleet_thread_deferred' } @{ log_events($bpdir) }), 1,
        '489b: one fleet_thread_deferred line is logged when deferral starts');

    $ctx->{tick_budget_s} = 30;
    BpOrch::_fleet_thread_tick($ctx, { paused => undef, meta => { '01-a' => {} }, now => time });
    ok(!(grep { !$ctx->{sent}{$_} } @ids), '489b: with the holder gone, the next tick sends every deferred id');
    my %sent_logged;
    for my $e (@{ thread_log($ctx->{name}, $P) }) {
        next unless $e->{event} eq 'escalation-sent';
        my ($tok) = split ' ', ($e->{reason} // ''), 2;
        $sent_logged{$tok}++;
    }
    is_deeply([ map { $sent_logged{$_} // 0 } @ids ], [ (1) x 6 ],
        '489b: each escalation is logged exactly once across both ticks');
}

# ===========================================================================
# 72f40000 / 74f30000 / d7f70000
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'th');
    # d7f7: already queued when the orchestrator starts.
    seed_esc($bpdir, '01-a--pre1', package => '01-a', kind => 'stuck-package', category => 'product', question => 'q');
    my $ctx = setup_ctx($bpdir, $bp);
    ok($ctx && $ctx->{sent}{'01-a--pre1'}, 'd7f7: an escalation queued before startup is observed at setup');
    unlink "$bpdir/runs/escalations/01-a--pre1.json";   # answered by the first tick's inbox bridge
    BpOrch::_fleet_thread_tick($ctx, { paused => undef, meta => { '01-a' => {} }, now => time });
    ok((grep { $_->{event} eq 'answer-applied' && ($_->{reason} // '') eq '01-a--pre1' } @{ thread_log($ctx->{name}, $P) }),
        'd7f7: answering it on the first tick logs answer-applied');

    # 72f4: a foreign file whose id is not a valid escalation id.
    seed_esc($bpdir, 'X junk', package => '01-a', kind => 'stuck-package', category => 'product');
    BpOrch::_fleet_thread_tick($ctx, { paused => undef, meta => { '01-a' => {} }, now => time });
    ok(!(grep { ($_->{reason} // '') =~ /\AX\b/ } @{ thread_log($ctx->{name}, $P) }),
        '72f4: an id with whitespace is never logged as escalation-sent');
    ok(!$ctx->{sent}{X} && !$ctx->{sent}{'X junk'}, '72f4: nor does it enter the sent set');

    # 72f4: the restart seed ignores a token that is not a whole valid id.
    Almanac::Thread::record_event($ctx->{name}, 'escalation-sent', reason => 'bad!id stuck-package product',
        actor => 'orchestrator', root => $P);
    my $ctx2 = setup_ctx($bpdir, $bp);
    ok($ctx2 && !$ctx2->{sent}{'bad!id'}, '72f4: a logged token that is not a valid id does not seed `sent`');

    # 74f3: a triage-owned record is read once, then only again when it changes.
    seed_esc($bpdir, '01-a--tri1', package => '01-a', kind => 'stuck-package', category => 'scoping', question => 'q');
    my %reads;
    {
        no warnings 'redefine';
        my $orig = \&BpOrch::_read_json;
        local *BpOrch::_read_json = sub { $reads{ $_[0] }++ if $_[0] =~ /tri1/; return $orig->(@_) };
        BpOrch::_fleet_thread_tick($ctx2, { paused => undef, meta => { '01-a' => {} }, now => time });
        BpOrch::_fleet_thread_tick($ctx2, { paused => undef, meta => { '01-a' => {} }, now => time });
        BpOrch::_fleet_thread_tick($ctx2, { paused => undef, meta => { '01-a' => {} }, now => time });
        my ($n) = values %reads;
        is($n // 0, 1, '74f3: an unchanged triage-owned record is decoded once across three ticks');
        ok(!$ctx2->{sent}{'01-a--tri1'}, '74f3: and it is not logged (still resolver-owned)');
        # The resolver re-tags it operator-owned: the file changes (size), so it is re-read.
        seed_esc($bpdir, '01-a--tri1', package => '01-a', kind => 'stuck-package', category => 'product',
            question => 'q', product_question => 'Which product behaviour do you want here?');
        BpOrch::_fleet_thread_tick($ctx2, { paused => undef, meta => { '01-a' => {} }, now => time });
        ok($ctx2->{sent}{'01-a--tri1'}, '74f3: a re-tag to an operator-owned category is still picked up');
    }
}

# ===========================================================================
# 41890000 -- _run_bounded, the answer seam's backstop.
# ===========================================================================
{
    my $t0 = Time::HiRes::time();
    my ($raw, $to) = BpOrch::_run_bounded([ $^X, '-e', 'sleep 60' ], 1);
    my $took = Time::HiRes::time() - $t0;
    is($to, 1, '4189: a child past its deadline is reported as timed out');
    cmp_ok($took, '<', 10, "4189: and the caller gets control back promptly (took ${took}s)");
    my ($raw2, $to2) = BpOrch::_run_bounded([ $^X, '-e', 'exit 3' ], 30);
    is($to2, 0, '4189: a child that exits in time is not a timeout');
    is($raw2 >> 8, 3, '4189: its exit status comes back $?-shaped');
}

# ===========================================================================
# ed3a0000 -- F2 covers turn-starved while a manual pause holds.
# ===========================================================================
{
    my $rec = { package => '01-a', kind => 'turn-starved', category => 'scoping' };
    my (undef, $f2_paused) = BpOrch::_inbox_bridge_eligible_now($rec, {}, {}, { manual => 1, reason => 'turn-starved: 01-a x' });
    my (undef, $f2_free)   = BpOrch::_inbox_bridge_eligible_now($rec, {}, {}, undef);
    my (undef, $f2_timed)  = BpOrch::_inbox_bridge_eligible_now($rec, {}, {}, { manual => 0, reason => 'usage' });
    is($f2_paused, 1, 'ed3a: turn-starved under a manual pause is F2-eligible (resolver unreachable)');
    is($f2_free,   0, 'ed3a: without a pause it stays with the resolver');
    is($f2_timed,  0, 'ed3a: a timed (auto-resuming) pause does not count');
    my (undef, $f2_other) = BpOrch::_inbox_bridge_eligible_now(
        { package => '01-a', kind => 'stuck-package', category => 'scoping' }, {}, {}, { manual => 1 });
    is($f2_other, 0, 'ed3a: other triageable kinds still wait for the resolver under a manual pause');
    is(BpOrch::_inbox_bridge_choices_for('01-a', 'turn-starved'), 'relaunch,accept,drop',
        'ed3a: a turn-starved item does not offer not-mine');
    is(BpOrch::_inbox_bridge_choices_for('01-a', 'stuck-package'), 'relaunch,accept,drop,not-mine',
        'ed3a: other package kinds are unchanged');
}

# ===========================================================================
# 1dba0000 -- broken-env self-check.
# ===========================================================================
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });
sub base_tun {
    my (%o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>120, watch_tick=>60,
        keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0, tele_retry=>3,
        usage_fail=>60, busy_path=>(tempdir() . '/busy'), harvest=>'audit',
        resolve_cap=>1, corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3, %o };
}
sub write_creds {
    my ($p) = @_;
    write_json($p, { claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 100*3600)*1000, scopes => ['user:inference'], subscriptionType => 'max',
        rateLimitTier => 'x' } });
}
sub broken_env_fixture {
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'be');
    write_creds("$bpdir/creds.json");
    BpOrch::write_paused("$bpdir/runs", { reason => 'broken-env: launcher could not be executed', manual => 1,
        created_at => time - 3600 });
    seed_esc($bpdir, '_fleet--be01', package => '_fleet', blueprint => $bp, kind => 'broken-env',
        category => 'unclassified', question => 'broken');
    return ($P, $bpdir, $bp);
}
sub run_once {
    my ($bpdir, $bp, %o) = @_;
    my $ok = eval {
        BpOrch::run({ blueprint => $bp, bp_dir => $bpdir, once => 1,
            creds_path => "$bpdir/creds.json", tunables => base_tun(%{ $o{tun} || {} }),
            now => sub { time }, sleep => sub { 0 },
            http_get => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            launch => sub { 0 }, spawn_judge => sub { 0 },
            read_verdict => sub { undef }, checkpoint => sub { {} },
            (exists $o{env_probe} ? (env_probe => $o{env_probe}) : ()) });
        1;
    };
    diag("run() died: $@") unless $ok;
    return $ok;
}
{
    my ($P, $bpdir, $bp) = broken_env_fixture();
    my $probed = 0;
    run_once($bpdir, $bp, env_probe => sub { $probed++; return (1, undef) }, tun => { broken_env_probe => 60 });
    is($probed, 1, '1dba: an overdue broken-env pause is probed');
    ok(!-e "$bpdir/runs/.paused", '1dba: a healthy probe lifts the broken-env pause');
    ok(!-e "$bpdir/runs/escalations/_fleet--be01.json" && -e "$bpdir/runs/resolved-escalations/_fleet--be01.json",
        '1dba: and archives the broken-env escalation (so its inbox item closes with a reason)');
    ok((grep { $_->{type} eq 'auto_resume' && ($_->{reason} // '') eq 'broken-env-selfcheck' } @{ log_events($bpdir) }),
        '1dba: the auto-resume is logged');
}
{
    my ($P, $bpdir, $bp) = broken_env_fixture();
    run_once($bpdir, $bp, env_probe => sub { return (0, 'bash missing') }, tun => { broken_env_probe => 60 });
    ok(-e "$bpdir/runs/.paused", '1dba: a failing probe leaves the pause in place');
    ok(-e "$bpdir/runs/escalations/_fleet--be01.json", '1dba: and the escalation queued');
}
{
    my ($P, $bpdir, $bp) = broken_env_fixture();
    my $probed = 0;
    run_once($bpdir, $bp, env_probe => sub { $probed++; return (1, undef) }, tun => { broken_env_probe => 60, broken_env_retries => 0 });
    is($probed, 0, '1dba: with the auto-resume budget spent nothing is probed');
    ok(-e "$bpdir/runs/.paused", '1dba: and the pause stays for the operator');
}
{
    my ($P, $bpdir, $bp) = broken_env_fixture();
    my $probed = 0;
    run_once($bpdir, $bp, env_probe => sub { $probed++; return (1, undef) }, tun => { broken_env_probe => 7200 });
    is($probed, 0, '1dba: a pause younger than the probe interval is not probed yet');
}
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'be2');
    write_creds("$bpdir/creds.json");
    BpOrch::write_paused("$bpdir/runs", { reason => 'reauth needed', manual => 1, created_at => time - 3600 });
    my $probed = 0;
    run_once($bpdir, $bp, env_probe => sub { $probed++; return (1, undef) }, tun => { broken_env_probe => 60 });
    is($probed, 0, '1dba: a manual pause with any other reason is never probed');
    ok(-e "$bpdir/runs/.paused", '1dba: nor lifted');
}

done_testing();
