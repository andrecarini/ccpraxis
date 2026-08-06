#!/usr/bin/env perl
# b03-keeper-resilience-antispam — the immutable test oracle.
#
# Derived ONLY from specs/04-keeper-resilience-antispam-spec.md (AC-1..AC-11;
# AC-12 is the whole-suite regression check, not new test code here).
#
# Style follows t/05-keeper.t (keeper_tick/atomic_writeback fixtures), t/06-
# orchestrator.t (fetch_usage/_enter_pause_manual direct calls), t/08-
# orchestrator-scenarios.t (base_tunables/mk_bp/needs_you_count shape) and
# t/21-durable-checkpoint-commits.t (the multi-tick drive() harness + the
# sc()/hv() call-guard idiom for subs that may not exist yet, so a missing
# subroutine is ONE failing assertion, never an aborted file).
#
# Per spec §4: requires ONLY bp-orchestrator.pl, which transitively requires
# bp-token-keeper.pl (BpKeeper:: is available without a second load).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps qw(chmod_works);

# The R1 group induces a deterministic close()-time EFBIG by capping RLIMIT_FSIZE
# with prlimit(1) (util-linux). Without prlimit no cap is set, the write simply
# SUCCEEDS, and the assertions invert: "atomic_writeback dies" fails because
# nothing made it die, and "the creds file is byte-identical" fails because the
# write it was supposed to be protected from went through normally. Probe for the
# tool rather than the platform — it is the actual dependency.
my $HAVE_PRLIMIT = do { my $o = `prlimit --version 2>/dev/null`; (defined $o && $o =~ /\S/) ? 1 : 0 };
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use Errno qw(EBUSY EXDEV EACCES);

require "$Bin/../../scripts/bp-orchestrator.pl";

plan tests => 89;

my $J    = JSON::PP->new;
my $UJ   = JSON::PP->new->utf8->canonical;
my $ROOT = tempdir(CLEANUP => 1);

