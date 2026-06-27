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

our $USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
our $USER_AGENT = $ENV{BP_USER_AGENT} // 'claude-code/2.1.170';

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
sub write_paused {
    my ($runs, $rec) = @_;
    # atomic: temp + rename, so a crash mid-write can never leave a truncated
    # .paused that would read back as a stuck "unknown" manual pause.
    my $tmp = "$runs/.paused.tmp.$$";
    open my $fh, '>', $tmp or die "bp-orchestrator: write .paused: $!";
    print $fh JSON::PP->new->canonical->encode($rec);
    close $fh;
    rename $tmp, "$runs/.paused" or die "bp-orchestrator: rename .paused: $!";
}
sub clear_pause { my ($runs) = @_; unlink "$runs/.paused"; }

# --- runs/needs-you/<pkg>--<shortid>.json (decision queue; A3 owns the schema).
sub queue_needs_you {
    my ($runs, $rec) = @_;
    my $dir = "$runs/needs-you";
    require File::Path; File::Path::make_path($dir) unless -d $dir;
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
    open my $fh, '>', $tmp or die "bp-orchestrator: queue needs-you: $!";
    print $fh JSON::PP->new->canonical->pretty->encode($rec);
    close $fh;
    rename $tmp, $file or do { unlink $tmp; die "bp-orchestrator: queue needs-you rename: $!"; };
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
    my $data = _read_json($args->{creds_path});
    unless ($data) { _log($log, 'creds_error', { detail => 'unreadable or invalid JSON' }); return { action => 'pause-creds' }; }
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

# ===========================================================================
# THE LOOP
# ===========================================================================

sub _tunables {
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
    my $t     = $opt->{tunables} || _tunables();
    my $now_fn   = $opt->{now}      || sub { time };
    my $sleep_fn = $opt->{sleep}    || sub { select(undef, undef, undef, $_[0]) };
    my $http_get  = $opt->{http_get};
    my $http_post = $opt->{http_post};

    # launch seam: default = bp-launch.sh; tests inject a recorder.
    my $launch = $opt->{launch} || sub {
        my ($a) = @_;
        my @cmd = ('bash', "$DIR/bp-launch.sh", $bp, $a->{pkg}, @{ $a->{args} || [] });
        my $rc = system(@cmd);
        return $rc == 0 ? 0 : ($rc >> 8 || 1);
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
    # pid-liveness seam: default = the real kill-0 check; the simulation harness (A6)
    # injects a scripted one so alive/progressing and alive/wedged coordinator paths
    # can be driven through the real loop (not just the dead-pid path).
    my $pid_alive = $opt->{pid_alive} || \&pid_alive;

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
    # judge in-flight + start-epoch state lives on disk (judge_inflight*), so nothing
    # to declare here — it survives an orchestrator restart (A5).
    my (@s5, @s7);       # usage utilization samples [[epoch,pct],...]
    my $next_usage  = 0; # poll immediately at launch (Decision #8: one probe)
    my $next_keeper = 0;
    my $tele_fail   = 0;

    my $err;
    eval {
        while (!$STOP) {
            my $now = $now_fn->();
            my $shutdown = -e "$runs/.shutdown" ? 1 : 0;
            my ($meta, $status, $att, $pid, $sid) = _load_state($bpdir, $runs);

            # ---- TOKEN-KEEPER (runs even while paused, to keep the token alive) ----
            if ($now >= $next_keeper) {
                my $k = BpKeeper::keeper_tick({ creds_path => $creds, now_ms => $now * 1000, log_path => $log, http_post => $http_post });
                my $act = $k->{action} // 'ok';
                $next_keeper = $now + ($act eq 'backoff' ? $t->{keeper_bo} : $t->{keeper_int});
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
                    _enter_pause_manual($runs, $log, "keeper-$act",
                        { package => '_fleet', blueprint => $bp, kind => 'contract-drift',
                          question => 'Credential/refresh contract drift — inspect before resuming.',
                          context => JSON::PP->new->canonical->encode($k->{detail} // {}), created_at => $now });
                }
            }

            my $paused = read_paused($runs);

            # ---- USAGE POLL (burn-rate-adaptive cadence) ----
            if ($now >= $next_usage) {
                my $u = fetch_usage({ creds_path => $creds, http_get => $http_get, log_path => $log });
                if (($u->{action} // '') eq 'ok') {
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
                    $next_usage = $now + $t->{usage_fail};
                    _enter_pause_manual($runs, $log, ($u->{action} // 'usage-fail'),
                        { package => '_fleet', blueprint => $bp, kind => 'contract-drift',
                          question => 'Credentials/usage contract problem — inspect before resuming.',
                          context => join('; ', @{ $u->{problems} || [] }), created_at => $now });
                    $paused = read_paused($runs);
                }
            }

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
                    my $v = watchdog_verdict({ alive => 1, progress => $prog, attempts => $att->{$pkg}, cap => $t->{cap} });
                    if ($v eq 'none') {
                        push @live, $pkg;
                    } elsif ($v eq 'cold-relaunch') {
                        next if $shutdown;     # shutdown gate (A4) parks it; we don't relaunch
                        _log($log, 'watchdog_kill_wedged', { package => $pkg, pid => $pid->{$pkg}, attempts => $att->{$pkg} });
                        kill_pid($pid->{$pkg});
                        my $rc = $launch->({ pkg => $pkg, args => [], kind => 'cold-wedged' });
                        if (defined $rc && $rc == 0) { push @live, $pkg; }
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
                    my $v = watchdog_verdict({ alive => 0, attempts => $att->{$pkg}, cap => $t->{cap} });
                    if ($v eq 'relaunch') {
                        if (@live < $t->{max_par}) {
                            my $age = ledger_age_min($bpdir, $pkg, $now);
                            my $mode = resume_mode($age, $sid->{$pkg}, $t->{thresh_min});
                            my @args = ($mode eq 'warm') ? ('--resume-session', $sid->{$pkg}) : ();
                            _log($log, 'watchdog_relaunch', { package => $pkg, mode => $mode, age_min => $age, attempts => $att->{$pkg} });
                            my $rc = $launch->({ pkg => $pkg, args => \@args, kind => $mode });
                            if (defined $rc && $rc == 0) { push @live, $pkg; }
                            else { _log($log, 'launch_failed', { package => $pkg, kind => $mode, rc => $rc }); }
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
                    my @ready = ready_packages($meta, $launch_status, \@live);
                    my @batch = pick_launch_batch(\@ready, $meta, [ map { $meta->{$_}{write_set} } @live ], $slots);
                    for my $pkg (@batch) {
                        my $rc = $launch->({ pkg => $pkg, args => [], kind => 'fresh' });
                        if (defined $rc && $rc == 0) {
                            _log($log, 'launch', { package => $pkg, kind => 'fresh' });
                            push @live, $pkg;
                        } else {
                            _log($log, 'launch_failed', { package => $pkg, kind => 'fresh', rc => $rc });
                        }
                    }
                }
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
            if (run_complete({ any_running => $any_running, outstanding => $outstanding,
                               resume_pending => $resume_pending, paused => ($paused ? 1 : 0),
                               awaiting_human => $awaiting_human })) {
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
sub _enter_pause_manual {
    my ($runs, $log, $reason, $decision) = @_;
    # Don't clobber an already-active manual pause's reason: keep the FIRST one in
    # .paused and just add this decision to the needs-you queue. The queue is the
    # authoritative list of everything the human must resolve before resuming, so a
    # second manual reason (e.g. a contract drift after a token-floor reauth) never
    # suppresses the first — both surface there.
    my $existing = read_paused($runs);
    unless ($existing && $existing->{manual}) {
        write_paused($runs, { reason => $reason, manual => 1, created_at => ($decision->{created_at} // time) });
    }
    queue_needs_you($runs, $decision) if $decision;
    _log($log, 'pause', { reason => $reason, manual => 1, package => ($decision->{package} // '_fleet'), kind => ($decision->{kind} // '') });
}

# mark a package blocked in its ledger + queue the decision (loop-guard). An
# optional $question/$kind override the defaults (A5: resolve-park surfaces the
# judge's own needs_you question; harvest-park raises a harvest-failure alarm).
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
