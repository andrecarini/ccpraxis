#!/usr/bin/env perl
# bp-orchestrator.pl — the deterministic, TOKEN-FREE orchestrator process-management
# loop for A3. It assembles the already-built decision-core (bp-govern, bp-contract,
# bp-token-keeper, bp-log) into the standing loop that drives a `dispatch-fleet` run
# inside the sandbox. There is NO Claude in this script (Decision #5/#14).
#
# What it does each tick (fast watch tick, ~10s — so a completion is acted on in
# seconds, not at the fallback-timer granularity):
#   • WATCH    — coordinator liveness (PID) + runs/<pkg>.jsonl growth (free signals).
#   • LAUNCH   — the instant a slot frees / a dep completes, compute newly-ready
#                packages off the blueprint DAG (deps ✅ + disjoint write-sets) and
#                launch them via bp-launch.sh, cap-bounded (BP_MAX_PARALLEL).
#   • WATCHDOG — dead→relaunch (warm/cold per resume economics); alive+log-flat→
#                kill+cold-relaunch; loop-guard past an attempt cap → blocked + queue
#                a runs/needs-you/ decision.
#   • USAGE    — burn-rate-adaptive poll of /api/oauth/usage (validated via
#                BpContract::validate_usage; cadence via BpGovern::next_cadence);
#                derived-trip pause via BpGovern::should_pause → write runs/.paused.
#   • TOKEN    — BpKeeper::keeper_tick on cadence; honor its action.
#   • BUSY     — touch /tmp/.butler-busy while work active OR auto-resume-pending;
#                NOT while the only outstanding work is parked-for-human.
#   • RESUME   — after resets_at (+ jitter), clear runs/.paused and relaunch.
#   • MARKER   — runs/.orchestrator (PID + flock) on start; removed on clean exit.
#   • FAIL-SAFE— telemetry/auth/contract loss ⇒ graceful pause, never fly blind.
#   • LOG      — every poll/refresh/pause/resume via BpLog::event to
#                runs/orchestrator.log (Decision #30); never a secret value.
#
# DESIGN: every DECISION the loop makes is a PURE function (top of file) that is
# unit-tested with an injected clock / registry / transport (Decision #25, t/06).
# The loop itself is the thin shell that reads disk, calls the decisions, and acts;
# its side-effecting seams (launch, http_get, http_post, clock) are injectable so a
# `--once` assembly test can drive it without the network or a real `claude`.
#
# require:  require "<path>/bp-orchestrator.pl"; BpOrch::ready_packages(...)
# CLI:      perl bp-orchestrator.pl <blueprint> [--bp-dir DIR] [--once]

package BpOrch;
use strict;
use warnings;
use JSON::PP;
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# MSYS2 path-conversion guard (house rule): this script may spawn bp-launch.sh
# (native bash) with ':'-bearing args on a Windows host; disable the translation.
BEGIN { $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/; }

# Absolute script dir so `require "$DIR/..."` resolves no matter how this script
# is invoked (relative CLI path, absolute, or `require`d from a test).
my $DIR = dirname(abs_path(__FILE__));
require "$DIR/bp-govern.pl";
require "$DIR/bp-contract.pl";
require "$DIR/bp-log.pl";
require "$DIR/bp-http.pl";
require "$DIR/bp-token-keeper.pl";
require "$DIR/bp-judge.pl";
require "$DIR/bp-remediate.pl";    # b07: auto-remediation engine (pure decision core)
require "$DIR/bp-checkpoint.pl";   # b02: durable WIP checkpoint commits

our $USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
our $USER_AGENT = $ENV{BP_USER_AGENT} // 'claude-code/2.1.170';

# Exec-not-found sentinel context: set ONLY by the DEFAULT launch closure, to the
# $! of a system() that returned -1 (the child could not be exec'd at all). An
# injected launch closure (tests/simulation) never sets it, so the broken-env
# decision falls back to a documented literal. Cleared at the start of every run().
our $LAST_EXEC_ERROR;

# ===========================================================================
# PURE DECISIONS  (no I/O, no globals — unit-tested in t/06-orchestrator.t)
# ===========================================================================

