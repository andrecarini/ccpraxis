#!/usr/bin/env perl
# t/68-exit-reason-classification.t — immutable oracle for b16-exit-reason-and-cold-escalation.
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b16-exit-reason-and-cold-escalation-spec.md
# section 3 (C1..C7) plus section 0's scout and section 2's composition rule with b41.
#
# WRITTEN BLIND TO THE FIX. Today (per the spec's own verified scout) the classifier
# (`BpOrch::terminal_verdict`, already shipped) is computed at the dead-coordinator
# watchdog site (`$tv = terminal_verdict(_last_jsonl_obj($runs, $pkg))`) but consulted
# ONLY for the turn-continuation/widen fork — the warm/cold MODE decision a few lines
# later is taken purely from `BpCacheState::verdict_from_runs`, and `$tv`'s classification
# is never logged on `watchdog_relaunch`. So every assertion below that expects a
# max_turns death to force COLD, or the exit reason to appear in the log, is expected to
# fail on WRONG MODE or an ABSENT LOG FIELD today — never a Perl exception, a missing
# module, or a wrong require path (SYN-23: everything here is located by grep pattern,
# never a line number).
#
# THE RULE UNDER TEST (spec §2):
#     exit_reason == max_turns  -> COLD, always, regardless of cache warmth
#     otherwise                 -> b41's cache verdict stands unchanged
#
# CONTRACT THIS ORACLE PINS (the spec leaves the exact log shape to the implementer,
# per its own "consumption, not invention" framing — house precedent is t/82's own
# `judge_marker_orphaned` naming):
#   - the classified exit reason is logged on EVERY `watchdog_relaunch` event as a field
#     named `exit_reason`, taking one of terminal_verdict's own verdict values:
#     max_turns | success | error | unknown.
#   - the mode field already logged today (`mode: warm|cold`) is what this package's
#     force-cold rule acts on.
#
# =====================================================================================
# MANDATORY VACUITY GATE: C2 ("warm cache + max_turns -> cold") and C3 ("warm cache +
# genuine crash -> STILL warm") are OPPOSITES. An "always cold" implementation passes
# C2 and C4 but fails C3. An "always warm" (i.e. today's unfixed code, which never
# forces cold) passes C3 but fails C2 and C4. Both are built into ONE blueprint dir and
# resolved by ONE go() tick below (dir_main), and C2's fixture's cache verdict is
# independently proven 'warm' via a DIRECT call to BpCacheState::verdict_from_runs
# before the tick even runs, and again cross-checked against C3's paired fixture in the
# same tick, so no constant-returning mode selector can satisfy both. See the explicit
# cross-check block after C3 below.
# =====================================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use Time::Local qw(timegm);

my $ORCH = "$Bin/../../scripts/bp-orchestrator.pl";
my $CACHE_STATE = "$Bin/../../scripts/bp-cache-state.pl";
my $SKILL = "$Bin/../../skills/orchestrator-protocol/SKILL.md";

require $ORCH;          # also requires bp-judge.pl (BpJudge) and bp-govern.pl (BpGovern) transitively
require $CACHE_STATE;   # BpCacheState — used here ONLY to independently prove ground truth (warm/cold)
                        # for the vacuity gate; the orchestrator itself also lazily requires this same
                        # file at the watchdog site, so requiring it twice here is a documented no-op
                        # (require guards on $INC), matching production's own lazy-require discipline.

diag("subject under test: $ORCH (terminal_verdict + the watchdog_relaunch site), "
   . "cross-checked against $CACHE_STATE (BpCacheState::verdict_from_runs)");

my $J = JSON::PP->new->canonical;

# =====================================================================================
# Scaffolding — copied from the house style (t/82-orphaned-judge-recovery.t, t/85-cache-state.t).
# Fixtures are built ONLY under a File::Temp tempdir; nothing under
# .ccpraxis-local-data/ is ever read or written by this file.
# =====================================================================================
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = 2_000_000_000;
my $DEAD_PID = 2_000_000_001;   # out of range -> kill 0 fails -> not alive (t/06/t/61/t/82 convention)

ok(!kill(0, $DEAD_PID), "fixture sanity: DEAD_PID=$DEAD_PID is verified dead via kill 0");

sub spit      { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }

sub iso_of { # epoch -> ISO8601 Z string, matching bp-cache-state.pl's _epoch_of_iso format
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]);
}

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
    my (%o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>10, cap=>5, flat=>600, watch_tick=>0,
             keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$ROOT/busy",
             harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>600, judge_spawn_cap=>3,
             turn_starved_thresh => 100,   # b11 is out of scope (spec §5) — disable its pause gate here
             %o };
}
sub go {
    my (%o) = @_;
    my $dir = $o{dir};
    my (@L, $err);
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
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables => $o{tunables},
            once      => 1,
            now       => ($o{now}   || sub { $NOW }),
            sleep     => ($o{sleep} || sub { }),
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => sub { 0 },   # NEVER spawn the real bp-judge.sh against the live tree
            launch => $seam,
        });
        1;
    } or $err = $@;
    return (\@L, ($err // ''));
}
sub log_events {
    my ($dir) = @_;
    my $c = slurp_raw("$dir/runs/orchestrator.log");
    return () unless defined $c;
    return map { eval { $J->decode($_) } || {} } grep { /\S/ } split /\n/, $c;
}
sub log_of     { my ($dir, $type) = @_; return grep { ($_->{type} // '') eq $type } log_events($dir) }
sub log_of_pkg { my ($dir, $type, $pkg) = @_; return grep { ($_->{package} // '') eq $pkg } log_of($dir, $type) }

sub read_registry_pkg {
    my ($dir, $pkg) = @_;
    my $txt = slurp_raw("$dir/runs/registry.json");
    return {} unless defined $txt && length $txt;
    my $doc = eval { JSON::PP->new->decode($txt) };
    return {} unless ref $doc eq 'HASH' && ref $doc->{packages} eq 'HASH';
    return ref $doc->{packages}{$pkg} eq 'HASH' ? $doc->{packages}{$pkg} : {};
}

# ── transcript builders ─────────────────────────────────────────────────────────────
sub jline { return $J->encode($_[0]) . "\n" }

# a real (non-terminal) assistant turn, carrying a cache-token usage record so
# bp-cache-state.pl's registry-observation matching has something plausible behind it,
# and (crucially) a `timestamp` — used when this line is deliberately made the LAST
# non-empty line of the transcript (the "unknown" exit-reason fixtures), since BOTH
# terminal_verdict's `_last_jsonl_obj` reader AND BpCacheState::last_activity_from_runs
# read that exact same last line.
sub assistant_line {
    my (%o) = @_;
    return {
        type => 'assistant', timestamp => iso_of($o{epoch}), session_id => $o{sid} // 'sid-x',
        message => { role => 'assistant', usage => {
            input_tokens => 2, output_tokens => 1,
            cache_read_input_tokens     => $o{cache_read}     // 0,
            cache_creation_input_tokens => $o{cache_creation} // 0,
        } },
    };
}
sub rate_limit_line {
    return { type => 'rate_limit_event', rate_limit_info => {
        status => 'rejected', resetsAt => 1785370800, rateLimitType => 'five_hour',
        overageStatus => 'rejected', overageDisabledReason => 'org_level_disabled' } };
}
# the coordinator's TERMINAL event. $reason selects the shape:
#   max_turns_subtype   -> subtype='error_max_turns' (the common case)
#   max_turns_termonly  -> subtype='error_other' but terminal_reason='max_turns' (the
#                          OR-branch terminal_verdict ALSO covers — proves the fix reuses
#                          the shared classifier rather than a subtype-only string match)
#   success             -> subtype='success', is_error=false
#   error                -> subtype='error_other', terminal_reason='error' (a genuine crash)
sub result_line {
    my (%o) = @_;
    my %base = (type => 'result', timestamp => iso_of($o{epoch}), session_id => $o{sid} // 'sid-x',
                num_turns => $o{num_turns} // 40);
    if ($o{reason} eq 'max_turns_subtype') {
        return { %base, is_error => JSON::PP::true, subtype => 'error_max_turns', terminal_reason => 'max_turns' };
    } elsif ($o{reason} eq 'max_turns_termonly') {
        return { %base, is_error => JSON::PP::true, subtype => 'error_other', terminal_reason => 'max_turns' };
    } elsif ($o{reason} eq 'success') {
        return { %base, is_error => JSON::PP::false, subtype => 'success' };
    } elsif ($o{reason} eq 'error') {
        return { %base, is_error => JSON::PP::true, subtype => 'error_other', terminal_reason => 'error' };
    }
    die "result_line: unknown reason $o{reason}";
}

# runs/<pkg>.jsonl path (blueprint-dir-relative), matching bp-lib.sh's own convention.
sub transcript_path { my ($dir, $pkg) = @_; return "$dir/runs/$pkg.jsonl" }

# ── registry fixture: a package whose coordinator is DEAD (pid never updated by our
# mock launch seam — exactly like the real bp-launch.sh writing a NEW pid only on a
# successful exec, which our test never performs) so every go() tick re-discovers it
# via the dead-coordinator watchdog branch. ─────────────────────────────────────────
sub dead_pkg_registry {
    my (%o) = @_;
    my %r = ( attempt => $o{attempt} // 1, pid => $DEAD_PID, status => 'pending', session_id => $o{sid} );
    $r{cache_observations} = $o{cache_observations} if $o{cache_observations};
    $r{rate_limit_discounted_attempt} = $o{rate_limit_discounted_attempt} if defined $o{rate_limit_discounted_attempt};
    return \%r;
}

# WARM cache fixture: transcript's last line at age_min minutes ago (well inside the
# 50-min effective threshold), a registry session_id, and a MATCHING cache_observations
# hit entry at that same age (bp-cache-state.pl's own feedback-loop requirement).
my $WARM_AGE = 5;
sub warm_registry { my ($sid, %o) = @_;
    return dead_pkg_registry(sid => $sid, %o,
        cache_observations => [ { age_min => $WARM_AGE, hit => JSON::PP::true } ]); }
# COLD cache fixture: no cache_observations recorded at all -> b41 itself must return
# cold (transcript age is irrelevant; "absent observation history" alone forces cold).
sub cold_registry { my ($sid, %o) = @_; return dead_pkg_registry(sid => $sid, %o); }

sub ground_truth_verdict { # direct call into BpCacheState, bypassing the orchestrator entirely
    my ($dir, $pkg) = @_;
    return BpCacheState::verdict_from_runs("$dir/runs", $pkg, $NOW);
}

# =====================================================================================
# dir_main: C1 (four exit reasons logged) + C2/C3 (the vacuity-gate pair, same tick) +
# C5 (unknown leaves b41 untouched, both directions) + C6 (rate-limit discount/cap
# semantics unaffected by the cold-escalation fork) — ALL seven packages resolved by
# ONE go() tick, per the spec's own "assert C2/C3 together against the same tick".
# =====================================================================================
my @pkgs_main = (
    ['mt_subtype',    '-', 'running', 'p/mt_subtype/'],
    ['mt_termonly',   '-', 'running', 'p/mt_termonly/'],
    ['success_warm',  '-', 'running', 'p/success_warm/'],
    ['crash_warm',    '-', 'running', 'p/crash_warm/'],   # C3
    ['unknown_warm',  '-', 'running', 'p/unknown_warm/'],
    ['unknown_cold',  '-', 'running', 'p/unknown_cold/'],
    ['ratelimit_mt',  '-', 'running', 'p/ratelimit_mt/'], # C6
);
my $mt_subtype_age  = $WARM_AGE;
my $crash_age       = $WARM_AGE;

my %reg_main = (
    mt_subtype   => warm_registry('sid-mt-subtype'),
    mt_termonly  => warm_registry('sid-mt-termonly'),
    success_warm => warm_registry('sid-success'),
    crash_warm   => warm_registry('sid-crash'),
    unknown_warm => warm_registry('sid-unk-warm'),
    unknown_cold => cold_registry('sid-unk-cold'),
    ratelimit_mt => warm_registry('sid-ratelimit', attempt => 2, rate_limit_discounted_attempt => 0),
);
my $dir_main = mk_bp(\@pkgs_main, \%reg_main);

spit(transcript_path($dir_main, 'mt_subtype'),
    jline(result_line(reason => 'max_turns_subtype', epoch => $NOW - $WARM_AGE*60, sid => 'sid-mt-subtype')));
spit(transcript_path($dir_main, 'mt_termonly'),
    jline(result_line(reason => 'max_turns_termonly', epoch => $NOW - $WARM_AGE*60, sid => 'sid-mt-termonly')));
spit(transcript_path($dir_main, 'success_warm'),
    jline(result_line(reason => 'success', epoch => $NOW - $WARM_AGE*60, sid => 'sid-success')));
spit(transcript_path($dir_main, 'crash_warm'),
    jline(result_line(reason => 'error', epoch => $NOW - $crash_age*60, sid => 'sid-crash')));
# "unknown": the transcript's LAST non-empty line is NOT a `result` object at all (an
# ordinary assistant turn), so terminal_verdict's early-return default ('unknown')
# applies. Both fixtures otherwise carry a normal, well-formed transcript.
spit(transcript_path($dir_main, 'unknown_warm'),
    jline(assistant_line(epoch => $NOW - 200*60, sid => 'sid-unk-warm', cache_read => 10))
  . jline(assistant_line(epoch => $NOW - $WARM_AGE*60, sid => 'sid-unk-warm', cache_read => 20)));
spit(transcript_path($dir_main, 'unknown_cold'),
    jline(assistant_line(epoch => $NOW - $WARM_AGE*60, sid => 'sid-unk-cold', cache_read => 20)));
spit(transcript_path($dir_main, 'ratelimit_mt'),
    jline(rate_limit_line())
  . jline(result_line(reason => 'max_turns_subtype', epoch => $NOW - $WARM_AGE*60, sid => 'sid-ratelimit')));

# ---- ground-truth cache verdicts, proven BEFORE the orchestrator ever runs a tick ----
is(ground_truth_verdict($dir_main, 'mt_subtype'),  'warm',
    'GROUND TRUTH: mt_subtype\'s BpCacheState verdict really is warm (C2 positive gate)');
is(ground_truth_verdict($dir_main, 'mt_termonly'), 'warm',
    'GROUND TRUTH: mt_termonly\'s BpCacheState verdict really is warm');
is(ground_truth_verdict($dir_main, 'success_warm'),'warm',
    'GROUND TRUTH: success_warm\'s BpCacheState verdict really is warm');
is(ground_truth_verdict($dir_main, 'crash_warm'),  'warm',
    'GROUND TRUTH: crash_warm\'s BpCacheState verdict really is warm (C3 positive gate)');
is(ground_truth_verdict($dir_main, 'unknown_warm'),'warm',
    'GROUND TRUTH: unknown_warm\'s BpCacheState verdict really is warm (C5 positive gate, warm side)');
is(ground_truth_verdict($dir_main, 'unknown_cold'),'cold',
    'GROUND TRUTH: unknown_cold\'s BpCacheState verdict really is cold (C5 positive gate, cold side)');
is(ground_truth_verdict($dir_main, 'ratelimit_mt'),'warm',
    'GROUND TRUTH: ratelimit_mt\'s BpCacheState verdict really is warm (C6 fixture sanity)');

my ($L_main, $err_main) = go(dir => $dir_main, tunables => tun());
is($err_main, '', 'dir_main: go() ran without a Perl exception') or diag($err_main);

sub relaunch_of { my ($pkg) = @_; my @e = log_of_pkg($dir_main, 'watchdog_relaunch', $pkg); return $e[0] }
sub kind_of     { my ($pkg) = @_; my ($rec) = grep { $_->{pkg} eq $pkg } @$L_main; return $rec ? $rec->{kind} : undef }

# =====================================================================================
# C1 — exit reason classified via the shared terminal_verdict and LOGGED on
# watchdog_relaunch, for max_turns, success, error and unknown. `mt_termonly` is the
# "not a matching string" proof: its subtype is 'error_other' (would NOT match a naive
# `subtype eq 'error_max_turns'` check) yet terminal_verdict's own OR-branch
# (`terminal_reason eq 'max_turns'`) still classifies it max_turns — so a correct
# implementation logs max_turns for it too, exactly like mt_subtype.
# =====================================================================================
{
    my $ev = relaunch_of('mt_subtype');
    ok($ev, 'C1: mt_subtype produced a watchdog_relaunch event') or diag(explain_log($dir_main));
    is($ev && $ev->{exit_reason}, 'max_turns', 'C1: mt_subtype exit_reason logged as max_turns');

    my $ev2 = relaunch_of('mt_termonly');
    ok($ev2, 'C1: mt_termonly produced a watchdog_relaunch event');
    is($ev2 && $ev2->{exit_reason}, 'max_turns',
        'C1 (not-a-matching-string proof): mt_termonly (subtype=error_other, terminal_reason=max_turns) '
      . 'is STILL classified max_turns -- proves reuse of terminal_verdict\'s OR-branch, not a bare '
      . "subtype eq 'error_max_turns' string check");

    my $ev3 = relaunch_of('success_warm');
    ok($ev3, 'C1: success_warm produced a watchdog_relaunch event');
    is($ev3 && $ev3->{exit_reason}, 'success', 'C1: success_warm exit_reason logged as success');

    my $ev4 = relaunch_of('crash_warm');
    ok($ev4, 'C1: crash_warm produced a watchdog_relaunch event');
    is($ev4 && $ev4->{exit_reason}, 'error', 'C1: crash_warm exit_reason logged as error');

    my $ev5 = relaunch_of('unknown_warm');
    ok($ev5, 'C1: unknown_warm produced a watchdog_relaunch event');
    is($ev5 && $ev5->{exit_reason}, 'unknown', 'C1: unknown_warm exit_reason logged as unknown');
}

# =====================================================================================
# C2 — turn exhaustion forces COLD even though the cache is warm (ground truth for
# mt_subtype/mt_termonly already proven 'warm' above -- this is NOT a cold-cache fixture
# passing trivially).
# =====================================================================================
is(kind_of('mt_subtype'), 'cold',
    'C2: mt_subtype (max_turns, warm cache) is relaunched COLD despite the warm cache');
is(kind_of('mt_termonly'), 'cold',
    'C2: mt_termonly (max_turns via terminal_reason, warm cache) is ALSO relaunched COLD');
{
    my $ev = relaunch_of('mt_subtype');
    is($ev && $ev->{mode}, 'cold', 'C2: watchdog_relaunch log itself records mode=cold for mt_subtype');
}

# =====================================================================================
# C3 — a genuine crash (exit_reason=error) with an equally warm cache STILL resumes
# warm. Same tick as C2. This is the other half of the vacuity gate: without it,
# "always cold" would pass C2/C4 while silently breaking every ordinary crash recovery.
# =====================================================================================
is(kind_of('crash_warm'), 'warm',
    'C3: crash_warm (genuine crash, warm cache) STILL resumes warm -- b41\'s verdict stands');
{
    my $ev = relaunch_of('crash_warm');
    is($ev && $ev->{mode}, 'warm', 'C3: watchdog_relaunch log records mode=warm for crash_warm');
}

# ---- explicit C2/C3 cross-check (the vacuity gate, made mechanical) ----
{
    my $mode_mt    = kind_of('mt_subtype');
    my $mode_crash = kind_of('crash_warm');
    isnt($mode_mt, $mode_crash,
        'VACUITY CROSS-CHECK: the SAME warm cache produces DIFFERENT modes depending solely on '
      . "exit_reason (max_turns => $mode_mt vs a genuine crash => $mode_crash) -- a constant-returning "
      . 'mode selector (always cold, or always warm) cannot produce this divergence');
}

# =====================================================================================
# C5 — an unknown/unparseable exit reason leaves b41's verdict UNTOUCHED. Two fixtures,
# both proven ground-truth first (above): unknown_warm is genuinely warm, unknown_cold
# is genuinely cold. A correct implementation passes the underlying verdict through
# unchanged in BOTH directions; "always cold on uncertainty" (a plausible but wrong
# generalisation of C2) would fail the warm side.
# =====================================================================================
is(kind_of('unknown_warm'), 'warm',
    'C5: unknown exit_reason + a genuinely warm cache -> mode stays warm (b41 untouched, warm side)');
is(kind_of('unknown_cold'), 'cold',
    'C5: unknown exit_reason + a genuinely cold cache -> mode stays cold (b41 untouched, cold side)');

# =====================================================================================
# C6 — b29's rate-limit attempt-discount and the give-up cap behave exactly as before;
# forcing a cold escalation is not itself an extra attempt, and does not reroute the
# package through the 'block' (attempt-cap) verdict branch instead of 'relaunch'.
# =====================================================================================
{
    is(kind_of('ratelimit_mt'), 'cold',
        'C6 fixture sanity: ratelimit_mt (max_turns + warm cache + a rate-limit marker) is cold, per C2\'s rule');

    my @discount_ev = log_of_pkg($dir_main, 'attempt_discounted_rate_limit', 'ratelimit_mt');
    is(scalar(@discount_ev), 1,
        "C6: b29's rate-limit discount still fires exactly once for ratelimit_mt -- the cold-escalation "
      . 'fork this package adds does not suppress or duplicate the existing discount logic');

    my $reg_after = read_registry_pkg($dir_main, 'ratelimit_mt');
    is($reg_after->{rate_limit_discounts}, 1,
        'C6: registry rate_limit_discounts incremented to 1, exactly as an ordinary (non-cold-forced) '
      . 'rate-limited relaunch would record');

    my @block_ev = log_of_pkg($dir_main, 'watchdog_block', 'ratelimit_mt');
    is(scalar(@block_ev), 0,
        'C6: ratelimit_mt was NOT routed through watchdog_block -- forcing cold is not itself an extra '
      . 'attempt that could push a healthy package past the give-up cap');

    my $ev = relaunch_of('ratelimit_mt');
    is($ev && $ev->{attempts}, $reg_main{ratelimit_mt}{attempt},
        'C6: the attempts figure logged on watchdog_relaunch is the pre-tick registry attempt count, '
      . 'unchanged by the cold-escalation fork (mirrors mt_subtype\'s own unforced attempts figure)');
}

sub explain_log { my ($dir) = @_; return join("\n", map { $J->encode($_) } log_events($dir)) }

# =====================================================================================
# C4 — the field scenario cannot recur: four SUCCESSIVE max_turns deaths of the SAME
# package produce four COLD relaunches, never a warm one. A fresh blueprint dir, one
# package, one go() tick per "death" -- our mock launch never rewrites the registry's
# `pid` (exactly like the field incident's own warm-relaunch loop, where each resume
# died the same way), so the SAME dead pid is rediscovered by the watchdog on every
# subsequent tick, exactly reproducing "died, relaunched, died again" four times over.
# =====================================================================================
{
    my $sid = 'sid-c4';
    my $pkgs = [ ['looper', '-', 'running', 'p/looper/'] ];
    my $reg  = { looper => warm_registry($sid) };
    my $dir_c4 = mk_bp($pkgs, $reg);
    spit(transcript_path($dir_c4, 'looper'),
        jline(result_line(reason => 'max_turns_subtype', epoch => $NOW - $WARM_AGE*60, sid => $sid)));

    is(ground_truth_verdict($dir_c4, 'looper'), 'warm',
        'C4 GROUND TRUTH: looper\'s cache verdict is warm on every tick (the fixture never changes)');

    my @modes;
    for my $death (1..4) {
        my ($L, $err) = go(dir => $dir_c4, tunables => tun());
        is($err, '', "C4 death #$death: go() ran without a Perl exception") or diag($err);
        my ($rec) = grep { $_->{pkg} eq 'looper' } @$L;
        push @modes, $rec ? $rec->{kind} : undef;
    }
    is_deeply(\@modes, ['cold','cold','cold','cold'],
        'C4: four successive max_turns deaths of the SAME warm-cache package produce four COLD '
      . 'relaunches, never a warm one -- the exact field scenario (13:51/14:00/14:12/14:22, all '
      . 'warm, looping into the same sentinel grep) cannot recur');

    my @relaunches = log_of_pkg($dir_c4, 'watchdog_relaunch', 'looper');
    is(scalar(@relaunches), 4, 'C4: exactly four watchdog_relaunch events were logged for looper');
    ok((!grep { ($_->{mode} // '') ne 'cold' } @relaunches),
        'C4: every one of the four watchdog_relaunch log entries itself records mode=cold');
    ok((!grep { ($_->{exit_reason} // '') ne 'max_turns' } @relaunches),
        'C4: every one of the four watchdog_relaunch log entries records exit_reason=max_turns');
}

# =====================================================================================
# C7 — the exit-reason field and the max_turns -> cold rule are documented in
# orchestrator-protocol/SKILL.md (mirrors t/80/t/82's own doc-coverage convention).
# Tolerant of exact wording (grep for the CONCEPT, not a fixed sentence) since the
# implementer, not this oracle, chooses the prose.
# =====================================================================================
{
    ok(-f $SKILL, "C7 fixture sanity: $SKILL exists") or diag("SKILL.md not found at $SKILL");
    my $doc = slurp_raw($SKILL) // '';

    like($doc, qr/exit[\s_-]?reason/i,
        'C7: SKILL.md documents an "exit reason" concept (the field this package logs on '
      . 'watchdog_relaunch)');

    my $has_force_cold_rule =
        ($doc =~ /max[\s_-]?turns\b.{0,120}\bcold\b/is) || ($doc =~ /\bcold\b.{0,120}max[\s_-]?turns\b/is);
    ok($has_force_cold_rule,
        'C7: SKILL.md documents the max_turns -> cold rule (a max_turns exit forces a cold relaunch '
      . 'regardless of cache warmth) within ~120 chars of context, not merely mentioning both terms '
      . 'in unrelated places')
        or diag('SKILL.md content did not satisfy the max_turns/cold proximity check');
}

done_testing();
