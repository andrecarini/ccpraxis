package BpContinuityLease;
# BpContinuityLease — hold the machine/container awake for as long as a session
# is ARMED FOR CONTINUITY, and release it when it is turned off.
#
# THE HOLE THIS FILLS.
#
# Every other long-running butler driver holds a wake-lock: bp-drive-next.pl and
# bp-orchestrator.pl both call BpKeepAwake::apply, and the fleet orchestrator
# also refreshes the busy-lease (/tmp/.butler-busy) that keeps a sandbox
# container from reaping itself and — through launcher.pl's dashboard probe —
# keeps the HOST awake behind it.
#
# `/butler:continuity on` held NEITHER. That is the exact inversion of
# bp-keepawake.pl's own founding complaint ("the lock existed on the path that
# needs it least and was absent from the one that needs it most"), one level
# further out: continuity arming exists PRECISELY for unattended work with no
# blueprint, no drive-solo and no reporter — i.e. for the sessions where nothing
# else is holding a lock, and nobody is sitting there to notice the host drop
# into connected standby or the container reap itself out from under the run.
#
# NAMING (Decision 10, resolved by package 04's spec 1.3): this module is BOTH
# the Windows HOST REFRESHER (daemon_loop starts and refreshes keep-awake.ps1)
# and the container's busy-lease toucher. Decision 10's "sandbox-side lease"
# was right about the objects -- the busy-lease and the keep-awake PidFile
# lease are independent -- but wrong to call the module itself sandbox-side.
# Packages 04-06 mean this module's Windows branch when they say "the
# refresher": the host refresher.
#
# TWO SURFACES, ONE PER PLATFORM — and they are not alternatives.
#
#   Windows host      -> the wake-lock (BpKeepAwake -> keep-awake.ps1). There is
#                        no container to keep alive; the risk is S0 standby.
#   macOS host        -> the same wake-lock, actuated as `caffeinate -i` held by
#                        BpKeepAwake's `hold` process, and only on AC power
#                        (KeepAwake.pm). The risk is idle sleep; a closed lid
#                        always sleeps the Mac, by the operator's rule.
#   Linux (a sandbox) -> the busy-lease (/tmp/.butler-busy). There is no
#                        SetThreadExecutionState to call, and the risk is
#                        heartbeat.sh reaping the container. Touching the lease
#                        ALSO keeps the host awake, because launcher.pl's
#                        dashboard gates its own keep-awake on this very file's
#                        freshness (KeepAwake::should_stay_awake, BUSY_STALE 600s).
#
# So the same arm covers both worlds, and in the sandbox case it covers both
# ENDS of it — which is what "must work inside a sandbox and outside on the
# host" actually requires.
#
# There is a THIRD case, and it holds nothing: a Linux HOST. No
# SetThreadExecutionState, no caffeinate, and no heartbeat.sh or dashboard reading
# /tmp/.butler-busy — so writing that file there would be a lease in name only,
# and state() would then report "held" off the file it had just created. That is
# the one thing bp-keepawake.pl's header forbids outright, so platform() names
# the case 'unsupported' and every branch returns honestly instead.
#
# HELD UNTIL TURNED OFF, not until the next lease expiry.
#
# Both mechanisms are deliberately LEASED rather than held-until-killed (see
# keep-awake.ps1's header for what an unleased orphan cost: ES_DISPLAY_REQUIRED
# held until reboot). A lease needs a refresher, and the refresher cannot be
# "whatever the agent happens to run next": a single turn can outlast the lease
# with no Stop hook and no `hold` tick in between, which is exactly the long
# unattended turn the lock exists to protect.
#
# So arming starts a detached refresher process (this module's own `lease
# --daemon` CLI entry) whose ONLY job is to re-assert both leases every tick for as long
# as any session is armed, and to release and exit once none is. Disarm does not
# have to kill it — it notices within a tick — but disarm re-syncs anyway so the
# release is immediate.
#
# WHY A SEPARATE PROCESS AND NOT A FORKED CHILD. On Git-for-Windows perl fork()
# is emulated with THREADS inside the same process, so a forked child dies the
# moment the parent perl exits — and the parent here is a one-shot Bash tool
# call. exec() from the pseudo-process starts a real, independent process that
# outlives it, which is the same mechanism keep-awake.ps1 already relies on.
# Verified end-to-end on this host: after `arm` returned, the daemon was still
# ticking and had brought the wake-lock up behind it.
#
# WHAT BOUNDS AN ABANDONED ARM. A session that dies without disarming leaves a
# marker behind, and the lease follows the marker: the refresher holds until
# nothing is armed, and the marker stops counting at the continuity TTL (12h by
# default, CCPRAXIS_CONTINUITY_TTL_H). So the worst case is a display held on for
# as long as the arm itself is still considered valid — and stop-gate.sh
# usually reaps such a marker much sooner, on the next Stop of ANY session.
#
# That horizon is deliberate rather than merely inherited. A shorter one just
# for the lease would mean a session can be "armed but no longer protected",
# which is precisely the state this file exists to remove; the arm and the thing
# that keeps the arm workable expire together.
#
# ITS PID IS STILL NOT A LIVENESS TEST, THOUGH. MSYS perl's $$ is an MSYS pid,
# not a Windows one — measured: a live daemon recorded 16818 and tasklist knew
# no such task. So identity here is the pid FILE (a heartbeat, for cheap
# readers) plus an flock (for exclusion), and the recorded number is only ever
# something for a human to act on. See ensure_daemon and daemon_loop.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use Cwd ();
use JSON::PP ();
use Encode qw(decode encode);
use MIME::Base64 qw(encode_base64);

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$DIR/bp-keepawake.pl";
require "$DIR/BpAwakeConst.pm" unless defined &BpAwakeConst::AC_STALE;
# Addendum A (06-far-pause-session-handoff, step 7, A.2.6): wrapped in eval
# so a broken BpAwakeIntent.pm degrades touch_busy to 05's bare empty touch
# (see touch_busy below) rather than taking the whole module down -- the
# Windows keep-awake path, the daemon and butler-continuity keep loading.
eval { require "$DIR/BpAwakeIntent.pm" unless defined &BpAwakeIntent::lease_line; };
# Batch C (spec 16-cutover, criterion C-6): the BpSession require is gone --
# it existed solely for _marker_is_live's BpSession::find_transcript call,
# and _marker_is_live (with the legacy registry it served) is deleted below.

# The refresher's cadence, and the pid-file heartbeat window derived from it.
# 60s is an order of magnitude inside both leases it refreshes (keep-awake.ps1's
# 900s, heartbeat.sh's 600s BUSY window), so a missed tick is never a dropped
# lock.
our $TICK_SECONDS = 60;

# STALE_TICKS — how many missed ticks make the daemon's pid file "dead" to a
# cheap mtime-only reader (stop-gate.sh). Liveness by mtime rather than by
# pid is deliberate: bash cannot tell a live native Windows pid from a dead one
# (kill -0 lies there — see BpKeepAwake::_pid_alive), but a heartbeat file's age
# is the same fact on every platform and costs one stat.
our $STALE_TICKS = 5;
sub stale_ticks { return $STALE_TICKS }

# tick_seconds — the cadence, with an override for tests and for an operator
# debugging a holder.
#
# CLAMPED TO [1, $TICK_SECONDS]: the override may only make the refresher
# FASTER, never slower, and never zero. Both ends were found by red-teaming and
# both are real.
#
#   0 busy-spins. sleep(0) returns instantly, and with a live helper recorded
#     each iteration costs a tasklist — measured at 2.3s of system time in 3s of
#     wall clock, which is the 2026-08-13 process-storm signature exactly.
#
#   Too large decouples this from stop-gate.sh, which must hardcode its
#     staleness window (300s = 60 * 5) because a hook cannot read a perl
#     constant. At tick=100000 the daemon asserts once and sleeps for a day
#     holding lease.lock, the gate calls its heartbeat stale on every Stop and
#     starts a replacement, and every replacement loses the flock and exits —
#     an unreplaceable zombie holding nothing. Capping at the default makes that
#     divergence unreachable instead of merely unlikely. The same skew arises
#     benignly whenever the agent's shell exports the var and the hook's
#     environment does not.
sub tick_seconds {
    my $t = $ENV{CCPRAXIS_CONTINUITY_LEASE_TICK};
    return $TICK_SECONDS unless defined $t && $t =~ /^\d+$/;
    return clamp_tick($t);
}

sub clamp_tick {
    my ($t) = @_;
    return $TICK_SECONDS unless defined $t && $t =~ /^\d+$/;
    return 1              if $t < 1;
    return $TICK_SECONDS  if $t > $TICK_SECONDS;
    return $t;
}

# The busy-lease freshness window. Must match heartbeat.sh's HB and
# launcher.pl's BUSY_STALE_SECS (both 600s) — it is the same file and the same
# question, asked from three sides.
our $BUSY_STALE_SECONDS = BpAwakeConst::LEASE_FRESH();

# $PLATFORM — a seam, not a setting. Every branch in this file is
# platform-selected, and a host can only ever run one of them; without a way to
# say "decide as if you were somewhere else", most of the logic would be
# verifiable only by running the suite on another OS, which is how branches
# drift apart. Tests set `local $BpContinuityLease::PLATFORM = 'posix'` (or
# 'windows', or 'unsupported'). Production never sets it; platform() answers.
our $PLATFORM;

# platform() -> 'windows' | 'darwin' | 'posix' | 'unsupported'
#
#   windows      a Windows host. The wake-lock is the mechanism.
#   darwin       a macOS host. The wake-lock is the mechanism (caffeinate).
#   posix        INSIDE A CONTAINER. The busy-lease is the mechanism, and it is
#                read by heartbeat.sh and by launcher.pl's dashboard.
#   unsupported  a Linux HOST. Neither mechanism exists here: there is no
#                SetThreadExecutionState to call, and /tmp/.butler-busy is a
#                file nobody reads, so writing one would be a lease in name only.
#
# THE THIRD CASE IS NOT PEDANTRY. Without it, `sync` on a Linux host creates
# /tmp/.butler-busy and `state` then reports "held" off the file it just made —
# a lock reported as held that holds nothing, which is the single failure mode
# bp-keepawake.pl's header forbids outright. Saying "unsupported" is the honest
# answer, and it is also actionable: it tells an operator on such a host that
# arming does not keep their machine awake.
sub platform {
    return $PLATFORM if defined $PLATFORM;
    return 'windows' if $^O =~ /^(MSWin32|msys|cygwin)$/;
    return 'posix'   if in_container();
    return 'darwin'  if $^O eq 'darwin';
    return 'unsupported';
}

sub is_windows { return platform() eq 'windows' ? 1 : 0 }

# host_wakelock() -- the platforms whose lease IS BpKeepAwake's wake-lock pid
# file (a host helper), as opposed to the container's busy-lease.
sub host_wakelock { my $p = platform(); return ($p eq 'windows' || $p eq 'darwin') ? 1 : 0 }

# in_container() — podman and docker both leave a marker at the filesystem root,
# and the sandbox image is built from one of them. Checked in that order and
# nothing else: an env var would be inherited by anything the container spawns
# on the host side, and a cgroup-path heuristic stopped being reliable with
# cgroup v2.
sub in_container {
    return 1 if -e '/run/.containerenv';   # podman
    return 1 if -e '/.dockerenv';          # docker
    return 0;
}