sub _is_terminal { my $s = shift // ''; $s =~ /^(done|dropped|blocked|parked)$/ ? 1 : 0 }
# blocked/parked = HALTED AWAITING A HUMAN: a human's answer (bp-answer-decision)
# flips the package back to pending and the STILL-RUNNING orchestrator relaunches it
# (the reporter contract is "no restart needed"). 'done'/'dropped' are settled —
# nothing a human can do reopens them — so they never keep the loop alive.
sub _awaits_human { my $s = shift // ''; $s =~ /^(blocked|parked)$/ ? 1 : 0 }

# --- coordinator progress (Decision #14: stream-log growth is a free liveness
# signal). Given the jsonl's current/previous size + its mtime + now, decide if a
# (live) coordinator is making progress or is wedged (no growth AND quiet >= flat).
sub progress_verdict {
    my ($cur_size, $cur_mtime, $prev_size, $now, $flat_secs) = @_;
    $flat_secs //= 600;
    return 'growing' unless defined $cur_size;          # no file yet -> give it time
    return 'growing' unless defined $prev_size;         # first observation
    return 'growing' if $cur_size > $prev_size;         # grew since last look
    my $quiet = $now - ($cur_mtime // $now);
    return ($quiet >= $flat_secs) ? 'flat' : 'growing';
}

# --- DAG: are a package's dependencies all done?
sub deps_met {
    my ($deps, $status) = @_;
    return 1 unless ref $deps eq 'ARRAY' && @$deps;
    for my $d (@$deps) { return 0 unless ($status->{$d} // '') eq 'done'; }
    return 1;
}

# --- write-set overlap (conservative; path-prefix aware). Two write-sets are
# disjoint iff no normalized prefix of one is an ancestor-or-equal of the other.
sub _ws_prefixes {
    my ($ws) = @_;
    my @out;
    for my $p (split /:/, (defined $ws ? $ws : '')) {
        next unless length $p;
        $p =~ s{\*.*$}{};      # cut at the first glob -> directory prefix
        $p =~ s{/+$}{};        # drop trailing slash(es)
        push @out, $p;
    }
    return @out;
}
sub _prefix_related {
    my ($a, $b) = @_;
    return 1 if $a eq $b;
    return 1 if $a eq '' || $b eq '';            # an empty prefix matches anything
    return 1 if index("$b/", "$a/") == 0;        # a is an ancestor dir of b
    return 1 if index("$a/", "$b/") == 0;        # b is an ancestor dir of a
    return 0;
}
sub write_sets_overlap {
    my ($wa, $wb) = @_;
    my @a = _ws_prefixes($wa);
    my @b = _ws_prefixes($wb);
    for my $x (@a) { for my $y (@b) { return 1 if _prefix_related($x, $y); } }
    return 0;
}

# --- newly-ready packages: pending, deps all done, write-set disjoint from every
# currently-running package. $meta = { pkg => {deps=>[...], write_set=>"..."} }.
sub ready_packages {
    my ($meta, $status, $running) = @_;
    my @run_ws = map { $meta->{$_}{write_set} } grep { exists $meta->{$_} } @{ $running || [] };
    my @ready;
    for my $pkg (sort keys %$meta) {
        my $st = $status->{$pkg} // 'pending';
        next unless $st eq 'pending';
        next unless deps_met($meta->{$pkg}{deps}, $status);
        my $ws = $meta->{$pkg}{write_set};
        next if grep { write_sets_overlap($ws, $_) } @run_ws;
        push @ready, $pkg;
    }
    return @ready;
}

# --- greedily pick a launch batch (<= slots) whose write-sets are mutually
# disjoint AND disjoint from what's already running (avoids same-tick clashes).
sub pick_launch_batch {
    my ($ready, $meta, $running_ws, $slots) = @_;
    my @chosen; my @ws = @{ $running_ws || [] };
    for my $pkg (@$ready) {
        last if @chosen >= ($slots // 0);
        my $w = $meta->{$pkg}{write_set};
        next if grep { write_sets_overlap($w, $_) } @ws;
        push @chosen, $pkg; push @ws, $w;
    }
    return @chosen;
}

# --- free parallelism slots.
sub cap_slots { my ($running, $cap) = @_; my $s = ($cap // 0) - ($running // 0); $s < 0 ? 0 : $s }

# --- watchdog verdict for one already-launched, non-terminal package.
#   alive + growing            -> none           (healthy)
#   alive + flat   (wedged)    -> cold-relaunch  (kill + fresh) | block past cap
#   dead                       -> relaunch       (warm/cold)    | block past cap
sub watchdog_verdict {
    my ($c) = @_;
    my $cap = $c->{cap} // 5;
    my $att = $c->{attempts} // 0;
    if ($c->{alive}) {
        return 'none' if ($c->{progress} // 'growing') eq 'growing';
        return ($att < $cap) ? 'cold-relaunch' : 'block';
    }
    return ($att < $cap) ? 'relaunch' : 'block';
}

# --- terminal-event classification. A coordinator that hits --max-turns exits 1
# and its LAST jsonl line is a result object with subtype 'error_max_turns' /
# terminal_reason 'max_turns' — indistinguishable from a crash by exit code alone.
# Total over ANY input (undef, a scalar, an arrayref); never dies. The four keys
# are always present so callers can read them unconditionally.
sub terminal_verdict {
    my ($obj) = @_;
    my %v = (verdict => 'unknown', subtype => undef, num_turns => undef, session_id => undef);
    return \%v unless ref $obj eq 'HASH';
    return \%v unless (defined $obj->{type} && !ref $obj->{type} && $obj->{type} eq 'result');
    $v{subtype}    = $obj->{subtype}    if defined $obj->{subtype}    && !ref $obj->{subtype};
    $v{num_turns}  = $obj->{num_turns}  if defined $obj->{num_turns}  && !ref $obj->{num_turns};
    $v{session_id} = $obj->{session_id} if defined $obj->{session_id} && !ref $obj->{session_id};
    my $st = (defined $obj->{subtype}         && !ref $obj->{subtype})         ? $obj->{subtype}         : '';
    my $tr = (defined $obj->{terminal_reason} && !ref $obj->{terminal_reason}) ? $obj->{terminal_reason} : '';
    $v{verdict} = ($st eq 'error_max_turns' || $tr eq 'max_turns') ? 'max_turns'
                : ($st eq 'success')                               ? 'success'
                :                                                    'error';
    return \%v;
}

# --- did the package make SEMANTIC progress since the snapshot taken at launch?
# Deliberately NOT jsonl growth (a max-turns run always appends lines, so growth
# would make every exhaustion look productive) and NOT a ledger mtime bump (a
# no-op ledger rewrite touches it). Only: the status advanced, or at least one
# more pipeline checkbox got ticked. A DECREASE is not progress (strict >).
sub snapshot_progressed {
    my ($snap, $cur) = @_;
    return 0 unless ref $snap eq 'HASH' && ref $cur eq 'HASH';    # no snapshot => cannot prove progress
    return 1 if ($cur->{status} // '') ne ($snap->{status} // '');
    return 1 if ($cur->{checkboxes} // 0) > ($snap->{checkboxes} // 0);
    return 0;
}

# --- b02: did the package's LEDGER move in a way worth a WIP checkpoint since
# the previous tick's snapshot? Everything snapshot_progressed calls progress,
# plus a ledger rewrite (the `## Decisions & attempt log` lives in the same
# file, so "the attempt log grew" is observed as an mtime bump).
# jsonl_size is deliberately NOT compared: the coordinator's stream log grows on
# essentially every turn, so including it would make every tick "meaningful" and
# produce a commit every watch tick (same rationale as :199-203).
sub checkpoint_advanced {
    my ($prev, $cur) = @_;
    return 0 unless ref $prev eq 'HASH' && ref $cur eq 'HASH';   # no baseline => cannot prove an advance
    return 1 if snapshot_progressed($prev, $cur);
    return 1 if ($cur->{ledger_mtime} // 0) > ($prev->{ledger_mtime} // 0);
    return 0;
}

# --- absolute ceiling on any turn budget this script will ever hand to
# `claude -p --max-turns`. The per-package 2x ceiling is anchored on the AUTHOR's
# intent, which comes off disk (ledger frontmatter `max_turns`, runs/.tunables
# `default_max_turns`, $BP_DEFAULT_MAX_TURNS) — all three are attacker- or
# fat-finger-reachable. A `{"default_max_turns": 99999999}` would otherwise
# propagate initial -> widen -> `--max-turns 149999998`: one unbounded-cost
# session, no relaunch needed, no cap in the loop to stop it. This is the last
# line of defence, applied AFTER every other clamp so nothing can out-rank it.
# Far above every realistic budget (defaults are 80-120), so it never binds in
# normal operation — it only truncates the absurd.
our $MAX_TURNS_CEILING = 1000;

# --- adaptive turn budget: 1.5x per productive exhaustion, capped at 2x the
# author's intent, never shrinking. int() truncates (all values positive => floor).
sub widen_max_turns {
    my ($current, $initial) = @_;
    $current = 0 + ($current // 0);
    $initial = 0 + (defined $initial ? $initial : $current);
    my $next = int(1.5 * $current);
    my $ceil = 2 * $initial;
    $next = $ceil    if $next > $ceil;
    $next = $current if $next < $current;
    # Hard ceiling LAST: it must beat "never shrinks below current" too, because a
    # $current read back from a poisoned registry is exactly the hostile input.
    $next = $MAX_TURNS_CEILING if $next > $MAX_TURNS_CEILING;
    return $next;
}

# --- give-up cap isolation: bp-launch.sh bumps `attempt` on EVERY launch, incl.
# orchestrator-granted turn continuations. Subtract the continuations we granted
# at the watchdog call site so a productive package isn't blocked for being
# continued (watchdog_verdict itself stays pure and unchanged).
sub effective_attempts {
    my ($attempts, $turn_continuations) = @_;
    my $n = ($attempts // 0) - ($turn_continuations // 0);
    return $n < 0 ? 0 : $n;
}

# --- warm-resume vs cold-start economics (mirrors bp-resume-sweep.sh): warm only
# within the threshold of the last ledger touch AND with a known session id.
sub resume_mode {
    my ($age_min, $sid, $threshold_min) = @_;
    $threshold_min //= 60;
    return 'warm' if defined $sid && length $sid && defined $age_min && $age_min <= $threshold_min;
    return 'cold';
}

# --- usage governance: validate the poll, then derive a trip-based pause below the
# ceilings (Decision #9) and the next adaptive cadence (Decision #8).
#   $t = { ceil5, ceil7, drain }
sub usage_decision {
    my ($parsed, $s5, $s7, $t) = @_;
    my ($ok, $probs) = BpContract::validate_usage($parsed);
    return { action => 'pause-contract', problems => $probs } unless $ok;
    my $u5 = $parsed->{five_hour}{utilization};
    my $u7 = $parsed->{seven_day}{utilization};
    my $b5 = BpGovern::burn_per_sec($s5);
    my $b7 = BpGovern::burn_per_sec($s7);
    my $p5 = BpGovern::should_pause($u5, $b5, $t->{drain}, $t->{ceil5});
    my $p7 = BpGovern::should_pause($u7, $b7, $t->{drain}, $t->{ceil7});
    my $trip5 = BpGovern::trip_point($b5, $t->{drain}, $t->{ceil5});
    my $trip7 = BpGovern::trip_point($b7, $t->{drain}, $t->{ceil7});
    my $cadence = BpGovern::next_cadence($s5, $trip5, $s7, $trip7);
    if ($p5 || $p7) {
        my $w = $p5 ? 'five_hour' : 'seven_day';
        return {
            action   => 'pause-usage',
            window   => $w,
            resets_at=> BpGovern::iso_to_epoch($parsed->{$w}{resets_at}),
            util     => { five => $u5, seven => $u7 },
            cadence  => $cadence,
        };
    }
    return { action => 'ok', cadence => $cadence, util => { five => $u5, seven => $u7 } };
}

# --- b03: seconds until the next usage re-poll while a creds episode persists.
#   $n = ordinal of the consecutive creds-failed usage poll (1 = the first).
# Each knob resolves as $t->{k} // $ENV{BP_...} // pinned default, so a tunables
# HASH injected by a pre-existing test (t/08 base_tunables, t/11, t/21) that has
# none of these keys still gets the pinned defaults (spec §5.9).
# creds_backoff_secs(n) = min(base * mult^(n-1), max); n<=0/undef treated as 1.
sub creds_backoff_secs {
    my ($n, $t) = @_;
    $t ||= {};
    my $base = $t->{creds_bo_base} // $ENV{BP_CREDS_BACKOFF_BASE_SECS} // 60;
    my $mult = $t->{creds_bo_mult} // $ENV{BP_CREDS_BACKOFF_MULT}      // 2;
    my $max  = $t->{creds_bo_max}  // $ENV{BP_CREDS_BACKOFF_MAX_SECS}  // 1800;
    $n = 1 if !defined $n || $n < 1;
    my $s = $base; $s *= $mult for 2 .. $n;
    return $s > $max ? $max : $s;
}

# --- pause payload (Decision #12 contract: epoch resets_at + jittered relaunch).
sub choose_jitter {
    my ($lo, $hi, $rand) = @_;          # $rand in [0,1); injected for determinism
    $lo //= 300; $hi //= 900;
    $rand //= rand();
    return int($lo + $rand * ($hi - $lo));
}
sub paused_payload {
    my ($resets_at, $now, $jitter_secs, $reason) = @_;
    my $relaunch = (defined $resets_at ? $resets_at : $now) + ($jitter_secs // 0);
    return {
        reason      => ($reason // 'usage'),
        resets_at   => $resets_at,
        relaunch_at => $relaunch,
        created_at  => $now,
    };
}
# --- ready to auto-resume? Only time-based (usage/telemetry-with-time) pauses
# auto-resume; manual pauses (auth/contract/creds — need a human) never do.
sub resume_ready {
    my ($paused, $now) = @_;
    return 0 unless ref $paused eq 'HASH';
    return 0 if $paused->{manual};
    return 0 unless defined $paused->{relaunch_at};
    return $now >= $paused->{relaunch_at} ? 1 : 0;
}

# --- busy-lease (Decision #16): touch while work is active OR an auto-resume is
# pending; never while shut down or only parked-for-human.
sub should_touch_busy {
    my ($c) = @_;
    return 0 if $c->{shutdown};
    return ($c->{any_running} || $c->{outstanding} || $c->{resume_pending}) ? 1 : 0;
}

# --- is there still progressable work? (a non-terminal package with no
# blocked/parked dependency). Used for busy-lease + the idle-exit decision.
sub has_progressable_work {
    my ($meta, $status) = @_;
    for my $pkg (keys %$meta) {
        my $st = $status->{$pkg} // 'pending';
        next if _is_terminal($st);
        my $dead_dep = 0;
        for my $d (@{ $meta->{$pkg}{deps} || [] }) {
            my $ds = $status->{$d} // 'pending';
            # a dependency that is terminal-but-not-done (blocked/parked/dropped)
            # can never satisfy deps_met, so this package is dead-ended, not
            # progressable. (deps_met requires the dep === 'done'.)
            $dead_dep = 1 if _is_terminal($ds) && $ds ne 'done';
        }
        return 1 unless $dead_dep;
    }
    return 0;
}

# --- awaiting-human packages (blocked/parked) that have NO queued needs-you
# decision. A coordinator can self-block/park in its OWN ledger (gate-stop.sh
# permits a terminal stop with a '## Next action') WITHOUT the orchestrator ever
# running its escalation path — so no decision is filed, the reporter's queue-watcher
# (bp-wait-for-decision) stays silent, and the run goes quiet. The loop reconciles
# this every tick: every awaiting-human package must leave the human something to
# act on. $queued = { pkg => 1 } of packages that already have a decision (any kind).
# Pure.
sub orphan_escalations {
    my ($meta, $status, $queued) = @_;
    $queued ||= {};
    my @out;
    for my $pkg (sort keys %$meta) {
        next unless _awaits_human($status->{$pkg} // '');
        next if $queued->{$pkg};
        push @out, $pkg;
    }
    return @out;
}

# --- the orchestrator exits ONLY when there is genuinely nothing left it could do:
# nothing running, nothing progressable, no auto-resume pending, not paused, AND
# nothing parked/blocked awaiting a human. The last clause is load-bearing: a
# blocked/parked package is unblocked by a human's answer (bp-answer-decision flips
# it to pending), and the documented reporter contract is that the STILL-RUNNING
# orchestrator relaunches it next tick — "no restart needed". Exiting here strands
# the run on a dead orchestrator. Awaiting-human work keeps the loop alive (idle-
# polling) but NOT the busy-lease (should_touch_busy still excludes parked-for-human),
# so the machine can still sleep while waiting on the human.
sub run_complete {
    my ($c) = @_;
    return 0 if $c->{any_running} || $c->{outstanding} || $c->{resume_pending} || $c->{paused};
    return 0 if $c->{awaiting_human};
    # b05: an un-remediated characterizable conformance failure (or a conformance
    # judge still in flight) keeps the run open. Caller-computed flag ONLY — this sub
    # stays pure so it remains unit-testable; see conformance_outstanding().
    return 0 if $c->{conformance_outstanding};
    # b07: a queued/awaiting_verify remediation entry keeps the run alive exactly
    # like conformance_outstanding above. An ESCALATED entry does NOT hold the
    # run alive — the human is now the blocking dependency and the decision is
    # already on disk (Decision #20); see remediation_outstanding().
    # NB (b05 AC-6 / b07 AC-17): this sub's body is scanned for file-I/O tokens by
    # /(?<![\w:>])open\s*[\(\s]/, so no comment here may write "open" followed by a
    # space or a paren. Say "alive". b05's own "open." survives only via its period.
    return 0 if $c->{remediation_outstanding};
    return 1;
}

# --- parse the blueprint.md package-status table into a DAG: { pkg => [deps] }.
# The table header row contains 'depends_on'; columns are
# | pkg | deliverable | depends_on | model | status |. A '—'/'-'/empty deps cell
# means no dependencies.
sub parse_dag {
    my ($md) = @_;
    my %dag;
    my @lines = split /\n/, (defined $md ? $md : '');
    my ($in, $hdr) = (0, undef);
    for my $ln (@lines) {
        if (!$in) {
            if ($ln =~ /^\s*\|/ && $ln =~ /depends_on/) {
                $hdr = [ _table_cols($ln) ];
                $in = 1;
            }
            next;
        }
        last unless $ln =~ /^\s*\|/;            # table ended
        next if $ln =~ /^\s*\|[\s:|-]+\|?\s*$/; # separator row
        my @c = _table_cols($ln);
        my %row; @row{@$hdr} = @c;
        my $pkg = $row{pkg};
        next unless defined $pkg && length $pkg;
        my $deps_raw = $row{depends_on} // '';
        my @deps;
        # Keep only tokens that look like a package id. A '—'/'–'/'-' (incl. its
        # multi-byte UTF-8 form read from disk as raw bytes) means "no deps" and is
        # rejected by the whitelist, so no decoding is needed.
        for my $d (split /[,\s]+/, $deps_raw) {
            push @deps, $d if $d =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
        }
        $dag{$pkg} = \@deps;
    }
    return \%dag;
}
sub _table_cols {
    my ($ln) = @_;
    $ln =~ s/^\s*\|//; $ln =~ s/\|\s*$//;
    my @c = split /\|/, $ln, -1;
    s/^\s+//, s/\s+$// for @c;
    return @c;
}

# ===========================================================================
# I/O HELPERS  (disk, processes — kept thin; the loop composes them)
# ===========================================================================

sub _read_file { my $f = shift; open my $fh, '<:raw', $f or return undef; local $/; my $r = <$fh>; close $fh; $r }
sub _read_json { my $f = shift; my $r = _read_file($f); return undef unless defined $r; eval { JSON::PP->new->decode($r) } }

# ledger frontmatter reader (status / write_set live in the ledger; authoritative).
sub ledger_fm {
    my ($bpdir, $pkg, $key) = @_;
    my $f = "$bpdir/packages/$pkg.md";
    my $txt = _read_file($f);
    return undef unless defined $txt;
    my ($fm) = $txt =~ /\A---\s*\n(.*?)\n---/s;
    return undef unless defined $fm;
    for my $ln (split /\n/, $fm) {
        if ($ln =~ /^\Q$key\E:\s*(.*?)\s*$/) { return $1; }
    }
    return undef;
}

# read a ledger's '## Next action' body (first few non-empty, non-heading lines),
# collapsed to one bounded line, so an orphan escalation can surface the
# coordinator's OWN handoff note to the human (e.g. "expand this package's
# write_set + test_paths…") instead of only a generic prompt. undef if absent.
sub ledger_next_action {
    my ($bpdir, $pkg) = @_;
    my $txt = _read_file("$bpdir/packages/$pkg.md");
    return undef unless defined $txt;
    return undef unless $txt =~ /^##\s+Next action\s*\n(.*?)(?=\n##\s|\z)/ims;
    my @lines = grep { /\S/ && !/^\s*#/ } split /\n/, $1;
    return undef unless @lines;
    @lines = @lines[0 .. ($#lines < 4 ? $#lines : 4)];     # cap at first 5 lines
    my $s = join(' ', map { my $x = $_; $x =~ s/^\s+//; $x =~ s/\s+$//; $x } @lines);
    # The ledger is coordinator-written (a Claude); this text lands in a decision the
    # reporter prints to a terminal. Strip C0/DEL control bytes (e.g. a raw ESC that
    # could spoof the approval UI) at this input seam — display-seam sanitization is
    # the reporter's job too, but defence in depth (house rule: sanitize untrusted).
    $s =~ tr/\x00-\x08\x0B\x0C\x0E-\x1F\x7F//d;
    $s =~ s/\s+/ /g;
    return length $s ? substr($s, 0, 500) : undef;
}

sub read_registry {
    my ($runs) = @_;
    my $r = _read_json("$runs/registry.json");
    return (ref $r eq 'HASH' && ref $r->{packages} eq 'HASH') ? $r->{packages} : {};
}

# --- last NON-EMPTY line of a file, read seek-from-end so a multi-GB coordinator
# stream is never slurped into one scalar. undef on missing/empty/all-blank.
our $MAX_JSONL_LINE = 1_048_576;      # hard cap on the terminal line we will hold/decode

sub _last_nonempty_line {
    my ($f) = @_;
    open my $fh, '<:raw', $f or return undef;
    my $size = (stat($fh))[7];
    unless (defined $size && $size > 0) { close $fh; return undef; }
    my $CHUNK = 65536;
    my $pos   = $size;
    my $tail  = '';           # always a suffix of the file
    my $found;
    while ($pos > 0) {
        my $len = $pos < $CHUNK ? $pos : $CHUNK;
        $pos -= $len;
        last unless seek($fh, $pos, 0);
        my $data = '';
        my $got  = read($fh, $data, $len);
        last unless defined $got && $got > 0;
        $tail = $data . $tail;
        my @lines = split /\n/, $tail, -1;
        my $lo = $pos > 0 ? 1 : 0;        # element 0 may be a partial line
        for (my $i = $#lines; $i >= $lo; $i--) {
            next unless $lines[$i] =~ /\S/;
            $found = $lines[$i];
            last;
        }
        last if defined $found;
        $tail = $lo ? $lines[0] : '';
        # One pathological line (a coordinator that dumped a payload without a
        # newline) would otherwise pull the whole file into memory — and then
        # JSON-decode it once per dead package per tick. Give up instead.
        last if length($tail) > $MAX_JSONL_LINE;
    }
    close $fh;
    return $found;
}

# --- the JSON-decoded last non-empty line of runs/<pkg>.jsonl (the coordinator's
# TERMINAL event), or undef when the file is missing/empty/all-blank/truncated or
# the last line isn't a JSON object. NOTE: `type` is NOT the first key on that
# line, so the line MUST be decoded — a prefix/regex grep would never match.
sub _last_jsonl_obj {
    my ($runs, $pkg) = @_;
    my $line = _last_nonempty_line("$runs/$pkg.jsonl");
    return undef unless defined $line && $line =~ /\S/;
    return undef if length($line) > $MAX_JSONL_LINE;   # never decode an unbounded line
    my $obj = eval { JSON::PP->new->decode($line) };
    return (ref $obj eq 'HASH') ? $obj : undef;
}

# --- ticked pipeline checkboxes in a ledger BODY (frontmatter excluded). The
# human-meaningful unit of within-attempt progress. Unreadable ledger -> 0.
sub ledger_checkboxes {
    my ($bpdir, $pkg) = @_;
    my $txt = _read_file("$bpdir/packages/$pkg.md");
    return 0 unless defined $txt;
    $txt =~ s/\A---\s*\n.*?\n---//s;          # drop frontmatter; count the body only
    my $n = 0;
    for my $ln (split /\n/, $txt) { $n++ if $ln =~ /^\s*-\s*\[[xX]\]/ }
    return $n;
}

# --- the progress baseline captured immediately BEFORE a launch. status +
# checkboxes are the progress signal (snapshot_progressed); jsonl_size and
# ledger_mtime are recorded for the decision context only (see §2.3).
sub launch_snapshot {
    my ($bpdir, $runs, $pkg, $now) = @_;
    my ($sz) = jsonl_stat($runs, $pkg);
    my @st = stat("$bpdir/packages/$pkg.md");
    return {
        status       => (ledger_fm($bpdir, $pkg, 'status') // ''),
        checkboxes   => ledger_checkboxes($bpdir, $pkg),
        jsonl_size   => ($sz // 0),
        ledger_mtime => (@st ? $st[9] : 0),
        at           => ($now // time),
    };
}

# --- the package author's turn budget (ledger frontmatter = intent), else the
# tunable/env default. The 2x ceiling in widen_max_turns is anchored on THIS, so
# it stays stable however many continuations were granted.
sub initial_max_turns {
    my ($bpdir, $pkg, $t) = @_;
    # Every source below is off-disk and untrusted, so each accepted value is
    # clamped to $MAX_TURNS_CEILING (see widen_max_turns): the anchor can never
    # be absurd, hence neither can 2x the anchor.
    my $fm = ledger_fm($bpdir, $pkg, 'max_turns');
    return _clamp_turns($fm + 0) if defined $fm && $fm =~ /^\d+$/ && $fm > 0;
    my $d = (ref $t eq 'HASH' ? $t->{default_max_turns} : undef) // $ENV{BP_DEFAULT_MAX_TURNS} // 80;
    return (defined $d && !ref $d && $d =~ /^\d+$/ && $d > 0) ? _clamp_turns($d + 0) : 80;
}
sub _clamp_turns { my ($n) = @_; return $n > $MAX_TURNS_CEILING ? $MAX_TURNS_CEILING : $n; }

sub jsonl_stat {
    my ($runs, $pkg) = @_;
    my @st = stat("$runs/$pkg.jsonl");
    return (undef, undef) unless @st;
    return ($st[7], $st[9]);     # size, mtime
}

sub ledger_age_min {
    my ($bpdir, $pkg, $now) = @_;
    my @st = stat("$bpdir/packages/$pkg.md");
    return undef unless @st;
    return int((($now // time) - $st[9]) / 60);
}

# port of bp-lib.sh pid_alive (kill 0 + /proc zombie check).
sub pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return 0 unless kill 0, $pid;
    if (open my $s, '<', "/proc/$pid/stat") {
        my $line = <$s>; close $s;
        if (defined $line && $line =~ /\)\s+(\S)/) { return 0 if $1 eq 'Z'; }
    }
    return 1;
}

# best-effort kill of a (setsid) coordinator and its process group.
sub kill_pid {
    my ($pid) = @_;
    return unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    # The pid comes off disk and may be stale, forged, or recycled. `kill -1` (pid 1)
    # signals EVERY process the uid can reach; our own pid or our own pgroup would
    # take the orchestrator down with the coordinator. Never signal those.
    return if $pid <= 1 || $pid == $$ || $pid == getpgrp();
    eval { kill 'TERM', -$pid; 1 } or eval { kill 'TERM', $pid; 1 };
    eval { kill 'KILL', -$pid; 1 } or eval { kill 'KILL', $pid; 1 };
}

# --- runs/.paused (usage/telemetry/auth pause signal; epoch fields).
sub read_paused {
    my ($runs) = @_;
    my $p = "$runs/.paused";
    return undef unless -e $p;
    my $d = _read_json($p);
    return (ref $d eq 'HASH') ? $d : { reason => 'unknown', manual => 1 };
}
# --- shared failure path for the two ESCALATION writers below (write_paused,
# queue_needs_you). They must never `die`: they are called precisely when the
# environment is already suspect (broken-env trip, telemetry loss) — a read-only,
# full, or badly-mounted runs/ is the expected input, not a surprise. Dying here
# is caught by the loop's outer eval and re-thrown, killing the orchestrator with
# NO .paused written and NO decision filed: the fleet stops silently, the worst
# possible outcome for an escalation path. Returning 0 keeps the loop alive so the
# next tick can retry (a transient ENOSPC/EROFS may clear) and so the remaining
# escalation steps still run. Callers use these in void context; the only
# return-value consumer wants queue_needs_you's path on SUCCESS, which is
# unchanged, and 0 is reliably false for a failed write.
sub _escalation_write_failed {
    my ($runs, $writer, $path, $err) = @_;
    # BpLog::event writes into runs/ and dies on failure — i.e. the very condition
    # being reported may also break the report. Guard it, and fall back to STDERR
    # so a broken runs/ still leaves a trace somewhere.
    my $detail = defined $err && length "$err" ? "$err" : 'unknown error';
    eval {
        _log("$runs/orchestrator.log", 'escalation_write_failed',
             { writer => $writer, path => $path, error => $detail,
               detail => 'escalation write failed — loop continues, will retry next tick' });
        1;
    } or warn "bp-orchestrator: $writer failed for $path: $detail (orchestrator.log unwritable too)\n";
    return 0;
}

# Returns 1 on success, 0 on any write/rename failure (never dies — see above).
sub write_paused {
    my ($runs, $rec) = @_;
    # atomic: temp + rename, so a crash mid-write can never leave a truncated
    # .paused that would read back as a stuck "unknown" manual pause.
    my $tmp = "$runs/.paused.tmp.$$";
    open my $fh, '>', $tmp
        or return _escalation_write_failed($runs, 'write_paused', $tmp, $!);
    unless (print $fh JSON::PP->new->canonical->encode($rec)) {
        my $e = $!; close $fh; unlink $tmp;
        return _escalation_write_failed($runs, 'write_paused', $tmp, $e);
    }
    # close can be the first place a full filesystem reports ENOSPC.
    unless (close $fh) {
        my $e = $!; unlink $tmp;
        return _escalation_write_failed($runs, 'write_paused', $tmp, $e);
    }
    unless (rename $tmp, "$runs/.paused") {
        my $e = $!; unlink $tmp;
        return _escalation_write_failed($runs, 'write_paused(rename)', "$runs/.paused", $e);
    }
    return 1;
}
sub clear_pause { my ($runs) = @_; unlink "$runs/.paused"; }

# --- runs/needs-you/<pkg>--<shortid>.json (decision queue; A3 owns the schema).
# Returns the decision file path on success (existing one when deduped), 0 on any
# mkdir/write/rename failure (never dies — see _escalation_write_failed).
sub queue_needs_you {
    my ($runs, $rec) = @_;
    my $dir = "$runs/needs-you";
    # make_path croaks on failure (read-only / full runs/) — never let that escape.
    unless (-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 }
            or return _escalation_write_failed($runs, 'queue_needs_you(mkdir)', $dir, ($@ || $!));
        return _escalation_write_failed($runs, 'queue_needs_you(mkdir)', $dir, $!) unless -d $dir;
    }
    # dedupe: don't re-queue the same package+kind every tick.
    if (opendir my $dh, $dir) {
        for my $f (grep { /\.json$/ } readdir $dh) {
            my $ex = _read_json("$dir/$f");
            next unless ref $ex eq 'HASH';
            if (($ex->{package} // '') eq ($rec->{package} // '')
             && ($ex->{kind}    // '') eq ($rec->{kind}    // '')) {
                closedir $dh; return "$dir/$f";
            }
        }
        closedir $dh;
    }
    my $sid = substr(sprintf('%x%x', ($rec->{created_at} // time), $$), 0, 10);
    my $file = "$dir/$rec->{package}--$sid.json";
    # Atomic publish (temp in the same dir + rename) so the A7 bp-wait-for-decision
    # watcher — which polls this dir — never reads a half-written queue file. The
    # target name is always fresh+unique (the dedupe above returns early when a
    # package+kind entry already exists), so the rename never clobbers and is
    # atomic on both POSIX and Windows. Matches the temp+rename discipline every
    # other writer here uses (ledgers, registry, judge verdicts).
    my $tmp = "$file.tmp.$$";
    open my $fh, '>', $tmp
        or return _escalation_write_failed($runs, 'queue_needs_you', $tmp, $!);
    unless (print $fh JSON::PP->new->canonical->pretty->encode($rec)) {
        my $e = $!; close $fh; unlink $tmp;
        return _escalation_write_failed($runs, 'queue_needs_you', $tmp, $e);
    }
    unless (close $fh) {
        my $e = $!; unlink $tmp;
        return _escalation_write_failed($runs, 'queue_needs_you', $tmp, $e);
    }
    unless (rename $tmp, $file) {
        my $e = $!; unlink $tmp;
        return _escalation_write_failed($runs, 'queue_needs_you(rename)', $file, $e);
    }
    return $file;
}

# --- packages that currently have a queued needs-you decision (any kind). Used to
# reconcile orphaned blocked/parked packages (orphan_escalations) so the loop never
# re-files a decision for a package the human can already see. Half-written/non-JSON
# files and dotfiles are ignored (matches bp-wait-for-decision's scanner).
sub queued_decision_pkgs {
    my ($runs) = @_;
    my %pk;
    my $dir = "$runs/needs-you";
    if (opendir my $dh, $dir) {
        for my $f (grep { /\.json$/ && !/^\./ } readdir $dh) {
            my $ex = _read_json("$dir/$f");
            next unless ref $ex eq 'HASH';
            my $p = $ex->{package};
            $pk{$p} = 1 if defined $p && length $p;
        }
        closedir $dh;
    }
    return \%pk;
}

# --- registry per-package merge (A5). The orchestrator now writes registry fields
# (resolve_attempts / corrective_attempts / harvest) that bp-launch.sh doesn't, so
# it must serialize against bp-launch.sh's writes. Use the SAME lock file the shell
# side uses (bp-lib.sh registry_merge: flock on runs/registry.lock) + same-dir temp
# + rename so the merge is atomic on the shared registry.json.
sub update_registry_pkg {
    my ($runs, $pkg, $fields) = @_;
    require File::Path; File::Path::make_path($runs) unless -d $runs;
    my $reg = "$runs/registry.json";
    open my $lk, '>', "$runs/registry.lock" or return 0;
    unless (flock($lk, LOCK_EX)) { close $lk; return 0; }
    my $data = _read_json($reg);
    $data = { packages => {} } unless ref $data eq 'HASH' && ref $data->{packages} eq 'HASH';
    $data->{packages}{$pkg} = { %{ $data->{packages}{$pkg} || {} }, %$fields };
    my $tmp = "$reg.tmp.$$";
    my $ok = 0;
    if (open my $w, '>', $tmp) {
        print $w JSON::PP->new->canonical->pretty->encode($data);
        close $w;
        # Honest result: a failed rename means the update was LOST (a cap counter
        # increment, a harvest=pass) — return 0 so the caller can log/react rather
        # than silently bypassing resolve_cap / corrective_cap on the next tick (H1).
        if (rename $tmp, $reg) { $ok = 1; } else { unlink $tmp; }
    }
    flock($lk, LOCK_UN); close $lk;
    return $ok;
}

# update_registry_pkg + an honest log line when the merge was LOST (H1): the tick
# continues (worst case one continuation is re-granted or a streak increment is
# dropped next tick) but the loss is never silent.
sub _upd_pkg {
    my ($runs, $log, $pkg, $fields) = @_;
    return 1 if update_registry_pkg($runs, $pkg, $fields);
    _log($log, 'registry_update_lost', { package => $pkg, fields => join(',', sort keys %$fields) });
    return 0;
}

# a registry integer field that survived hand-editing / type drift, else undef.
sub _reg_int {
    my ($v) = @_;
    return undef unless defined $v && !ref $v && $v =~ /^\d+$/ && $v > 0;
    return $v + 0;
}

# --- judge verdicts (A5): each judge is a detached process that writes a verdict
# JSON to runs/<kind>/<pkg>.verdict.json. The orchestrator spawns then polls — it
# never blocks its watch tick on a multi-minute Claude call (kind = harvest|resolve).
sub judge_verdict_path { my ($runs, $kind, $pkg) = @_; "$runs/$kind/$pkg.verdict.json" }
sub read_judge_verdict {
    my ($runs, $kind, $pkg) = @_;
    my $f = judge_verdict_path($runs, $kind, $pkg);
    return undef unless -e $f;
    # File present but unreadable/!JSON -> a sentinel hash so the normalizers
    # classify it fail-closed (harvest->error, resolve->park) rather than re-polling.
    return _read_json($f) // { _malformed => 1 };
}
sub clear_judge_verdict { my ($runs, $kind, $pkg) = @_; unlink judge_verdict_path($runs, $kind, $pkg); }

# judge IN-FLIGHT state is kept ON DISK (runs/<kind>/<pkg>.inflight, content = the
# epoch the judge was fired) rather than in orchestrator memory, so it survives an
# orchestrator restart (a judge fired before a crash isn't double-spawned and its
# timeout is still honored) and is observable/testable. judge_inflight returns the
# stored start-epoch (truthy) or undef.
sub judge_inflight_path { my ($runs, $kind, $pkg) = @_; "$runs/$kind/$pkg.inflight" }
sub judge_inflight {
    my ($runs, $kind, $pkg) = @_;
    my $r = _read_file(judge_inflight_path($runs, $kind, $pkg));
    return undef unless defined $r;
    return ($r =~ /^(\d+)/) ? $1 : 0;     # 0 = inflight but no/garbled epoch (still truthy-via-defined)
}
sub mark_judge_inflight {
    my ($runs, $kind, $pkg, $now) = @_;
    require File::Path; File::Path::make_path("$runs/$kind") unless -d "$runs/$kind";
    # Atomic temp+rename so a write that fails after truncation can't leave a
    # zero-length marker (which would read back as epoch 0 -> instant false timeout, C1).
    my $f = judge_inflight_path($runs, $kind, $pkg);
    my $tmp = "$f.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print $fh ($now // time); close $fh;
    rename $tmp, $f or do { unlink $tmp; return 0; };
    return 1;
}
sub clear_judge_inflight { my ($runs, $kind, $pkg) = @_; unlink judge_inflight_path($runs, $kind, $pkg); }

# --- runs/.orchestrator marker (PID + flock; held for the run's lifetime).
sub acquire_marker {
    my ($path) = @_;
    open my $fh, '>', $path or die "bp-orchestrator: marker open: $!";
    unless (flock($fh, LOCK_EX | LOCK_NB)) { close $fh; return undef; }
    { my $o = select($fh); local $| = 1; print $fh "$$\n"; select($o); }
    return $fh;                       # keep open to hold the lock
}
sub read_marker_pid {
    my ($path) = @_;
    my $r = _read_file($path);
    return ($r && $r =~ /^(\d+)/) ? $1 : undef;
}
sub release_marker {
    my ($fh, $path) = @_;
    if ($fh) { flock($fh, LOCK_UN); close $fh; }
    unlink $path if defined $path;
}

sub touch_busy {
    my ($path) = @_;
    my $now = time;
    unless (-e $path) { open my $fh, '>', $path or return 0; close $fh; }
    utime $now, $now, $path;
    return 1;
}

# ===========================================================================
# TRANSPORTS  (injectable; real ones used in production, mocks in tests)
# ===========================================================================

sub _real_http_get {
    my ($url, $headers) = @_;
    # curl transport (bp-http.pl): the sandbox perl lacks IO::Socket::SSL, so
    # HTTP::Tiny HTTPS is unavailable there. curl trusts the system cert store.
    return BpHttp::request('GET', $url, $headers);
}

# fetch + validate one usage poll. Returns one of:
#   {action=>'ok', usage=>$parsed} | {action=>'unavailable', status=>N}
#   {action=>'pause-creds'} | {action=>'pause-contract', problems=>[...]}
sub fetch_usage {
    my ($args) = @_;
    my $get = $args->{http_get} || \&_real_http_get;
    my $log = $args->{log_path};
    my $quiet_creds = $args->{quiet_creds_error} // 0;
    my $data = _read_json($args->{creds_path});
    unless ($data) {
        _log($log, 'creds_error', { detail => 'unreadable or invalid JSON' }) unless $quiet_creds;
        return { action => 'pause-creds' };
    }
    my ($cok, $cprob) = BpContract::validate_creds($data);
    unless ($cok) { _log($log, 'creds_drift', { problems => $cprob }); return { action => 'pause-contract', problems => $cprob }; }
    my $tok = $data->{claudeAiOauth}{accessToken};
    my $res = $get->($USAGE_URL, {
        'Authorization'  => "Bearer $tok",
        'anthropic-beta' => 'oauth-2025-04-20',
        'User-Agent'     => $USER_AGENT,
        'Accept'         => 'application/json',
    });
    my $status = $res->{status} // 0;
    if ($status == 200) {
        my $parsed = eval { JSON::PP->new->decode($res->{content} // '') };
        my ($ok, $probs) = $parsed ? BpContract::validate_usage($parsed) : (0, ['usage: response not JSON']);
        unless ($ok) { _log($log, 'usage_drift', { problems => $probs }); return { action => 'pause-contract', problems => $probs }; }
        _log($log, 'usage_poll', {
            result => 200,
            five   => $parsed->{five_hour}{utilization},
            seven  => $parsed->{seven_day}{utilization},
        });
        return { action => 'ok', usage => $parsed };
    }
    # non-200 (incl. 429 = unauth/abuse per A0) -> telemetry unavailable.
    _log($log, 'usage_poll', { result => $status, detail => 'telemetry unavailable' });
    return { action => 'unavailable', status => $status };
}

sub _log { my ($p, $t, $f) = @_; return unless defined $p; BpLog::event($p, $t, $f); }

# b02: the project checkout a blueprint dir belongs to, or undef.
# <project>/.ccpraxis-local-data/blueprints/<bp> -> <project>. Used as the
# checkpoint root hint so a commit target never depends on the inherited cwd.
sub _project_root_of {
    my ($bpdir) = @_;
    return undef unless defined $bpdir && !ref $bpdir && length $bpdir;
    my $d = abs_path($bpdir) // $bpdir;
    my %seen;
    while (length $d && !$seen{$d}++) {
        return $d if -d "$d/.ccpraxis-local-data";
        my $parent = dirname($d);
        last if $parent eq $d;                     # filesystem / drive root
        $d = $parent;
    }
    return undef;
}

# b02: a log `detail` is one trimmed line of at most 200 chars — git output and
# $@ are both multi-line, and the log is one JSON record per line.
sub _oneline {
    my ($txt) = @_;
    return undef unless defined $txt && !ref $txt;
    my ($line) = grep { /\S/ } split /\n/, $txt;
    return undef unless defined $line;
    $line =~ s/\A\s+//; $line =~ s/\s+\z//;
    return length($line) > 200 ? substr($line, 0, 200) : $line;
}

# ===========================================================================
# THE LOOP
# ===========================================================================

# Base = env/defaults (unchanged). Then, when a runs dir (or an explicit file) is
# given, overlay the WHITELISTED keys from runs/.tunables so a live run can be
# retuned without a restart. Unparseable / non-object / out-of-range values are
# ignored silently — the overlay can never crash or wedge a tick (§2.6).
# Back-compatible with the zero-arg call: _tunables() reads no file at all.
sub _tunables {
    my ($runs, $file) = @_;
    my $t = _tunables_base();
    my $path = defined $file ? $file : (defined $runs ? "$runs/.tunables" : undef);
    return $t unless defined $path;
    my $ov = _read_json($path);                  # undef on missing/unparseable; never dies
    return $t unless ref $ov eq 'HASH';
    for my $k (qw(max_par default_max_turns)) {  # the whitelist IS the contract (§10)
        my $v = $ov->{$k};
        next unless defined $v && !ref $v && $v =~ /^\d+$/ && $v > 0;
        $t->{$k} = $v + 0;
    }
    return $t;
}

sub _tunables_base {
    return {
        ceil5      => $ENV{BP_CEIL_5H}            // 85,
        ceil7      => $ENV{BP_CEIL_7D}            // 90,
        drain      => $ENV{BP_DRAIN_SECS}         // 600,
        max_par    => $ENV{BP_MAX_PARALLEL}       // 2,
        cap        => $ENV{BP_ATTEMPT_CAP}        // 5,
        flat       => $ENV{BP_FLAT_SECS}          // 600,
        watch_tick => $ENV{BP_WATCH_TICK}         // 10,
        keeper_int => $ENV{BP_KEEPER_INTERVAL}    // 600,
        keeper_bo  => $ENV{BP_KEEPER_BACKOFF}     // 120,
        thresh_min => $ENV{BP_RESUME_THRESHOLD_MIN} // 60,
        jit_lo     => $ENV{BP_RESUME_JITTER_MIN_SECS} // 300,
        jit_hi     => $ENV{BP_RESUME_JITTER_MAX_SECS} // 900,
        tele_retry => $ENV{BP_TELEMETRY_RETRIES}  // 3,
        usage_fail => $ENV{BP_USAGE_RETRY_SECS}   // 60,
        busy_path  => $ENV{BP_BUSY_PATH}          // '/tmp/.butler-busy',
        harvest    => $ENV{BP_HARVEST_MODE}       // 'audit',  # A5 #15: audit | gate
        resolve_cap=> $ENV{BP_RESOLVE_CAP}        // 1,        # A5 #13: resolve-judge tries/pkg
        corr_cap   => $ENV{BP_CORRECTIVE_CAP}     // 1,        # A5 Q2: corrective relaunches/pkg
        judge_to   => $ENV{BP_JUDGE_TIMEOUT_SECS} // 1800,     # A5: crashed/hung-judge fail-safe
        judge_spawn_cap => $ENV{BP_JUDGE_SPAWN_CAP} // 3,      # A5 H2: park after N harvest-spawn failures
        harvest_reaudit_cap => $ENV{BP_HARVEST_REAUDIT_CAP} // 2,  # #30: re-audit (not reopen) a done pkg whose harvest didn't complete, up to N times
        conformance_spawn_cap => $ENV{BP_CONFORMANCE_SPAWN_CAP} // 2, # b05: whole-blueprint conformance gate firings per run
        default_max_turns   => $ENV{BP_DEFAULT_MAX_TURNS}   // 80, # b01: turn budget when the ledger states none
        broken_env_thresh   => $ENV{BP_BROKEN_ENV_THRESH}   // 3,  # b01: consecutive exec-not-found launches -> broken-env
        turn_starved_thresh => $ENV{BP_TURN_STARVED_THRESH} // 3,  # b01: consecutive fruitless turn exhaustions -> turn-starved
        ckpt_int            => $ENV{BP_CHECKPOINT_INTERVAL} // 300, # b02: seconds between periodic WIP checkpoints
        creds_bo_base => $ENV{BP_CREDS_BACKOFF_BASE_SECS} // 60,   # b03: 1st creds re-poll delay
        creds_bo_mult => $ENV{BP_CREDS_BACKOFF_MULT}      // 2,    # b03: geometric factor
        creds_bo_max  => $ENV{BP_CREDS_BACKOFF_MAX_SECS}  // 1800, # b03: ceiling
        remediation_rounds => $ENV{BP_REMEDIATION_ROUNDS} // 2,    # b07: per-finding round budget (Decision #21)
        remediation_cap    => $ENV{BP_REMEDIATION_CAP}    // 6,    # b07: global rounds opened per run (SYN-7)
    };
}

# Build { pkg => {deps, write_set} } and { pkg => status } from disk.
sub _load_state {
    my ($bpdir, $runs) = @_;
    my $dag = parse_dag(_read_file("$bpdir/blueprint.md"));
    my $reg = read_registry($runs);
    my (%meta, %status, %att, %pid, %sid);
    for my $pkg (keys %$dag) {
        $status{$pkg} = ledger_fm($bpdir, $pkg, 'status') // ($reg->{$pkg}{status} // 'pending');
        $meta{$pkg}   = { deps => $dag->{$pkg}, write_set => (ledger_fm($bpdir, $pkg, 'write_set') // '') };
        $att{$pkg}    = $reg->{$pkg}{attempt} // 0;
        $pid{$pkg}    = $reg->{$pkg}{pid};
        $sid{$pkg}    = $reg->{$pkg}{session_id};
    }
    return (\%meta, \%status, \%att, \%pid, \%sid);
}

sub run {
    my ($opt) = @_;
    $opt ||= {};
    my $bp    = $opt->{blueprint} or die "run: blueprint required";
    my $bpdir = $opt->{bp_dir}    or die "run: bp_dir required";
    my $runs  = "$bpdir/runs";
    require File::Path; File::Path::make_path($runs) unless -d $runs;
    my $log   = "$runs/orchestrator.log";
    my $creds = $opt->{creds_path} // (($ENV{HOME} // '') . '/.claude/.credentials.json');
    # An INJECTED tunables hash wins entirely: runs/.tunables is then never read,
    # and the injected literal is frozen for the whole run (§2.6).
    my $t     = $opt->{tunables} || _tunables($runs, $opt->{tunables_file});
    my $now_fn   = $opt->{now}      || sub { time };
    my $sleep_fn = $opt->{sleep}    || sub { select(undef, undef, undef, $_[0]) };
    my $http_get  = $opt->{http_get};
    my $http_post = $opt->{http_post};

    # launch seam: default = bp-launch.sh; tests inject a recorder.
    $LAST_EXEC_ERROR = undef;      # only the DEFAULT closure below ever sets it
    my $launch = $opt->{launch} || sub {
        my ($a) = @_;
        # The likeliest broken environment is a missing/unmounted/unreadable
        # bp-launch.sh — and that does NOT give system() == -1: bash execs fine
        # and exits 127. Probe the script first so the plugin-dir-not-mounted
        # case reaches the broken-env trip instead of thrashing forever.
        unless (-r "$DIR/bp-launch.sh") {
            $LAST_EXEC_ERROR = "bp-launch.sh not found/readable at $DIR";
            return -1;
        }
        my @cmd = ('bash', "$DIR/bp-launch.sh", $bp, $a->{pkg}, @{ $a->{args} || [] });
        my $rc = system(@cmd);
        # system() returns -1 when the child could not be EXEC'd at all (no bash,
        # no bp-launch.sh, bad mount). -1 >> 8 is 72057594037927935 in Perl, so the
        # sentinel MUST be returned before any shift — otherwise a broken run
        # environment is logged as a garbage rc and relaunched forever.
        if ($rc == -1) { $LAST_EXEC_ERROR = "$!"; return -1; }
        my $ec = $rc >> 8;
        # 127 = command not found, 126 = found but not executable. bp-launch.sh
        # itself never exits either, so these are the shell reporting that the
        # script could not be run at all — same class of failure as -1.
        if ($ec == 126 || $ec == 127) {
            $LAST_EXEC_ERROR = "bp-launch.sh could not be executed (shell exit $ec)";
            return -1;
        }
        $LAST_EXEC_ERROR = undef;
        return $rc == 0 ? 0 : ($ec || 1);
    };

    # judge seams (A5): spawn a detached judge (default = bp-judge.sh, which runs a
    # scoped `claude -p` that writes the verdict file); read a completed verdict.
    # Tests inject a recorder for spawn + seed verdict files for read.
    my $spawn_judge = $opt->{spawn_judge} || sub {
        my ($a) = @_;       # { kind, pkg }
        require File::Path; File::Path::make_path("$runs/$a->{kind}");
        my @cmd = ('bash', "$DIR/bp-judge.sh", $a->{kind}, $bp, $a->{pkg},
                   judge_verdict_path($runs, $a->{kind}, $a->{pkg}));
        my $rc = system(@cmd);
        return $rc == 0 ? 0 : ($rc >> 8 || 1);
    };
    my $read_verdict = $opt->{read_verdict} || sub { my ($k, $p) = @_; read_judge_verdict($runs, $k, $p) };
    # b05 build-runner seam: the conformance gate captures a real build/test signal
    # once per firing. Tests inject a mock; NO real build ever runs under `prove`.
    # Absent (no command configured) => the gate records build.ran=false and judges
    # conformance on the mandated-means evidence alone.
    my $build_runner = exists $opt->{build_runner} ? $opt->{build_runner}
                     : ($t->{conformance_build_cmd} ? sub {
                           my ($s) = @_;
                           my @cmd = @{ $s->{cmd} && @{ $s->{cmd} } ? $s->{cmd} : $t->{conformance_build_cmd} };
                           my $rc = system(@cmd);
                           return { ok => ($rc == 0 ? 1 : 0), exit => ($rc >> 8), stdout => '', stderr => '' };
                       } : undef);
    # pid-liveness seam: default = the real kill-0 check; the simulation harness (A6)
    # injects a scripted one so alive/progressing and alive/wedged coordinator paths
    # can be driven through the real loop (not just the dead-pid path).
    my $pid_alive = $opt->{pid_alive} || \&pid_alive;
    # checkpoint seam (b02): make one WIP commit of a live package's write set.
    # The repo root is resolved ONCE per run(), lazily — the first checkpoint is
    # at least one interval away, and a run that never checkpoints never pays for
    # it. $opt->{project_root} is the test seam; a wrong root degrades to
    # 'not-a-repo' (one logged failure per package per interval), never a fatal.
    #
    # The hint below $opt->{project_root} is DERIVED FROM $bpdir, not from cwd.
    # In production nothing sets project_root and bp-orchestrate.sh does not
    # export BP_PROJECT_ROOT, so resolve_root would otherwise fall through to
    # `git rev-parse --show-toplevel` run from whatever cwd this detached process
    # inherited — and this root is a COMMIT TARGET, not a read. $bpdir is
    # <project>/.ccpraxis-local-data/blueprints/<name> by construction, so
    # walking it up to the ancestor that holds .ccpraxis-local-data names the
    # right checkout deterministically. No such ancestor (a temp-dir fixture) =>
    # undef => the §2.3 chain is used exactly as before.
    my $ckpt_root;
    my $checkpoint = $opt->{checkpoint} || sub {
        my ($a) = @_;          # { pkg, write_set, status, step, now, trigger }
        $ckpt_root = BpCheckpoint::resolve_root($opt->{project_root} // _project_root_of($bpdir))
            unless defined $ckpt_root;
        return BpCheckpoint::checkpoint({ root => $ckpt_root, pkg => $a->{pkg},
            write_set => $a->{write_set}, status => $a->{status},
            step => $a->{step}, now => $a->{now} });
    };

    my $marker_fh = acquire_marker("$runs/.orchestrator");
    unless ($marker_fh) {
        my $other = read_marker_pid("$runs/.orchestrator");
        _log($log, 'orchestrator_refused', { detail => 'another orchestrator holds the marker', other_pid => $other });
        die "bp-orchestrator: another orchestrator is already running on $bp (pid " . ($other // '?') . ")\n";
    }
    _log($log, 'orchestrator_start', { blueprint => $bp, pid => $$, tunables => $t });

    my $STOP = 0;
    local $SIG{TERM} = sub { $STOP = 1 };
    local $SIG{INT}  = sub { $STOP = 1 };

    my %seen;            # pkg => {size,mtime} prior jsonl observation
    # b02 checkpoint bookkeeping: pkg => { at => epoch of the last observation,
    # snap => the launch_snapshot taken then }. LOOP-SCOPE on purpose, mirroring
    # %seen and b01's $exec_fail_streak: no registry schema, no per-tick writes,
    # and the durability given up is worth little (after a restart the periodic
    # floor simply re-seeds — bounded by one interval).
    my %ckpt;
    # pkg => 1 once its unusable write_set has been reported (see the CHECKPOINT
    # section): a package that can never be checkpointed says so once, not once
    # per interval for the life of the run.
    my %ckpt_warned;
    # judge in-flight + start-epoch state lives on disk (judge_inflight*), so nothing
    # to declare here — it survives an orchestrator restart (A5).
    my (@s5, @s7);       # usage utilization samples [[epoch,pct],...]
    my $next_usage  = 0; # poll immediately at launch (Decision #8: one probe)
    my $next_keeper = 0;
    my $tele_fail   = 0;
    # b03: ONE creds episode = one creds_error + one pause line, then silence
    # until the episode ends (creds_recovered) or the process restarts (§5.2).
    # LOOP-SCOPE lexical, mirroring %seen/%ckpt/$tele_fail/$exec_fail_streak:
    # no registry schema, no per-tick write (Decision #3).
    my %creds_gate = ( armed => 0, polls => 0 );
    # Called whenever a poller PROVES the creds file is readable (any action
    # other than 'pause-creds' implies a successful read). Logs creds_recovered
    # exactly once per armed episode, then resets the gate.
    my $creds_ok = sub {
        my ($now, $source) = @_;
        if ($creds_gate{armed}) {
            _log($log, 'creds_recovered', { at => $now, polls => $creds_gate{polls}, source => $source });
            # b03 redteam MAJOR-4: the pause-creds arm can have parked
            # $next_usage up to creds_bo_max (1800s) into the future (below,
            # the `$next_usage = $now + creds_backoff_secs(...)` assignment).
            # If the KEEPER is the poller that observes the recovery (a fast
            # keeper_int can win that race), nothing else re-arms the usage
            # cadence, so the usage poller stays parked with zero 5h/7d
            # utilization telemetry for the rest of the backoff window --
            # blinding usage_decision's ceil5/ceil7 guard. Un-park it here so
            # a poll happens promptly after ANY recovery. Harmless for a
            # usage-sourced recovery: the usage-poll block below overwrites
            # $next_usage again two lines later regardless. This does NOT
            # re-arm %creds_gate -- a recovery is not a creds failure.
            $next_usage = $now;
        }
        %creds_gate = ( armed => 0, polls => 0 );
    };
    # CONSECUTIVE exec-not-found launches, fleet-wide, across all three launch
    # sites. Loop-scope state, not registry (§5.1): the durable artifact of a trip
    # is .paused + the deduped needs-you file, which a restarted orchestrator
    # re-reads; a still-broken environment re-accumulates the streak in ~3
    # attempts. Persisting it would mean a registry write on every launch.
    my $exec_fail_streak = 0;
    my %exec_counted;                 # packages already counted THIS tick
    # One package can legitimately be attempted twice inside a single tick (a failed
    # watchdog relaunch leaves it out of @live, so the fresh-launch path picks it up
    # again). That is ONE package's launch failing, not two independent probes of the
    # environment, so it contributes to the fleet-level streak once per tick — AC-6's
    # "the streak reaches 3 from ONE -1 from each site". Any non-sentinel rc (a
    # success or an ordinary non-zero exit) proves exec works and clears everything.
    my $note_exec = sub {
        my ($pkg, $rc) = @_;
        if (defined $rc && $rc == -1) { $exec_fail_streak++ unless $exec_counted{$pkg}++; }
        else { $exec_fail_streak = 0; %exec_counted = (); }
    };

    my $err;
    eval {
        while (!$STOP) {
            my $now = $now_fn->();
            my $shutdown = -e "$runs/.shutdown" ? 1 : 0;
            %exec_counted = ();       # the exec-failure dedupe is per tick

            my ($meta, $status, $att, $pid, $sid) = _load_state($bpdir, $runs);

            # b07: per-tick DAG-append merge of runs/remediation-queue.json into
            # %meta/%status (spec-08 §3.1, D1) — no orchestrator restart is ever
            # needed for a new remediation package to be seen, and blueprint.md
            # itself is NEVER mutated. $rq is threaded through the rest of THIS
            # tick (incl. the conformance-gate ingestion sites below) so a
            # same-tick ledger-status resync (queued -> awaiting_verify, done by
            # BpRemediate::merge_queue) is visible to remediation_step without a
            # second disk read.
            my $rq = remediation_merge($bpdir, $runs, $meta, $status, $now);
            my $rem_outstanding = BpRemediate::remediation_outstanding($rq);

            # ---- TOKEN-KEEPER (runs even while paused, to keep the token alive) ----
            if ($now >= $next_keeper) {
                my $k = BpKeeper::keeper_tick({ creds_path => $creds, now_ms => $now * 1000, log_path => $log,
                                                 http_post => $http_post, quiet_creds_error => $creds_gate{armed} });
                my $act = $k->{action} // 'ok';
                $next_keeper = $now + ($act eq 'backoff' ? $t->{keeper_bo} : $t->{keeper_int});
                $creds_ok->($now, 'keeper') if $act ne 'pause-creds';
                if ($act eq 'pause-floor') {
                    _enter_pause_manual($runs, $log, 'token-floor',
                        { package => '_fleet', blueprint => $bp, kind => 'reauth',
                          question => 'OAuth token crossed the 1h floor unrefreshed — re-authenticate with /login.',
                          context => 'token-keeper hit the pause-floor', created_at => $now });
                } elsif ($act eq 'pause-auth') {
                    # LOUD divergence alert (hard requirement): a 4xx on the
                    # sandbox's OWN refresh is distinct from a routine expiry —
                    # it means the copied token was rejected / the host & sandbox
                    # grants diverged, the signal to revisit the copy-token
                    # architecture. Wording is deliberately DIFFERENT from the
                    # pause-floor re-login case so it stands out in the
                    # reporter/dashboard. The graceful pause underneath is
                    # unchanged (nothing collapses silently).
                    _enter_pause_manual($runs, $log, 'token-auth',
                        { package => '_fleet', blueprint => $bp, kind => 'reauth', alert => 1,
                          question => "!! ALERT: the sandbox's OWN OAuth refresh was REJECTED (4xx). "
                                    . "The copied token may be invalid OR the host/sandbox token grants have "
                                    . "DIVERGED -- REVISIT the copy-token architecture. This is NOT a routine "
                                    . "/login expiry.",
                          context => ($k->{detail} // 'the sandbox refresh returned a 4xx'), created_at => $now });
                } elsif ($act eq 'pause-contract' || $act eq 'pause-creds') {
                    my $is_creds = ($act eq 'pause-creds');
                    _enter_pause_manual($runs, $log, "keeper-$act",
                        { package => '_fleet', blueprint => $bp, kind => 'contract-drift',
                          question => 'Credential/refresh contract drift — inspect before resuming.',
                          context => JSON::PP->new->canonical->encode($k->{detail} // {}), created_at => $now },
                        ($is_creds ? { quiet_log => $creds_gate{armed} } : undef));
                    $creds_gate{armed} = 1 if $is_creds;
                }
            }

            my $paused = read_paused($runs);

            # ---- USAGE POLL (burn-rate-adaptive cadence) ----
            if ($now >= $next_usage) {
                my $u = fetch_usage({ creds_path => $creds, http_get => $http_get, log_path => $log,
                                       quiet_creds_error => $creds_gate{armed} });
                if (($u->{action} // '') eq 'ok') {
                    $creds_ok->($now, 'usage');
                    $tele_fail = 0;
                    push @s5, [ $now, $u->{usage}{five_hour}{utilization} ];
                    push @s7, [ $now, $u->{usage}{seven_day}{utilization} ];
                    @s5 = @s5[-5 .. -1] if @s5 > 5;
                    @s7 = @s7[-5 .. -1] if @s7 > 5;
                    my $d = usage_decision($u->{usage}, \@s5, \@s7, $t);
                    $next_usage = $now + ($d->{cadence} // 300);
                    if (($d->{action} // '') eq 'pause-usage') {
                        my $jit = choose_jitter($t->{jit_lo}, $t->{jit_hi});
                        my $pp = paused_payload($d->{resets_at}, $now, $jit, 'usage');
                        write_paused($runs, $pp);
                        _log($log, 'pause', { reason => 'usage', window => $d->{window}, resets_at => $pp->{resets_at}, relaunch_at => $pp->{relaunch_at}, util => $d->{util} });
                        $paused = $pp;
                    } elsif (($d->{action} // '') eq 'pause-contract') {
                        _enter_pause_manual($runs, $log, 'usage-contract',
                            { package => '_fleet', blueprint => $bp, kind => 'contract-drift',
                              question => 'Usage endpoint contract drift — inspect before resuming.',
                              context => join('; ', @{ $d->{problems} || [] }), created_at => $now });
                        $paused = read_paused($runs);
                    } elsif ($paused && ($paused->{reason} // '') eq 'telemetry') {
                        # telemetry recovered and we are below the trip -> auto-resume.
                        _log($log, 'auto_resume', { reason => 'telemetry-recovered' });
                        clear_pause($runs); $paused = undef;
                    }
                } elsif (($u->{action} // '') eq 'unavailable') {
                    $creds_ok->($now, 'usage');
                    $tele_fail++;
                    $next_usage = $now + $t->{usage_fail};
                    if ($tele_fail >= $t->{tele_retry} && !$paused) {
                        my $pp = { reason => 'telemetry', manual => 0, created_at => $now };  # no relaunch_at: cleared on recovery
                        write_paused($runs, $pp);
                        _log($log, 'pause', { reason => 'telemetry', detail => "no usage telemetry after $tele_fail tries (status $u->{status})" });
                        $paused = $pp;
                    }
                } else {
                    # pause-creds / pause-contract from fetch_usage
                    if ((($u->{action}) // '') eq 'pause-creds') {
                        # b03: creds unreadable — the SAME suppressible episode
                        # as the keeper's pause-creds (Decision #2: one class).
                        # Back the re-poll off through the pinned schedule
                        # instead of a flat $t->{usage_fail}.
                        $creds_gate{polls}++;
                        $next_usage = $now + creds_backoff_secs($creds_gate{polls}, $t);
                        _enter_pause_manual($runs, $log, ($u->{action} // 'usage-fail'),
                            { package => '_fleet', blueprint => $bp, kind => 'contract-drift',
                              question => 'Credentials/usage contract problem — inspect before resuming.',
                              context => join('; ', @{ $u->{problems} || [] }), created_at => $now },
                            { quiet_log => $creds_gate{armed} });
                        $creds_gate{armed} = 1;
                    } else {
                        # pause-contract: the creds file WAS readable, so this is
                        # not the creds episode — resets the gate (spec §5.5) and
                        # is never suppressed.
                        $creds_ok->($now, 'usage');
                        $next_usage = $now + $t->{usage_fail};
                        _enter_pause_manual($runs, $log, ($u->{action} // 'usage-fail'),
                            { package => '_fleet', blueprint => $bp, kind => 'contract-drift',
                              question => 'Credentials/usage contract problem — inspect before resuming.',
                              context => join('; ', @{ $u->{problems} || [] }), created_at => $now });
                    }
                    $paused = read_paused($runs);
                }
            }

            # ---- LIVE TUNABLES: re-read runs/.tunables every tick so max_par can
            # be changed on a running fleet. Skipped entirely when a tunables hash
            # was injected (tests/simulation) — injection wins (§2.6).
            $t = _tunables($runs, $opt->{tunables_file}) unless $opt->{tunables};
            # bp-launch.sh enforces its OWN cap from $BP_MAX_PARALLEL (default 2) and
            # exits 3 above it. Without exporting the live value, a raised max_par
            # gives extra orchestrator-side slots whose launches the shell then
            # refuses every tick. `local` is scoped to this tick, so the next
            # _tunables() re-read above still sees the operator's real environment.
            local $ENV{BP_MAX_PARALLEL} = $t->{max_par} // 2;

            # ---- PAUSE GATING: maybe auto-resume; never launch while paused ----
            my $resume_pending = ($paused && !$paused->{manual}) ? 1 : 0;
            if ($paused) {
                if (!$shutdown && resume_ready($paused, $now)) {
                    _log($log, 'auto_resume', { reason => $paused->{reason}, resets_at => $paused->{resets_at} });
                    clear_pause($runs);
                    $paused = undef; $resume_pending = 0;
                    # fall through into the watch/launch section: a cleared pause
                    # lets dead non-terminal packages be relaunched immediately.
                } else {
                    touch_busy($t->{busy_path}) if should_touch_busy({ resume_pending => $resume_pending, shutdown => $shutdown });
                    last if $opt->{once};
                    $sleep_fn->($t->{watch_tick});
                    next;
                }
            }

            # ---- JUDGES (A5): consume completed verdicts, then fire new ones ----
            my $mode = BpJudge::harvest_mode($t->{harvest});
            my $reg  = read_registry($runs);

            # (a) RESOLVE verdicts — a stuck package's resolve-judge has returned.
            for my $pkg (sort keys %$meta) {
                my $started = judge_inflight($runs, 'resolve', $pkg);
                next unless defined $started;
                my $v = $read_verdict->('resolve', $pkg);
                if (!defined $v) {
                    # Still running — UNLESS it has blown the timeout (crashed/hung judge):
                    # then fail-safe to a synthetic verdict so the package can't wedge forever.
                    # $started==0 means a garbled marker (lost epoch) — let it run to a real
                    # verdict rather than false-timeout it on the very next tick (C1).
                    next unless $started && ($now - $started) > $t->{judge_to};
                    _log($log, 'judge_timeout', { kind => 'resolve', package => $pkg });
                    $v = { _timeout => 1 };               # normalize_resolve -> park
                }
                # Clear markers BEFORE acting (deliberate; rejected the clear-after refactor):
                # a crash in the gap degrades safely — resolve_attempts was already counted at
                # fire, so on restart the package parks rather than relaunching atop a still-
                # alive detached coordinator. Clearing after would risk that double-launch.
                clear_judge_inflight($runs, 'resolve', $pkg);
                clear_judge_verdict($runs, 'resolve', $pkg);
                my $r = BpJudge::normalize_resolve($v);
                if ($r->{action} eq 'relaunch') {
                    # The judge applied an intent-clear fix on disk: give the package a
                    # FRESH coordinator-retry budget and let the launch section relaunch
                    # it (reset to pending + attempt 0; the corrected ledger is read cold).
                    _log($log, 'resolve_relaunch', { package => $pkg, reason => $r->{reason}, mutated => $r->{mutated_files} });
                    _set_ledger_status($bpdir, $pkg, 'pending');
                    update_registry_pkg($runs, $pkg, { attempt => 0, status => 'pending' });
                    $status->{$pkg} = 'pending'; $att->{$pkg} = 0; $pid->{$pkg} = undef;
                } else {
                    my $q = ($r->{needs_you} && $r->{needs_you}{question})
                          ? $r->{needs_you}{question}
                          : "Package '$pkg' is stuck and the resolve-judge could not fix it: $r->{reason}";
                    _log($log, 'resolve_park', { package => $pkg, reason => $r->{reason} });
                    _block_and_queue($bpdir, $runs, $log, $bp, $pkg, $r->{reason}, $now, $q,
                                     ($r->{needs_you} ? $r->{needs_you}{kind} : undef));
                    $status->{$pkg} = 'blocked';
                }
            }

            # (b) HARVEST verdicts — a finished package's audit/gate has returned.
            for my $pkg (sort keys %$meta) {
                my $started = judge_inflight($runs, 'harvest', $pkg);
                next unless defined $started;
                my $v = $read_verdict->('harvest', $pkg);
                if (!defined $v) {
                    next unless $started && ($now - $started) > $t->{judge_to};   # see C1 note above
                    _log($log, 'judge_timeout', { kind => 'harvest', package => $pkg });
                    # A harvest TIMEOUT (no verdict in the window) is NOT evidence the
                    # package's work is bad — only a fail VERDICT is. It means the audit
                    # didn't complete: commonly the orchestrator/host died mid-harvest, or
                    # the judge hung. RE-AUDIT a done package (re-fire the read-only audit)
                    # rather than reopening + re-running the whole coordinator over
                    # already-complete work (#30). Kill any still-alive judge first; bound
                    # the re-audits so a judge that never completes eventually escalates
                    # instead of looping forever.
                    my $st = $status->{$pkg} // 'pending';
                    my $ra = $reg->{$pkg}{harvest_reaudit} // 0;
                    if ($st eq 'done' && $ra < ($t->{harvest_reaudit_cap} // 0)) {
                        my $jpidf = "$runs/harvest/$pkg.pid";
                        if (-f $jpidf) {
                            my ($jp) = (_read_file($jpidf) // '') =~ /^(\d+)/;
                            kill_pid($jp) if defined $jp && pid_alive($jp);
                            unlink $jpidf;
                        }
                        clear_judge_inflight($runs, 'harvest', $pkg);
                        clear_judge_verdict($runs, 'harvest', $pkg);
                        update_registry_pkg($runs, $pkg, { harvest => '', harvest_reaudit => $ra + 1 });
                        $reg->{$pkg}{harvest} = ''; $reg->{$pkg}{harvest_reaudit} = $ra + 1;
                        _log($log, 'harvest_reaudit', { package => $pkg, attempt => $ra + 1,
                              reason => 'harvest did not complete (interrupted/hung) — re-auditing, not reopening' });
                        next;   # section (c) re-fires the harvest this tick
                    }
                    $v = { _timeout => 1 };               # cap exhausted (or not done) -> error -> escalate
                }
                # Clear before acting — harvest degrades even more safely (a lost verdict just
                # re-audits next tick, since status stays 'done' + harvest stays '').
                clear_judge_inflight($runs, 'harvest', $pkg);
                clear_judge_verdict($runs, 'harvest', $pkg);
                my $hv = BpJudge::normalize_harvest($v);
                if ($hv eq 'pass') {
                    update_registry_pkg($runs, $pkg, { harvest => 'pass', harvest_reaudit => 0 });
                    $reg->{$pkg}{harvest} = 'pass'; $reg->{$pkg}{harvest_reaudit} = 0;
                    _log($log, 'harvest_pass', { package => $pkg, mode => $mode });
                } else {
                    my $corr = $reg->{$pkg}{corrective_attempts} // 0;
                    my $ao = BpJudge::audit_outcome({ verdict => $hv, corrective_attempts => $corr, corrective_cap => $t->{corr_cap} });
                    if ($ao eq 'reopen') {
                        # Failed audit, budget remains: reopen NON-terminal with the audit's
                        # findings as corrective context (Q2). Dependents that already ran off
                        # the bad output are FLAGGED for re-verification, never auto-killed.
                        _log($log, 'harvest_reopen', { package => $pkg, verdict => $hv, corrective_attempts => $corr });
                        _apply_harvest_findings($bpdir, $pkg, $v);
                        _set_ledger_status($bpdir, $pkg, 'pending');
                        update_registry_pkg($runs, $pkg, { attempt => 0, status => 'pending', harvest => '', corrective_attempts => $corr + 1 });
                        $status->{$pkg} = 'pending'; $att->{$pkg} = 0; $pid->{$pkg} = undef;
                        $reg->{$pkg}{harvest} = '';   # mirror the disk clear in-memory (M2)
                        for my $dep (sort keys %$meta) {
                            next unless grep { $_ eq $pkg } @{ $meta->{$dep}{deps} || [] };
                            next unless ($reg->{$dep}{harvest} // '') eq 'pass';
                            update_registry_pkg($runs, $dep, { harvest => '' });
                            $reg->{$dep}{harvest} = '';
                            _log($log, 'harvest_flag_dependent', { package => $dep, reason => "depends on reopened $pkg" });
                        }
                    } else {  # park: failed twice -> alarm, keep independent work running.
                        _log($log, 'harvest_park', { package => $pkg, verdict => $hv, corrective_attempts => $corr });
                        _block_and_queue($bpdir, $runs, $log, $bp, $pkg,
                            "failed harvest audit ($hv) after a corrective cycle", $now,
                            "Package '$pkg' failed its harvest audit after a corrective relaunch — its outputs don't meet the done-criteria. Inspect and decide: fix, re-scope, or accept.",
                            'harvest-failure');
                        $status->{$pkg} = 'blocked';
                    }
                }
            }

            # (c) FIRE a harvest judge for each newly-finished package (once each).
            unless ($shutdown) {
                for my $pkg (sort keys %$meta) {
                    my $st   = $status->{$pkg} // 'pending';
                    my $h    = $reg->{$pkg}{harvest};
                    my $infl = defined(judge_inflight($runs, 'harvest', $pkg)) ? 1 : 0;
                    my $fire = ($mode eq 'gate')
                        ? BpJudge::want_harvest_gate({  mode => $mode, status => $st, harvest => $h, inflight => $infl })
                        : BpJudge::want_harvest_audit({ mode => $mode, status => $st, harvest => $h, inflight => $infl });
                    next unless $fire;
                    my $rc = $spawn_judge->({ kind => 'harvest', pkg => $pkg });
                    if (defined $rc && $rc == 0) {
                        mark_judge_inflight($runs, 'harvest', $pkg, $now);
                        update_registry_pkg($runs, $pkg, { harvest_spawn_fail => 0 }) if ($reg->{$pkg}{harvest_spawn_fail} // 0);
                        _log($log, 'harvest_fire', { package => $pkg, mode => $mode });
                    } else {
                        # Bound the retry: a persistently broken spawn (bad bp-judge.sh, no
                        # claude) must NOT re-fire every tick forever (gate mode would block
                        # dependents indefinitely). After a cap, park + alarm instead (H2).
                        my $sf = ($reg->{$pkg}{harvest_spawn_fail} // 0) + 1;
                        update_registry_pkg($runs, $pkg, { harvest_spawn_fail => $sf });
                        $reg->{$pkg}{harvest_spawn_fail} = $sf;
                        _log($log, 'judge_spawn_failed', { kind => 'harvest', package => $pkg, rc => $rc, fails => $sf });
                        if ($sf >= $t->{judge_spawn_cap}) {
                            _block_and_queue($bpdir, $runs, $log, $bp, $pkg,
                                "harvest judge could not be spawned ($sf attempts)", $now,
                                "Package '$pkg' finished but its harvest judge could not be spawned after $sf tries — check bp-judge.sh / claude in the sandbox, then re-verify and resume.",
                                'harvest-spawn-failure');
                            $status->{$pkg} = 'blocked';
                        }
                    }
                }
            }

            # ---- WATCH + WATCHDOG (assess each non-terminal launched package) ----
            my @live;     # packages occupying a coordinator slot now
            my %starved;  # packages parked as turn-starved THIS tick: the pause
                          # gate stops launches from tick N+1, so hold them out of
                          # this tick's launchable set too (§3 B8.4 "do not relaunch").
            for my $pkg (sort keys %$meta) {
                next if _is_terminal($status->{$pkg});
                next if defined judge_inflight($runs, 'resolve', $pkg);   # a resolve-judge is editing its ledger; hands off (A5)
                # A never-launched package (status pending, attempt 0, no pid) is the
                # LAUNCH section's job, not the watchdog's — skip it here so it isn't
                # mistaken for a dead coordinator. A crashed package whose ledger still
                # reads 'pending' but has attempt>0 / a recorded pid IS the watchdog's.
                my $launched = (($att->{$pkg} // 0) > 0)
                            || (defined $pid->{$pkg} && length $pid->{$pkg})
                            || (($status->{$pkg} // 'pending') ne 'pending');
                next unless $launched;
                my $alive = $pid_alive->($pid->{$pkg});
                if ($alive) {
                    my ($sz, $mt) = jsonl_stat($runs, $pkg);
                    my $prev = $seen{$pkg};
                    my $prog = progress_verdict($sz, $mt, ($prev ? $prev->{size} : undef), $now, $t->{flat});
                    $seen{$pkg} = { size => ($sz // 0), mtime => ($mt // $now) };
                    my $v = watchdog_verdict({ alive => 1, progress => $prog,
                        attempts => effective_attempts($att->{$pkg}, _reg_int($reg->{$pkg}{turn_continuations}) // 0),
                        cap => $t->{cap} });
                    if ($v eq 'none') {
                        push @live, $pkg;
                    } elsif ($v eq 'cold-relaunch') {
                        next if $shutdown;     # shutdown gate (A4) parks it; we don't relaunch
                        _log($log, 'watchdog_kill_wedged', { package => $pkg, pid => $pid->{$pkg}, attempts => $att->{$pkg} });
                        kill_pid($pid->{$pkg});
                        my $snap = launch_snapshot($bpdir, $runs, $pkg, $now);
                        my $rc = $launch->({ pkg => $pkg, args => [], kind => 'cold-wedged' });
                        $note_exec->($pkg, $rc);
                        if (defined $rc && $rc == 0) { _upd_pkg($runs, $log, $pkg, { launch_snapshot => $snap }); push @live, $pkg; }
                        else { _log($log, 'launch_failed', { package => $pkg, kind => 'cold-wedged', rc => $rc }); }
                    } elsif ($v eq 'block') {
                        _log($log, 'watchdog_block', { package => $pkg, reason => 'wedged past attempt cap', attempts => $att->{$pkg} });
                        kill_pid($pid->{$pkg});
                        $status->{$pkg} = _escalate_stuck({ bpdir=>$bpdir, runs=>$runs, log=>$log, bp=>$bp, pkg=>$pkg,
                            why=>'wedged past attempt cap (no log growth)', now=>$now, reg=>$reg, t=>$t,
                            spawn_judge=>$spawn_judge, shutdown=>$shutdown });
                    }
                } else {
                    next if $shutdown;          # don't relaunch during a graceful-shutdown-all
                    # A coordinator that exhausted its turn budget exits 1 exactly
                    # like a crash — only its TERMINAL jsonl event tells them apart.
                    # Classify first so a productive package is continued with a
                    # wider budget instead of burning the give-up cap (§3 B6-B9).
                    my $tv = terminal_verdict(_last_jsonl_obj($runs, $pkg));
                    if ($tv->{verdict} eq 'success' && (_reg_int($reg->{$pkg}{turn_exhaust_streak}) // 0)) {
                        _upd_pkg($runs, $log, $pkg, { turn_exhaust_streak => 0 });   # B9b
                        $reg->{$pkg}{turn_exhaust_streak} = 0;
                    }
                    my $v = watchdog_verdict({ alive => 0,
                        attempts => effective_attempts($att->{$pkg}, _reg_int($reg->{$pkg}{turn_continuations}) // 0),
                        cap => $t->{cap} });
                    if ($v eq 'relaunch') {
                        if (@live < $t->{max_par}) {
                            # Continuation bookkeeping is COMPUTED here (the widened
                            # budget has to be known before @args is built) but only
                            # PERSISTED after a successful launch — a relaunch that
                            # never execs must not burn a continuation, inflate the
                            # exhaust streak, or leave the stale snapshot behind.
                            # Without this the counter ratchets on every tick while
                            # the frozen snapshot keeps reading "progressed", so
                            # effective_attempts is pinned and the give-up cap can
                            # never be reached (§3 B7/B8).
                            my %pending_reg;
                            my $reg_rollback;      # in-memory max_turns to restore on failure
                            # Turn-exhaustion fork (only with a free slot: a deferred
                            # relaunch must not widen or count a continuation).
                            if ($tv->{verdict} eq 'max_turns') {
                                my $initial = initial_max_turns($bpdir, $pkg, $t);
                                my $current = _reg_int($reg->{$pkg}{max_turns}) // $initial;
                                my $prog = snapshot_progressed($reg->{$pkg}{launch_snapshot},
                                                               launch_snapshot($bpdir, $runs, $pkg, $now));
                                if ($prog) {
                                    # B7 — productive: widen the budget, continue, and
                                    # count the continuation so effective_attempts is
                                    # unchanged (the give-up cap is NOT consumed).
                                    my $next = widen_max_turns($current, $initial);
                                    my $tc   = (_reg_int($reg->{$pkg}{turn_continuations}) // 0) + 1;
                                    %pending_reg = (max_turns => $next, turn_continuations => $tc,
                                                    turn_exhaust_streak => 0);
                                    $reg_rollback = $current;
                                    # the widened budget must ride @args below, so the
                                    # in-memory mirror is set now and rolled back if the
                                    # launch never happens.
                                    $reg->{$pkg}{max_turns} = $next;
                                    _log($log, 'turn_continuation', { package => $pkg, num_turns => $tv->{num_turns},
                                        from => $current, to => $next, attempts => $att->{$pkg} });
                                } else {
                                    # B8 — fruitless: no widening, the attempt burns the
                                    # cap, and a run of them means a wider budget is not
                                    # the answer — park for a human instead of thrashing.
                                    my $streak = (_reg_int($reg->{$pkg}{turn_exhaust_streak}) // 0) + 1;
                                    $pending_reg{turn_exhaust_streak} = $streak;
                                    _log($log, 'turn_exhausted_no_progress', { package => $pkg, streak => $streak,
                                        num_turns => $tv->{num_turns}, attempts => $att->{$pkg} });
                                    if ($streak >= ($t->{turn_starved_thresh} // 3)) {
                                        # This arm legitimately never launches, so the
                                        # streak is persisted inline instead.
                                        _upd_pkg($runs, $log, $pkg, { turn_exhaust_streak => $streak });
                                        $reg->{$pkg}{turn_exhaust_streak} = $streak;
                                        $starved{$pkg} = 1;
                                        _enter_pause_manual($runs, $log,
                                            "turn-starved: $pkg exhausted turns ${streak}x with no progress",
                                            { package => $pkg, blueprint => $bp, kind => 'turn-starved',
                                              question => "Package '$pkg' hit its turn budget $streak times in a row with no ledger progress. "
                                                        . 'Widening the budget is not helping — re-scope the package, split it, or give it guidance, then resume '
                                                        . 'by deleting runs/.paused (`rm runs/.paused`) — this pause is manual and will not lift on its own.',
                                              context  => "$streak consecutive turn exhaustions with no progress; attempts="
                                                        . ($att->{$pkg} // 0)
                                                        . ', turn_continuations=' . (_reg_int($reg->{$pkg}{turn_continuations}) // 0)
                                                        . ", max_turns=$current, last num_turns=" . ($tv->{num_turns} // '?'),
                                              created_at => $now });
                                        next;                     # do NOT relaunch it
                                    }
                                }
                            }
                            my $age = ledger_age_min($bpdir, $pkg, $now);
                            my $mode = resume_mode($age, $sid->{$pkg}, $t->{thresh_min});
                            my @args = ($mode eq 'warm') ? ('--resume-session', $sid->{$pkg}) : ();
                            # The widened budget rides on the relaunch. Only ever set
                            # after a continuation, so an ordinary run's @cmd is
                            # byte-identical to today (bp-launch.sh keeps its own
                            # ledger fallback when no --max-turns is passed).
                            my $budget = _reg_int($reg->{$pkg}{max_turns});
                            push @args, '--max-turns', $budget if defined $budget;
                            _log($log, 'watchdog_relaunch', { package => $pkg, mode => $mode, age_min => $age, attempts => $att->{$pkg} });
                            my $snap = launch_snapshot($bpdir, $runs, $pkg, $now);
                            my $rc = $launch->({ pkg => $pkg, args => \@args, kind => $mode });
                            $note_exec->($pkg, $rc);
                            if (defined $rc && $rc == 0) {
                                _upd_pkg($runs, $log, $pkg, { %pending_reg, launch_snapshot => $snap });
                                $reg->{$pkg}{$_} = $pending_reg{$_} for keys %pending_reg;
                                push @live, $pkg;
                            } else {
                                # nothing was exec'd: roll the widened budget back so the
                                # next tick recomputes from the persisted value.
                                $reg->{$pkg}{max_turns} = $reg_rollback if defined $reg_rollback;
                                _log($log, 'launch_failed', { package => $pkg, kind => $mode, rc => $rc });
                            }
                        } else {
                            _log($log, 'relaunch_deferred', { package => $pkg, reason => 'parallel cap full' });
                        }
                    } elsif ($v eq 'block') {
                        _log($log, 'watchdog_block', { package => $pkg, reason => 'serial failer past attempt cap', attempts => $att->{$pkg} });
                        $status->{$pkg} = _escalate_stuck({ bpdir=>$bpdir, runs=>$runs, log=>$log, bp=>$bp, pkg=>$pkg,
                            why=>'serial failer past attempt cap (dead coordinator)', now=>$now, reg=>$reg, t=>$t,
                            spawn_judge=>$spawn_judge, shutdown=>$shutdown });
                    }
                }
            }

            # ---- CHECKPOINT: durable WIP commits (b02, Decisions #2/#17) ----
            # Placed here on purpose: @live is complete and authoritative, and a
            # package the LAUNCH section starts below is not in it yet — so a
            # just-launched coordinator is never checkpointed on its launch tick.
            #
            # Two triggers per live package (a periodic floor and a meaningful
            # ledger advance) funnel into exactly ONE $checkpoint->() call site
            # behind one `next unless`, so both firing together is still one
            # commit. Nothing in this section may end the tick: every outcome is
            # caught, and the loop falls through to LAUNCH.
            for my $pkg (sort @live) {
                # Liveness = THIS package's own coordinator is alive right now,
                # which is narrower than @live: the watchdog also pushes packages
                # it relaunched this very tick, and those have no in-flight work
                # of their own to capture yet. $pid was read at the top of the
                # tick, so a package the launch seam just registered isn't in it.
                my $cpid = $pid->{$pkg};
                next unless defined $cpid && length $cpid && $pid_alive->($cpid);

                # FRESH snapshot — never the registry's launch_snapshot, which is
                # a *launch* baseline and would read "advanced" on every tick
                # after the first advance.
                my $cur = launch_snapshot($bpdir, $runs, $pkg, $now);
                my $prev = $ckpt{$pkg};
                # First observation SEEDS and does not commit: no commit storm
                # across N packages when the orchestrator starts.
                unless ($prev) { $ckpt{$pkg} = { at => $now, snap => $cur }; next }

                my $due = ($now - ($prev->{at} // $now)) >= ($t->{ckpt_int} // 300) ? 1 : 0;
                my $adv = checkpoint_advanced($prev->{snap}, $cur) ? 1 : 0;
                next unless $due || $adv;
                my $trigger = ($due && $adv) ? 'both' : $adv ? 'ledger' : 'periodic';
                # Bookkeeping advances on EVERY outcome (committed, clean, error)
                # and BEFORE the attempt, so a permanently broken repo costs at
                # most one attempt + one log line per package per interval.
                $ckpt{$pkg} = { at => $now, snap => $cur };

                my $st_str = $status->{$pkg} // '';
                my $res = eval { $checkpoint->({ pkg => $pkg, trigger => $trigger,
                    write_set => ($meta->{$pkg}{write_set} // ''), status => $st_str,
                    step => $cur->{checkboxes}, now => $now }) };
                my $ex = $@;
                # Both _log calls are eval-wrapped (mirroring :629-634): BpLog::event
                # DIES on an unwritable runs/, and logging a checkpoint failure must
                # never become the fatal error.
                if ($ex || ref $res ne 'HASH') {
                    my $detail = $ex ? _oneline("$ex")
                               : 'checkpoint returned ' . (defined $res ? (ref($res) || 'a non-hashref') : 'undef');
                    eval { _log($log, 'checkpoint_failed', { package => $pkg, trigger => $trigger,
                        reason => 'exception', detail => $detail }); 1 } or 1;
                } elsif (!$res->{ok}) {
                    eval { _log($log, 'checkpoint_failed', { package => $pkg, trigger => $trigger,
                        reason => ($res->{reason} // 'error'), detail => _oneline($res->{detail}) }); 1 } or 1;
                } elsif ($res->{committed}) {
                    eval { _log($log, 'checkpoint', { package => $pkg, trigger => $trigger,
                        sha => $res->{sha}, status => $st_str, step => $cur->{checkboxes},
                        message => $res->{message} }); 1 } or 1;
                } elsif (($res->{reason} // '') eq 'no-safe-pathspec' && !$ckpt_warned{$pkg}++) {
                    # The ONE clean outcome that is not a healthy no-op: every
                    # write_set entry was rejected as unsafe, so this package can
                    # NEVER be checkpointed. Silence would make a misconfigured
                    # ledger indistinguishable from a clean tree, and write-set-only
                    # staging is this package's core safety property. Logged once
                    # per package per run, so it cannot spam a long fleet.
                    eval { _log($log, 'checkpoint_failed', { package => $pkg, trigger => $trigger,
                        reason => 'no-safe-pathspec', detail => _oneline($res->{detail}) }); 1 } or 1;
                }
                # every other 'clean' outcome logs NOTHING: a no-op is not an
                # event, and it would otherwise spam the log every interval.
            }

            # ---- LAUNCH newly-ready packages into free slots (event-driven) ----
            unless ($shutdown) {
                my $slots = cap_slots(scalar @live, $t->{max_par});
                if ($slots > 0) {
                    # Harvest gate (#15): in gate mode a 'done' package whose harvest
                    # verdict isn't 'pass' is demoted to 'harvesting' so it does NOT yet
                    # satisfy its dependents (audit mode is an identity passthrough).
                    my %harvest = map { $_ => ($reg->{$_}{harvest}) } keys %$meta;
                    my $launch_status = BpJudge::effective_status($mode, $status, \%harvest);
                    # Hold any package whose resolve-judge is mid-flight out of the
                    # launchable set (its ledger is being edited — don't race it).
                    $launch_status->{$_} = 'resolving' for grep { defined judge_inflight($runs, 'resolve', $_) } keys %$launch_status;
                    # A package parked as turn-starved this tick must not be picked
                    # straight back up by the fresh-launch path (its pause only gates
                    # ticks N+1...).
                    $launch_status->{$_} = 'turn-starved' for keys %starved;
                    my @ready = ready_packages($meta, $launch_status, \@live);
                    my @batch = pick_launch_batch(\@ready, $meta, [ map { $meta->{$_}{write_set} } @live ], $slots);
                    for my $pkg (@batch) {
                        my $snap = launch_snapshot($bpdir, $runs, $pkg, $now);
                        my $rc = $launch->({ pkg => $pkg, args => [], kind => 'fresh' });
                        $note_exec->($pkg, $rc);
                        if (defined $rc && $rc == 0) {
                            _upd_pkg($runs, $log, $pkg, { launch_snapshot => $snap });
                            _log($log, 'launch', { package => $pkg, kind => 'fresh' });
                            push @live, $pkg;
                        } else {
                            _log($log, 'launch_failed', { package => $pkg, kind => 'fresh', rc => $rc });
                        }
                    }
                }
            }

            # ---- BROKEN-ENV TRIP (fleet-level; once per tick, after every launch
            # site has had its say). N consecutive exec-not-found launches means
            # nothing this loop does can succeed — bash, bp-launch.sh or the mount
            # is gone. Stop the thrash with a MANUAL pause (no auto-resume) and one
            # deduped decision for the human, then reset the streak.
            if ($exec_fail_streak >= ($t->{broken_env_thresh} // 3)) {
                my $n = $exec_fail_streak;
                my $errno = (defined $LAST_EXEC_ERROR && length "$LAST_EXEC_ERROR")
                          ? "$LAST_EXEC_ERROR" : 'exec failed (errno unavailable)';
                _enter_pause_manual($runs, $log, 'broken-env: launcher could not be executed',
                    { package => '_fleet', blueprint => $bp, kind => 'broken-env',
                      question => "The launcher could not be executed $n times in a row — the run environment is broken "
                                . '(missing bash, missing bp-launch.sh, or a bad mount). Fix it, then resume the run '
                                . 'by deleting runs/.paused (`rm runs/.paused`) — this pause is manual and will not lift on its own.',
                      context  => "exec of 'bash $DIR/bp-launch.sh' failed on $n consecutive launch attempts; last errno: $errno",
                      created_at => $now });
                $exec_fail_streak = 0;
            }

            # ---- RECONCILE ORPHANED ESCALATIONS ----
            # A coordinator can end a package blocked/parked in its OWN ledger
            # (gate-stop.sh permits a terminal stop) without the orchestrator's
            # escalation path ever running — so no needs-you decision is filed and
            # the reporter's watcher stays silent. Enforce the invariant "every
            # awaiting-human package has a decision the human can act on" so the run
            # never goes quiet. Skip during a graceful shutdown: those parks are
            # expected and the human already asked for the stop.
            unless ($shutdown) {
                my $queued = queued_decision_pkgs($runs);
                for my $pkg (orphan_escalations($meta, $status, $queued)) {
                    my $st = $status->{$pkg} // '';
                    my $next = ledger_next_action($bpdir, $pkg);
                    _log($log, 'orphan_escalation', { package => $pkg, status => $st,
                        detail => 'awaiting-human with no queued decision (coordinator self-park) — escalating' });
                    queue_needs_you($runs, {
                        package => $pkg, blueprint => $bp, kind => 'stuck-package',
                        question => "Package '$pkg' was set to '$st' by its coordinator with no decision filed for you. "
                                  . "Read its '## Next action' (it may address an instruction to the orchestrator, e.g. a write_set change), then relaunch with guidance / accept / drop.",
                        context  => ($next // "orphaned '$st' status — no needs-you decision existed; filed by the orchestrator so the run doesn't go silent"),
                        created_at => $now,
                    });
                }
            }

            # ---- BUSY-LEASE + IDLE-EXIT ----
            my $any_running = (scalar @live) > 0 ? 1 : 0;
            # A detached judge in flight is active work the run must wait for (C2): in
            # AUDIT mode a finished package is terminal, so without this the loop could
            # idle-exit while a harvest audit is still running and silently drop its
            # verdict (including a fail that should have reopened the package).
            my $judges_inflight = (grep { defined judge_inflight($runs, 'harvest', $_)
                                       || defined judge_inflight($runs, 'resolve', $_) } keys %$meta) ? 1 : 0;
            my $outstanding = has_progressable_work($meta, $status) || $judges_inflight;
            # Awaiting-human work (blocked/parked) keeps the loop ALIVE but is NOT
            # part of the busy-lease signal (the machine may sleep while we wait on
            # the human). It IS part of the idle-exit gate (below): exiting would
            # strand the run on a dead orchestrator when the human answers.
            my $awaiting_human = (grep { _awaits_human($status->{$_}) } keys %$meta) ? 1 : 0;
            touch_busy($t->{busy_path}) if should_touch_busy({
                any_running => $any_running, outstanding => $outstanding,
                resume_pending => $resume_pending, shutdown => $shutdown,
            });

            if ($shutdown && !$any_running) {
                _log($log, 'shutdown_complete', { detail => 'graceful-shutdown-all: no coordinators left' });
                last;
            }
            # ---- b05 CONFORMANCE GATE ----
            # Fires when the run would otherwise be idle-complete. An in-flight
            # conformance judge counts as outstanding (mirroring $judges_inflight at
            # :1808-1810) so the loop stays alive to READ the verdict — exiting at fire
            # time would strand it unread and no finding could ever reach remediation.
            my $conf_outstanding = 0;
            # NB: deliberately NOT gated on $outstanding — that includes
            # $judges_inflight, and a per-package harvest audit fires for the very same
            # finished packages on this tick, which would starve the gate forever.
            # BpJudge::conformance_ready already requires every package terminal and
            # none awaiting a human, which is the real precondition.
            #
            # b07: verify_ready($rq) is the additional conjunct (spec-08 §3.4) — 0
            # while any remediation entry is still `queued` (authored but not yet
            # finished), so the gate never re-verifies against a half-remediated
            # world.
            if (!$any_running && !$resume_pending && !$paused && BpRemediate::verify_ready($rq)) {
                my $cpkgs = conformance_registry($bpdir, $meta, $status);
                my $ready = BpJudge::conformance_ready($cpkgs);
                my $cinfl = defined judge_inflight($runs, 'conformance', '_run') ? 1 : 0;
                my $cvpre = -e conformance_verdict_path($runs) ? 1 : 0;
                if ($cinfl) {
                    # judge running: ingest its verdict if it landed, else keep waiting
                    my $raw = $read_verdict->('conformance', '_run');
                    if (defined $raw) {
                        clear_judge_inflight($runs, 'conformance', '_run');
                        my $v = write_conformance_channels({ bpdir => $bpdir, runs => $runs,
                            raw => $raw, pkgs => $cpkgs, now => $now, blueprint => $bp,
                            build => $reg->{_run}{build} });
                        _log($log, 'conformance_verdict', { outcome => $v->{outcome},
                              findings => scalar @{ $v->{findings} } });
                        # b07: the :1862-equivalent (later-tick) verdict-ingestion
                        # site — hooking only ONE of the two sites silently skips
                        # remediation for whichever runs take the other path.
                        $rem_outstanding = remediation_step({ bpdir => $bpdir, runs => $runs, verdict => $v,
                            meta => $meta, status => $status, now => $now, blueprint => $bp, tunables => $t,
                            log => $log, queue => $rq });
                    } else {
                        # No verdict yet. Keep the loop alive and WAIT — the judge is a
                        # detached `claude -p` that legitimately takes minutes. Only once
                        # judge_to has elapsed is a missing verdict a real timeout, at
                        # which point we write the authoritative error verdict (spec
                        # §3.1.5; never a silent pass). This mirrors the harvest/resolve
                        # timeout pattern rather than declaring 'error' on tick one, which
                        # would leave runs/conformance-verdict.json reading outcome=error
                        # for the judge's entire real run time.
                        $conf_outstanding = 1;
                        my $started = judge_inflight($runs, 'conformance', '_run');
                        my $elapsed = (defined $started && $started =~ /^\d+$/) ? ($now - $started) : 0;
                        if (!$cvpre && $elapsed > ($t->{judge_to} // 1800)) {
                            clear_judge_inflight($runs, 'conformance', '_run');
                            my $v = write_conformance_channels({ bpdir => $bpdir, runs => $runs,
                                raw => undef, pkgs => $cpkgs, now => $now, blueprint => $bp,
                                build => $reg->{_run}{build} });
                            _log($log, 'conformance_timeout', { outcome => $v->{outcome},
                                  elapsed => $elapsed });
                            $conf_outstanding = 0;
                        }
                    }
                } elsif (!$ready->{ready}) {
                    if (!$cvpre && ($ready->{reason} // '') eq 'awaiting_human') {
                        my $nt = BpJudge::notice_record('conformance gate skipped',
                            'every package is terminal but some await a human, so the run never actually finished; not judging it',
                            { generated_at => _iso($now), severity => 'warn',
                              evidence => { awaiting => $ready->{awaiting} } });
                        _write_json_atomic("$runs/notices/" . (defined $now ? $now : 0) . "-conformance-gate-skipped.json", $nt);
                        _log($log, 'conformance_skipped', { reason => $ready->{reason} });
                    }
                } elsif (!$cvpre) {
                    my $spawns = $reg->{_run}{conformance_spawns} // 0;
                    if (BpJudge::conformance_should_spawn({ inflight => 0, verdict_present => 0,
                            spawns => $spawns, cap => ($t->{conformance_spawn_cap} // 0) })) {
                        require File::Path; File::Path::make_path("$runs/conformance");
                        my $b = $build_runner ? $build_runner->({ cwd => $bpdir, cmd => [] }) : undef;
                        my $build = (ref $b eq 'HASH')
                            ? { ran => JSON::PP::true, ok => ($b->{ok} ? JSON::PP::true : JSON::PP::false),
                                exit => $b->{exit}, stderr => ($b->{stderr} // '') }
                            : { ran => JSON::PP::false };
                        update_registry_pkg($runs, '_run', { conformance_spawns => $spawns + 1 });
                        $reg->{_run}{conformance_spawns} = $spawns + 1;
                        $reg->{_run}{build} = $build;
                        my $rc = $spawn_judge->({ kind => 'conformance', pkg => '_run' });
                        if (defined $rc && $rc == 0) {
                            mark_judge_inflight($runs, 'conformance', '_run', $now);
                            _log($log, 'conformance_fire', { packages => scalar keys %$cpkgs });
                            # An unparseable mandated_means is a property of the LEDGERS,
                            # not of the verdict, so notice it as soon as the gate fires —
                            # it must not wait on (or depend on) a judge verdict arriving.
                            for my $pkg (sort keys %$cpkgs) {
                                next if $cpkgs->{$pkg}{means_ok};
                                my $nt = BpJudge::notice_record('unparseable mandated_means',
                                    "package $pkg has a mandated_means value this reader cannot interpret; treated as an empty list",
                                    { generated_at => _iso($now), severity => 'warn',
                                      evidence => { package => $pkg, shape => $cpkgs->{$pkg}{means_shape} } });
                                _write_json_atomic("$runs/notices/" . (defined $now ? $now : 0)
                                    . '-unparseable-mandated-means-' . _slug($pkg) . '.json', $nt);
                            }
                            my $raw = $read_verdict->('conformance', '_run');
                            if (defined $raw) {
                                clear_judge_inflight($runs, 'conformance', '_run');
                                my $v = write_conformance_channels({ bpdir => $bpdir, runs => $runs,
                                    raw => $raw, pkgs => $cpkgs, now => $now, blueprint => $bp,
                                    build => $build });
                                _log($log, 'conformance_verdict', { outcome => $v->{outcome},
                                      findings => scalar @{ $v->{findings} } });
                                # b07: the :1930-equivalent (same-tick) verdict-
                                # ingestion site — a verdict already present when
                                # the judge is spawned takes THIS path, not the
                                # cinfl branch above.
                                $rem_outstanding = remediation_step({ bpdir => $bpdir, runs => $runs, verdict => $v,
                                    meta => $meta, status => $status, now => $now, blueprint => $bp, tunables => $t,
                                    log => $log, queue => $rq });
                            } else {
                                # Just spawned and nothing to read yet — normal for a
                                # detached judge. Keep the loop alive; the timeout branch
                                # above writes the error verdict if judge_to elapses.
                                $conf_outstanding = 1;
                            }
                        } else {
                            _log($log, 'conformance_spawn_failed', { rc => $rc });
                        }
                    } else {
                        my $nt = BpJudge::notice_record('conformance spawn cap reached',
                            'the conformance gate hit its spawn cap for this run; not firing again',
                            { generated_at => _iso($now), severity => 'warn',
                              evidence => { spawns => $spawns, cap => ($t->{conformance_spawn_cap} // 0) } });
                        _write_json_atomic("$runs/notices/" . (defined $now ? $now : 0) . "-conformance-spawn-cap-reached.json", $nt);
                        _log($log, 'conformance_spawn_cap', { spawns => $spawns });
                    }
                }
            }
            if (run_complete({ any_running => $any_running, outstanding => $outstanding,
                               resume_pending => $resume_pending, paused => ($paused ? 1 : 0),
                               awaiting_human => $awaiting_human,
                               conformance_outstanding => $conf_outstanding })) {
                _log($log, 'idle_exit', { detail => 'no running, no progressable work, not paused, nothing awaiting a human' });
                last;
            }

            last if $opt->{once};
            $sleep_fn->($t->{watch_tick});
        }
        1;
    } or $err = $@;

    release_marker($marker_fh, "$runs/.orchestrator");
    _log($log, 'orchestrator_stop', { err => ($err ? "$err" : undef) });
    die $err if $err;
    return 0;
}

# write a manual (no-auto-resume) pause + queue a needs-you decision.
# b03: optional 5th arg $opt = { quiet_log => 0|1 }. INV-P1: a pause that
# actually WROTE .paused is always logged, regardless of quiet_log — only a
# repeat call that changed no durable state can be silenced. All pre-existing
# call sites pass no $opt and are byte-for-byte unaffected.
sub _enter_pause_manual {
    my ($runs, $log, $reason, $decision, $opt) = @_;
    # Don't clobber an already-active manual pause's reason: keep the FIRST one in
    # .paused and just add this decision to the needs-you queue. The queue is the
    # authoritative list of everything the human must resolve before resuming, so a
    # second manual reason (e.g. a contract drift after a token-floor reauth) never
    # suppresses the first — both surface there.
    my $existing = read_paused($runs);
    my $wrote = 0;
    unless ($existing && $existing->{manual}) {
        write_paused($runs, { reason => $reason, manual => 1, created_at => ($decision->{created_at} // time) });
        $wrote = 1;
    }
    queue_needs_you($runs, $decision) if $decision;
    _log($log, 'pause', { reason => $reason, manual => 1, package => ($decision->{package} // '_fleet'), kind => ($decision->{kind} // '') })
        if $wrote || !($opt && $opt->{quiet_log});
}

# mark a package blocked in its ledger + queue the decision (loop-guard). An
# optional $question/$kind override the defaults (A5: resolve-park surfaces the
# judge's own needs_you question; harvest-park raises a harvest-failure alarm).

# ===========================================================================
# b07 — auto-remediation engine: orchestrator seams (spec-08 §3.1, §3.3, §3.5)
# ===========================================================================

# Per-tick DAG-append merge (spec-08 §3.1, D1): read runs/remediation-queue.json,
# read each entry's on-disk ledger frontmatter status where the ledger exists,
# and hand both to BpRemediate::merge_queue to mutate %meta/%status IN PLACE.
# Returns the queue (read fresh off disk) so the rest of this tick — including
# both conformance-verdict ingestion sites — sees a consistent view without a
# second disk read.
sub remediation_merge {
    my ($bpdir, $runs, $meta, $status, $now) = @_;
    my $queue = BpRemediate::read_queue("$runs/remediation-queue.json");
    $queue = BpRemediate::queue_new({}) unless ref $queue eq 'HASH';
    return $queue if $queue->{_corrupt};   # fail-closed: never merge a corrupt queue

    my %ledger_status;
    for my $e (@{ (ref $queue->{entries} eq 'ARRAY') ? $queue->{entries} : [] }) {
        next unless ref $e eq 'HASH';
        my $id = $e->{id};
        next unless defined $id && length $id;
        next unless -f "$bpdir/packages/$id.md";
        my $st = ledger_fm($bpdir, $id, 'status');
        $ledger_status{$id} = $st if defined $st && length $st;
    }
    my $r = BpRemediate::merge_queue($queue, $meta, $status, \%ledger_status);

    # b07 (deviation from spec-08 §3.5 behavior 21, recorded in the
    # implementer report): rotation of runs/conformance-verdict.json — the
    # seam that re-arms b05's gate — happens HERE, at merge time, rather than
    # at authoring time. Authoring cannot usefully rotate: verify_ready (§3.4)
    # stays 0 while any entry is 'queued', so the gate can't re-fire yet at
    # that moment anyway. The merge above is what flips queued -> awaiting_verify
    # (the ONLY transition that can make verify_ready become 1), and it runs
    # every tick, so it is the correct place to detect "the queue's readiness
    # just changed" and rotate the stale verdict out of the way.
    if (@{ $r->{transitioned} || [] }) {
        BpRemediate::rotate_verdict($runs, $queue, $now);
        update_registry_pkg($runs, '_run', { conformance_spawns => 0 });
        BpRemediate::write_queue("$runs/remediation-queue.json", $queue);
    }
    return $queue;
}

# One verdict-ingestion-time step (spec-08 §3.3 behavior 12, §3.5). $a is the
# argument hash built at both call sites (:1897ish, :1972ish): bpdir, runs,
# verdict, meta, status, now, blueprint, tunables, log, queue.
sub remediation_step {
    my ($a) = @_;
    my $bpdir = $a->{bpdir};
    my $runs  = $a->{runs};
    my $now   = $a->{now};
    my $bp    = $a->{blueprint};
    my $t     = $a->{tunables} || {};
    my $log   = $a->{log};
    my $meta  = $a->{meta}   || {};
    my $status= $a->{status} || {};

    my $qpath = "$runs/remediation-queue.json";
    my $queue = $a->{queue};
    $queue = BpRemediate::read_queue($qpath) unless ref $queue eq 'HASH';
    $queue = BpRemediate::queue_new({}) unless ref $queue eq 'HASH';

    my %pkg_write_sets = map { $_ => $meta->{$_}{write_set} } grep { defined $meta->{$_}{write_set} } keys %$meta;
    my %pkg_status     = %$status;

    my %ctx = (
        now            => $now,
        iso            => _iso($now),
        blueprint      => $bp,
        rounds         => ($t->{remediation_rounds} // 2),
        cap            => ($t->{remediation_cap}    // 6),
        pkg_write_sets => \%pkg_write_sets,
        pkg_status     => \%pkg_status,
        model          => ($t->{remediation_model} // 'sonnet'),
        max_turns      => ($t->{remediation_max_turns} // 60),
        test_paths     => ($t->{remediation_test_paths} // 'plugins/butler/tests/'),
        backpack_path  => $t->{backpack_path},   # §8.2: no invented default; undef => escalate
    );

    my $plan = BpRemediate::plan($a->{verdict}, $queue, \%ctx);

    # (i) author every ledger BEFORE the entry is merged/persisted (§2.11 —
    # a launchable remediation package always has a readable ledger on disk).
    for my $entry (@{ $plan->{author} || [] }) {
        BpRemediate::author_ledger($bpdir, $entry, \%ctx);
    }

    # (ii) persist the queue AFTER the ledgers (§3.5): a crash between them
    # must leave an inert orphan ledger, never a merged entry with no ledger.
    #
    # NOTE: this write is deliberately UNCONDITIONAL. b07's own oracle requires
    # it -- t/26 AC-30 asserts "the remediation queue is written after ingestion
    # (even with zero entries)". Making it conditional to spare b05's AC-26
    # boundary assertion trades one oracle for the other; see the coordinator's
    # escalation in the b07 ledger. Do not "fix" AC-26 here.
    BpRemediate::write_queue($qpath, $plan->{queue});

    # (iii) notices — reused b05 channel, source overridden per §2.7.
    for my $n (@{ $plan->{notices} || [] }) {
        my $nt = BpJudge::notice_record($n->{subject}, $n->{detail},
            { generated_at => _iso($now), severity => ($n->{severity} // 'warn'),
              evidence => (ref $n->{evidence} eq 'HASH' ? $n->{evidence} : {}) });
        $nt->{source} = 'remediation-engine';
        _write_json_atomic("$runs/notices/" . (defined $now ? $now : 0)
            . '-remediation-' . _slug($n->{subject}) . '.json', $nt);
    }

    # (iv) reviews — a 'justify' finding, unchanged builder.
    for my $f (@{ $plan->{reviews} || [] }) {
        my $rec = BpJudge::review_record(
            { package => $f->{subject}, means => undef, change => $f->{detail}, justification => $f->{detail} },
            { generated_at => _iso($now) });
        _write_json_atomic("$runs/review/" . ($rec->{package} // 'unknown') . '-' . _slug($f->{detail} // $f->{subject}) . '.json', $rec);
    }

    # (v) exactly one blocking decision iff plan.escalate is non-empty (D8).
    if (@{ $plan->{escalate} || [] }) {
        my $n = scalar @{ $plan->{escalate} };
        my @reasons = do { my %seen; grep { !$seen{$_}++ } map { $_->{escalation_reason} // '' } @{ $plan->{escalate} } };
        queue_needs_you($runs, {
            kind       => 'remediation-escalation',
            package    => '_remediation',
            blueprint  => $bp,
            reason     => 'auto-remediation could not close one or more characterized findings',
            ts         => _iso($now),
            manual     => 0,
            question   => "$n finding" . ($n == 1 ? '' : 's') . ' could not be auto-remediated',
            context    => { findings => $plan->{escalate}, rounds_used => $plan->{queue}{rounds_used},
                             rounds_cap => $ctx{cap}, queue => 'runs/remediation-queue.json' },
            created_at => $now,
        });
    }

    # (vi) rotate the verdict + re-arm b05's gate: only when a round actually
    # opened this plan AND the global cap wasn't already exhausted opening it
    # (spec-08 item 9) — bounds gate_firings <= rounds_used <= remediation_cap.
    if ($plan->{rotate} && ($plan->{queue}{rounds_used} // 0) < $ctx{cap}) {
        BpRemediate::rotate_verdict($runs, $plan->{queue}, $now);
        update_registry_pkg($runs, '_run', { conformance_spawns => 0 });
    }

    _log($log, 'remediation_step', {
        authored => scalar(@{ $plan->{author}   || [] }),
        escalated => scalar(@{ $plan->{escalate} || [] }),
        rotate    => ($plan->{rotate} ? 1 : 0),
        outstanding => ($plan->{outstanding} ? 1 : 0),
    });

    return $plan->{outstanding};
}

sub _block_and_queue {
    my ($bpdir, $runs, $log, $bp, $pkg, $why, $now, $question, $kind) = @_;
    _set_ledger_status($bpdir, $pkg, 'blocked');
    # Also persist to the registry (H3): _load_state prefers the ledger, but if the
    # ledger write above failed, the registry is the fallback — without this a parked
    # package could re-enter the watchdog and re-escalate after an orchestrator restart.
    update_registry_pkg($runs, $pkg, { status => 'blocked' });
    queue_needs_you($runs, {
        package => $pkg, blueprint => $bp, kind => ($kind // 'stuck-package'),
        question => ($question // "Package '$pkg' is blocked: $why. Re-scope, fix, or drop it?"),
        context => $why, created_at => ($now // time),
    });
}

# escalation ladder gate (A5 #13): a package is stuck past the coordinator's own
# retries. Spend a resolve-judge if the per-package budget remains (and we aren't
# shutting down), else park the branch. Returns the resulting status string the
# caller records ('resolving' = judge in flight; 'blocked' = parked).
sub _escalate_stuck {
    my ($a) = @_;
    my ($runs, $log, $pkg) = @{$a}{qw(runs log pkg)};
    my $resolve_att = $a->{reg}{$pkg}{resolve_attempts} // 0;
    my $verdict = BpJudge::escalation_verdict({ resolve_attempts => $resolve_att, resolve_cap => $a->{t}{resolve_cap} });
    if ($verdict eq 'resolve' && !$a->{shutdown}) {
        my $rc = $a->{spawn_judge}->({ kind => 'resolve', pkg => $pkg });
        if (defined $rc && $rc == 0) {
            mark_judge_inflight($runs, 'resolve', $pkg, $a->{now});
            update_registry_pkg($runs, $pkg, { resolve_attempts => $resolve_att + 1 });
            _log($log, 'resolve_fire', { package => $pkg, why => $a->{why}, resolve_attempts => $resolve_att + 1 });
            return 'resolving';
        }
        _log($log, 'judge_spawn_failed', { kind => 'resolve', package => $pkg, rc => $rc });
        # couldn't even spawn the judge -> fall through and park.
    }
    _block_and_queue($a->{bpdir}, $runs, $log, $a->{bp}, $pkg, $a->{why}, $a->{now});
    return 'blocked';
}

# --- b05 conformance gate -------------------------------------------------
# Build the { pkg => {status, means, means_shape, means_ok} } map the pure
# BpJudge::conformance_ready consumes. ledger_fm is scalar-only, so mandated_means
# gets this narrow list-aware read (NOT a general YAML parser — deliberately).
sub conformance_registry {
    my ($bpdir, $meta, $status) = @_;
    my %pkgs;
    for my $pkg (sort keys %{ $meta || {} }) {
        # b07 (spec-08 §3.4 behavior 17, D9): remediation packages are never
        # conformance-judged — excluding them here is the recursion guard.
        next if $meta->{$pkg}{remediation};
        my $raw = ledger_fm($bpdir, $pkg, 'mandated_means');
        my $mm  = BpJudge::parse_mandated_means($raw);
        $pkgs{$pkg} = { status => ($status->{$pkg} // 'pending'),
                        means => $mm->{means}, means_shape => $mm->{shape}, means_ok => $mm->{ok} };
    }
    return \%pkgs;
}

sub conformance_verdict_path { my ($runs) = @_; "$runs/conformance-verdict.json" }

# ISO-8601 from the injected clock (never wall-clock, so tests are deterministic).
sub _iso {
    my ($epoch) = @_;
    $epoch = 0 unless defined $epoch;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _slug {
    my ($s, $max) = @_;
    $s = '' unless defined $s;
    $s = lc $s;
    $s =~ s/[^a-z0-9]+/-/g;
    $s =~ s/^-+//; $s =~ s/-+$//;
    $s = substr($s, 0, ($max || 48));
    $s =~ s/-+$//;
    return length($s) ? $s : 'entry';
}

# atomic temp+rename, best-effort (never fatal) — same contract as _apply_harvest_findings.
sub _write_json_atomic {
    my ($path, $data) = @_;
    require File::Basename;
    my $dir = File::Basename::dirname($path);
    require File::Path; File::Path::make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    if (open my $w, '>', $tmp) {
        print $w JSON::PP->new->canonical->pretty->encode($data);
        close $w;
        return 1 if rename $tmp, $path;
        unlink $tmp;
    }
    return 0;
}

# Deterministically turn the RAW judge verdict into the authoritative verdict plus
# the review/notice channels. The judge never writes these (spec D5) — that is what
# keeps the whole gate testable through the injected read_verdict seam.
sub write_conformance_channels {
    my ($a) = @_;
    my ($bpdir, $runs, $raw, $pkgs, $now, $bp, $build) =
        @{$a}{qw(bpdir runs raw pkgs now blueprint build)};
    my $norm  = BpJudge::normalize_conformance($raw);
    my @findings = @{ $norm->{findings} || [] };
    my (@reviews, @notices);
    my $iso = _iso($now);
    my $ctx = { generated_at => $iso };

    # a package whose mandated_means could not be parsed gets a notice, never a crash
    for my $pkg (sort keys %{ $pkgs || {} }) {
        next if $pkgs->{$pkg}{means_ok};
        push @notices, BpJudge::notice_record('unparseable mandated_means',
            "package $pkg has a mandated_means value this reader cannot interpret; treated as an empty list",
            { %$ctx, severity => 'warn', evidence => { package => $pkg,
              shape => $pkgs->{$pkg}{means_shape} } });
    }

    # classify each deviation the judge asserted, against the ledger's marker
    for my $dev (@{ $norm->{deviations} || [] }) {
        next unless ref $dev eq 'HASH';
        my $pkg   = defined $dev->{package} ? $dev->{package} : '';
        my $means = defined $dev->{means}   ? $dev->{means}   : '';
        my $declared = ($pkgs && ref $pkgs->{$pkg} eq 'HASH' && ref $pkgs->{$pkg}{means} eq 'ARRAY')
                       ? $pkgs->{$pkg}{means} : [];
        # the EXPLICIT list is the only source of mandated means — prose never counts
        unless (grep { $_ eq $means } @$declared) {
            push @notices, BpJudge::notice_record('deviation against undeclared means',
                "the judge asserted a deviation for '$means' in $pkg, which is not in that package's mandated_means list; ignored",
                { %$ctx, severity => 'info', evidence => { package => $pkg, means => $means } });
            next;
        }
        my $marks = BpJudge::parse_means_deviations(_read_file("$bpdir/packages/$pkg.md"));
        my $mark  = (ref $marks eq 'HASH' && ref $marks->{$means} eq 'HASH') ? $marks->{$means} : undef;
        my $verd  = BpJudge::classify_deviation({
            package => $pkg, means => $means, observed => $dev->{observed},
            files => $dev->{files},
            justification_present => ($mark ? 1 : 0),
            justification         => ($mark ? $mark->{why} : undef) });
        if ($verd eq 'review') {
            # who= (when the coordinator recorded one) is the authoritative identity;
            # fall back to the package name, then 'unknown' (spec §8 open question 1).
            my $who = (defined $mark->{who} && $mark->{who} =~ /\S/) ? $mark->{who} : $pkg;
            push @reviews, BpJudge::review_record(
                { %$dev, change => $mark->{change}, justification => $mark->{why}, who => $who },
                { %$ctx, coordinator => $who });
        } elsif ($verd eq 'fail') {
            push @findings, BpJudge::finding_record($dev, $ctx);
        }
    }

    # fold b04's dependency report (read-only; Decision #14)
    my $depsf = "$runs/deps-check.json";
    my $rep   = (-e $depsf) ? (_read_json($depsf) // { _malformed => 1 }) : undef;
    my $fold  = BpJudge::fold_deps_check($rep);
    push @findings, @{ $fold->{findings} || [] };
    push @reviews,  map { BpJudge::review_record($_, $ctx); } ();      # shape below
    for my $rv (@{ $fold->{reviews} || [] }) { push @reviews, { schema => 'review/1', generated_at => $iso, %$rv } }
    for my $nt (@{ $fold->{notices} || [] }) {
        push @notices, BpJudge::notice_record($nt->{subject}, $nt->{detail},
            { %$ctx, severity => ($nt->{severity} || 'warn'), evidence => ($nt->{evidence} || {}) });
    }

    # a red build is a characterizable failure too
    if ($build && $build->{ran} && !$build->{ok}) {
        push @findings, { kind => 'conformance-build-failure', severity => 'block',
            subject => ($bp // 'run'), detail => 'the project build/test command failed during the conformance gate',
            evidence => { exit => $build->{exit}, stderr => ($build->{stderr} // '') },
            remedy => { action => 'remediate-build' }, needs_justification => 0 };
    }

    my $raw_ok = (ref $raw eq 'HASH' && !$raw->{_malformed}) ? 1 : 0;
    my $outcome = $norm->{outcome};
    $outcome = 'fail'  if @findings && $outcome ne 'error';
    $outcome = 'error' if !$raw_ok;
    $outcome = 'error' if ($fold->{outcome_hint} // '') eq 'error';
    $outcome = 'fail'  if $outcome eq 'pass' && @findings;

    for my $rv (@reviews) {
        my $key = _slug(($rv->{package} // 'unknown') . '-' . ($rv->{original_means} // 'means'));
        _write_json_atomic("$runs/review/$key.json", $rv);          # deterministic name => idempotent
    }
    my $n = 0;
    for my $nt (@notices) {
        my $base = _slug($nt->{subject});
        my $p = "$runs/notices/" . (defined $now ? $now : 0) . "-$base.json";
        $p = "$runs/notices/" . (defined $now ? $now : 0) . "-$base-" . (++$n + 1) . ".json" if -e $p;
        _write_json_atomic($p, $nt);
    }

    my $verdict = {
        schema => 'conformance-verdict/1', generated_at => $iso, project => ($bp // ''),
        outcome => $outcome, raw_verdict_path => "runs/conformance/_run.verdict.json",
        raw_ok => ($raw_ok ? JSON::PP::true : JSON::PP::false),
        build => ($build || { ran => JSON::PP::false }),
        packages => [ map { { name => $_, status => $pkgs->{$_}{status},
                              mandated_means => $pkgs->{$_}{means},
                              means_shape => $pkgs->{$_}{means_shape} } } sort keys %{ $pkgs || {} } ],
        findings => \@findings, reviews => \@reviews, notices => \@notices,
        notes => ($norm->{notes} || []),
    };
    _write_json_atomic(conformance_verdict_path($runs), $verdict);
    return $verdict;
}

# write the harvest audit's findings into the ledger (A5 Q2) so the reopened
# coordinator reads them on its corrective relaunch. Idempotent: replaces any prior
# findings block. Best-effort (atomic temp + rename).
sub _apply_harvest_findings {
    my ($bpdir, $pkg, $verdict) = @_;
    my $f = "$bpdir/packages/$pkg.md";
    my $txt = _read_file($f);
    return unless defined $txt;
    my @fails  = (ref $verdict eq 'HASH' && ref $verdict->{failures} eq 'ARRAY') ? @{ $verdict->{failures} } : ();
    my $reason = (ref $verdict eq 'HASH' ? $verdict->{reason} : undef) // 'harvest audit failed';
    $txt =~ s/\n*## Harvest findings \(re-verify\).*?(?=\n## |\z)//s;   # drop any prior block
    my $sec = "\n\n## Harvest findings (re-verify)\n\n"
            . "The independent harvest audit FAILED this package after it was reported done: $reason\n"
            . "Address each finding, then re-run your own tests/review before reporting done again:\n\n"
            . (@fails ? join("\n", map { "- $_" } @fails)
                      : "- (no itemized failures recorded; re-verify every done-criterion against disk)")
            . "\n";
    $txt .= $sec;
    open my $w, '>:raw', "$f.tmp.$$" or return;
    print $w $txt; close $w;
    rename "$f.tmp.$$", $f;
}

# rewrite a ledger's frontmatter status: line (+ last_updated). Best-effort.
sub _set_ledger_status {
    my ($bpdir, $pkg, $st) = @_;
    my $f = "$bpdir/packages/$pkg.md";
    my $txt = _read_file($f);
    return unless defined $txt;
    return unless $txt =~ /\A---\s*\n(.*?)\n---/s;
    my $fm = $1;
    my $newfm = $fm;
    if ($newfm =~ /^status:.*$/m) { $newfm =~ s/^status:.*$/status: $st/m; }
    else { $newfm .= "\nstatus: $st"; }
    my @t = gmtime(time);
    my $iso = sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0];
    if ($newfm =~ /^last_updated:.*$/m) { $newfm =~ s/^last_updated:.*$/last_updated: $iso/m; }
    $txt =~ s/\A---\s*\n.*?\n---/---\n$newfm\n---/s;
    open my $w, '>:raw', "$f.tmp.$$" or return;
    print $w $txt; close $w;
    rename "$f.tmp.$$", $f;
}

# ===========================================================================
# CLI
# ===========================================================================
package main;
use strict;
use warnings;
unless (caller) {
    my $bp = shift @ARGV;
    unless (defined $bp && length $bp && $bp !~ /^--/) {
        print STDERR "usage: bp-orchestrator.pl <blueprint> [--bp-dir DIR] [--once]\n";
        exit 2;
    }
    my ($bpdir, $once);
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--bp-dir') { $bpdir = shift @ARGV; }
        elsif ($a eq '--once')   { $once = 1; }
        else { print STDERR "bp-orchestrator: unknown option $a\n"; exit 2; }
    }
    unless (defined $bpdir) {
        my $data = $ENV{CCPRAXIS_DATA_DIR};
        unless (defined $data) {
            print STDERR "bp-orchestrator: set --bp-dir or CCPRAXIS_DATA_DIR\n";
            exit 2;
        }
        $bpdir = "$data/blueprints/$bp";
    }
    BpOrch::run({ blueprint => $bp, bp_dir => $bpdir, once => $once });
}
1;
