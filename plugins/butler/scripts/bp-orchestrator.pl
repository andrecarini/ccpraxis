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

our $USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
our $USER_AGENT = $ENV{BP_USER_AGENT} // 'claude-code/2.1.170';

# ===========================================================================
# PURE DECISIONS  (no I/O, no globals — unit-tested in t/06-orchestrator.t)
# ===========================================================================

sub _is_terminal { my $s = shift // ''; $s =~ /^(done|blocked|parked)$/ ? 1 : 0 }

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
            $dead_dep = 1 if $ds eq 'blocked' || $ds eq 'parked';
        }
        return 1 unless $dead_dep;
    }
    return 0;
}

# --- the orchestrator exits when nothing is running, nothing is progressable, and
# no auto-resume is pending and we are not paused.
sub run_complete {
    my ($c) = @_;
    return 0 if $c->{any_running} || $c->{outstanding} || $c->{resume_pending} || $c->{paused};
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
    open my $fh, '>', $file or die "bp-orchestrator: queue needs-you: $!";
    print $fh JSON::PP->new->canonical->pretty->encode($rec);
    close $fh;
    return $file;
}

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
                    _enter_pause_manual($runs, $log, 'token-auth',
                        { package => '_fleet', blueprint => $bp, kind => 'reauth',
                          question => 'OAuth token is un-refreshable (4xx) — re-authenticate with /login.',
                          context => ($k->{detail} // 'refresh returned a 4xx'), created_at => $now });
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

            # ---- WATCH + WATCHDOG (assess each non-terminal launched package) ----
            my @live;     # packages occupying a coordinator slot now
            for my $pkg (sort keys %$meta) {
                next if _is_terminal($status->{$pkg});
                # A never-launched package (status pending, attempt 0, no pid) is the
                # LAUNCH section's job, not the watchdog's — skip it here so it isn't
                # mistaken for a dead coordinator. A crashed package whose ledger still
                # reads 'pending' but has attempt>0 / a recorded pid IS the watchdog's.
                my $launched = (($att->{$pkg} // 0) > 0)
                            || (defined $pid->{$pkg} && length $pid->{$pkg})
                            || (($status->{$pkg} // 'pending') ne 'pending');
                next unless $launched;
                my $alive = pid_alive($pid->{$pkg});
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
                        _block_and_queue($bpdir, $runs, $log, $bp, $pkg, 'wedged past attempt cap (no log growth)', $now);
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
                        _block_and_queue($bpdir, $runs, $log, $bp, $pkg, 'serial failer past attempt cap (dead coordinator)', $now);
                    }
                }
            }

            # ---- LAUNCH newly-ready packages into free slots (event-driven) ----
            unless ($shutdown) {
                my $slots = cap_slots(scalar @live, $t->{max_par});
                if ($slots > 0) {
                    my @ready = ready_packages($meta, $status, \@live);
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

            # ---- BUSY-LEASE + IDLE-EXIT ----
            my $any_running = (scalar @live) > 0 ? 1 : 0;
            my $outstanding = has_progressable_work($meta, $status);
            touch_busy($t->{busy_path}) if should_touch_busy({
                any_running => $any_running, outstanding => $outstanding,
                resume_pending => $resume_pending, shutdown => $shutdown,
            });

            if ($shutdown && !$any_running) {
                _log($log, 'shutdown_complete', { detail => 'graceful-shutdown-all: no coordinators left' });
                last;
            }
            if (run_complete({ any_running => $any_running, outstanding => $outstanding, resume_pending => $resume_pending, paused => ($paused ? 1 : 0) })) {
                _log($log, 'idle_exit', { detail => 'no running, no progressable work, not paused' });
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

# mark a package blocked in its ledger + queue the decision (loop-guard).
sub _block_and_queue {
    my ($bpdir, $runs, $log, $bp, $pkg, $why, $now) = @_;
    _set_ledger_status($bpdir, $pkg, 'blocked');
    queue_needs_you($runs, {
        package => $pkg, blueprint => $bp, kind => 'stuck-package',
        question => "Package '$pkg' is blocked: $why. Re-scope, fix, or drop it?",
        context => $why, created_at => ($now // time),
    });
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