# Two clocks, same instant, different units (per the house convention):
#   $NOW_MS  — ms, for direct BpKeeper:: calls (05-keeper.t style).
#   $NOW     — seconds, for the orchestrator loop's `now`/`sleep` seam.
my $NOW_MS = 1_782_000_000_000;
my $NOW    = $NOW_MS / 1000;
my $H      = 3_600_000;

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------
sub spit       { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw  { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }
sub slurp      { my ($p) = @_; return slurp_raw($p) // '' }
sub mode_of    { my @st = stat(shift); return @st ? ($st[2] & 07777) : undef }

# Call guard for subs that may not exist yet (t/21:46) — a missing subroutine
# becomes a string, never an aborted script.
sub sc { my $c = shift; my $r = eval { $c->() }; return $@ ? 'DIED: ' . ((split /\n/, $@)[0]) : $r }

# --- R1/R3 scaffolding: a forked probe for OS-level fault injection --------
# This sandbox runs the whole suite as root, where chmod-based failure
# injection is a no-op (root bypasses DAC checks) and there is no capability
# to mount/chattr/ulimit the WHOLE test process without corrupting its own
# TAP output. fork_probe() isolates a real, deterministic OS-level fault
# (an rlimit or a dropped-privilege uid, applied via $setup) to a disposable
# CHILD process that runs ONLY $code, reporting back over a NUL-delimited
# pipe (open($fh,"-|")) so a die/signal inside the child can never touch
# this process's own Test::More state. The child never runs Test::More
# assertions and always exit()s explicitly.
sub fork_probe {
    my ($setup, $code) = @_;
    my $kid_pid = open(my $kid, "-|");
    defined $kid_pid or die "fork_probe: fork failed: $!";
    if ($kid_pid == 0) {
        $setup->() if $setup;
        my $died = 0; my $msg = '';
        eval { $code->(); 1 } or do { $died = 1; $msg = $@ };
        print "$died\0$msg";
        exit 0;
    }
    my $full = join('', <$kid>);
    close $kid;
    my ($died, $msg) = split /\0/, $full, 2;
    return { died => ($died ? 1 : 0), msg => ($msg // '') };
}

# One JSON record per line (04-log.t / 21-durable-checkpoint-commits.t:558-564).
sub log_events {
    my ($txt) = @_;
    return () unless defined $txt && length $txt;
    return map { eval { $UJ->decode($_) } || {} } grep { /\S/ } split /\n/, $txt;
}
sub log_events_file { my ($p) = @_; return log_events(slurp($p)) }

sub make_creds {
    my ($path, $exp) = @_;
    $exp //= $NOW_MS + 5 * $H;
    spit($path, $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb',
        expiresAt => $exp, scopes => ['user:inference','user:profile'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
}
sub try_read_creds {
    my ($path) = @_;
    my $raw = slurp_raw($path);
    return undef unless defined $raw;
    my $d = eval { $J->decode($raw) };
    return $d ? $d->{claudeAiOauth} : undef;
}

# --- orchestrator-loop fixtures (AC-1, AC-3, AC-4) --------------------------
my $bpn = 0;
sub mk_bp {
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die "blueprint: $!";
    print $b "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| solo | d | \x{2014} | sonnet | pending |\n";
    close $b;
    open my $l, '>', "$dir/packages/solo.md" or die "ledger: $!";
    print $l "---\npackage: solo\nblueprint: T\nstatus: pending\nwrite_set: p/s/\ntest_paths: p/s/\n"
           . "last_updated: 2026-06-24T00:00:00Z\n---\n# solo\n\n## Next action\n\ngo\n";
    close $l;
    return $dir;
}

# tunables literal per spec §4 fixture recipe (08-orchestrator-scenarios.t:68-73
# style, plus the b03 additions: watch_tick=>10, keeper_int=>100_000 so the
# keeper fires only on tick 1 and cannot win the recovery race, usage_fail=>60,
# the three creds_bo_* keys, tele_retry=>3).
sub b03_tunables {
    my ($dir, %o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>10,
             keeper_int=>100_000, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$dir/busy",
             creds_bo_base=>60, creds_bo_mult=>2, creds_bo_max=>1800, %o };
}

my $USAGE_OK = $J->encode({ five_hour => { utilization=>10, resets_at=>'2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization=>5,  resets_at=>'2099-01-01T12:00:00+00:00' } });

sub write_valid_creds {
    my ($path) = @_;
    spit($path, $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-RECOVERED-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RECOVEREDREF-bbbbbbbbbbbbbbbb',
        expiresAt => 9_000_000_000_000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
}

# drive(...) — ONE BpOrch::run() across several ticks with a fake clock,
# copied from 21-durable-checkpoint-commits.t:570-615 (once=>0 + a sleep seam
# that advances a fake clock, runs an optional per-tick world mutation, and
# finally dies "STOP\n", wrapped in eval).
sub drive {
    my (%o) = @_;
    my $dir   = $o{dir};
    my $step  = $o{step} // 10;
    my $stop  = $o{stop} // 400;
    my $clock = $NOW;
    my $ticks = 0;
    my $err;
    my %opt = (
        blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables  => ($o{tunables} || b03_tunables($dir)),
        once      => 0,
        now       => sub { $clock },
        sleep     => sub {
            $ticks++;
            $clock += $step;
            $o{on_tick}->($dir, $ticks, $clock) if $o{on_tick};
            die "STOP\n" if $ticks >= $stop;
        },
        http_get  => ($o{http_get} || sub { { status => 200, content => $USAGE_OK } }),
        http_post => sub { { status => 200, content => '{}' } },
        launch    => sub { 0 },
    );
    eval { BpOrch::run(\%opt); 1 } or $err = $@;
    return { dir => $dir, ticks => $ticks, err => ($err // ''), log => slurp("$dir/runs/orchestrator.log") };
}

sub needs_you_count { my $bpdir = shift; my $d = "$bpdir/runs/needs-you"; return 0 unless -d $d;
                       opendir my $h, $d; my @j = grep { /\.json$/ } readdir $h; closedir $h; scalar @j }
sub needs_you_count_runs { my $runs = shift; my $d = "$runs/needs-you"; return 0 unless -d $d;
                       opendir my $h, $d; my @j = grep { /\.json$/ } readdir $h; closedir $h; scalar @j }

# ===========================================================================
# AC-1 — one line per episode, both pollers collapsed.
# ===========================================================================
{
    my $dir = mk_bp();
    spit("$dir/creds.json", 'not json{');
    BpOrch::write_paused("$dir/runs", { reason=>'token-floor', manual=>1, created_at=>$NOW-1 });

    my $r = drive(dir => $dir, step => 10, stop => 400);
    my @ev = log_events($r->{log});

    my @ce = grep { ($_->{type} // '') eq 'creds_error' } @ev;
    is(scalar @ce, 1, 'AC-1 exactly one creds_error line across the whole run (both pollers collapse into one episode)');

    my @pz = grep { (($_->{type} // '') eq 'pause') && (($_->{reason} // '') =~ /pause-creds/) } @ev;
    is(scalar @pz, 1, 'AC-1 exactly one creds-reason pause line across the whole run');

    my $p = BpOrch::read_paused("$dir/runs");
    is(($p ? $p->{reason} : undef), 'token-floor', 'AC-1 pre-existing manual pause reason preserved (first-manual-reason-wins)');

    is(needs_you_count($dir), 1, 'AC-1 needs-you queue holds exactly one entry');
}

# ===========================================================================
# AC-2 — the pinned backoff schedule, as a pure function.
# ===========================================================================
{
    sub bo { my ($n, $t) = @_; return sc(sub { BpOrch::creds_backoff_secs($n, $t) }) }

    my @got = map { bo($_, {}) } 1 .. 8;
    is_deeply(\@got, [60,120,240,480,960,1800,1800,1800], 'AC-2 pinned default schedule for n=1..8');

    my $t2 = { creds_bo_base=>10, creds_bo_mult=>3, creds_bo_max=>50 };
    my @got2 = map { bo($_, $t2) } 1 .. 4;
    is_deeply(\@got2, [10,30,50,50], 'AC-2 tunables override the default schedule (base=10,mult=3,max=50)');

    {
        local $ENV{BP_CREDS_BACKOFF_BASE_SECS} = 5;
        is(bo(1, {}), 5, 'AC-2 env var BP_CREDS_BACKOFF_BASE_SECS is the second-priority source (n=1)');
    }

    is(bo(0, {}),      60, 'AC-2 n=0 (falls back to n=1) returns the base');
    is(bo(undef, {}),  60, 'AC-2 n=undef (falls back to n=1) returns the base');
    is(bo(-5, {}),     60, 'AC-2 n=-5 (negative, falls back to n=1) returns the base');
}

# ===========================================================================
# AC-3 — the loop actually uses the schedule (observed from disk).
# ===========================================================================
{
    my $dir = mk_bp();
    spit("$dir/creds.json", 'not json{');
    BpOrch::write_paused("$dir/runs", { reason=>'token-floor', manual=>1, created_at=>$NOW-1 });

    my $wrote_valid = 0;
    my $r = drive(dir => $dir, step => 10, stop => 400, on_tick => sub {
        my ($d, $ticks, $clock) = @_;
        if (!$wrote_valid && $clock - $NOW >= 1000) {
            write_valid_creds("$d/creds.json");
            $wrote_valid = 1;
        }
    });

    my @ev = log_events($r->{log});
    my @cr = grep { ($_->{type} // '') eq 'creds_recovered' } @ev;
    is(scalar @cr, 1, 'AC-3 exactly one creds_recovered event is logged');

    my $ev0 = $cr[0] // {};
    is($ev0->{at},     $NOW + 1860, 'AC-3 recovery at NOW+1860 after 5 failed polls (pinned backoff schedule)');
    is($ev0->{polls},  5,           'AC-3 creds_recovered carries polls==5 (five failed usage polls in the episode)');
    is($ev0->{source}, 'usage',     'AC-3 creds_recovered source is usage (keeper_int keeps the keeper out of the race)');
}

# ===========================================================================
# AC-4 — a new episode after recovery is announced again.
# ===========================================================================
{
    my $dir = mk_bp();
    spit("$dir/creds.json", 'not json{');
    BpOrch::write_paused("$dir/runs", { reason=>'token-floor', manual=>1, created_at=>$NOW-1 });

    my $wrote_valid = 0;
    my $recorrupted = 0;
    my $r = drive(dir => $dir, step => 10, stop => 900, on_tick => sub {
        my ($d, $ticks, $clock) = @_;
        if (!$wrote_valid && $clock - $NOW >= 1000) {
            write_valid_creds("$d/creds.json");
            $wrote_valid = 1;
        }
        if ($wrote_valid && !$recorrupted) {
            # Only re-corrupt AFTER the recovery has actually been announced on
            # disk, so the first episode's recovery poll has a chance to see
            # the valid file (rather than racing it out from under the poller).
            my @ev = log_events(slurp("$d/runs/orchestrator.log"));
            if (grep { ($_->{type} // '') eq 'creds_recovered' } @ev) {
                spit("$d/creds.json", 'not json{ again');
                $recorrupted = 1;
            }
        }
    });

    my @ev = log_events($r->{log});
    my @ce = grep { ($_->{type} // '') eq 'creds_error' } @ev;
    my @pz = grep { (($_->{type} // '') eq 'pause') && (($_->{reason} // '') =~ /pause-creds/) } @ev;
    is(scalar @ce, 2, 'AC-4 two creds_error lines total: the gate is per-episode, never a permanent mute');
    is(scalar @pz, 2, 'AC-4 two creds-reason pause lines total (one per episode)');
}

# ===========================================================================
# AC-5 — the quiet seams in isolation.
# ===========================================================================
{
    my $c = "$ROOT/ac5-keeper.json"; spit($c, 'not json{');

    my $L1 = "$ROOT/ac5-keeper-quiet.log";
    my $r1 = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW_MS, log_path=>$L1,
                                      quiet_creds_error=>1, http_post=>sub { die "must not be called" } });
    is($r1->{action}, 'pause-creds', 'AC-5 keeper_tick quiet_creds_error=1 still returns pause-creds');
    is(scalar(grep { ($_->{type} // '') eq 'creds_error' } log_events_file($L1)), 0,
       'AC-5 keeper_tick quiet_creds_error=1 emits NO creds_error line');

    my $L2 = "$ROOT/ac5-keeper-loud.log";
    my $r2 = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW_MS, log_path=>$L2,
                                      quiet_creds_error=>0, http_post=>sub { die "must not be called" } });
    is($r2->{action}, 'pause-creds', 'AC-5 keeper_tick quiet_creds_error=0 still returns pause-creds');
    is(scalar(grep { ($_->{type} // '') eq 'creds_error' } log_events_file($L2)), 1,
       'AC-5 keeper_tick quiet_creds_error=0 (default) emits exactly one creds_error line');

    my $c2 = "$ROOT/ac5-usage.json"; spit($c2, 'not json{');

    my $L3 = "$ROOT/ac5-usage-quiet.log";
    my $u1 = BpOrch::fetch_usage({ creds_path=>$c2, log_path=>$L3,
                                    quiet_creds_error=>1, http_get=>sub { die "must not be called" } });
    is($u1->{action}, 'pause-creds', 'AC-5 fetch_usage quiet_creds_error=1 still returns pause-creds');
    is(scalar(grep { ($_->{type} // '') eq 'creds_error' } log_events_file($L3)), 0,
       'AC-5 fetch_usage quiet_creds_error=1 emits NO creds_error line');

    my $L4 = "$ROOT/ac5-usage-loud.log";
    my $u2 = BpOrch::fetch_usage({ creds_path=>$c2, log_path=>$L4,
                                    quiet_creds_error=>0, http_get=>sub { die "must not be called" } });
    is($u2->{action}, 'pause-creds', 'AC-5 fetch_usage quiet_creds_error=0 still returns pause-creds');
    is(scalar(grep { ($_->{type} // '') eq 'creds_error' } log_events_file($L4)), 1,
       'AC-5 fetch_usage quiet_creds_error=0 (default) emits exactly one creds_error line');
}

# ===========================================================================
# AC-6 — `quiet_log` never mutes a state change (INV-P1).
# ===========================================================================
{
    my $runs = "$ROOT/ac6-runs"; mkdir $runs;
    my $log  = "$ROOT/ac6.log";
    my $dec  = { package=>'_fleet', blueprint=>'T', kind=>'contract-drift', question=>'creds unreadable',
                 context=>'c', created_at=>$NOW };

    BpOrch::_enter_pause_manual($runs, $log, 'pause-creds', $dec, { quiet_log=>1 });
    ok(-e "$runs/.paused", 'AC-6 first call (no existing pause) writes .paused despite quiet_log=>1');

    my @p1 = grep { ($_->{type} // '') eq 'pause' } log_events_file($log);
    is(scalar @p1, 1, 'AC-6 first call logs exactly one pause line despite quiet_log=>1 (INV-P1)');
    is(needs_you_count_runs($runs), 1, 'AC-6 first call queues exactly one needs-you entry');

    my $paused_before = BpOrch::read_paused($runs);

    BpOrch::_enter_pause_manual($runs, $log, 'pause-creds', $dec, { quiet_log=>1 });
    is_deeply(BpOrch::read_paused($runs), $paused_before,
              'AC-6 second call (existing manual pause) leaves .paused unchanged');
    is(needs_you_count_runs($runs), 1, 'AC-6 second call: needs-you still exactly one entry (own dedup)');

    my @p2 = grep { ($_->{type} // '') eq 'pause' } log_events_file($log);
    is(scalar @p2, 1, 'AC-6 second call logs NO additional pause line (quiet_log honoured for a repeat)');
}

# ===========================================================================
# AC-7 / AC-8 — read path on bad creds: pause action, never a write.
# REGRESSION tests over ALREADY-CORRECT behaviour (§B1/§B2) — nobody should
# "fix" the code these cover; they are expected to pass against today's code.
# ===========================================================================
sub bad_creds_fixtures {
    my ($prefix) = @_;
    my %f;
    $f{malformed} = "$ROOT/$prefix-malformed.json"; spit($f{malformed}, 'not json{');
    my $valid = $J->encode({ claudeAiOauth => { accessToken=>'sk-ant-T', refreshToken=>'sk-ant-R',
                              expiresAt=>$NOW_MS+$H, scopes=>['user:inference'],
                              subscriptionType=>'max', rateLimitTier=>'x' } });
    $f{truncated} = "$ROOT/$prefix-truncated.json"; spit($f{truncated}, substr($valid, 0, int(length($valid)/2)));
    $f{empty}     = "$ROOT/$prefix-empty.json";     spit($f{empty}, '');
    $f{missing}   = "$ROOT/$prefix-missing.json";   # never created
    return \%f;
}

{
    my $fx = bad_creds_fixtures('ac7');
    for my $kind (qw(malformed truncated empty missing)) {
        my $c = $fx->{$kind};
        my $fp_before = (-e $c) ? slurp_raw($c) : '<MISSING>';

        my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW_MS, http_post=>sub { die "must not be called" } });
        is($r->{action}, 'pause-creds', "AC-7 keeper_tick($kind creds): returns pause-creds");

        my $fp_after = (-e $c) ? slurp_raw($c) : '<MISSING>';
        is($fp_after, $fp_before, "AC-7 keeper_tick($kind creds): file bytes/absence unchanged");

        my @residue = grep { -e } ("$c.lock", glob("$c.tmp*"));
        is(scalar @residue, 0, "AC-7 keeper_tick($kind creds): no \$c.lock / \$c.tmp* residue created");
    }
}

{
    my $fx = bad_creds_fixtures('ac8');
    for my $kind (qw(malformed truncated empty missing)) {
        my $c = $fx->{$kind};
        my $fp_before = (-e $c) ? slurp_raw($c) : '<MISSING>';

        my $u = BpOrch::fetch_usage({ creds_path=>$c, http_get=>sub { die "must not be called" } });
        is($u->{action}, 'pause-creds', "AC-8 fetch_usage($kind creds): returns pause-creds");

        my $fp_after = (-e $c) ? slurp_raw($c) : '<MISSING>';
        is($fp_after, $fp_before, "AC-8 fetch_usage($kind creds): file bytes/absence unchanged");

        my @residue = grep { -e } ("$c.lock", glob("$c.tmp*"));
        is(scalar @residue, 0, "AC-8 fetch_usage($kind creds): no \$c.lock / \$c.tmp* residue created");
    }
}

# ===========================================================================
# AC-9 — a failed in-place write leaves the original intact, no temp residue.
# ===========================================================================
{
    my $c = "$ROOT/ac9-wb.json"; make_creds($c); chmod 0640, $c;
    my $before      = slurp_raw($c);
    my $before_mode = mode_of($c);

    my $busy = sub { $! = EBUSY; return 0 };
    my $bad_inplace = sub {
        my ($p, $bytes, $mode) = @_;
        open my $f, '+<:raw', $p or die "test-fixture open failed: $!";
        print $f substr($bytes, 0, 20);
        close $f;
        die "simulated interrupted write\n";
    };

    my $resp = { access_token=>'sk-ant-NEWACCESS9-xxxxxxxxxxxxxxxxxxxx',
                 refresh_token=>'sk-ant-NEWREF9-yyyyyyyyyyyyyyyyyyyy', expires_in=>28800 };
    my $ok = eval { BpKeeper::atomic_writeback($c, $resp, 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW_MS,
                                                $busy, $bad_inplace); 1 };
    my $err = $@;

    ok(!$ok, 'AC-9 atomic_writeback DIES when the injected in-place writer fails mid-write');
    like(($err // ''), qr/original creds restored/, 'AC-9 die message matches /original creds restored/ (INV-W3)');
    is(slurp_raw($c), $before, 'AC-9 creds file byte-identical to pre-call content after the failed write (INV-W2)');
    is(mode_of($c), $before_mode, 'AC-9 creds file mode unchanged after the failed write');

    my $after = try_read_creds($c);
    is(($after ? $after->{accessToken} : undef), 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa',
       'AC-9 creds file still decodes and holds the OLD accessToken');

    my @tmp = glob("$c.tmp*");
    is_deeply(\@tmp, [], 'AC-9 no *.tmp* residue remains beside the creds file');
}

# ===========================================================================
# AC-10 — the success fallback still works and cleans up.
# ===========================================================================
{
    my $c = "$ROOT/ac10-wb.json"; make_creds($c); chmod 0640, $c;
    my $before_mode = mode_of($c);

    my $busy = sub { $! = EBUSY; return 0 };
    my $resp = { access_token=>'sk-ant-NEWACCESS10-wwwwwwwwwwwwwwwwwwww',
                 refresh_token=>'sk-ant-NEWREF10-zzzzzzzzzzzzzzzzzzzz', expires_in=>3600 };
    my $wb = eval { BpKeeper::atomic_writeback($c, $resp, 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW_MS, $busy) };

    is($wb, 'ok', 'AC-10 default in-place writer still returns ok on EBUSY (unchanged happy path)');
    my $o = try_read_creds($c) // {};
    is($o->{accessToken},  'sk-ant-NEWACCESS10-wwwwwwwwwwwwwwwwwwww', 'AC-10 rotated accessToken lands on disk');
    is($o->{refreshToken}, 'sk-ant-NEWREF10-zzzzzzzzzzzzzzzzzzzz',    'AC-10 rotated refreshToken lands on disk');
    is($o->{expiresAt},    $NOW_MS + 3600*1000,                      'AC-10 rotated expiresAt lands on disk');
    is(mode_of($c), $before_mode, 'AC-10 mode is preserved through the in-place fallback');

    my @tmp = glob("$c.tmp*");
    is_deeply(\@tmp, [], 'AC-10 no *.tmp* residue remains after the in-place fallback');
}

# ===========================================================================
# AC-11 — an existing target is never truncated by the create branch (INV-W4).
# ===========================================================================
{
    my $c = "$ROOT/ac11-existing.json"; spit($c, 'ORIGINAL-NON-EMPTY-BYTES'); chmod 0644, $c;
    my $before = slurp_raw($c);
    my $open_fn = sub {
        my ($how, $p) = @_;
        return undef if $how =~ /^\+</;
        open(my $fh, $how, $p) or return undef;
        return $fh;
    };
    my $ok  = eval { BpKeeper::_inplace_overwrite($c, 'NEW-BYTES-MUST-NOT-LAND', 0600, $open_fn); 1 };
    my $err = $@;

    ok(!$ok, 'AC-11 _inplace_overwrite DIES when the +< open fails on an EXISTING file');
    like(($err // ''), qr/in-place open/,
         'AC-11 die message names the in-place open failure (no truncating create fallback, INV-W4)');
    is(slurp_raw($c), $before, 'AC-11 existing file bytes are unchanged after the failed open');
    ok(length(slurp_raw($c) // '') > 0, 'AC-11 existing file was NOT truncated to empty by a create fallback');
}
{
    my $c2  = "$ROOT/ac11-absent.json";   # never created
    my $ok2 = eval { BpKeeper::_inplace_overwrite($c2, 'CREATED-BYTES-XYZ', 0600); 1 };

    ok($ok2, 'AC-11 _inplace_overwrite creates an absent path with the default opener');
    is(slurp_raw($c2), 'CREATED-BYTES-XYZ', 'AC-11 absent path: file created with exactly the given bytes');
  SKIP: {
    skip 'this filesystem stores no POSIX permission bits, so the created mode is unobservable', 1
        unless chmod_works();
    is(mode_of($c2), 0600, 'AC-11 absent path: file created with mode 0600');
  }
}

# ===========================================================================
# R1 (redteam MAJOR-1 regression) — a print()/close() failure on the INITIAL
# temp write (bp-token-keeper.pl:99, strictly BEFORE the chmod at :100 and
# before any unlink) must not orphan "$path.tmp.$$" holding the plaintext new
# access/refresh tokens at a wide-open default-umask mode.
#
# This sandbox runs as root, where chmod-based failure injection is a no-op
# (root bypasses DAC checks -- verified empirically), so we cannot "make the
# directory unwritable" as a non-root repro would. Instead we force a REAL,
# deterministic close()-time EFBIG via RLIMIT_FSIZE, scoped to a disposable
# forked child (fork_probe) so the limit never touches this test runner's
# own log/TAP writes. The FSIZE cap is measured from THIS run's actual
# serialized bytes (via an untouched happy-path writeback to a scratch
# file) rather than assumed from JSON key order, so the truncated residue
# is guaranteed to contain both full new-token strings if orphaned.
# ===========================================================================
{
    my $c = "$ROOT/r1-wb.json"; make_creds($c); chmod 0640, $c;
    my $before      = slurp_raw($c);
    my $before_mode = mode_of($c);

    my $resp = { access_token=>'sk-ant-NEWACCESSR1-xxxxxxxxxxxxxxxxxxxx',
                 refresh_token=>'sk-ant-NEWREFR1-yyyyyyyyyyyyyyyyyyyy', expires_in=>28800 };

    my $scratch = "$ROOT/r1-scratch.json"; spit($scratch, $before); chmod 0640, $scratch;
    my $measure_ok = eval { BpKeeper::atomic_writeback($scratch, $resp, 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW_MS); 1 };
    die "R1 fixture broken: measurement writeback failed: $@" unless $measure_ok;
    my $full_out = slurp_raw($scratch);
    my $tok_a = 'sk-ant-NEWACCESSR1-xxxxxxxxxxxxxxxxxxxx';
    my $tok_r = 'sk-ant-NEWREFR1-yyyyyyyyyyyyyyyyyyyy';
    my $at_a  = index($full_out, $tok_a);
    my $at_r  = index($full_out, $tok_r);
    die "R1 fixture broken: measured happy-path output is missing an expected token" if $at_a < 0 || $at_r < 0;
    my $last_end = ($at_a > $at_r ? $at_a + length($tok_a) : $at_r + length($tok_r));
    my $cap = $last_end + 5;
    die "R1 fixture broken: cap ($cap) is not short of the full write (" . length($full_out) . ")"
        unless $cap < length($full_out);

    my $p = fork_probe(
        sub { system("prlimit --pid=$$ --fsize=$cap >/dev/null 2>&1"); $SIG{XFSZ} = 'IGNORE'; },
        sub { BpKeeper::atomic_writeback($c, $resp, 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW_MS); },
    );

  SKIP: {
    skip 'prlimit(1) is unavailable, so no RLIMIT_FSIZE cap was applied and the write did not '
       . 'fail — the mid-write-failure behaviour is NOT exercised here', 1 unless $HAVE_PRLIMIT;
    is($p->{died}, 1,
       'R1 atomic_writeback dies when the INITIAL temp-file close() fails mid-write (EFBIG via a per-child RLIMIT_FSIZE, never applied to the test runner itself)');
  }

    my ($residue_file) = grep { -f $_ } glob("$c.tmp*");
    ok(!defined($residue_file), 'R1 INV-W1: no $path.tmp.* file survives the failed initial temp write')
        or diag("residue found: $residue_file");

    my $residue_bytes = defined($residue_file) ? (slurp_raw($residue_file) // '') : '';
    ok(index($residue_bytes, $tok_a) < 0 && index($residue_bytes, $tok_r) < 0,
       'R1 SECURITY: no surviving temp residue contains the new access or refresh token bytes');

    ok(!defined($residue_file) || (mode_of($residue_file) & 077) == 0,
       'R1 SECURITY: any surviving temp residue is not group/world-readable (no wide-mode window survives)');

  SKIP: {
    skip 'prlimit(1) unavailable: the write SUCCEEDED rather than failing, so "unchanged after a '
       . 'failed write" has no failed write to be unchanged after', 1 unless $HAVE_PRLIMIT;
    is(slurp_raw($c), $before, 'R1 the real creds file is byte-identical after the failed initial temp write (only the orphan is at risk, not the target)');
  }
    is(mode_of($c), $before_mode, 'R1 the real creds file mode is unchanged after the failed initial temp write');
}

# ===========================================================================
# R2 (redteam MAJOR-2 regression) — a rollback must not destroy the only
# surviving copy of the new, server-rotated tokens. By the time the restore
# at :130 runs, the refresh POST has already rotated the refresh token
# server-side, so restoring $orig_raw re-installs a credential the server
# has invalidated -- while :132's "unlink $tmp" (unconditional, before
# either die branch) deletes the only copy of the tokens that ARE still
# valid. Uses the exact same EBUSY + partial-write-then-die fixture as AC-9
# (a real fault, no OS trickery needed) to reach that restore branch.
# ===========================================================================
{
    my $c = "$ROOT/r2-wb.json"; make_creds($c); chmod 0640, $c;
    my $before = slurp_raw($c);

    my $busy = sub { $! = EBUSY; return 0 };
    my $bad_inplace = sub {
        my ($p, $bytes, $mode) = @_;
        open my $f, '+<:raw', $p or die "test-fixture open failed: $!";
        print $f substr($bytes, 0, 20);
        close $f;
        die "simulated interrupted write\n";
    };

    my $resp = { access_token=>'sk-ant-NEWACCESSR2-xxxxxxxxxxxxxxxxxxxx',
                 refresh_token=>'sk-ant-NEWREFR2-yyyyyyyyyyyyyyyyyyyy', expires_in=>28800 };
    my $ok = eval { BpKeeper::atomic_writeback($c, $resp, 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW_MS,
                                                $busy, $bad_inplace); 1 };
    my $err = $@;

    ok(!$ok, 'R2 atomic_writeback dies via the EBUSY + failing-inplace path (same fixture shape as AC-9)');
    is(slurp_raw($c), $before, 'R2 the restore itself succeeds (original creds are back in place) -- the ONLY problem is losing the new tokens');

    # WITHDRAWN: an earlier version of this block asserted (via @residue /
    # $recoverable over glob("$c.tmp*")) that the new, server-already-rotated
    # tokens must remain recoverable from a retained temp/sidecar file. That
    # directly contradicted AC-9 (:434), which asserts no *.tmp* residue may
    # remain beside the creds file -- a verbatim restatement of this
    # package's done-criterion (c), "cleans up the temp file (no
    # partial/corrupt target)". AC-9 prevails: retaining a token-bearing file
    # on disk to satisfy R2 would reintroduce the MAJOR-1 credential-
    # disclosure risk this package exists to close, and a differently-named
    # sidecar can't satisfy R2 either since its glob targets "$c.tmp*"
    # specifically. The residual risk this withdrawal accepts -- a transient
    # fault losing the newly-rotated tokens with no on-disk recovery path --
    # is documented in the package ledger; its mitigations are the
    # stale-refresh-token warning below (the salvageable half of MAJOR-2)
    # and the launcher re-materializing creds from the host on next run. Do
    # not restore a recoverability assertion here without re-reading that
    # history.

    like(($err // ''), qr/refresh token.*stale|stale.*refresh token/i,
       'R2 the die message warns that the just-restored refresh token may already be stale (the auth server rotated it server-side before this restore ever ran)');
}

# ===========================================================================
# R3 (redteam MAJOR-3 regression) — the restore must not claim damage to a
# file it never actually touched. The restore at :130 reuses the exact same
# real opener (_inplace_overwrite, unmocked) that the primary attempt just
# used, so a real open-step failure (no bytes ever written) hits BOTH
# identically and produces "RESTORE FAILED ... creds may be damaged" for a
# byte-for-byte untouched file.
#
# Forced via a REAL (non-mocked) permission failure: fork_probe drops the
# child's uid/gid to a non-root identity (this sandbox runs the suite as
# root, where a chmod-based repro is a no-op for the parent) against a
# 0444 creds file -- both the primary in-place attempt AND the restore hit
# the identical EACCES, with zero bytes ever written to the target.
# ===========================================================================
{
    my $r3dir = tempdir(CLEANUP => 1); chmod 0777, $r3dir;   # world-traversable/writable
    my $c = "$r3dir/r3-wb.json"; make_creds($c);
    my $before = slurp_raw($c);
    chmod 0444, $c;   # readable, NOT writable -- real for a non-root child, even root-owned

    my $resp = { access_token=>'sk-ant-NEWACCESSR3-xxxxxxxxxxxxxxxxxxxx',
                 refresh_token=>'sk-ant-NEWREFR3-yyyyyyyyyyyyyyyyyyyy', expires_in=>28800 };
    my $busy = sub { $! = EBUSY; return 0 };

    my $p = fork_probe(
        sub { $) = 65534; $( = 65534; $> = 65534; $< = 65534; },   # drop privileges: makes 0444 real
        sub { BpKeeper::atomic_writeback($c, $resp, 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW_MS, $busy); },
    );

    chmod 0640, $c;   # restore this (root) process's own ability to inspect/clean up

    is($p->{died}, 1, 'R3 atomic_writeback dies when a real permission failure hits both the in-place attempt and its restore identically');
    is(slurp_raw($c), $before, 'R3 the creds file is byte-identical to its pre-call bytes -- neither attempt ever wrote to it');
    unlike($p->{msg}, qr/RESTORE FAILED|may be damaged/i,
       'R3 SECURITY: the die message must NOT claim the creds may be damaged for a file that was never actually touched (must distinguish "nothing written" from "write failed midway")');
}

# ===========================================================================
# R4 (redteam MAJOR-4 regression) — a KEEPER-sourced recovery must also
# re-arm the usage poller: $creds_ok (bp-orchestrator.pl:1158-1164) resets
# %creds_gate but never resets $next_usage, which the pause-creds arm can
# park up to creds_bo_max=1800s into the future. Every OTHER loop fixture in
# this file pins keeper_int=>100_000 specifically so the keeper cannot win
# the recovery race (per spec's own fixture recipe) -- this is the one
# fixture that does the opposite, giving this path its first-ever coverage.
# ===========================================================================
{
    my $dir = mk_bp();
    spit("$dir/creds.json", 'not json{');
    BpOrch::write_paused("$dir/runs", { reason=>'token-floor', manual=>1, created_at=>$NOW-1 });

    my $tun = b03_tunables($dir, keeper_int => 50);   # small: the keeper wins the race

    my @usage_poll_clocks;
    my $cur_clock = $NOW;
    my $wrote_valid = 0;
    my $custom_http_get = sub { push @usage_poll_clocks, $cur_clock; return { status => 200, content => $USAGE_OK } };

    my $r = drive(dir => $dir, step => 10, stop => 150, tunables => $tun, http_get => $custom_http_get,
        on_tick => sub {
            my ($d, $ticks, $clock) = @_;
            $cur_clock = $clock;
            if (!$wrote_valid && $clock - $NOW >= 1010) {
                write_valid_creds("$d/creds.json");
                $wrote_valid = 1;
            }
        });

    my @ev = log_events($r->{log});
    my @cr = grep { ($_->{type} // '') eq 'creds_recovered' } @ev;
    is(scalar @cr, 1, 'R4 exactly one creds_recovered event is logged');

    my $ev0 = $cr[0] // {};
    is($ev0->{source}, 'keeper', 'R4 the keeper (small keeper_int) is the poller that observes recovery, not usage');

    my $rec_at = $ev0->{at};
    ok(defined $rec_at, 'R4 creds_recovered carries an at timestamp')
        or diag("no creds_recovered event / no at field; log tail: " . substr($r->{log}, -400));

    my $PROMPT_WINDOW = 100;   # seconds -- well inside the up-to-1800s parked backoff
    my @prompt = (defined $rec_at) ? (grep { $_ >= $rec_at && $_ <= $rec_at + $PROMPT_WINDOW } @usage_poll_clocks) : ();
    ok(scalar(@prompt) > 0,
       "R4 the usage poller re-polls promptly (within ${PROMPT_WINDOW}s) after a keeper-sourced recovery, instead of staying parked at the pre-recovery backoff deadline (MAJOR-4)")
        or diag("usage http_get call clocks (rel to NOW): [" . join(',', map { defined($rec_at) ? $_ - $NOW : $_ } @usage_poll_clocks) . "], recovered at " . (($rec_at//0) - $NOW));
}
