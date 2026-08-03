#!/usr/bin/env perl
# t/82-orphaned-judge-recovery.t — immutable oracle for b31-orphaned-judge-marker-recovery.
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b31-orphaned-judge-marker-recovery-spec.md
# (C1..C6, plus the vacuity gate) and
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages/b31-orphaned-judge-marker-recovery.md
# (the live incident: 2026-07-30T07:57:02Z, seven packages parked in one second, all seven
# judge markers carrying a 6103-byte jsonl with a rate-limit rejection and a long-dead pid;
# two of the seven -- b27, s19 -- were `running` with live coordinator work at the time).
# C7 (protocol doc) mirrors t/80's own C6 pattern, per the driver's explicit instruction.
#
# WRITTEN BLIND TO THE FIX. Today the resolve-judge-verdict loop in bp-orchestrator.pl
# classifies a missing verdict on ELAPSED TIME ALONE:
#     next unless $started && ($now - $started) > $t->{judge_to};
#     _log($log, 'judge_timeout', { kind => 'resolve', package => $pkg });
#     $v = { _timeout => 1 };               # normalize_resolve -> park
# It never calls judge_pid()/judge_pid_path() (grepped: those ARE used on the harvest
# paths, never on this one) and never consults the package's own ledger status or
# registry coordinator pid. So every fixture below that should NOT park (C1, C3, C4)
# is expected to park TODAY, and every fixture that should re-fire (C1, C5) never does
# (spawn_judge is never called from this path today at all -- grepped, zero call sites).
# Every assertion is expected to fail on WRONG BEHAVIOUR (an orphan parked, a live judge
# timed out, a running package parked, a re-fire that never happened), never on a Perl
# exception, missing module, or wrong require path -- this file calls only functions
# that exist on disk today (BpOrch::run / mark_judge_inflight / judge_pid_path /
# judge_verdict_path / read_registry / update_registry_pkg), per SYN-23 (grep by
# pattern, never a line number).
#
# CONTRACT THIS ORACLE FIXES (since the spec leaves the exact log/registry shape to the
# implementer, this test pins one -- reusing existing machinery wherever it already
# exists, rather than inventing parallel plumbing):
#   - classification of an orphan is logged as `judge_marker_orphaned` (kind, package,
#     evidence) -- named analogously to the harvest path's `judge_starved`/`judge_crashed`
#     (bp-orchestrator.pl 2005/2010) and to b29's `attempt_discounted_rate_limit`.
#   - the orphan/hung distinction over the JUDGE's own stream (runs/resolve/<pkg>.jsonl,
#     NOT the coordinator's runs/<pkg>.jsonl) reuses b29's already-shipped
#     BpOrch::rate_limit_rejection_evidence("$runs/resolve", $pkg) -- its path
#     construction ("$runs/$pkg.jsonl") lands exactly on judge_log_path($runs,'resolve',$pkg)
#     when handed "$runs/resolve" as its $runs arg, so no third detector is written (spec
#     Sec1 "reuse b29's detector").
#   - the re-fire is bounded by the SAME resolve_attempts/resolve_cap ladder
#     BpJudge::escalation_verdict already enforces for the initial stuck-package
#     escalation (_escalate_stuck) -- not a second, parallel cap. This is the spec's own
#     "the fail-safe is preserved rather than removed" instruction read literally: the
#     existing escalation ladder already IS "re-fire while budget remains, else park",
#     it is simply never consulted for a marker found orphaned on restart.
#   - the actual re-fire is observed via the REAL spawn_judge seam (kind=>'resolve',
#     pkg=>$pkg) being invoked again -- a black-box, implementation-name-independent
#     positive signal -- not merely a log line.
#   - the stale `.pid` marker is unlinked on a successful re-fire (C6), mirroring the
#     harvest re-audit path's own `unlink $jpidf` (bp-orchestrator.pl ~2036).
#
# Style follows t/80-rate-limit-attempt-isolation.t: mk_bp / go() drives the REAL
# BpOrch::run tick; no reimplementation of the classification logic under test.
#
# =====================================================================================
# MANDATORY VACUITY GATE: C1 ("seven orphaned markers -> zero parks, seven re-fires")
# and C2 ("a judge that ran and hung still parks") are OPPOSITES -- a classifier that
# NEVER parks passes C1 but fails C2; TODAY's classifier (always parks on timeout, the
# unfixed code) passes C2 but fails C1. Both are asserted against fixtures built into
# ONE blueprint dir and resolved by ONE go() tick (dir_main / one call), so no
# constant-returning implementation can satisfy both. The explicit cross-check block
# after C2 demonstrates this directly by diffing park counts between the two groups
# from that single tick's log.
# =====================================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