# The busy-lease path. Same default and same env override as the orchestrator's
# (bp-orchestrator.pl's BP_BUSY_PATH / '/tmp/.butler-busy') and the same file
# heartbeat.sh watches, ON PURPOSE: "a butler run is active" is one fact, and an
# armed continuity session is one of the things that makes it true.
sub busy_path { return $ENV{BP_BUSY_PATH} // '/tmp/.butler-busy' }

sub daemon_pid_file { my ($dir) = @_; return "$dir/lease.pid" }
sub wakelock_pid_file { my ($dir) = @_; return "$dir/keepawake.pid" }

# Package 04 constants (spec 2.2): handover timing and the lease.log rotation
# threshold.
our $HANDOVER_TIMEOUT_SECONDS = 60;
our $HANDOVER_RETRY_SECONDS   = 600;
our $LEASE_LOG_MAX_BYTES      = 1048576;

# ttl_hours — this session's continuity TTL rule (12h, sanitised). The bash
# side no longer mirrors this rule; it was retired when the old bash TTL
# check was folded away, so this perl copy is now the only implementation.
sub ttl_hours {
    my $h = $ENV{CCPRAXIS_CONTINUITY_TTL_H};
    return 12 unless defined $h && $h =~ /^\d+$/ && $h > 0;
    return $h;
}

# ---------------------------------------------------------------------------
# Package 04 additions: bridging to BpHook's new per-session arm store.
# Batch C (spec 16-cutover, C-6) retired the old registry from any_active
# outright -- see any_active's own header below.
# ---------------------------------------------------------------------------

# $STATE_ROOT -- a test seam, same shape as $PLATFORM above. Production
# never sets it; store_root_for() resolves through BpHook::state_dir()
# instead.
our $STATE_ROOT;

sub _is_abs_legacy {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{^/};
    return 0 unless $v =~ m{^[A-Za-z]:};
    my $rest = substr($v, 2);
    return 1 if $rest eq q{} || $rest =~ m{^/} || substr($rest, 0, 1) eq chr(92);
    return 0;
}

# legacy_dir() -- exactly the retired continuity CLI's continuity_active_dir rule:
# CCPRAXIS_CONTINUITY_ACTIVE_DIR if absolute (undef if set but relative);
# otherwise $HOME (then $USERPROFILE) plus the fixed suffix; otherwise
# undef. Backslashes are folded to forward slashes on the way out, matching
# every other path this file hands to a filesystem call.
sub legacy_dir {
    my $override = $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    if (defined $override && length $override) {
        return undef unless _is_abs_legacy($override);
        (my $v = $override) =~ tr{\\}{/};
        return $v;
    }
    for my $var (qw(HOME USERPROFILE)) {
        my $val = $ENV{$var};
        next unless _is_abs_legacy($val);
        (my $v = "$val/.claude/ccpraxis/.continuity-active") =~ tr{\\}{/};
        return $v;
    }
    return undef;
}

# store_root_for($dir) -- the new-store root that a given LEGACY registry
# dir corresponds to, or undef when $dir is not the production legacy
# registry (a fixture tempdir is never paired with the real store).
sub store_root_for {
    my ($dir) = @_;
    return $STATE_ROOT if defined $STATE_ROOT;
    return undef unless defined $dir && length $dir;

    my $ldir = legacy_dir();
    return undef unless defined $ldir;

    my $norm_d = $dir;    $norm_d =~ tr{\\}{/}; $norm_d =~ s{/+$}{};
    my $norm_l = $ldir;   $norm_l =~ tr{\\}{/}; $norm_l =~ s{/+$}{};
    return undef unless $norm_d eq $norm_l;

    my $override = $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    my $bsd      = $ENV{BUTLER_STATE_DIR};
    if (defined $override && length $override && !(defined $bsd && length $bsd)) {
        return undef;
    }

    my $root = eval {
        require "$DIR/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
        BpHook::state_dir();
    };
    return $@ ? undef : $root;
}

# new_store_active($root) -> 1 iff $root/armed/ holds a regular file whose
# name matches a session id and is LIVE. Never deletes anything -- reaping
# an expired arm file is the Stop gate's job, not a detached process's.
#
# R6-D53 (Decision 53, hook-continuity-remake blueprint.md): "an idle armed
# session keeps the machine awake for at most ONE HOUR... The lease counts
# an armed session only while its transcript was written in the last hour,
# and it no longer honours a 12-hour Stop-touch window." So when an arm
# file names a determinable transcript_path, liveness is decided PURELY by
# that transcript's own 1h freshness (_transcript_path_is_live) -- the arm
# file's own mtime (what a Stop gate's G7 step refreshes on every Stop) no
# longer gates it at all; a session active right now must not be excluded
# just because nothing happened to touch its arm file for the last 12h.
# Only when the arm file carries NO determinable transcript_path (missing,
# unreadable, undecodable) does the legacy ttl_hours() mtime cutoff apply,
# exactly as before.
sub new_store_active {
    my ($root) = @_;
    return 0 unless defined $root && length $root;
    my $dir = "$root/armed";
    return 0 unless -d $dir;
    my $cutoff = time() - ttl_hours() * 3600;
    opendir(my $dh, $dir) or return 0;
    while (defined(my $e = readdir($dh))) {
        next if $e eq '.' || $e eq '..';
        next unless $e =~ /^[A-Za-z0-9_-]{1,128}$/;
        my $f = "$dir/$e";
        next unless -f $f;
        my $tp = _arm_file_transcript_path($f);
        if (defined $tp) {
            next unless _transcript_path_is_live($tp, $f);
        }
        else {
            next if ((stat($f))[9] // 0) < $cutoff;
        }
        closedir($dh);
        return 1;
    }
    closedir($dh);
    return 0;
}

# _arm_file_transcript_path($path) -> transcript_path string | undef.
# undef covers every undeterminable case (unreadable, undecodable, no such
# key, or a non-string value) -- new_store_active treats undef as "fall
# back to the legacy mtime cutoff", exactly as _arm_file_is_live's old
# fail-open comment described for those same cases.
sub _arm_file_transcript_path {
    my ($path) = @_;
    my $raw = _slurp_small($path);
    return undef unless defined $raw && length $raw;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return undef unless ref $data eq 'HASH';
    my $tp = $data->{transcript_path};
    return undef unless defined $tp && !ref($tp) && length $tp;
    return $tp;
}

sub _slurp_small {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# TRANSCRIPT_LIVENESS_SECONDS — how stale a resolved transcript may be before
# its session is treated as provably dead rather than merely quiet.
#
# Reuses BpSession::transcript_files' OWN precedent for this exact number: its
# default max_age is 3600, on the reasoning that a transcript untouched for an
# hour cannot be the one currently in use. The longest LEGITIMATE transcript
# silence here is bounded by the wake-up TTL (900s — a `hold` may not exceed
# it without refreshing), so 3600s leaves roughly 4x headroom over that while
# still being 12x tighter than the 12h marker TTL below. It is not the same
# question ensure_daemon's pid-file staleness asks (that is "is the refresher
# still ticking", answered every $TICK_SECONDS) and the two are not harmonised
# on purpose — different clocks, different owners.
our $TRANSCRIPT_LIVENESS_SECONDS = 3600;

# F3 (red-team H2): the refresher itself must periodically reap ghost arm
# files (BpHook::gc_sessions), not just exclude them from any_active --
# otherwise the registry only ever grows, and hook-architecture.md's own
# claim ("the lease daemon runs it at most once an hour") stays fiction.
# Rate-limited to at most once per $GC_SESSIONS_INTERVAL, same shape as
# BindDispatch's own $GC_INTERVAL.
our $GC_SESSIONS_INTERVAL = 3600;

# _transcript_path_is_live($path, $armfile) -- applies
# TRANSCRIPT_LIVENESS_SECONDS to a new-store arm file's own transcript_path
# (R4-M2 / redteam MEDIUM-2). A stat FAILURE (missing transcript) is
# "undeterminable" and answers "live" -- but only for as long as the arm
# file ITSELF is fresh (F3 / red-team H2): treating a permanently-missing
# transcript as live forever is exactly how the wake-lock got held with no
# armed session anywhere -- once the arm file's own mtime passes the same
# one-hour window, a ghost arm (transcript gone) must stop counting. $armfile
# is optional; omitting it (or an unstat-able arm file) keeps the old
# fail-safe "live" answer, since there is then nothing to bound it by.
sub _transcript_path_is_live {
    my ($path, $armfile) = @_;
    return 1 unless defined $path && length $path;

    my @st = stat($path);
    unless (@st) {
        return 1 unless defined $armfile;
        my @ast = stat($armfile);
        return 1 unless @ast && defined $ast[9];
        my $age = time() - $ast[9];
        return 1 if $age < 0;
        return $age <= $TRANSCRIPT_LIVENESS_SECONDS ? 1 : 0;
    }

    my $age = time() - $st[9];
    return 1 if $age < 0;        # future mtime: clock skew, not evidence of death
    return $age <= $TRANSCRIPT_LIVENESS_SECONDS ? 1 : 0;
}

# ---------------------------------------------------------------------------
# any_active($dir) -> 0|1
#
# Batch C (spec 16-cutover, criterion C-6): the legacy registry is gone from
# this decision. Is ANY session on this machine currently armed, per the new
# store alone? Registry-wide, not per-session, because the lease is a
# machine-level resource: two armed sessions share one wake-lock, and the
# last one to disarm is what releases it. $dir is still the legacy registry
# path (callers resolve it the same way as before); store_root_for($dir)
# maps it to the new-store root new_store_active actually reads.
#
# _legacy_any_active and _marker_is_live (the old registry-only logic and its
# BpSession::find_transcript-based liveness filter) are deleted outright, not
# kept as a fallback: a fresh legacy-registry marker with an empty new store
# must answer 0, which is exactly what a fallback would have prevented.
sub any_active {
    my ($dir) = @_;
    my $root = store_root_for($dir);
    return new_store_active($root) if defined $root;
    return 0;
}

# ---------------------------------------------------------------------------
# live_arms($root) -> \@list of {sid, basis, age, role, workers}       (05)
#
# The loop body active_reason used to run inline, made reusable so package
# 05's journal can list every live session (not just the first) plus its
# role and its holder's worker ids. $root is the STATE ROOT directly (the
# same value store_root_for/new_store_active operate on), not the legacy
# continuity-active dir -- callers that hold a legacy dir resolve it via
# store_root_for first, exactly as active_reason does below.
sub live_arms {
    my ($root) = @_;
    my @out;
    return \@out unless defined $root && length $root;
    my $adir = "$root/armed";
    return \@out unless -d $adir;

    my $cutoff = time() - ttl_hours() * 3600;
    opendir(my $dh, $adir) or return \@out;
    my @entries = sort grep { /^[A-Za-z0-9_-]{1,128}$/ } readdir($dh);
    closedir $dh;

    for my $e (@entries) {
        my $f = "$adir/$e";
        next unless -f $f;
        my $tp = _arm_file_transcript_path($f);
        my ($live, $basis, $age);
        if (defined $tp) {
            my @st = stat($tp);
            if (@st) {
                $basis = 'transcript';
                $live  = _transcript_path_is_live($tp, $f);
                my $a  = time() - $st[9];
                $age   = $a < 0 ? 0 : $a;
            } else {
                $basis = 'transcript-missing';
                $live  = _transcript_path_is_live($tp, $f);
                my @ast = stat($f);
                if (@ast) { my $a = time() - $ast[9]; $age = $a < 0 ? 0 : $a } else { $age = 'unknown' }
            }
        } else {
            $basis = 'arm-mtime';
            my @ast = stat($f);
            if (@ast) {
                $live = (($ast[9] // 0) >= $cutoff) ? 1 : 0;
                my $a = time() - $ast[9];
                $age = $a < 0 ? 0 : $a;
            } else {
                $live = 0;
                $age  = 'unknown';
            }
        }
        next unless $live;

        my $role = 'unknown';
        my $raw = _slurp_small($f);
        if (defined $raw && length $raw) {
            my $data = eval { JSON::PP->new->utf8->decode($raw) };
            $role = $data->{role} if ref $data eq 'HASH' && defined $data->{role} && length $data->{role};
        }
        my $workers = [];
        my $hraw = _slurp_small("$root/holder/$e.json");
        if (defined $hraw && length $hraw) {
            my $hdata = eval { JSON::PP->new->utf8->decode($hraw) };
            $workers = $hdata->{items} if ref $hdata eq 'HASH' && ref $hdata->{items} eq 'ARRAY';
        }
        push @out, { sid => $e, basis => $basis, age => $age, role => $role, workers => $workers };
    }
    return \@out;
}

# active_reason($dir) -> undef | { sid, basis, age, arms }     (package 04)
#
# Re-expressed (package 05) as "first of live_arms plus arms => scalar
# @list", exactly as spec 2.5 requires -- its own observable output
# (sid/basis/age/arms only, no role/workers) is unchanged. Invariant:
# any_active($dir) == (defined active_reason($dir) ? 1 : 0) for every fixture.
sub active_reason {
    my ($dir) = @_;
    my $root = store_root_for($dir);
    return undef unless defined $root && length $root;
    my $list = live_arms($root);
    return undef unless @$list;
    my $first = { sid => $list->[0]{sid}, basis => $list->[0]{basis}, age => $list->[0]{age} };
    $first->{arms} = scalar @$list;
    return $first;
}

# ---------------------------------------------------------------------------
# IN FLIGHT, OR ONLY WAITING FOR THE OPERATOR -- what the lock follows.
#
# A live arm used to hold the machine awake for as long as it counted as live
# (its transcript written within the hour). That kept a machine awake after
# the work had ended, for no one: the operator's requirement (2026-10-29,
# after a hand-run caffeinate held a lid-closed Mac awake from 23:01, when the
# work finished, to 08:52) is that the lock follows WORK, not the arm.
#
# Continuity has no "armed, waiting for the operator" state to read: the Stop
# gate never lets an armed session end a turn unless a live holder will wake
# it, and the skill's path for "nothing can proceed without the operator" is
# to turn continuity off, which releases the lock at once. What does happen is
# an arm whose session is doing nothing: its turn ended by an interrupt, an API
# or usage-limit error or a crash, or it sits on a permission prompt. Nothing
# is in flight there, and only the operator can move it. So an arm has work in
# flight when either:
#
#   holder    its butler-hold holder is live (BpHook::holder_live): a hold that
#             will wake the session, over background work it names;
#   activity  its session wrote its transcript, a subagent transcript, or its
#             arm file within $IN_FLIGHT_QUIET_SECONDS: it is mid-turn (a
#             driver run between director ticks is one of these two as well).
#
# and every other live arm is only waiting for the operator. The lock is held
# while ANY live arm has work in flight, released while every one is waiting,
# and taken again on the refresher's first tick after work resumes: the
# refresher keeps running for as long as an arm is live (live_arms, the
# one-hour window), whether the lock is held or not.
#
# THE QUIET WINDOW is 20 minutes: the longest silence a working turn can have
# is one tool call or one model response, and the Bash tool's own ceiling is
# 10 minutes (a foreground subagent writes its own transcript, which counts).
# Twice that leaves headroom without holding an idle machine for the hour the
# old rule did. A false "waiting" while a turn really runs is the expensive
# mistake (a lid-closed Mac on AC sleeps the moment the assertion goes), so
# the window errs long.
#
# This never touches the arm itself: disarming stays the operator's or the
# judged two-step's business (.ccpraxis-local-data/guidance/
# only-the-operator-ends-a-run.md). It decides only whether the lock is held.
our $IN_FLIGHT_QUIET_SECONDS = 1200;

# _holder_running($root, $sid) -> 0|1 -- BpHook::holder_live's own answer for
# this arm's holder, asked as a plain (non-coordinator) session whatever role
# the calling process has. holder_live reads BpHook::state_dir(), which IS the
# store the lease reads in production (store_root_for); a test that points the
# lease at another root has no holder to ask about there, so that is 0.
sub _holder_running {
    my ($root, $sid) = @_;
    my $ok = eval { require "$DIR/BpHook.pm" unless defined &BpHook::holder_live; 1 };
    return 0 unless $ok;
    local $ENV{BP_LEDGER};
    local $ENV{BP_ROLE};
    my $hroot = BpHook::state_dir();
    return 0 unless defined $hroot && defined $root;
    (my $x = $hroot) =~ s{/+\z}{};
    (my $y = $root)  =~ s{/+\z}{};
    return 0 unless $x eq $y;
    return eval { BpHook::holder_live($sid, {}) } ? 1 : 0;
}

# _activity_age($root, $sid) -> seconds since this arm's session last wrote
# anything the lease can see: the arm file (written by `on`, touched by every
# Stop), the transcript, and the subagent transcripts beside it
# (<transcript dir>/<sid>/subagents/agent-*.jsonl). undef when none exists.
sub _activity_age {
    my ($root, $sid) = @_;
    my $af = "$root/armed/$sid";
    my @m = ((stat $af)[9]);
    my $tp = _arm_file_transcript_path($af);
    if (defined $tp) {
        utf8::encode($tp) if utf8::is_utf8($tp);
        $tp =~ tr{\\}{/};
        push @m, (stat $tp)[9];
        (my $d = $tp) =~ s{/[^/]*\z}{};
        my $sub = "$d/$sid/subagents";
        if (opendir(my $dh, $sub)) {
            for my $e (readdir $dh) {
                next unless $e =~ /\Aagent-[A-Za-z0-9_-]{1,64}\.jsonl\z/;
                push @m, (stat "$sub/$e")[9];
            }
            closedir $dh;
        }
    }
    my ($newest) = sort { $b <=> $a } grep { defined } @m;
    return undef unless defined $newest;
    my $age = time() - $newest;
    return $age < 0 ? 0 : $age;
}

# arm_in_flight($root, $sid) -> ('activity' | 'holder' | undef, $quiet_age)
# Activity is asked first: it is a few stats, while the holder check may run
# one `ps` on macOS (BpHook::start_fp).
sub arm_in_flight {
    my ($root, $sid) = @_;
    my $age = _activity_age($root, $sid);
    return ('activity', $age) if defined $age && $age <= $IN_FLIGHT_QUIET_SECONDS;
    return ('holder', $age) if _holder_running($root, $sid);
    return (undef, $age);
}

# lease_verdict($dir) -> ($verdict, \%detail) -- THE decision every lease
# actuator follows (converge, for every caller that is not the refresher, and
# the refresher's own tick):
#
#   'idle'     no live arm at all: release, and the refresher exits.
#   'held'     a live arm has work in flight. %detail: reason (active_reason's
#              shape, naming the arm in flight), why ('activity' | 'holder').
#   'waiting'  live arms, none in flight: every one is only waiting for the
#              operator. Release, but keep the refresher. %detail: arms,
#              quiet (the shortest quiet age among them).
sub lease_verdict {
    my ($dir) = @_;
    my $root = store_root_for($dir);
    return ('idle', {}) unless defined $root && length $root;
    my $list = live_arms($root);
    return ('idle', {}) unless @$list;
    my $quiet;
    for my $arm (@$list) {
        my ($why, $age) = arm_in_flight($root, $arm->{sid});
        if (defined $why) {
            my $reason = { sid => $arm->{sid}, basis => $arm->{basis}, age => $arm->{age}, arms => scalar @$list };
            return ('held', { reason => $reason, why => $why });
        }
        $quiet = $age if defined $age && (!defined $quiet || $age < $quiet);
    }
    return ('waiting', { arms => scalar @$list, quiet => $quiet });
}

# ---------------------------------------------------------------------------
# code_snapshot() -> { abs_path => mtime }                     (package 04)
# code_changed(\%snap, $now?) -> path | undef
#
# The refresher's own liveness-of-code check (spec 2.2/2.3). code_changed
# returns the first path (sorted) whose mtime differs from the snapshot AND
# is at least 2s old, so a half-written file mid-promotion never triggers a
# handover before it finishes compiling.
sub code_snapshot {
    my %snap;
    # Separators FIRST, then abs_path -- __FILE__ can carry backslashes on
    # Windows. Same shape as BpTurnCaps::script_dir_for; asserted repo-wide by
    # turn-cap-consistency.t's C9.
    (my $self = __FILE__) =~ s{\\}{/}g;
    my $own = Cwd::abs_path($self) // $self;
    $own =~ s{\\}{/}g;
    my @st = stat($own);
    $snap{$own} = $st[9] if @st;
    _snapshot_add_new(\%snap);
    return \%snap;
}

sub _snapshot_add_new {
    my ($snap) = @_;
    for my $inc (values %INC) {
        my $abs = Cwd::abs_path($inc) // $inc;
        $abs =~ s{\\}{/}g;
        next unless index($abs, $DIR) == 0;
        next if exists $snap->{$abs};
        my @st = stat($abs);
        $snap->{$abs} = $st[9] if @st;
    }
    return;
}

sub code_changed {
    my ($snap, $now) = @_;
    $now = defined $now ? $now : time();
    for my $path (sort keys %$snap) {
        my @st = stat($path);
        next unless @st;
        next if $st[9] == $snap->{$path};
        next unless ($now - $st[9]) >= 2;
        return $path;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# live_script_path() -> abs path | undef                        (package 04)
# is_live_script($path) -> 0|1
sub live_script_path {
    my $override = $ENV{CCPRAXIS_LEASE_LIVE_SCRIPT};
    if (defined $override && length $override) {
        return _is_abs_legacy($override) ? $override : undef;
    }
    my $plat = platform();
    return undef if $plat eq 'unsupported';
    my $suffix = host_wakelock()
        ? '.claude/ccpraxis/plugins/butler/scripts/BpContinuityLease.pm'
        : '.claude/plugins/marketplaces/ccpraxis-local/butler/scripts/BpContinuityLease.pm';
    for my $var (qw(HOME USERPROFILE)) {
        my $val = $ENV{$var};
        next unless _is_abs_legacy($val);
        (my $v = "$val/$suffix") =~ tr{\\}{/};
        return $v if -f $v;
        return undef;
    }
    return undef;
}

sub is_live_script {
    my ($path) = @_;
    my $live = live_script_path();
    return 1 unless defined $live;
    my $a = Cwd::abs_path($path) // $path;
    my $b = Cwd::abs_path($live) // $live;
    $a =~ tr{\\}{/}; $b =~ tr{\\}{/};
    # Case-folded where the filesystem folds case: NTFS, and APFS (whose
    # abs_path keeps whatever case it was typed with).
    return host_wakelock() ? ((lc($a) eq lc($b)) ? 1 : 0) : (($a eq $b) ? 1 : 0);
}

# ---------------------------------------------------------------------------
# lease_log($dir, $event, $detail)                              (package 04)
#
# Best effort, never dies: a lease.log that cannot be written must not take
# the lease down with it (see the edge case in the spec). ASCII-forced: any
# byte outside \x20-\x7e in $detail becomes '?'.
sub lease_log {
    my ($dir, $event, $detail) = @_;
    return unless defined $dir && length $dir;
    eval {
        my $path = "$dir/lease.log";
        if (-e $path && ((stat($path))[7] // 0) > $LEASE_LOG_MAX_BYTES) {
            unlink "$path.1";
            rename($path, "$path.1");
        }
        my @t = localtime(time);
        my $ts = sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
        my $d = defined $detail ? $detail : q{};
        $d =~ s/[^\x20-\x7e]/?/g;
        open(my $fh, '>>', $path) or return;
        print {$fh} "$ts pid=$$ $event $d\n";
        close $fh;
    };
    return;
}

# _owner_desc_for($reason_data) -> string | undef                (package 04)
sub _owner_desc_for {
    my ($r) = @_;
    return undef unless ref $r eq 'HASH';
    my $raw = sprintf('continuity-lease,sid=%s,arms=%d', $r->{sid} // q{}, $r->{arms} // 0);
    return BpKeepAwake::owner_desc_clean($raw);
}

# ---------------------------------------------------------------------------
# state($dir) -> 'held' | 'released' | 'starting' | 'standby' | 'unsupported'
#
# What is ACTUALLY asserted right now, read off the artifacts — not what the
# registry says ought to be. The distinction is the whole discipline of
# bp-keepawake.pl's header ("degrades honestly ... never a false claim of
# holding one"): a status line that reports the intent would say "held" on a
# machine whose helper died an hour ago, which is worse than saying nothing.
sub state {
    my ($dir, %opts) = @_;
    return 'released' unless defined $dir && length $dir;
    my $plat = platform();
    return 'unsupported' if $plat eq 'unsupported';

    if (host_wakelock()) {
        my $pf = wakelock_pid_file($dir);
        return 'released' unless -e $pf;
        # An empty pid file is BpKeepAwake's atomic claim and the helper has not
        # written itself into it yet. That is a lock COMING UP, and calling it
        # "released" would make `status` warn about a degradation that is about
        # to resolve itself a second later.
        if (-z $pf) {
            my $age = time - ((stat($pf))[9] // 0);
            return 'starting' if $age >= 0 && $age < BpKeepAwake::starting_grace_seconds();
            return 'released';
        }
        my $alive = $opts{pid_alive} // \&BpKeepAwake::pid_alive;
        my $pid = BpKeepAwake::read_pid($pf);
        return 'released' unless defined $pid && $alive->($pid);
        # A live macOS holder off AC power asserts nothing: it stands by until
        # AC returns (KeepAwake::hold_main). Saying "held" then would be the
        # false claim this function exists to avoid.
        if ($plat eq 'darwin') {
            my $hs = BpKeepAwake::holder_state($pf);
            return 'standby' if defined $hs && $hs eq 'standby';
        }
        return 'held';
    }

    my $bp = $opts{busy_path} // busy_path();
    return 'released' unless -e $bp;
    my $age = time - ((stat($bp))[9] // 0);
    return ($age < $BUSY_STALE_SECONDS) ? 'held' : 'released';
}

# ---------------------------------------------------------------------------
# refresh($dir) -> 0|1 — THE CHEAP PATH: stats, utimes and, in a container,
# one small atomic rewrite of the busy lease (touch_busy); it starts no
# process and kills none.
#
# Its only caller is converge()'s armed branch; converge runs from the Stop
# gate's G7 and from butler-continuity. It re-asserts the heartbeat of
# whatever is already running; it never decides to start or stop anything.
# That separation is why the gate can refresh on every single Stop without
# paying the tasklist/powershell process cost that sync() can incur.
sub refresh {
    my ($dir, %opts) = @_;
    my $did = 0;
    my $now = time;

    my $plat = platform();
    return 0 if $plat eq q{unsupported};   # nothing here reads either lease

    if (host_wakelock()) {
        # keep-awake.ps1 (and the macOS holder) polls this file's mtime and
        # exits once it goes stale.
        # Touching it is the whole of "a run still wants this". If it is absent
        # the helper is not running, and only sync() may start one.
        #
        # AN EMPTY FILE IS NOT TOUCHED. That is BpKeepAwake's atomic claim,
        # waiting for a helper that has not written its pid yet, and its age is
        # the only thing that can ever expire it ($STARTING_GRACE_SECONDS).
        # Refreshing it would freeze a claim whose helper died at birth into a
        # permanent "starting", and nothing would ever replace it.
        my $pf = wakelock_pid_file($dir);
        if (-s $pf) { utime($now, $now, $pf); $did = 1 }
    } else {
        # In a container this rewrites the small lease file (see touch_busy
        # below); it still starts and kills no process.
        $did = touch_busy($opts{busy_path} // busy_path()) ? 1 : $did;
    }
    return $did;
}

# touch_busy($path) — writes the arm's intent
# ({"v":1,"awake":1,"reason":"armed","until":null,"written_at":<epoch>})
# through BpAwakeIntent::lease_line/arm_intent, with the same temp+rename+
# utime write and fallback as bp-orchestrator.pl's own touch_busy (against
# the same file: last writer's reason wins, both always write awake=1). It
# is only ever called while an arm is live (sync's $active branch, refresh
# via converge's armed branch) — Decision 12 (never write awake=0) never
# needs enforcing here because lease_line cannot produce such a line.
sub touch_busy {
    my ($path) = @_;
    return 0 unless defined $path && length $path;
    my $d = dirname($path);
    make_path($d) unless -d $d;
    my $now = time;

    # Addendum A (A.2.6): BpAwakeIntent may have failed to load (eval-guarded
    # require above) -- then neither sub exists, $line stays undef, and step
    # 4 below is skipped outright (no temp file is even attempted) straight
    # to the fallback.
    my $line;
    if (defined &BpAwakeIntent::lease_line && defined &BpAwakeIntent::arm_intent) {
        $line = eval { BpAwakeIntent::lease_line(BpAwakeIntent::arm_intent(), $now) };
    }

    if (defined $line) {
        my $tmp   = "$path.tmp.$$";
        my $wrote = 0;
        if (open(my $fh, '>:raw', $tmp)) {
            if (print({$fh} $line) && close($fh) && rename($tmp, $path)) {
                $wrote = 1;
            }
        }
        if ($wrote) {
            utime $now, $now, $path;
            return 1;
        }
        unlink $tmp if -f $tmp;
    }
    # FALLBACK = today's touch, byte-for-byte in effect: create-if-absent
    # EMPTY (never truncates existing content), then bump mtime. Reached
    # either from a failed temp write above or directly when BpAwakeIntent
    # could not supply a line at all.
    unless (-e $path) { open my $fh, '>', $path or return 0; close $fh; }
    utime $now, $now, $path;
    return 1;
}

# ---------------------------------------------------------------------------
# sync($dir, %opts) -> 'held' | 'released'   — THE DECIDING PATH.
#
# %opts:
#   active   — force the verdict (skips any_active); used by the CLI and tests
#   plus every seam BpKeepAwake::apply accepts (spawn/kill_pid/
#   powershell_available/log), passed straight through so tests never actuate.
#
# ONLY THE REFRESHER CALLS THIS WITH active => 1. Non-daemon callers go through
# converge() instead, which refreshes and delegates starting to the daemon. One
# process may start the wake-lock helper; everything else only ever re-asserts
# or releases. Measured 2026-09-15, before that rule existed: three `arm`s in
# the same instant plus a refresher left FIFTEEN live keep-awake.ps1 helpers and
# a pid file that survived disarm, because each caller independently decided the
# lock was missing while a helper was still starting. BpKeepAwake::apply now
# claims the pid file atomically, which closes the same race one level down —
# both are needed: the claim makes a double start impossible, and this rule
# means it is not attempted in the first place.
#
# NOTE WHAT RELEASE DOES **NOT** DO: it never unlinks the busy-lease. That file
# is SHARED with bp-orchestrator.pl, so deleting it on disarm would cancel a
# live fleet run's own lease and invite heartbeat.sh to reap the container out
# from under it. Letting it go stale is the orchestrator's own contract for
# "idle" and is the only safe release for a shared heartbeat: worst case the
# container stays protected for one BUSY window (600s) after disarm.
sub sync {
    my ($dir, %opts) = @_;
    return 'released' unless defined $dir && length $dir;
    my $active = exists $opts{active} ? ($opts{active} ? 1 : 0) : any_active($dir);

    my $plat = platform();
    return ($active ? q{held} : q{released}) if $plat eq q{unsupported};

    if (host_wakelock()) {
        my %ka = map { $_ => $opts{$_} }
                 grep { exists $opts{$_} }
                 qw(spawn kill_pid powershell_available log owner_winpid owner_desc);
        BpKeepAwake::apply($active ? 'active' : 'settled', $dir, \%ka);
    } elsif ($active) {
        touch_busy($opts{busy_path} // busy_path());
    }
    return $active ? 'held' : 'released';
}

# ---------------------------------------------------------------------------
# converge($dir, %opts) -> ($verdict, $holder)
#   $verdict : 'held' | 'released'  — what the lease was converged TOWARD.
#   $holder  : ensure_daemon's verdict, or 'idle' when nothing is armed.
#
# FOLLOWS lease_verdict: held while a live arm has work in flight; released
# when nothing is armed ('idle') AND when every live arm is only waiting for
# the operator -- the latter keeps (or starts) a refresher, so the lock is
# taken again on its first tick after work resumes.
#
# Both come back from ONE call on purpose. A caller that wanted the holder label
# and asked ensure_daemon again would do so in the second before a just-spawned
# daemon has written its pid file — and a second look at a missing pid file
# starts a second daemon. That is the same shape as the helper storm this file
# already documents, so the value is returned rather than re-derived.
#
# THE VERB EVERY NON-DAEMON CALLER USES — arm, disarm, the repair verb, the Stop
# gate. It says what the lease should be and gets it there, without ever being
# the thing that starts the wake-lock helper (see sync's header for the storm
# that rule exists to prevent).
#
# Armed:   re-assert whatever is already running (pure stat + utime), and make
#          sure a refresher exists. The refresher starts the helper on its first
#          tick, about a second later. In a sandbox the protection is immediate
#          either way, because there the lease IS the file we just touched.
# Unarmed: release directly. Releasing starts nothing and is idempotent, so any
#          caller may do it — and `off` should take effect now, not at whatever
#          point a background process next happens to look.
sub converge {
    my ($dir, %opts) = @_;
    return ('released', 'idle') unless defined $dir && length $dir;
    my ($verdict) = lease_verdict($dir);
    if ($verdict eq 'held') {
        refresh($dir, %opts);
        return ('held', ensure_daemon($dir, %opts));
    }
    # Package 08-host-awake-actuator: never release the daemon's helper
    # while a registry source counts (sandbox/fleet/solo) -- that would
    # drop the one host lock a counting source is relying on, with nobody
    # else about to notice until its own next refresh.
    if (@{ sources_counting($dir) }) {
        return ('held', ensure_daemon($dir, %opts));
    }
    sync($dir, %opts, active => 0);
    return ('released', 'idle') if $verdict eq 'idle';
    return ('released', ensure_daemon($dir, %opts));
}

# holds_pending($dir, %o) -> 0|1                       (package 02-plan-hold-expiry)
#
# Is there a sandbox hold file -- fresh or stale -- that nothing has pruned
# yet? Windows-only (a sandbox keeps itself alive through its own busy-lease,
# never through a hold file it would be reading about itself), and only when
# $dir resolves to the real store (store_root_for), the same guard any_active
# already applies. BpPowerPlan is loaded lazily, with the same %INC-guard
# idiom run_plan_step uses below -- not required at file scope, because that
# would make THIS file require BpPowerPlan.pm unconditionally while
# BpPowerPlan.pm already requires this one unconditionally (see its own
# header), which is fine on its own but is simply never exercised off the one
# path (a tick) that genuinely needs it.
#
# %o: skip => \%names, a hashref of hold names already known to be stuck
# (prune failed in this process) -- a name in it never counts toward keeping
# the refresher alive again (spec 2.3, B11).
#
# Never dies: a load failure, a missing root, or any other surprise all
# answer 0 rather than propagate, same discipline as any_active/active_reason.
sub holds_pending {
    my ($dir, %o) = @_;
    my $result = eval {
        return 0 unless platform() eq 'windows';
        my $root = store_root_for($dir);
        return 0 unless defined $root && length $root;
        require "$DIR/BpPowerPlan.pm" unless grep { m{(?:^|/)BpPowerPlan\.pm$} } keys %INC;
        my $skip = (ref $o{skip} eq 'HASH') ? $o{skip} : {};
        my $files = BpPowerPlan::sandbox_hold_files($root);
        for my $f (@$files) {
            return 1 unless exists $skip->{$f};
        }
        return 0;
    };
    return $@ ? 0 : ($result // 0);
}

# sources_pending($dir, %o) -> 0|1       (package 08-host-awake-actuator)
#
# holds_pending's own shape, for the new registry: is there at least one
# <id>.json file (valid or not -- a garbled one still pins a HOLD tick until
# pruned, B22) whose id is not in $o{skip}? Windows-platform only, and only
# when $dir resolves to the real store, same guards holds_pending applies.
# HostAwake.pm is loaded lazily with the symbol-table guard every lazy
# require in this file uses (BpPowerPlan's own header explains why an %INC
# guard is wrong here). Never dies: 0 on any failure.
sub sources_pending {
    my ($dir, %o) = @_;
    my $result = eval {
        return 0 unless platform() eq 'windows';
        my $root = store_root_for($dir);
        return 0 unless defined $root && length $root;
        require "$DIR/HostAwake.pm" unless defined &HostAwake::publish;
        my $skip = (ref $o{skip} eq 'HASH') ? $o{skip} : {};
        my $entries = HostAwake::read_registry($root);
        for my $e (@$entries) {
            return 1 unless exists $skip->{$e->{id}};
        }
        return 0;
    };
    return $@ ? 0 : ($result // 0);
}

# sources_counting($dir) -> [ids]        (package 08-host-awake-actuator)
#
# converge's own question: which registry entries actually count RIGHT NOW
# (entry_counts, not merely present)? Windows-platform only; [] on any
# failure or off Windows, same discipline as holds_pending/sources_pending.
sub sources_counting {
    my ($dir) = @_;
    my $result = eval {
        return [] unless platform() eq 'windows';
        my $root = store_root_for($dir);
        return [] unless defined $root && length $root;
        require "$DIR/HostAwake.pm" unless defined &HostAwake::publish;
        return HostAwake::counting_ids($root, time());
    };
    return (ref $result eq 'ARRAY') ? $result : [];
}

# ---------------------------------------------------------------------------
# ensure_daemon($dir, %opts) -> 'running' | 'spawned' | 'idle' | 'refused'
#
# Idempotent. LIVENESS IS THE PID FILE'S MTIME, AND ONLY THAT — the recorded pid
# is written for a human to act on, never read back as a liveness test.
#
# Measured on this host, 2026-09-15: a daemon started through fork+exec from
# Git-for-Windows perl recorded $$ = 16818, and `tasklist /FI "PID eq 16818"`
# reported no such task while the process was demonstrably alive and ticking.
# MSYS perl's $$ is an MSYS pid, not a Windows one, so neither kill(0) nor
# tasklist can validate it — the same asymmetry BpKeepAwake::_pid_alive works
# around for the PowerShell helper, except there the helper writes its OWN real
# Windows pid and here there is no equivalent to write.
#
# Trusting that pid would have made every check say "dead" and spawn another
# daemon on every call — the precise shape of the 2026-08-13 leak. The heartbeat
# answers the question that actually matters ("is something still refreshing
# this?"), means the same thing on every platform, costs one stat, and is the
# same signal this sub's own heartbeat check reads below -- the Stop gate never
# reads lease.pid itself; it reaches this check through converge (addendum
# A.3.5, reviewer NIT-1: stop-gate.sh mentions neither).
sub ensure_daemon {
    my ($dir, %opts) = @_;
    return 'refused' unless defined $dir && length $dir;

    # An explicit "hold nothing" wins over every other consideration. Note this
    # is the DECISION layer: the test guard that stops a real process ever being
    # started lives in _spawn_daemon, one level down, exactly as BpKeepAwake
    # puts its own in spawn() rather than in apply(). Guarding the decision as
    # well would make the decision itself untestable.
    return 'refused' if $ENV{CCPRAXIS_NO_WAKELOCK};

    # Nothing armed, no sandbox hold pending, and no registry source entry
    # pending (package 08-host-awake-actuator's three-way gate): nothing to
    # refresh. Without this, the repair verb (`lease`) and `status` would
    # each start a daemon whose entire life is to notice it has no reason to
    # exist — harmless, but a process spawned per call on paths that run
    # routinely, and a 'spawned' that reads as if something is now being held
    # when nothing is.
    #
    # holds_pending is the package 02-plan-hold-expiry half of its own
    # mechanism: a launcher's `--hold` tick must be able to start a refresher
    # with NO host arm live, or a crashed launcher's stale hold would never be
    # reconciled again (nothing else re-runs reconcile without one).
    # sources_pending is the same idea for 08's registry: a sandbox, fleet or
    # solo entry with no host arm must still be able to start a refresher.
    # Short-circuited in this order (any_active, then holds_pending, then
    # sources_pending) so an armed caller never loads BpPowerPlan or
    # HostAwake.pm at all.
    return 'idle' unless any_active($dir) || holds_pending($dir) || sources_pending($dir);

    my $pf = daemon_pid_file($dir);
    if (-e $pf) {
        my $age = time - ((stat($pf))[9] // 0);
        # A NEGATIVE age is a heartbeat stamped in the future — a clock jumped
        # backwards, or a registry on a filesystem with its own clock. It is not
        # evidence of life, and reading it as "very fresh" would let a DEAD
        # refresher look healthy for the whole skew, which is the failure with
        # no floor: no lease, nothing to notice, nothing to repair it. Treated
        # as stale instead, and a needless respawn costs nothing — the flock
        # turns it into an immediate, silent exit.
        return 'running' if $age >= 0 && $age < tick_seconds() * $STALE_TICKS;
    }

    # 'spawned' only if something really came back. _spawn_daemon returns undef
    # when its test guard fires, and reporting 'spawned' there would be the
    # false claim of holding a lock this whole file is written to avoid.
    my $spawn = $opts{spawn} // \&_spawn_daemon;
    my $pid = eval { $spawn->($dir) };
    return (!$@ && defined $pid) ? 'spawned' : 'refused';
}

# --- Addendum A (step 7, plan-hold-expiry spec): a console-detached spawn on
# Windows. MEASURED on this host (driver, 2026-11-04): a plain fork+exec
# child of Git-for-Windows perl, parented by the launcher's console, dies in
# the same second the console is closed (CloseMainWindow) -- that held for a
# plain child, one that called POSIX::setsid(), and one with
# $SIG{HUP}='IGNORE'. CTRL_CLOSE is a console event, not a POSIX session or
# signal matter, so none of those survive. A child started by
# `powershell -NoProfile -NonInteractive -EncodedCommand ...` running
# `Start-Process -WindowStyle Hidden` (its own hidden console) was measured
# to survive 12s past the close and to inherit the caller's environment, so
# it is the Windows branch below. posix and unsupported are unchanged: they
# have no console to lose in the first place.
#
# The helpers below are split pure/orchestration/effector on purpose: the
# pure ones (_spawn_method, _native_exe_path, _detached_spawn_argv,
# _parse_spawned_pid) decide and build without ever spawning, so a test can
# call them directly; _spawn_daemon_impl takes its spawners as arguments, so
# a test can inject recorders in place of _run_detached/_fork_exec_daemon
# without ever starting a real process; the real production path stays in
# _spawn_daemon.
# ---------------------------------------------------------------------------

# _spawn_method(%a) -> 'detached' | 'fork' | 'fork-setsid' -- pure.
# a: platform => 'windows'|'posix'|'unsupported', ps_available => 0|1,
#    perl_win => string|undef.
sub _spawn_method {
    my (%a) = @_;
    return 'fork-setsid' unless defined $a{platform} && $a{platform} eq 'windows';
    return 'detached' if $a{ps_available} && defined $a{perl_win} && length $a{perl_win};
    return 'fork';   # windows, but no powershell or no usable native perl path:
                      # today's Windows behaviour, kept so this change can
                      # never leave a host with NO refresher where it had one.
}

# _native_exe_path($path) -> 'X:/.../name.exe' | undef -- pure (apart from
# whether Cygwin::posix_to_win_path exists). The Windows form of a perl
# binary, for Start-Process -FilePath, which Windows (not MSYS) resolves.
# Mirrors MountSpec::native_path's technique, restated here because butler
# must not require anything from plugins/sandbox.
sub _native_exe_path {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    (my $p = $path) =~ s{\\}{/}g;

    my $win;
    if ($p =~ m{\A[A-Za-z]:/}) {
        $win = $p;
    } elsif ($p =~ m{\A/}) {
        if (defined &Cygwin::posix_to_win_path) {
            my $converted = eval { Cygwin::posix_to_win_path($p, 1) };
            return undef unless defined $converted;
            (my $c = $converted) =~ s{\\}{/}g;
            return undef unless $c =~ m{\A[A-Za-z]:/};
            $win = $c;
        } elsif ($p =~ m{\A/([A-Za-z])/(.*)\z}) {
            $win = uc($1) . ':/' . $2;
        } else {
            return undef;
        }
    } else {
        # A relative path or a bare "perl" is never handed to a native
        # binary: Windows would resolve it against the current drive. A bare
        # name is what $^X is when perl was started as `perl script` (the host
        # hooks start it that way), so resolve it through the interpreter's
        # own absolute install path instead of giving up on detaching
        # (driver ruling, amending spec Addendum A.2 step 5).
        require Config;
        my $abs = $Config::Config{perlpath};
        return undef unless defined $abs && $abs =~ m{\A(?:/|[A-Za-z]:[\\/])};
        return _native_exe_path($abs);
    }

    $win .= '.exe' unless $win =~ /\.exe\z/i;
    return $win;
}

# _q_escape($s) -- PowerShell single-quoted-literal escaping: every ' doubled.
sub _q_escape { my ($s) = @_; (my $r = $s) =~ s/'/''/g; return $r }

# _detached_spawn_argv($perl_win, $script) -> @argv | () -- pure. The exact
# argv of the transient powershell, or the empty list when it refuses.
sub _detached_spawn_argv {
    my ($perl_win, $script) = @_;
    return () unless defined $perl_win && length $perl_win;
    return () unless defined $script && length $script;
    return () unless $perl_win =~ m{\A[A-Za-z]:/};
    for my $s ($perl_win, $script) {
        return () if $s =~ /["\x00-\x1f]/;
    }
    my ($perl_u, $script_u);
    {
        local $@;
        $perl_u   = eval { decode('UTF-8', $perl_win, Encode::FB_CROAK) };
        return () if $@;
        $script_u = eval { decode('UTF-8', $script,   Encode::FB_CROAK) };
        return () if $@;
    }

    # $script is passed in the parent perl's own spelling (e.g. "/c/...") --
    # the child is the same MSYS/Cygwin perl binary and resolves that form
    # itself, so __FILE__/is_live_script see what they see today. Only
    # -FilePath (read by Windows, not MSYS) gets the Windows form.
    my $arglist = qq{"$script_u" lease --daemon};
    my $text = "\$ErrorActionPreference = 'Stop'; \$p = Start-Process -FilePath '"
        . _q_escape($perl_u) . "' -ArgumentList '" . _q_escape($arglist)
        . "' -WindowStyle Hidden -PassThru; [Console]::Out.Write([string]\$p.Id)";

    # -EncodedCommand, not a quoted -Command string: no element of this argv
    # can be rewritten by MSYS2 argument conversion in either conversion
    # state (none starts with /, none contains : or ;; base64 of UTF-16LE
    # text beginning with $ begins with J). MSYS2_ARG_CONV_EXCL is therefore
    # neither set nor cleared here -- the child inherits whatever the caller
    # had, as it does today. It also carries non-ASCII and ' byte-exactly,
    # with no Windows command-line quoting rules involved.
    #
    # No -WindowStyle on the transient itself: it shares the caller's
    # console, and -WindowStyle Hidden there would hide/minimise the
    # OPERATOR'S terminal (the bug-20261102 shape MountSpec's own comment
    # records). Only the grandchild, through Start-Process, gets Hidden.
    my $bytes = encode('UTF-16LE', $text);
    my $b64   = encode_base64($bytes, '');
    return ('powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand', $b64);
}

# _parse_spawned_pid($out, $status) -> winpid | undef -- pure.
sub _parse_spawned_pid {
    my ($out, $status) = @_;
    return undef unless defined $status && $status == 0;
    return undef unless defined $out;
    (my $t = $out) =~ s/\A\s+//;
    $t =~ s/\s+\z//;
    return $t =~ /\A[1-9]\d{0,9}\z/ ? $t : undef;
}

# _spawn_daemon_impl(%d) -> pid | undef -- orchestration, deps injected.
# d: script, platform, ps_available, perl_win,
#    run_detached => CODE(\@argv) -> pid|undef,
#    fork_exec    => CODE($script, $setsid) -> pid   (may die, as today)
sub _spawn_daemon_impl {
    my (%d) = @_;
    my $m = _spawn_method(platform => $d{platform}, ps_available => $d{ps_available}, perl_win => $d{perl_win});
    if ($m eq 'detached') {
        my @argv = _detached_spawn_argv($d{perl_win}, $d{script});
        if (@argv) {
            my $pid = eval { $d{run_detached}->(\@argv) };
            return $pid if defined $pid && $pid =~ /\A[1-9]\d*\z/;
        }
        # The detached attempt failed (argv refused, powershell missing at
        # run time, non-zero exit, no pid printed): fall back to today's
        # attached fork+exec. A refresher that dies with its console is
        # still better than none. If powershell DID start a child but its
        # pid output was lost, this fallback spawn loses the existing flock
        # and exits 'duplicate', so no double refresher results.
        return $d{fork_exec}->($d{script}, 0);
    }
    return $d{fork_exec}->($d{script}, $m eq 'fork-setsid' ? 1 : 0);
}

# _run_detached(\@argv) -> winpid | undef -- production effector. A forking
# pipe open: the transient powershell exits as soon as Start-Process has
# returned (about a second), printing the grandchild's winpid to stdout; this
# never waits on the refresher itself.
sub _run_detached {
    my ($argv) = @_;
    require POSIX;
    my $pid = open(my $ph, '-|');
    return undef unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDERR, '>', '/dev/null');   # never NUL -- a hook's stderr must stay clean
        # The transient powershell, and the refresher daemon it starts (which
        # inherits this env and later spawns the keep-awake helper), must
        # never resolve PowerShell's module-analysis cache relative to cwd.
        eval { BpKeepAwake::pin_ps_analysis_cache() };
        exec(@$argv) or POSIX::_exit(127);
    }
    local $/;
    my $out = <$ph>;
    close $ph;
    return _parse_spawned_pid($out, $?);
}

# _fork_exec_daemon($script, $setsid) -> pid -- production effector. Today's
# _spawn_daemon fork body, unchanged in effect.
sub _fork_exec_daemon {
    my ($script, $setsid) = @_;
    require POSIX;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        # Leave the caller's process group where we can: a Bash tool call that
        # is interrupted must not take the wake-lock down with it. setsid is a
        # no-op concept on the Windows side, where exec() already yields an
        # independent process.
        eval { POSIX::setsid() } if $setsid;
        exec($^X, $script, 'lease', '--daemon') or POSIX::_exit(127);
    }
    return $pid;
}

# _spawn_daemon($dir) — detach a real, independent `lease --daemon` process.
#
# NOTHING IS PASSED ON THE COMMAND LINE ON PURPOSE. The registry directory is an
# absolute Windows path on the host ("C:/Users/.../.continuity-active"), and
# MSYS2 rewrites colon-bearing argv elements when a native binary is spawned —
# the class of corruption CLAUDE.md documents (mount specs becoming
# "HOST;CONTAINER", stray ";C" directories). The child resolves the directory
# through exactly the same env-based rule we did, so the argument is not needed
# and the hazard is simply not taken. Tests point both ends at a temp dir with
# CCPRAXIS_CONTINUITY_ACTIVE_DIR, which exec inherits.
sub _spawn_daemon {
    my ($dir) = @_;

    # A TEST MUST NEVER SPAWN AN IMMORTAL BACKGROUND HOLDER. Same rule, same
    # wording, same reason as BpKeepAwake::spawn: a leaked daemon outlives the
    # test that made it and keeps the machine awake forever. There is no prove
    # on this host, so every test is a .t run directly and $0 identifies it.
    # Tests that legitimately exercise the spawn DECISION inject their own seam
    # and never reach this sub. This stays the FIRST statement on purpose: a
    # test can never start a transient powershell or a refresher.
    return undef if defined $0 && $0 =~ /\.t\z/;

    # Batch C (spec 16-cutover, 1.3 departure #7): the old CLI script is on
    # the deletion list (batch E1); the daemon's entry point is this module's
    # own script main (see _script_main / spec 2.9), invoked with the same
    # `lease --daemon` argv it always used.
    my $script = "$DIR/BpContinuityLease.pm";
    die "continuity module missing: $script\n" unless -f $script;

    my $perl_win = is_windows() ? _native_exe_path($^X) : undef;
    $perl_win = undef if defined $perl_win && !-f $perl_win;

    return _spawn_daemon_impl(
        script       => $script,
        platform     => platform(),
        ps_available => (is_windows() ? BpKeepAwake::ps_available() : 0),
        perl_win     => $perl_win,
        run_detached => \&_run_detached,
        fork_exec    => \&_fork_exec_daemon,
    );
}

# _spawn_successor($script, $tick) — the default handover_spawn (package 04,
# spec 2.2/2.3). Same guards and stdio-to-/dev/null shape as _spawn_daemon; not
# gated by CCPRAXIS_NO_WAKELOCK (a successor's own BpKeepAwake::spawn still
# refuses under that opt-out, so no new holder is added). Inherits the calling
# refresher's %ENV unchanged -- the argument list carries no path, same reason
# as _spawn_daemon's own header.
sub _spawn_successor {
    my ($script, $tick) = @_;
    return undef if defined $0 && $0 =~ /\.t\z/;
    return undef unless defined $script && length $script && -f $script;
    require POSIX;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        my @args = ($^X, $script, 'lease', '--daemon', '--handover');
        push @args, '--tick', $tick if defined $tick;
        exec(@args) or POSIX::_exit(127);
    }
    return $pid;
}

# ---------------------------------------------------------------------------
# _script_main(@argv) — the module's own CLI entry (spec 2.9), so
# _spawn_daemon has somewhere to exec now that the old CLI script is deleted (E1).
#
#   lease --daemon [--tick N]   runs daemon_loop(legacy_dir(), tick => N) and
#                               exits 0. legacy_dir() undef prints one stderr
#                               line and exits 1 instead of looping forever
#                               against nothing.
#   anything else               one-line usage to stderr, exit 1.
# ---------------------------------------------------------------------------
sub _script_main {
    my ($class, @argv) = @_;
    if (@argv && $argv[0] eq 'lease' && grep { $_ eq '--daemon' } @argv[1 .. $#argv]) {
        my $tick;
        my $handover = 0;
        for my $i (1 .. $#argv) {
            $handover = 1 if $argv[$i] eq '--handover';
            next unless $argv[$i] eq '--tick';
            $tick = $argv[$i + 1] if defined $argv[$i + 1];
        }
        my $dir = legacy_dir();
        unless (defined $dir) {
            print STDERR "BpContinuityLease: no continuity registry directory resolvable (HOME/USERPROFILE unset)\n";
            return 1;
        }
        my %opts = defined $tick ? (tick => $tick) : ();
        $opts{handover} = 1 if $handover;
        daemon_loop($dir, %opts);
        return 0;
    }
    print STDERR "usage: perl BpContinuityLease.pm lease --daemon [--tick N] [--handover]\n";
    return 1;
}

# ---------------------------------------------------------------------------
# _handle_signal($reason, \$handing_over, $release, $log) — shared by both
# $SIG{TERM} and $SIG{INT} (AC-7: one common subroutine invoked by both).
# While a handover is in flight (H4 onward) NEITHER signal may run the release
# closure: the helper and the lock both belong to the successor now.
sub _handle_signal {
    my ($reason, $handing_over_ref, $release, $log, $exit_plan_step) = @_;
    if ($$handing_over_ref) {
        eval { $exit_plan_step->('refresher-signal') } if defined $exit_plan_step;
        $log->('EXIT', 'reason=signal-during-handover');
        exit 0;
    }
    eval { $exit_plan_step->('refresher-signal') } if defined $exit_plan_step;
    $release->($reason);
    exit 0;
}

# ---------------------------------------------------------------------------
# _do_handover(%a) -> 1 (handed-over) | 0 (continue as holder)
#
# Implements H1-H6 (spec 2.3). $a{lock_ref}/$a{locked_ref} are references to
# daemon_loop's own $lock/$locked so H4 can drop the flock and H6 can retake
# it. $a{handing_over_ref} is a reference to daemon_loop's $handing_over flag,
# read by the TERM/INT handlers through _handle_signal.
sub _do_handover {
    my (%a) = @_;
    my ($dir, $pf, $lock_ref, $locked_ref, $handing_over_ref, $reason, $file,
        $target, $tick, $spawn, $log, $own_script)
        = @a{qw(dir pf lock_ref locked_ref handing_over_ref reason file target tick spawn log own_script)};

    my $pid_f = wakelock_pid_file($dir);
    my $live_disp = defined $target ? $target : 'unresolved';
    $log->('HANDOVER-START', sprintf('reason=%s file=%s live=%s', $reason, $file, $live_disp));

    unlink "$dir/lease.handover";
    my $w_old = -e $pid_f ? BpKeepAwake::read_pid($pid_f) : undef;

    my $spawn_target = defined $target ? $target : $own_script;
    my $succ_pid = eval { $spawn->($spawn_target, $tick) };
    if ($@ || !defined $succ_pid) {
        $log->('HANDOVER-FAILED', 'reason=spawn-refused retry_in=600s');
        return 0;
    }

    my $ready = 0;
    my $deadline = time() + $HANDOVER_TIMEOUT_SECONDS;
    while (time() < $deadline) {
        if (-e "$dir/lease.handover") { $ready = 1; last }
        select(undef, undef, undef, 0.25);
    }
    unless ($ready) {
        $log->('HANDOVER-FAILED', 'reason=successor-not-ready retry_in=600s');
        return 0;
    }

    $$handing_over_ref = 1;
    close $$lock_ref if $$locked_ref;
    $$locked_ref = 0;

    my $done_lock   = 0;
    my $done_helper = 0;
    my $successor_pid;
    $deadline = time() + $HANDOVER_TIMEOUT_SECONDS;
    while (time() < $deadline) {
        my $lp = BpKeepAwake::read_pid($pf);
        if (defined $lp && "$lp" ne "$$") { $done_lock = 1; $successor_pid = $lp }
        my $cur_helper = -e $pid_f ? BpKeepAwake::read_pid($pid_f) : undef;
        $done_helper = (!defined $w_old) || (($cur_helper // q{}) ne $w_old);
        last if $done_lock && $done_helper;
        select(undef, undef, undef, 0.25);
    }

    if ($done_lock && $done_helper) {
        $log->('HANDOVER-DONE', sprintf('successor=%s helper=%s',
            $successor_pid // 'unknown', (defined $w_old ? 'replaced' : 'none')));
        $log->('EXIT', 'reason=handed-over');
        return 1;
    }
    if ($done_lock) {
        $log->('HANDOVER-DONE', sprintf('successor=%s helper=pending', $successor_pid // 'unknown'));
        $log->('EXIT', 'reason=handed-over');
        return 1;
    }

    # H6: nobody has taken over the lock. Try to retake it ourselves.
    if (open(my $relock, '>>', "$dir/lease.lock")) {
        if (flock($relock, LOCK_EX | LOCK_NB)) {
            $$lock_ref = $relock;
            $$locked_ref = 1;
            _write_pid($pf, $$);
            $$handing_over_ref = 0;
            $log->('HANDOVER-FAILED', 'reason=lock-not-taken retry_in=600s');
            return 0;
        }
        close $relock;
    }
    $log->('HANDOVER-DONE', 'successor=unknown helper=pending');
    $log->('EXIT', 'reason=handed-over');
    return 1;
}

# ---------------------------------------------------------------------------
# daemon_loop($dir, %opts) — the refresher itself. Blocks.
#
# %opts: tick, max_iterations (tests), handover (bool), handover_spawn (seam),
# owner_winpid (default BpKeepAwake::self_owner_pid(): our Windows pid, or $$
# on macOS, so the helper lets go if this refresher dies), owner_desc, log (default
# lease_log), plus sync()'s seams.
sub daemon_loop {
    my ($dir, %opts) = @_;
    # A .t file calling daemon_loop in-process with no explicit tick (AC-21) is
    # exercising the loop's CONTROL FLOW, not its cadence -- the same distinction
    # _spawn_daemon/_spawn_successor/BpKeepAwake::spawn already draw with their
    # own $0 =~ /\.t\z/ guard. Falling through to the production 60s default
    # here would make max_iterations-bounded unit tests sleep for real minutes.
    my $tick = defined $opts{tick} ? clamp_tick($opts{tick})
             : (defined $0 && $0 =~ /\.t\z/) ? 2
             : tick_seconds();
    my $pf   = daemon_pid_file($dir);
    my $handover_flag = $opts{handover} ? 1 : 0;
    my $log  = $opts{log} // sub { lease_log($dir, @_) };
    # BpKeepAwake's own log seam hands us a single pre-built message string,
    # not an (event, detail) pair -- wrap it under one event token so a
    # keep-awake stop/spawn/replace line is findable in lease.log (spec 2.7's
    # KEEPAWAKE token).
    my $ka_log = sub { my ($msg) = @_; $log->('KEEPAWAKE', $msg) };
    my $handover_spawn = $opts{handover_spawn} // \&_spawn_successor;
    my $owner_winpid = exists $opts{owner_winpid} ? $opts{owner_winpid} : BpKeepAwake::self_owner_pid();

    make_path($dir) unless -d $dir;

    # SINGLE-INSTANCE BY flock, NOT BY INSPECTING THE PID FILE.
    #
    # ensure_daemon's heartbeat check is a cheap filter, and it has a real race:
    # two arms in the same second both find no pid file and both spawn. A check
    # inside the daemon closes nothing on its own, because both daemons can run
    # it before either writes. An advisory lock held for the process's lifetime
    # is the only version of this that is actually exclusive — and the OS drops
    # it when the holder dies, so a crashed daemon leaves nothing to clean up.
    #
    # A separate file from the pid/heartbeat on purpose: the heartbeat's whole
    # job is to be rewritten and re-stat'd constantly, which is the last thing
    # you want under a lock others are testing.
    #
    # IT IS NEVER UNLINKED, and that is the right call rather than an oversight.
    # Removing it would race: on POSIX an unlink succeeds while another process
    # holds the lock on the same inode, so the next arrival creates a FRESH file,
    # locks that instead, and both refreshers then believe they are the only one.
    # The residue is one empty dot-named file per registry, which any_active
    # already ignores.
    # DEGRADES TO UNLOCKED RATHER THAN TO NOTHING. If the lock file cannot be
    # opened at all — an unwritable registry, a full disk, a mount where this
    # fails — returning early would leave the arm with NO refresher, and
    # ensure_daemon would start a fresh one that failed the same way on every
    # Stop, forever, silently. Running without exclusivity risks a second
    # refresher; running not at all risks a suspended host mid-run. The first is
    # the lesser failure, and BpKeepAwake's atomic claim still stops two
    # refreshers from becoming two wake-locks.
    # NOT canonicalised through Cwd::abs_path on purpose: this is logged
    # verbatim (script=<...> below, and as the code-changed handover's
    # fallback target), and a caller may have started us from an 8.3
    # short-name path (Windows hands those out for $env:TEMP on a non-ASCII
    # username) or a test's own literal path string. is_live_script() below
    # still canonicalises internally for the COMPARISON, so correctness there
    # is unaffected; only the logged spelling is left alone.
    my $own_script = __FILE__;
    $own_script =~ s{\\}{/}g;
    my $live_at_start = live_script_path();
    my $is_live = is_live_script($own_script);

    my $lock;
    my $locked = 0;

    if ($handover_flag) {
        # S1 (spec 2.3, R2 side): announce readiness via lease.handover, then
        # retry LOCK_EX|LOCK_NB every 0.05s up to $HANDOVER_TIMEOUT_SECONDS.
        # We hold NOTHING yet, so TERM/INT here just exit -- no release closure
        # exists to call, and none is needed.
        local $SIG{TERM} = sub { exit 0 };
        local $SIG{INT}  = sub { exit 0 };
        unless (open $lock, '>>', "$dir/lease.lock") { return 'duplicate' }
        _write_pid("$dir/lease.handover", $$);
        my $got = 0;
        my $deadline = time() + $HANDOVER_TIMEOUT_SECONDS;
        while (time() < $deadline) {
            if (flock($lock, LOCK_EX | LOCK_NB)) { $got = 1; last }
            select(undef, undef, undef, 0.05);
        }
        unless ($got) {
            my $hf = "$dir/lease.handover";
            my $hp = -e $hf ? BpKeepAwake::read_pid($hf) : undef;
            unlink $hf if defined $hp && "$hp" eq "$$";
            $log->('HANDOVER-ABANDONED', 'reason=lock-not-acquired');
            close $lock;
            return 'duplicate';
        }
        $locked = 1;
        unlink "$dir/lease.handover";     # S2
        _write_pid($pf, $$);
    } else {
        if (open $lock, '>>', "$dir/lease.lock") {
            unless (flock($lock, LOCK_EX | LOCK_NB)) {
                close $lock;
                return 'duplicate';
            }
            $locked = 1;
        }
        _write_pid($pf, $$);
    }

    $log->('START', sprintf('script=%s dir=%s live=%s is_live=%d tick=%ds winpid=%s handover=%d platform=%s',
        $own_script, $dir, (defined $live_at_start ? $live_at_start : 'unresolved'), $is_live, $tick,
        (defined $owner_winpid ? $owner_winpid : 'none'), $handover_flag, platform()));
    # Said once per refresher, not per tick: on a host with no mechanism every
    # tick is the same no-op. The arm is still worth keeping (the Stop gate and
    # the holder do not depend on it), but nobody should believe this machine
    # is being held awake.
    $log->('UNSUPPORTED', 'no keep-awake mechanism on this host; the arm holds nothing awake')
        if platform() eq 'unsupported';

    my $released = 0;
    my $handing_over = 0;
    my $release = sub {
        return if $released++;
        my ($reason) = @_;
        sync($dir, %opts, active => 0, log => $ka_log, owner_winpid => $owner_winpid, owner_desc => $opts{owner_desc});
        unlink $pf;
        $log->('RELEASE', 'reason=' . (defined $reason ? $reason : 'unknown'));
        $log->('EXIT', 'reason=released');
    };
    # Package 06: the power plan follows arming. Windows-platform-only,
    # inside an eval, so a plan failure (including a failed require) can
    # never take the refresher down with it -- neither the journal step nor
    # the heartbeat below is skipped on account of it. Same repeat-
    # suppression shape as JOURNAL-ERROR (spec 2.8), with its own state.
    #
    # Defined here, BEFORE the SIG{TERM}/SIG{INT} handlers are installed just
    # below, so a signal delivered at any point after START is logged can
    # reach $exit_plan_step (package 11: the plan is restored on every
    # refresher exit, not only the IDLE one).
    my $plan_err_text;
    my $plan_err_repeats = 0;
    my $plan_err_logged_at = 0;
    my $run_plan_step = sub {
        my ($why, %extra) = @_;
        return unless platform() eq 'windows' && (!exists $opts{plan} || $opts{plan});
        my $plan_opts = (ref $opts{plan_opts} eq 'HASH') ? $opts{plan_opts} : {};
        my $outcome;
        my $ok = eval {
            require "$DIR/BpPowerPlan.pm" unless grep { m{(?:^|/)BpPowerPlan\.pm$} } keys %INC;
            $outcome = BpPowerPlan::reconcile($dir, why => $why, %$plan_opts, %extra);
            1;
        };
        unless ($ok) {
            my $err = defined $@ && length $@ ? $@ : 'unknown error';
            $err =~ s/\n.*//s;
            $err =~ s/[^\x20-\x7e]/?/g;
            $err = substr($err, 0, 200);
            my $now_e = time();
            if (defined $plan_err_text && $plan_err_text eq $err) {
                $plan_err_repeats++;
                if ($plan_err_repeats >= 2 && ($now_e - $plan_err_logged_at) < 3600) {
                    # suppressed: same text logged less than an hour ago
                } else {
                    $log->('PLAN-ERROR', $err);
                    $plan_err_logged_at = $now_e;
                }
            } else {
                $plan_err_repeats = 0;
                $log->('PLAN-ERROR', $err);
                $plan_err_logged_at = $now_e;
            }
            $plan_err_text = $err;
            return;
        }
        return unless ref $outcome eq 'HASH';
        return unless $outcome->{outcome} eq 'corrected' || $outcome->{outcome} eq 'error';
        $log->('PLAN', sprintf('why=%s outcome=%s found=%s wanted=%s error=%s journaled=%d',
            $why, $outcome->{outcome},
            (defined $outcome->{found_guid} ? $outcome->{found_guid} : 'unknown'),
            (defined $outcome->{wanted_guid} ? $outcome->{wanted_guid} : 'none'),
            (defined $outcome->{reason} ? $outcome->{reason} : ''),
            ($outcome->{journaled} ? 1 : 0)));
    };
    my $exit_plan_ran = 0;
    my $exit_plan_step = sub {
        my ($why) = @_;
        return if $exit_plan_ran;
        $run_plan_step->($why, journal_noop => 1);
        $exit_plan_ran = 1;
    };

    local $SIG{TERM} = sub { _handle_signal('term', \$handing_over, $release, $log, $exit_plan_step) };
    local $SIG{INT}  = sub { _handle_signal('int',  \$handing_over, $release, $log, $exit_plan_step) };

    # THERE IS NO PROCESS-START DEADLINE, AND THAT IS A CORRECTION.
    #
    # There was one: TTL + 1h from the moment the refresher started. It looked
    # like a harmless belt and was a guillotine. The Stop gate touches an armed
    # marker on every turn end, so a long-lived arm never expires — but the
    # daemon did, and at that instant it released the lock and exited. The only
    # thing that restarts it is the Stop gate, and this file's own header argues
    # a daemon was needed precisely BECAUSE a long unattended turn has no Stop.
    # So a session armed past the deadline, mid-turn, silently lost its
    # wake-lock and the host was free to suspend: the exact failure this module
    # exists to prevent, reintroduced on a timer.
    #
    # any_active is already the bound, and it is the RIGHT bound: it is derived
    # from the markers, so it expires when the arms do rather than when this
    # process happens to have started. A second cap derived from the same clock
    # and the same files could only either duplicate it or contradict it.
    my $iter = 0;
    my $last_gc = 0;
    my $next_handover_try = 0;
    my $did_replace = 0;

    # Package 02-plan-hold-expiry: names whose stale-hold prune has already
    # failed once IN THIS PROCESS (spec 2.3, B11). Passed to holds_pending as
    # a skip set so a hold file this process cannot remove stops keeping it
    # alive -- otherwise a permanently-unremovable file would pin the
    # refresher forever instead of bounding its lifetime at the next IDLE
    # exit. A fresh process (a handover successor, or the next launcher
    # `--hold`) starts with an empty skip set and tries again.
    my %unremovable;

    # Package 08-host-awake-actuator: the same per-process skip set, for
    # registry entries this process has already failed to prune (spec 2.2,
    # B11's rule extended to the new registry). SOURCE-PRUNE-FAILED is
    # logged once per id, same shape as HOLD-PRUNE-FAILED above.
    my %unremovable_src;

    # Package 05: the power journal's per-process probe cache/seq counter,
    # and the JOURNAL-ERROR repeat-suppression state (spec 2.8: after two
    # consecutive identical JOURNAL-ERRORs, the same text logs no more than
    # once per hour, so a persistently-failing journal never fills lease.log).
    my %journal_cache;
    my $journal_err_text;
    my $journal_err_repeats = 0;
    my $journal_err_logged_at = 0;
    my $snap = code_snapshot();

    # review m2: logged once per process the first time HostAwake::gather (or
    # decide) dies or returns something unusable, so a half-installed or
    # syntax-broken HostAwake.pm degrades silently to pre-08 arm-or-hold
    # behaviour (dropping every registry source) WITHOUT also dropping the
    # only line that would tell an operator why. Not repeated every tick --
    # that would fill lease.log the same way an unremovable source does.
    my $source_error_logged = 0;

    my $loop_result;
    my $loop_err;
    my $ok_loop = eval {
    my $last_verdict = '';
    while (1) {
        # The one decision about ARMS (lease_verdict): 'held' -- a live arm
        # has work in flight, and counts as an arm toward HostAwake below;
        # 'waiting' -- live arms, every one only waiting for the operator: it
        # does NOT count as an arm, so it never holds the wake-lock on its
        # own, but the refresher keeps ticking (a 'wait' tick) to take the
        # lock again the moment work resumes; 'idle' -- no live arm.
        my ($verdict, $vd) = lease_verdict($dir);
        my $reason_data = $verdict eq 'held' ? $vd->{reason} : undef;
        # Package 08-host-awake-actuator: the tick's mode now comes from
        # HostAwake's own decide(), fed by gather() -- the registry (sandbox/
        # fleet/solo entries) and the old sandbox-holds files are both
        # considered, not just an arm. %unremovable/%unremovable_src keep a
        # name or id this process already failed to prune from resurrecting
        # hold/source mode forever (B11). A load or call failure degrades to
        # today's pre-08 "arm or hold-only" shape rather than taking the
        # refresher down with it. Only an in-flight ('held') arm is passed
        # as an arm, so a waiting arm alongside a counting source still gets
        # a source tick (the source's lock is kept), never a lock-dropping
        # wait tick.
        my $ha_d;
        {
            local $@;
            eval {
                require "$DIR/HostAwake.pm" unless defined &HostAwake::gather;
                my $ha_in = HostAwake::gather($dir,
                    arms => (defined $reason_data ? $reason_data->{arms} : 0),
                    skip_holds => \%unremovable, skip_sources => \%unremovable_src);
                $ha_d = HostAwake::decide($ha_in);
            };
        }
        unless (ref $ha_d eq 'HASH') {
            unless ($source_error_logged) {
                $log->('SOURCE-ERROR', 'HostAwake::gather/decide unavailable, falling back to arm-or-hold');
                $source_error_logged = 1;
            }
            if (defined $reason_data) {
                $ha_d = { mode => 'arm', counting => [] };
            } elsif (holds_pending($dir, skip => \%unremovable)) {
                $ha_d = { mode => 'hold', counting => [] };
            } else {
                $ha_d = { mode => 'idle', counting => [] };
            }
        }
        # Nothing else counts, but live arms are waiting for the operator:
        # not idle -- release and keep ticking (origin's 'waiting' verdict).
        if ($ha_d->{mode} eq 'idle' && $verdict eq 'waiting') {
            $ha_d = { %$ha_d, mode => 'wait' };
        }
        if ($ha_d->{mode} eq 'idle') {
            # This normal IDLE exit always reconciles the plan ($exit_plan_step
            # -> run_plan_step -> BpPowerPlan::reconcile), which is what
            # restores it once nothing counts (review m3/redteam m3/m4's
            # scenarios are both about this call NEVER HAPPENING: the process
            # dying outright -- killed, crashed, console closed -- bypasses
            # this whole loop body including this line). 26(e) (KeepAwake's
            # registry_seams `stop`) narrows that window for the launcher's
            # own exit by ensuring a successor once more right after its last
            # withdraw, but ensure_daemon's gate (above) answers 'idle' with
            # nothing pending, so a daemon dead with nothing left to count
            # never gets a chance to run THIS reconcile either. That residual
            # gap -- a dead refresher, a plan already switched away, and no
            # producer left to re-ensure one -- is the same accepted-risk
            # shape as spec 5.1's promotion window: bounded to an operator
            # noticing and manually re-running `lease`/`status`, not engineered
            # around here.
            $log->('IDLE', 'reason=no-live-arm');
            $exit_plan_step->('refresher-exit');
            last;
        }
        my $hold_mode   = ($ha_d->{mode} eq 'hold')   ? 1 : 0;
        my $source_mode = ($ha_d->{mode} eq 'source') ? 1 : 0;
        my $wait_mode   = ($ha_d->{mode} eq 'wait')   ? 1 : 0;
        # IN-FLIGHT / WAITING: logged once per change of the arm verdict, not
        # every tick. An 'idle' verdict (no live arm; a source or hold tick is
        # running instead) logs nothing, but is remembered so that a later
        # arm is announced afresh.
        if ($verdict ne $last_verdict) {
            if ($verdict eq 'held') {
                $log->('IN-FLIGHT', sprintf('sid=%s why=%s', $reason_data->{sid}, $vd->{why}));
            } elsif ($verdict eq 'waiting') {
                $log->('WAITING', sprintf('reason=waiting-for-operator arms=%d quiet=%ss',
                    $vd->{arms}, defined $vd->{quiet} ? $vd->{quiet} : 'unknown'));
            }
            $last_verdict = $verdict;
        }

        if (time() >= $next_handover_try) {
            _snapshot_add_new($snap);
            my $changed_path = code_changed($snap);
            my ($ho_reason, $target, $file);
            if (defined $changed_path) {
                $ho_reason = 'code-changed';
                $file      = $changed_path;
                $target    = live_script_path() // $own_script;
            } elsif (!$is_live && !$handover_flag) {
                $ho_reason = 'not-live';
                $file      = $own_script;
                $target    = live_script_path();
            }
            if (defined $ho_reason) {
                my $handed = _do_handover(
                    dir => $dir, pf => $pf, lock_ref => \$lock, locked_ref => \$locked,
                    handing_over_ref => \$handing_over, reason => $ho_reason, file => $file,
                    target => $target, tick => $tick, spawn => $handover_spawn, log => $log,
                    own_script => $own_script,
                );
                if ($handed) {
                    $exit_plan_step->('refresher-handover');
                    $loop_result = 'handed-over';
                    last;
                }
                $next_handover_try = time() + $HANDOVER_RETRY_SECONDS;
            }
        }

        if ($hold_mode) {
            # Hold-only tick (package 02-plan-hold-expiry spec 2.3). No arm is
            # live, so there is no host helper for THIS session to own -- release
            # whatever a now-gone arm left behind, the same release today's IDLE
            # exit performs via $release, except this process keeps running.
            # Never sync(active => 1): the sandbox's own launcher holds that
            # machine's lock, not this refresher.
            #
            # Addendum A.3.3 (reviewer MINOR-1, red-team m3): a new host arm
            # that lands while this tick is asleep waits for the next tick --
            # up to $tick seconds -- before converge sees 'running' and starts
            # its own helper. Accepted, for two different reasons depending on
            # what put this tick into hold mode (package 08-host-awake-
            # actuator widened hold mode beyond its original one case):
            #   - an old-style sandbox hold file: a launcher writes one only
            #     while IT holds its own wake-lock, so the machine is already
            #     awake for that minute regardless.
            #   - a stale or garbled registry entry with no lock held
            #     anywhere (no arm, no counting source): there is genuinely
            #     no lock during this gap, bounded at $tick seconds (the same
            #     bound B10's "level, not edge" design accepts everywhere
            #     else).
            # Fixing either gap would need a refresher-wake channel or sliced
            # sleeps that poll arms/sources -- new machinery for a window
            # bounded at one tick.
            sync($dir, %opts, active => 0, log => $ka_log, owner_winpid => $owner_winpid, owner_desc => undef);

            my $root = store_root_for($dir);
            my $files = eval { BpPowerPlan::sandbox_hold_files($root) } || [];
            my $fresh = eval { BpPowerPlan::sandbox_holds($root) } || [];
            my $file_count = scalar grep { !exists $unremovable{$_} } @$files;
            my $fresh_count = scalar @$fresh;
            # Package 08-host-awake-actuator: the registry's own entry files
            # (any id, valid or not -- the same count gather()'s `pending`
            # already looked at), minus ids this process has already failed
            # to prune, appended to the same line so an operator reading
            # lease.log sees both pending mechanisms at a glance.
            my $entries_count = eval {
                require "$DIR/HostAwake.pm" unless defined &HostAwake::read_registry;
                my $reg = HostAwake::read_registry($root);
                scalar grep { !exists $unremovable_src{$_->{id}} } @$reg;
            };
            $entries_count = 0 unless defined $entries_count;
            $log->('HOLD-TICK', sprintf('active=0 reason=sandbox-hold files=%d fresh=%d entries=%d',
                $file_count, $fresh_count, $entries_count));

            $run_plan_step->('refresher-hold-tick');

            # Prune AFTER the reconcile above, re-stat'd at this moment (spec
            # 2.1) -- a hold refreshed between the reconcile's directory read
            # and here survives (B10); one failed on purpose is logged once and
            # added to %unremovable so it stops resurrecting hold mode (B11).
            my $pr = eval { BpPowerPlan::prune_stale_sandbox_holds($root) };
            if (ref $pr eq 'HASH') {
                for my $r (@{ $pr->{removed} || [] }) {
                    $log->('HOLD-PRUNED', sprintf('name=%s age=%ss', $r->{name}, $r->{age}));
                }
                for my $n (@{ $pr->{failed} || [] }) {
                    unless (exists $unremovable{$n}) {
                        $log->('HOLD-PRUNE-FAILED', "name=$n");
                        $unremovable{$n} = 1;
                    }
                }
            }
        } elsif ($source_mode) {
            # Package 08-host-awake-actuator: a SOURCE-TICK. No host arm is
            # live, but at least one registry entry (sandbox/fleet/solo)
            # counts -- the same shape as an arm tick (one host helper held,
            # the plan switched to Continuous work), except there is no
            # $reason_data to describe: the owner description names the
            # source count instead.
            my $src_desc = BpKeepAwake::owner_desc_clean(
                sprintf('host-awake,sources=%d', scalar @{ $ha_d->{counting} || [] }));

            # S3 (spec 2.3), same code as the arm branch below: on the
            # successor's first live tick, replace the inherited helper so
            # it is owned (and logged) by this process.
            if ($handover_flag && !$did_replace) {
                $did_replace = 1;
                my $ka_pid_f = wakelock_pid_file($dir);
                if (-e $ka_pid_f) {
                    my $old_h = BpKeepAwake::read_pid($ka_pid_f);
                    if (defined $old_h && BpKeepAwake::pid_alive($old_h)) {
                        my $r = BpKeepAwake::replace($dir, {
                            owner_winpid => $owner_winpid, owner_desc => $src_desc, log => $ka_log,
                        });
                        if ($r eq 'replaced') {
                            my $new_h = BpKeepAwake::read_pid($ka_pid_f);
                            $log->('HELPER-REPLACED', "old=$old_h new=" . (defined $new_h ? $new_h : 'unknown'));
                        } else {
                            $log->('HELPER-REPLACE-FAILED', "old=$old_h reason=$r");
                        }
                    }
                }
            }

            sync($dir, %opts, active => 1, log => $ka_log, owner_winpid => $owner_winpid, owner_desc => $src_desc);
            $log->('SOURCE-TICK', sprintf('active=1 reason=source sources=%s count=%d',
                join(',', @{ $ha_d->{counting} || [] }), scalar @{ $ha_d->{counting} || [] }));

            # Package 06's plan-follows-arming step runs here too (spec 2.3):
            # a counting registry entry is just as much a reason to switch to
            # Continuous work as a host arm is. No journal (nothing arm-shaped
            # to describe) and no gc_sessions (it reaps arm files; there is
            # none here).
            $run_plan_step->('refresher-source-tick');
        } else {
            # An arm tick ('held': work in flight, the lock is taken) or a
            # wait tick ('waiting': every live arm only waits for the
            # operator, so the lock is released and the refresher keeps
            # ticking to take it again when work resumes).
            #
            # S3 (spec 2.3): on the successor's first live HELD tick, replace
            # the inherited helper so it is owned (and logged) by this
            # process. A wait tick releases instead, so it leaves the
            # replacement to whichever held tick comes next.
            if ($handover_flag && !$did_replace && !$wait_mode) {
                $did_replace = 1;
                my $ka_pid_f = wakelock_pid_file($dir);
                if (-e $ka_pid_f) {
                    my $old_h = BpKeepAwake::read_pid($ka_pid_f);
                    if (defined $old_h && BpKeepAwake::pid_alive($old_h)) {
                        my $desc_now = _owner_desc_for($reason_data);
                        my $r = BpKeepAwake::replace($dir, {
                            owner_winpid => $owner_winpid, owner_desc => $desc_now, log => $ka_log,
                        });
                        if ($r eq 'replaced') {
                            my $new_h = BpKeepAwake::read_pid($ka_pid_f);
                            $log->('HELPER-REPLACED', "old=$old_h new=" . (defined $new_h ? $new_h : 'unknown'));
                        } else {
                            $log->('HELPER-REPLACE-FAILED', "old=$old_h reason=$r");
                        }
                    }
                }
            }

            if ($wait_mode) {
                sync($dir, %opts, active => 0, log => $ka_log, owner_winpid => $owner_winpid);
                $log->('TICK', sprintf('active=0 reason=waiting-for-operator arms=%d quiet=%ss',
                    $vd->{arms}, defined $vd->{quiet} ? $vd->{quiet} : 'unknown'));
            } else {
                my $desc = _owner_desc_for($reason_data);
                sync($dir, %opts, active => 1, log => $ka_log, owner_winpid => $owner_winpid, owner_desc => $desc);
                $log->('TICK', sprintf('active=1 reason=arm sid=%s basis=%s age=%ss arms=%d',
                    $reason_data->{sid}, $reason_data->{basis}, $reason_data->{age}, $reason_data->{arms}));
            }

            # Package 06: the power plan follows arming, checked on every tick
            # BEFORE the journal step so a probe spawned in the same tick sees
            # the corrected plan.
            $run_plan_step->('refresher-tick');

            # Package 05: the power journal. Windows-platform-only, inside an
            # eval, so a journal failure (including a failed require) can never
            # take the refresher down with it -- sync() already ran and the
            # heartbeat pid file is touched below regardless of what happens here.
            if (platform() eq 'windows' && (!exists $opts{journal} || $opts{journal})) {
                my $jopts = (ref $opts{journal_opts} eq 'HASH') ? $opts{journal_opts} : {};
                my $ok = eval {
                    require "$DIR/BpPowerJournal.pm" unless grep { m{(?:^|/)BpPowerJournal\.pm$} } keys %INC;
                    BpPowerJournal::tick($dir, tick_s => $tick, cache => \%journal_cache, %$jopts);
                    1;
                };
                unless ($ok) {
                    my $err = defined $@ && length $@ ? $@ : 'unknown error';
                    $err =~ s/\n.*//s;
                    $err =~ s/[^\x20-\x7e]/?/g;
                    $err = substr($err, 0, 200);
                    my $now_e = time();
                    if (defined $journal_err_text && $journal_err_text eq $err) {
                        $journal_err_repeats++;
                        if ($journal_err_repeats >= 2 && ($now_e - $journal_err_logged_at) < 3600) {
                            # suppressed: same text logged less than an hour ago
                        } else {
                            $log->('JOURNAL-ERROR', $err);
                            $journal_err_logged_at = $now_e;
                        }
                    } else {
                        $journal_err_repeats = 0;
                        $log->('JOURNAL-ERROR', $err);
                        $journal_err_logged_at = $now_e;
                    }
                    $journal_err_text = $err;
                }
            }

            my $now = time;
            if (($now - $last_gc) >= $GC_SESSIONS_INTERVAL) {
                $last_gc = $now;
                eval {
                    require "$DIR/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
                    BpHook::gc_sessions();
                };
            }
        }

        # Package 08-host-awake-actuator: registry prune, after the tick's
        # own plan step, for every non-idle mode (arm, source and hold
        # alike) -- a registry entry can go stale under an arm tick too, and
        # must not wait for a source/hold tick to be noticed. Wrapped in
        # eval, same discipline as the journal/gc steps above: a prune
        # failure must never take the refresher down with it.
        eval {
            require "$DIR/HostAwake.pm" unless defined &HostAwake::prune_registry;
            my $root = store_root_for($dir);
            my $pruned = HostAwake::prune_registry($root, skip => \%unremovable_src);
            if (ref $pruned eq 'HASH') {
                for my $r (@{ $pruned->{removed} || [] }) {
                    $log->('SOURCE-PRUNED', sprintf('id=%s age=%ss', $r->{id}, $r->{age}));
                }
                for my $id (@{ $pruned->{failed} || [] }) {
                    unless (exists $unremovable_src{$id}) {
                        $log->('SOURCE-PRUNE-FAILED', "id=$id");
                        $unremovable_src{$id} = 1;
                    }
                }
            }
        };

        # Shared, unchanged order: heartbeat, iteration bound, sleep -- for
        # both an arm tick and a hold-only tick, so a hold-only refresher's
        # pid file stays as fresh to ensure_daemon's cheap mtime check (the
        # Stop gate's own reader, reached through converge; stop-gate.sh
        # itself never reads lease.pid -- addendum A.3.5, reviewer NIT-1) as
        # an armed one's.
        my $hb_now = time;
        utime($hb_now, $hb_now, $pf);    # the heartbeat cheap readers rely on
        $iter++;
        last if defined $opts{max_iterations} && $iter >= $opts{max_iterations};
        # Package 02-plan-hold-expiry: a test seam (spec 2.3). Production never
        # passes it, so this is CORE sleep exactly as before off a .t harness.
        if (ref $opts{sleep} eq 'CODE') { $opts{sleep}->($tick) } else { sleep $tick }
    }
    1;
    };
    unless ($ok_loop) {
        $loop_err = $@;
        eval {
            my $m = defined $loop_err && length $loop_err ? $loop_err : 'unknown error';
            $m =~ s/\n.*//s;
            $m =~ s/[^\x20-\x7e]/?/g;
            $m = substr($m, 0, 200);
            $log->('ERROR', "reason=$m");
        };
        eval { $exit_plan_step->('refresher-error') };
        eval { $release->('error') } unless $handing_over;
        close $lock if $locked;
        die $loop_err;
    }

    return 'handed-over' if defined $loop_result && $loop_result eq 'handed-over';

    $release->('idle');
    close $lock if $locked;
    return q{done};
}

sub _write_pid {
    my ($pf, $pid) = @_;
    open my $fh, '>', $pf or return 0;
    print {$fh} "$pid\n";
    close $fh;
    return 1;
}

exit(__PACKAGE__->_script_main(@ARGV)) unless caller;

1;