my $ORCH = "$Bin/../../scripts/bp-orchestrator.pl";
require $ORCH;   # also requires bp-judge.pl (BpJudge) and bp-govern.pl (BpGovern) transitively

diag("subject under test: $ORCH (+ bp-judge.pl, bp-govern.pl, required transitively)");

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = time;
my $DEAD_PID    = 2_000_000_000;   # out of range -> kill 0 fails -> not alive (t/06/t/61 convention)
my $ALIVE_PID   = $$;              # genuinely alive: this very process (per operator instruction)
my $OLD_STARTED = $NOW - 999_999;  # "days old" marker per the live incident -- way past any judge_to
my $JUDGE_TO    = 600;             # 10 minutes; $OLD_STARTED blows this by orders of magnitude

# confirm the "dead" pid really is dead and the "alive" pid really is alive, on THIS
# machine, rather than assuming either literal (operator instruction).
ok(!kill(0, $DEAD_PID), "fixture sanity: DEAD_PID=$DEAD_PID is verified dead via kill 0");
ok(kill(0, $ALIVE_PID), "fixture sanity: ALIVE_PID=$ALIVE_PID (\$\$) is verified alive via kill 0");

# ── fixture plumbing, copied verbatim from the house style (t/80, t/61) ────────────────
sub spit       { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw  { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }

my $bpn = 0;
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    write_ledger($dir, @$_) for @$pkgs;
    if ($registry) { spit("$dir/runs/registry.json", $J->encode({ packages => $registry })); }
    spit("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-SCN-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-SCNREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}
sub write_ledger {
    my ($dir, $name, $deps, $status, $ws, $extra_fm, $body) = @_;
    $ws //= "p/$name/"; $extra_fm //= ''; $body //= '';
    open my $l, '>', "$dir/packages/$name.md" or die;
    print $l "---\npackage: $name\nblueprint: T\nstatus: $status\nwrite_set: $ws\ntest_paths: $ws\n"
           . $extra_fm . "last_updated: 2026-06-24T00:00:00Z\n---\n# $name\n\n## Next action\n\ngo\n" . $body;
    close $l;
}
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });
sub tun {
    my ($dir, %o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>0,
             keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$dir/busy",
             harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>$JUDGE_TO, judge_spawn_cap=>3, %o };
}
sub go {
    my (%o) = @_;
    my $dir = $o{dir};
    my (@L, $err, @spawned);
    my $rcs = $o{rcs};
    my $i   = 0;
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, kind => $a->{kind}, args => [ @{ $a->{args} || [] } ] };
        return $o{launch}->($a) if $o{launch};
        return 0 unless $rcs;
        my $rc = defined $rcs->[$i] ? $rcs->[$i] : $rcs->[-1];
        $i++;
        return $rc;
    };
    my $spawn_judge = $o{spawn_judge} || sub { push @spawned, $_[0]; 0 };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            (exists $o{tunables}      ? (tunables      => $o{tunables})      : ()),
            (exists $o{tunables_file} ? (tunables_file => $o{tunables_file}) : ()),
            once      => (exists $o{once} ? $o{once} : 1),
            now       => ($o{now}   || sub { $NOW }),
            sleep     => ($o{sleep} || sub { }),
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => $spawn_judge,
            ($o{no_launch} ? () : (launch => $seam)),
        });
        1;
    } or $err = $@;
    return (\@L, \@spawned, ($err // ''));
}
sub log_events {
    my ($dir) = @_;
    my $c = slurp_raw("$dir/runs/orchestrator.log");
    return () unless defined $c;
    return map { eval { $J->decode($_) } || {} } grep { /\S/ } split /\n/, $c;
}
sub log_of { my ($dir, $type) = @_; return grep { ($_->{type} // '') eq $type } log_events($dir) }
sub log_of_pkg { my ($dir, $type, $pkg) = @_; return grep { ($_->{package} // '') eq $pkg } log_of($dir, $type) }
sub ledger_status { my ($dir, $pkg) = @_; my $t = slurp_raw("$dir/packages/$pkg.md") // '';
                     return ($t =~ /^status:\s*(\S+)/m) ? $1 : '' }
sub spawned_for { my ($spawned, $kind, $pkg) = @_;
                  return grep { ($_->{kind} // '') eq $kind && ($_->{pkg} // '') eq $pkg } @$spawned }

# ── judge-marker fixture helpers (mirrors t/61-judge-starvation.t's mk_pid_file /
#    mk_judge_jsonl, extended to accept a LIST of jsonl objects since the orphan/hung
#    distinction is read from more than the terminal line — b29's tail reader looks
#    back up to 200 lines) ─────────────────────────────────────────────────────────
sub mk_judge_pid { my ($dir, $kind, $pkg, $pid) = @_;
    mkdir "$dir/runs/$kind" unless -d "$dir/runs/$kind";
    spit("$dir/runs/$kind/$pkg.pid", "$pid\n"); }
sub mk_judge_stream { my ($dir, $kind, $pkg, @objs) = @_;
    mkdir "$dir/runs/$kind" unless -d "$dir/runs/$kind";
    spit("$dir/runs/$kind/$pkg.jsonl", join('', map { $J->encode($_) . "\n" } @objs)); }
sub mark_inflight { my ($dir, $kind, $pkg, $epoch) = @_;
    BpOrch::mark_judge_inflight("$dir/runs", $kind, $pkg, $epoch); }

# the judge ITSELF died on an API rate-limit rejection before producing a verdict --
# the exact shape the live incident's seven 6103-byte streams carried (rejection,
# then a synthetic assistant turn, then a terminal api_error/num_turns<=1/duration:0
# result). This is signature (a)+(b) both present, exactly like the ledger's quoted
# b12 incident stream reused across b29/b30/b31.
sub orphan_stream {
    my ($pkg) = @_;
    return (
        { type => 'rate_limit_event', rate_limit_info => { status => 'rejected', resetsAt => 1785370800,
              rateLimitType => 'five_hour', overageStatus => 'rejected', overageDisabledReason => 'org_level_disabled' } },
        { type => 'assistant', session_id => "jsid-$pkg",
          message => { content => [ { type => 'text', text => "<synthetic> You've hit your usage limit until 5pm." } ] } },
        { type => 'result', is_error => JSON::PP::true, num_turns => 1, terminal_reason => 'api_error',
          duration_api_ms => 0, subtype => 'error_other', session_id => "jsid-$pkg" },
    );
}
# the judge RAN, did real analysis (multiple turns), and then died on an ordinary
# error -- no rate_limit_event anywhere, num_turns well above 1, non-zero
# duration_api_ms. This is the "ran and hung" case the fail-safe must still catch.
sub hung_stream {
    my ($pkg) = @_;
    return (
        { type => 'assistant', session_id => "jsid-$pkg", message => { content => [ { type => 'text', text => 'reviewing package diff against spec...' } ] } },
        { type => 'assistant', session_id => "jsid-$pkg", message => { content => [ { type => 'text', text => 'cross-checking write-set boundaries...' } ] } },
        { type => 'assistant', session_id => "jsid-$pkg", message => { content => [ { type => 'text', text => 'drafting verdict...' } ] } },
        { type => 'result', is_error => JSON::PP::true, num_turns => 22, terminal_reason => 'error',
          duration_api_ms => 61_000, subtype => 'error_other', session_id => "jsid-$pkg" },
    );
}

# =====================================================================================
# C1 + C2 + C3 + C4 -- built into ONE blueprint dir, resolved by ONE go() tick, per the
# vacuity gate's own requirement that C1/C2 be asserted "together against the SAME tick".
#
#   orphan1..orphan6 : dead judge pid, no verdict, infra-death-only stream  -> ORPHAN
#   orphan7          : dead judge pid, no verdict, ABSENT stream (never wrote a byte)
#                      -> ORPHAN (spec Sec1: "infra-death-only, OR ABSENT")
#   hung1            : dead judge pid, no verdict, REAL content then an ordinary error
#                      -> ran-and-hung, must still PARK (C2)
#   live1            : judge pid ALIVE ($$), no verdict, marker as old as the orphans'
#                      -> must NEVER be timed out, however old (C3)
#   run1             : package's OWN ledger status is 'running' with a LIVE coordinator
#                      pid ($$ in the registry); its judge marker is dead-pid + real
#                      hung content (i.e. exactly the shape that alone would PARK per
#                      C2) -- proves the running-package guard overrides the judge
#                      classification, not just the timeout math (C4)
#
# All seven orphans + hung1 + run1 use a coordinator-pid=DEAD_PID / status=pending
# registry entry EXCEPT run1 (status=running, coordinator pid=$$ alive) so the watchdog
# loop's own dead/alive-coordinator branches never fire for any of them (they are all
# skipped there via `next if defined judge_inflight(...,'resolve',...)`  -- verified by
# grep -- isolating the resolve-judge-verdict loop as the only code path under test).
# =====================================================================================
my @orphans = map { "orphan$_" } (1..7);
my @all_pkgs = (@orphans, 'hung1', 'live1', 'run1');

my %reg = map {
    my $p = $_;
    ($p => { attempt => 3, pid => $DEAD_PID, status => 'pending', session_id => "sid-$p", resolve_attempts => 0 })
} (@orphans, 'hung1', 'live1');
$reg{run1} = { attempt => 1, pid => $ALIVE_PID, status => 'running', session_id => 'sid-run1', resolve_attempts => 0 };

my $dir_main = mk_bp(
    [ (map { [$_, '-', 'pending', "p/$_/"] } @orphans),
      ['hung1', '-', 'pending', 'p/hung1/'],
      ['live1', '-', 'pending', 'p/live1/'],
      ['run1',  '-', 'running', 'p/run1/'],
    ],
    \%reg,
);

for my $p (@orphans[0..5]) {                # orphan1..orphan6: dead pid + infra-death stream
    mk_judge_pid($dir_main, 'resolve', $p, $DEAD_PID);
    mk_judge_stream($dir_main, 'resolve', $p, orphan_stream($p));
    mark_inflight($dir_main, 'resolve', $p, $OLD_STARTED);
}
# orphan7: dead pid, marker present, but NO stream file was ever written at all.
mk_judge_pid($dir_main, 'resolve', 'orphan7', $DEAD_PID);
mark_inflight($dir_main, 'resolve', 'orphan7', $OLD_STARTED);
ok(!-e "$dir_main/runs/resolve/orphan7.jsonl", 'fixture: orphan7 genuinely has no judge stream file at all');

mk_judge_pid($dir_main, 'resolve', 'hung1', $DEAD_PID);
mk_judge_stream($dir_main, 'resolve', 'hung1', hung_stream('hung1'));
mark_inflight($dir_main, 'resolve', 'hung1', $OLD_STARTED);

mk_judge_pid($dir_main, 'resolve', 'live1', $ALIVE_PID);
mark_inflight($dir_main, 'resolve', 'live1', $OLD_STARTED);

mk_judge_pid($dir_main, 'resolve', 'run1', $DEAD_PID);
mk_judge_stream($dir_main, 'resolve', 'run1', hung_stream('run1'));
mark_inflight($dir_main, 'resolve', 'run1', $OLD_STARTED);

my ($L_main, $spawned_main, $err_main) = go(
    dir => $dir_main,
    tunables => tun($dir_main, resolve_cap => 3, judge_to => $JUDGE_TO),
);
is($err_main, '', 'main tick completes without dying');

# ---- C1 -----------------------------------------------------------------------------
{
    my @orphan_class = grep { my $p = $_->{package} // ''; grep { $p eq $_ } @orphans } log_of($dir_main, 'judge_marker_orphaned');
    is(scalar @orphan_class, 7, 'C1 (positive): all seven orphaned markers are classified judge_marker_orphaned')
        or diag('classified: ' . join(', ', map { $_->{package} // '?' } @orphan_class));

    my @refires = grep { spawned_for($spawned_main, 'resolve', $_) } @orphans;
    is(scalar @refires, 7, 'C1 (positive): all seven orphans actually got a re-fired resolve judge (spawn_judge seam invoked)')
        or diag('re-fired: ' . join(', ', @refires) . ' -- a tick that reclassifies but never re-fires must not pass C1');

    my @orphan_parks = grep { my $p = $_->{package} // ''; grep { $p eq $_ } @orphans } log_of($dir_main, 'resolve_park');
    is(scalar @orphan_parks, 0, 'C1 (negative): zero of the seven orphans were parked')
        or diag('wrongly parked: ' . join(', ', map { $_->{package} // '?' } @orphan_parks));

    for my $p (@orphans) {
        isnt(ledger_status($dir_main, $p), 'blocked', "C1: $p ledger status is not blocked");
    }
}

# ---- C2 -------------------------------------------------------------------------------
{
    my @parks = log_of_pkg($dir_main, 'resolve_park', 'hung1');
    ok(scalar(@parks) >= 1, 'C2: a judge that ran and hung (dead pid, real content, ordinary error) still parks')
        or diag('hung1 was never parked -- the fail-safe has been defeated');
    is(ledger_status($dir_main, 'hung1'), 'blocked', 'C2: hung1 ledger status is blocked');
    my @orphan_class_hung = log_of_pkg($dir_main, 'judge_marker_orphaned', 'hung1');
    is(scalar @orphan_class_hung, 0, 'C2: hung1 is NEVER classified judge_marker_orphaned');
    my @refire_hung = spawned_for($spawned_main, 'resolve', 'hung1');
    is(scalar @refire_hung, 0, 'C2: hung1 is never re-fired (it is parked, not resurrected)');
}

# ---- VACUITY CROSS-CHECK (same tick, same harness, opposite outcomes required) --------
{
    my $orphan_parks = scalar(grep { my $p = $_->{package} // ''; grep { $p eq $_ } @orphans } log_of($dir_main, 'resolve_park'));
    my $hung_parks   = scalar log_of_pkg($dir_main, 'resolve_park', 'hung1');
    isnt($orphan_parks == 0 ? 'none' : 'parked', $hung_parks == 0 ? 'none' : 'parked',
        'VACUITY GATE: identical tick, identical machinery -- orphans (0 parks) and the hung judge (>=1 park) '
      . 'must differ, so no constant-returning classifier (always-park or never-park) can satisfy both C1 and C2')
        or diag("orphan parks=$orphan_parks hung parks=$hung_parks -- these must differ for the distinction to be real");
}

# ---- C3 -------------------------------------------------------------------------------
{
    my @timeouts = log_of_pkg($dir_main, 'judge_timeout', 'live1');
    is(scalar @timeouts, 0, 'C3: a live judge pid is never timed out, however old its marker (no judge_timeout)');
    my @orphaned = log_of_pkg($dir_main, 'judge_marker_orphaned', 'live1');
    is(scalar @orphaned, 0, 'C3: a live judge pid is never classified as an orphan either');
    my @parks = log_of_pkg($dir_main, 'resolve_park', 'live1');
    is(scalar @parks, 0, 'C3: a live judge pid is never parked');
    my @refire = spawned_for($spawned_main, 'resolve', 'live1');
    is(scalar @refire, 0, 'C3: a live judge is never re-fired (a second judge would race the first)');
    is(ledger_status($dir_main, 'live1'), 'pending', 'C3: live1 ledger status is untouched');
    ok(-e "$dir_main/runs/resolve/live1.pid", 'C3: the live judge\'s own pid marker is left completely alone');
    ok(defined(BpOrch::judge_inflight("$dir_main/runs", 'resolve', 'live1')), 'C3: the in-flight marker is left completely alone (judge still working)');
}

# ---- C4 -------------------------------------------------------------------------------
{
    my @parks = log_of_pkg($dir_main, 'resolve_park', 'run1');
    is(scalar @parks, 0, 'C4: a package whose own status is running with a live coordinator is never parked by this path')
        or diag('run1 was parked despite being running with a live coordinator pid -- silently terminated live work');
    is(ledger_status($dir_main, 'run1'), 'running', 'C4: run1 ledger status stays running (unchanged)');
}

# =====================================================================================
# C5 — the re-fire is bounded by the SAME resolve_attempts/resolve_cap ladder
# BpJudge::escalation_verdict already enforces (assumption documented at file top).
# Two one-tick fixtures isolate "below cap -> re-fire allowed" from "at cap ->
# falls back to the existing park", per the spec's own wording ("falls back to the
# existing park" -- i.e. resolve_park, not a new mechanism).
# =====================================================================================
{
    # C5a: resolve_attempts=1 < resolve_cap=2 -> one more re-fire must be allowed.
    my $dir5a = mk_bp([['orph5a', '-', 'pending', 'p/orph5a/']],
        { orph5a => { attempt => 3, pid => $DEAD_PID, status => 'pending', resolve_attempts => 1 } });
    mk_judge_pid($dir5a, 'resolve', 'orph5a', $DEAD_PID);
    mk_judge_stream($dir5a, 'resolve', 'orph5a', orphan_stream('orph5a'));
    mark_inflight($dir5a, 'resolve', 'orph5a', $OLD_STARTED);
    my ($L5a, $spawned5a, $err5a) = go(dir => $dir5a, tunables => tun($dir5a, resolve_cap => 2, judge_to => $JUDGE_TO));
    is($err5a, '', 'C5a tick completes without dying');
    my @refire5a = spawned_for($spawned5a, 'resolve', 'orph5a');
    ok(scalar(@refire5a) >= 1, 'C5 (bound): below the resolve_cap, an orphan IS re-fired')
        or diag('resolve_attempts=1 < resolve_cap=2 did not produce a re-fire');
    is(scalar(log_of_pkg($dir5a, 'resolve_park', 'orph5a')), 0, 'C5 (bound): below the cap, the orphan is not parked');

    # C5b: resolve_attempts=2 == resolve_cap=2 -> budget exhausted -> FALLS BACK to park.
    my $dir5b = mk_bp([['orph5b', '-', 'pending', 'p/orph5b/']],
        { orph5b => { attempt => 3, pid => $DEAD_PID, status => 'pending', resolve_attempts => 2 } });
    mk_judge_pid($dir5b, 'resolve', 'orph5b', $DEAD_PID);
    mk_judge_stream($dir5b, 'resolve', 'orph5b', orphan_stream('orph5b'));
    mark_inflight($dir5b, 'resolve', 'orph5b', $OLD_STARTED);
    my ($L5b, $spawned5b, $err5b) = go(dir => $dir5b, tunables => tun($dir5b, resolve_cap => 2, judge_to => $JUDGE_TO));
    is($err5b, '', 'C5b tick completes without dying');
    my @refire5b = spawned_for($spawned5b, 'resolve', 'orph5b');
    is(scalar(@refire5b), 0, 'C5 (fallback): at the cap, the orphan is NOT re-fired again')
        or diag('a re-fire happened even though resolve_attempts already equalled resolve_cap -- the cap is not real');
    ok(scalar(log_of_pkg($dir5b, 'resolve_park', 'orph5b')) >= 1, 'C5 (fallback): at the cap, the orphan FALLS BACK to the existing park')
        or diag('an exhausted orphan was neither re-fired nor parked -- it was silently dropped instead');
    is(ledger_status($dir5b, 'orph5b'), 'blocked', 'C5 (fallback): at the cap, ledger status is blocked, exactly as the pre-existing fail-safe');
}

# =====================================================================================
# C6 — stale markers are cleaned on re-fire so the same orphan is not re-detected
# next tick. Reuses C5a's below-cap scenario (a genuine re-fire happened), then drives
# a SECOND tick over the SAME dir with no new marker written by the spawn stub
# (mirroring a real bp-judge.sh detach that hasn't produced anything new yet) and
# asserts the orphan is not re-classified/re-logged a second time.
# =====================================================================================
{
    my $dir6 = mk_bp([['orph6', '-', 'pending', 'p/orph6/']],
        { orph6 => { attempt => 3, pid => $DEAD_PID, status => 'pending', resolve_attempts => 0 } });
    mk_judge_pid($dir6, 'resolve', 'orph6', $DEAD_PID);
    mk_judge_stream($dir6, 'resolve', 'orph6', orphan_stream('orph6'));
    mark_inflight($dir6, 'resolve', 'orph6', $OLD_STARTED);

    my ($L6a, $spawned6a, $err6a) = go(dir => $dir6, tunables => tun($dir6, resolve_cap => 3, judge_to => $JUDGE_TO));
    is($err6a, '', 'C6 tick 1 completes without dying');
    ok(scalar(spawned_for($spawned6a, 'resolve', 'orph6')) >= 1, 'C6: tick 1 re-fires the orphan (sanity: the reap actually happened)');
    is(scalar(log_of_pkg($dir6, 'judge_marker_orphaned', 'orph6')), 1, 'C6: tick 1 logs exactly one judge_marker_orphaned classification');
    ok(!-e "$dir6/runs/resolve/orph6.pid", 'C6: the stale dead-pid marker is unlinked after a successful re-fire')
        or diag('the old .pid file for orph6 is still on disk -- next tick could re-read the same dead pid');

    # Tick 2: nothing new written (the injected spawn stub never creates a fresh
    # marker, exactly like t/80's default `sub {0}` seam) -- the same orphan must
    # NOT be re-detected/re-logged a second time.
    my ($L6b, $spawned6b, $err6b) = go(dir => $dir6, tunables => tun($dir6, resolve_cap => 3, judge_to => $JUDGE_TO));
    is($err6b, '', 'C6 tick 2 completes without dying');
    is(scalar(log_of_pkg($dir6, 'judge_marker_orphaned', 'orph6')), 1,
        'C6: after tick 2, still exactly ONE judge_marker_orphaned total for orph6 -- not re-detected next tick')
        or diag('a second judge_marker_orphaned fired on tick 2 with no new marker -- the reap left stale state behind');
    is(scalar(spawned_for($spawned6b, 'resolve', 'orph6')), 0, 'C6: tick 2 does not re-fire a second judge for the same already-reaped orphan');
}

# =====================================================================================
# C7 — orchestrator-protocol/SKILL.md states the live-pid rule and the orphan-vs-hung
# distinction (mirrors t/80's own C6 protocol-doc pattern).
# =====================================================================================
{
    my $skill = "$Bin/../../skills/orchestrator-protocol/SKILL.md";
    ok(-f $skill, "C7: $skill exists") or diag('cannot assert C7 text against a missing file');
    my $txt = slurp_raw($skill) // '';
    like($txt, qr/orphan/i, 'C7: SKILL.md mentions an orphaned judge marker at all');
    # Tightened to require "judge" AND "live/alive" AND "pid" co-located (a bare
    # "PID liveness" mention elsewhere in the doc, e.g. the pre-existing coordinator-
    # watching description, must NOT satisfy this -- caught as a false positive while
    # authoring this oracle, since that phrase already exists in SKILL.md today).
    ok(($txt =~ /\bjudge\b(?:(?!\bjudge\b).){0,200}\b(?:live|alive)\b.{0,40}\bpid\b/is
        || $txt =~ /\bjudge\b(?:(?!\bjudge\b).){0,200}\bpid\b.{0,40}\b(?:live|alive)\b/is
        || $txt =~ /\b(?:live|alive)\b.{0,40}\bpid\b(?:(?!\bpid\b).){0,200}\bjudge\b/is
        || $txt =~ /\bpid\b.{0,40}\b(?:live|alive)\b(?:(?!\b(?:live|alive)\b).){0,200}\bjudge\b/is),
        'C7: SKILL.md states the live-pid rule for a JUDGE (a live judge pid is never timed out)')
        or diag('SKILL.md does not yet state the judge live-pid rule (a generic "PID liveness" mention elsewhere does not count)');
    ok(($txt =~ /\bhung\b|\bran and hung\b/i) && ($txt =~ /\bnever ran\b|\bnever ran to\b|\borphan/i),
        'C7: SKILL.md distinguishes "ran and hung" (parks) from "never ran" / orphaned (re-fires)')
        or diag('SKILL.md does not yet distinguish the hung case from the never-ran/orphan case');
}

done_testing();
