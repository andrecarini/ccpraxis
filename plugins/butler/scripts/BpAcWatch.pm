# BpAcWatch -- the AC-loss / clean-suspend state machine (package 11 of
# blueprint tooling-backlog). Contract: .ccpraxis-local-data/blueprints/
# tooling-backlog/specs/11-ac-loss-clean-suspend-cycle-spec.md sec 2.2-2.6.
#
# One state machine, driven from three places: butler-hold.pl (detects loss
# and grace expiry while the driver waits), bp-drive-next.pl's `next`
# (performs the mechanical stand-down and the resume) and bp-ac-watch.pl's
# `monitor` (the only thing that runs while stood down).
#
# BpPowerJournal and BpContinuityLease are loaded LAZILY, inside the subs
# that need them, never at module load -- the guard (AcStandDown.pm) and the
# holder's become/extend path must stay cheap.
package BpAcWatch;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();
use JSON::PP ();
use Fcntl qw(:flock);
use Time::Local ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

# BpAwakeConst is six constants and no I/O, so loading it eagerly at compile
# time costs the guard path nothing -- the LAZY rule in the header above is
# for BpPowerJournal/BpContinuityLease, not for this.
BEGIN {
    my $d = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
    require "$d/BpAwakeConst.pm" unless defined &BpAwakeConst::AC_STALE;
}
use constant GRACE         => BpAwakeConst::AC_GRACE();
use constant PROBE_INTERVAL => 55;   # $BpPowerJournal::PROBE_MIN_INTERVAL
use constant MONITOR_TICK  => 60;
use constant GAP_FACTOR    => 3;
use constant UNKNOWN_LIMIT => 10;

# H3 (fix-batch, redteam/reviewer-1): a stand-down nobody ever resumes (the
# session or the monitor died, or the whole stand-down is simply abandoned)
# must eventually lapse, or guard_active() refuses every subagent of every
# session in the project forever, with no reachable heal path outside
# drive-solo. 30 * MONITOR_TICK (30 min) is comfortably longer than any
# single tick, a SUSPEND-GAP blip, or a brief host sleep/resume, but far
# short of "forever".
use constant STALE_AFTER   => 30 * MONITOR_TICK;

# How long guard_active()'s self-heal waits for ac-state.lock. It runs inside
# a PreToolUse hook, so it must stay short; every legitimate holder keeps the
# lock for a few file operations only.
use constant GUARD_LOCK_TIMEOUT => 2;

# ---------------------------------------------------------------------------
# small path / io helpers
# ---------------------------------------------------------------------------

sub _dd { my ($d) = @_; (my $v = $d) =~ s{\\}{/}g; $v =~ s{/+\z}{}; return $v }
sub _dsdir      { my ($d) = @_; return _dd($d) . '/.drive-solo' }
sub _state_path { my ($d) = @_; return _dsdir($d) . '/ac-state.json' }
sub _lock_path  { my ($d) = @_; return _dsdir($d) . '/ac-state.lock' }
sub _marker_path{ my ($d) = @_; return _dsdir($d) . '/ac-standdown.json' }
sub _monlock_path { my ($d) = @_; return _dsdir($d) . '/ac-monitor.lock' }
sub log_path    { my ($d) = @_; return _dsdir($d) . '/ac-cycle.log' }

sub _is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

sub _mkpath {
    my ($dir) = @_;
    return 1 if -d $dir;
    eval { require File::Path; File::Path::make_path($dir) };
    return -d $dir ? 1 : 0;
}

# M1 (fix-batch, redteam-1): the director/holder resolve the data dir via
# BpDataRoot (env, then git top-level, then walk-up -- never
# CLAUDE_PROJECT_DIR). The PreToolUse guard (BpHook::data_dir, outside this
# package's write set) resolves CLAUDE_PROJECT_DIR directly when it is set,
# with no further git/walk-up step. When a session's CLAUDE_PROJECT_DIR
# differs from the director's resolved project root (e.g. launched from a
# subdirectory), the two sides land on different data dirs and the guard
# never sees the signal. Mirroring the marker + state to the
# CLAUDE_PROJECT_DIR-derived data dir (when it differs) closes that gap
# without touching BpHook.pm. A no-op whenever CLAUDE_PROJECT_DIR is unset
# or already matches -- true for every test in this suite and for any
# non-hook caller (the CLI, the holder run standalone).
sub _alt_data_dir {
    my ($data_dir) = @_;
    my $cpd = $ENV{CLAUDE_PROJECT_DIR};
    return undef unless defined $cpd && length $cpd;
    my $alt = _dd($cpd) . '/.ccpraxis-local-data';
    return undef if _dd($alt) eq _dd($data_dir);
    return $alt;
}

# _mirror_standdown_on($data_dir, $marker_payload, $state) -- best effort,
# never dies, return value ignored by callers (the real signal already lives
# at $data_dir; this is belt-and-suspenders for the CLAUDE_PROJECT_DIR-
# resolving guard/atom only).
sub _mirror_standdown_on {
    my ($data_dir, $marker_payload, $state) = @_;
    my $alt = _alt_data_dir($data_dir);
    return unless defined $alt;
    eval {
        _write_json_atomic(_marker_path($alt), $marker_payload) unless -e _marker_path($alt);
        my $alt_state = _read_state($alt);
        $alt_state->{phase}       = $state->{phase};
        $alt_state->{dc_since}    = $state->{dc_since};
        $alt_state->{grace_until} = $state->{grace_until};
        _write_state($alt, $alt_state);
    };
}

# _mirror_resume_on($data_dir) -- the resume-side counterpart: clears the
# mirrored marker and resets the mirrored state's phase to ac. Same
# best-effort, no-op-when-no-alt contract as _mirror_standdown_on.
sub _mirror_resume_on {
    my ($data_dir) = @_;
    my $alt = _alt_data_dir($data_dir);
    return unless defined $alt;
    eval {
        my $mp = _marker_path($alt);
        unlink $mp if -e $mp;
        my $alt_state = _read_state($alt);
        $alt_state->{phase} = 'ac';
        $alt_state->{dc_since} = undef;
        $alt_state->{grace_until} = undef;
        $alt_state->{reconnected_at} = undef;
        $alt_state->{reconnect_basis} = undef;
        _write_state($alt, $alt_state);
    };
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _read_json {
    my ($path) = @_;
    my $raw = _read_bytes($path);
    return undef unless defined $raw && length $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

sub _write_json_atomic {
    my ($path, $data) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    return 0 unless _mkpath($dir);
    my $json = eval { JSON::PP->new->utf8->canonical->encode($data) };
    return 0 unless defined $json;
    my $tmp = "$dir/." . time() . ".$$.tmp";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} $json;
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return rename($tmp, $path) ? 1 : (unlink($tmp), 0);
}

# ---------------------------------------------------------------------------
# timestamps -- 2.2's two-timestamp grammar.
# ---------------------------------------------------------------------------

sub _iso_utc {
    my ($epoch) = @_;
    $epoch = 0 unless defined $epoch;
    my @t = gmtime(int($epoch));
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _tz_offset_seconds {
    my ($epoch) = @_;
    my @g = gmtime($epoch);
    my @l = localtime($epoch);
    my $gt = eval { Time::Local::timegm(@g) };
    my $lt = eval { Time::Local::timegm(@l) };
    return 0 unless defined $gt && defined $lt;
    return $lt - $gt;
}

sub _iso_local {
    my ($epoch) = @_;
    $epoch = 0 unless defined $epoch;
    my @t = localtime(int($epoch));
    my $off = _tz_offset_seconds(int($epoch));
    my $sign = $off < 0 ? '-' : '+';
    my $abs = abs($off);
    my $oh = int($abs / 3600);
    my $om = int(($abs % 3600) / 60);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $sign, $oh, $om);
}

sub _hhmm_local {
    my ($epoch) = @_;
    $epoch = 0 unless defined $epoch;
    my @l = localtime(int($epoch));
    return sprintf('%02d:%02d', $l[2], $l[1]);
}

# ---------------------------------------------------------------------------
# env-seam helpers (2.4's "Test seams" note): honoured only while
# CCPRAXIS_AC_PROBE_FILE is set; production never sets any of these.
# ---------------------------------------------------------------------------

sub _seam_active {
    my $pf = $ENV{CCPRAXIS_AC_PROBE_FILE};
    return (defined $pf && length $pf && _is_abs($pf)) ? 1 : 0;
}

sub _grace_seconds {
    if (_seam_active()) {
        my $v = $ENV{CCPRAXIS_AC_GRACE_SECONDS};
        if (defined $v && $v =~ /\A\d+\z/ && $v >= 1 && $v <= 300) { return $v + 0 }
    }
    return GRACE;
}

sub _probe_interval {
    if (_seam_active()) {
        my $v = $ENV{CCPRAXIS_AC_TICK_SECONDS};
        if (defined $v && $v =~ /\A\d+(?:\.\d+)?\z/ && $v >= 0.01 && $v <= 60) { return $v + 0 }
    }
    return PROBE_INTERVAL;
}

sub _monitor_tick {
    if (_seam_active()) {
        my $v = $ENV{CCPRAXIS_AC_TICK_SECONDS};
        if (defined $v && $v =~ /\A\d+(?:\.\d+)?\z/ && $v >= 0.01 && $v <= 60) { return $v + 0 }
    }
    return MONITOR_TICK;
}

# ---------------------------------------------------------------------------
# enabled() -- 2.4.
# ---------------------------------------------------------------------------

sub enabled {
    return 1 if _seam_active();
    return ($^O =~ /^(?:MSWin32|msys|cygwin)$/) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# probe_source(%o) -- 2.4.
# ---------------------------------------------------------------------------

# %_PROBE_CACHE -- shared across every probe_source() call in this process
# (red-team m8, fix-batch): run_bounded's own SHOULD-FIX-5 comment names an
# unreaped timed-out child as "a slow zombie leak" in a long-lived caller.
# Before package 09, probe_source ran only in short-lived holders and
# monitors; 09 puts it inside the refresher's own tick, so the daemon now
# lives for days across this call. One shared cache lets run_bounded sweep
# its own prior zombies (if any) on every subsequent call.
my %_PROBE_CACHE;

sub _norm_reading {
    my ($v) = @_;
    return 'unknown' unless defined $v && !ref($v);
    my $t = lc($v);
    $t =~ s/^\s+|\s+$//g;
    return ($t eq 'ac' || $t eq 'dc') ? $t : 'unknown';
}

sub probe_source {
    my (%o) = @_;
    if (ref $o{probe} eq 'CODE') {
        my $v = eval { $o{probe}->() };
        return 'unknown' if $@;
        return _norm_reading($v);
    }
    my $pf = $ENV{CCPRAXIS_AC_PROBE_FILE};
    if (defined $pf && length $pf && _is_abs($pf)) {
        open(my $fh, '<:raw', $pf) or return 'unknown';
        my $line = <$fh>;
        close $fh;
        return 'unknown' unless defined $line;
        $line =~ s/^\s+|\s+$//g;
        $line = lc($line);
        return ($line eq 'ac' || $line eq 'dc' || $line eq 'unknown') ? $line : 'unknown';
    }
    my $ok = eval {
        require "$DIR/BpPowerJournal.pm" unless defined &BpPowerJournal::probe_argv;
        1;
    };
    return 'unknown' unless $ok;
    my $argv = eval { BpPowerJournal::probe_argv() };
    return 'unknown' unless ref $argv eq 'ARRAY';
    # red-team m8 / fix-batch: pass the shared zombie cache so a prior call's
    # timed-out (unreaped) child gets swept here, instead of leaking one
    # process slot per timeout for the life of a multi-day refresher.
    my $r = eval { BpPowerJournal::run_bounded($argv, $BpPowerJournal::PROBE_TIMEOUT_SECONDS, \%_PROBE_CACHE) };
    return 'unknown' unless ref $r eq 'HASH' && defined $r->{status} && $r->{status} eq 'ok';
    my $parsed = eval { BpPowerJournal::parse_probe($r->{out}) };
    return 'unknown' unless ref $parsed eq 'HASH';
    # L8 (redteam-1): parse_probe's overall status is "partial" whenever ANY
    # other probe part (plan, cs, ka) failed, but power_source is only ever
    # ac/dc when the power part itself succeeded (err.power absent; see
    # BpPowerJournal::parse_probe). So a valid power reading is used
    # regardless of the overall status rather than discarded as unknown.
    my $ps = $parsed->{power_source};
    return (defined $ps && ($ps eq 'ac' || $ps eq 'dc')) ? $ps : 'unknown';
}

# ---------------------------------------------------------------------------
# state read/write -- 2.3.
# ---------------------------------------------------------------------------

sub _default_state {
    return {
        v => 1, phase => 'ac', source => 'unknown', probed_at => 0,
        dc_since => undef, grace_until => undef,
        reconnected_at => undef, reconnect_basis => undef, updated_at => 0,
        # Decision 29(a) (fix-batch): both the host-wide instance's
        # consecutive-unknown-probe counter and its last-ANNOUNCED battery
        # verdict live HERE, on disk under this state's own lock, rather than
        # in a per-process package hash. A per-process cache duplicated a
        # "released" journal record on every refresher restart (a cold
        # process always started believing "hold") and lost a "held" edge
        # when the daemon idle-exited mid-outage (review M1, red-team m3).
        # Persisting both here means any process, at any time, agrees with
        # whatever the LAST process already announced or counted.
        unknown_count => 0, announced => 'hold',
    };
}

# _KNOWN_PHASES -- every phase this state machine ever writes. Shared by
# host_step's step 2 (Decision 29(b)) so "a phase this code does not
# recognise" is named once rather than inferred from what it is NOT.
my %_KNOWN_PHASES = map { $_ => 1 } qw(ac grace expired standing-down monitoring reconnected);
sub _is_known_phase { my ($phase) = @_; return (defined $phase && $_KNOWN_PHASES{$phase}) ? 1 : 0 }

# _is_release_phase($phase) -> 0|1 -- "release phases" per spec 09 section 2.1's
# notation: expired, standing-down, monitoring. Shared by battery_verdict and
# host_step so the rule is named once.
sub _is_release_phase {
    my ($phase) = @_;
    return 0 unless defined $phase;
    return ($phase eq 'expired' || $phase eq 'standing-down' || $phase eq 'monitoring') ? 1 : 0;
}

sub _read_state {
    my ($data_dir) = @_;
    my $data = _read_json(_state_path($data_dir));
    my %st = %{ _default_state() };
    if (ref $data eq 'HASH') {
        for my $k (keys %st) {
            $st{$k} = $data->{$k} if exists $data->{$k};
        }
    }
    return \%st;
}

sub _write_state {
    my ($data_dir, $state) = @_;
    _mkpath(_dsdir($data_dir));
    $state->{updated_at} = time();
    return _write_json_atomic(_state_path($data_dir), $state);
}

# read_state($data_dir) -> \%state (package 09, spec 2.1). A public copy of
# _read_state for a caller outside this file (HostAwake::battery_releases)
# that must never probe, lock or write -- just see what is on disk right now.
# Same no-die, defaults-on-missing-or-garbled contract as _read_state itself.
sub read_state { my ($data_dir) = @_; return _read_state($data_dir) }

# mark_announced($data_dir, $verdict, %o) -> 0|1 (package 09, Decision 29(a)
# fix-batch). The host-ac state's own record of the verdict a caller has
# just finished journaling -- written under the state's own lock, so every
# process (not just the one that happened to make the last call) agrees on
# what was last announced. The ONLY caller is HostAwake::battery_step, and
# ONLY after BpPowerJournal::append_record has already returned success:
# never mark a verdict as announced before the record describing it is
# safely on disk, or a failed append would permanently drop that edge
# (review M1).
sub mark_announced {
    my ($data_dir, $verdict, %o) = @_;
    my $lock_timeout = defined $o{lock_timeout} ? $o{lock_timeout} : 10;
    my $saved = 0;
    _with_state_lock($data_dir, $lock_timeout, sub {
        my $state = _read_state($data_dir);
        $state->{announced} = (defined $verdict && length $verdict) ? $verdict : 'hold';
        $saved = _write_state($data_dir, $state) ? 1 : 0;
    });
    return $saved;
}

# battery_verdict(\%state, $now) -> { verdict => release|hold, basis => WORD }
# (package 09, spec 2.1). PURE: no I/O, no clock read when $now is given, no
# %ENV. Rows V1-V3, first match wins. A non-HASH $state is V1's bogus-phase
# case (basis unknown-phase), so a caller that hands this a corrupt value
# fails open to hold rather than dying.
sub battery_verdict {
    my ($state, $now) = @_;
    $now = time() unless defined $now;
    return { verdict => 'hold', basis => 'unknown-phase' } unless ref $state eq 'HASH';

    my $phase = $state->{phase};
    unless (_is_release_phase($phase)) {
        # V1: not released -- ac/grace/reconnected name themselves; anything
        # else (a bogus or missing phase) is unknown-phase.
        my $basis = (defined $phase && ($phase eq 'ac' || $phase eq 'grace' || $phase eq 'reconnected'))
            ? $phase : 'unknown-phase';
        return { verdict => 'hold', basis => $basis };
    }

    # V2: released, but the last probe is untrustworthy -- future-dated (the
    # clock stepped back), not a plain number, or older than AC_STALE. Any of
    # these means the override has gone unverified too long, so the machine
    # stays held rather than released on stale information.
    my $probed_at = $state->{probed_at};
    # L2-style future-dated check (same rule as observe()'s own), but with a
    # 1s tolerance: probed_at and $now both round-trip through JSON (written
    # by one host_step call, read back by the next battery_verdict check) at
    # sub-second precision, and a double that close to a whole-second
    # boundary can decode a handful of microseconds HIGHER than the exact
    # value that was encoded. Without slack, that rounding noise alone reads
    # as "the clock stepped back" and wrongly holds a release that is
    # actually fresh. A real clock step-back is seconds or minutes, never
    # microseconds, so 1s of slack costs nothing real (AC1's own
    # probed_at=now+5 fixture is still well past it).
    my $stale = (!defined $probed_at || ref($probed_at) || "$probed_at" !~ /\A\d+(?:\.\d+)?\z/)
        || $probed_at > $now + 1
        || ($now - $probed_at) > BpAwakeConst::AC_STALE();
    return { verdict => 'hold', basis => 'stale' } if $stale;

    # V3: released and fresh.
    return { verdict => 'release', basis => 'expired' };
}

# clear($data_dir, $reason) -> 1 -- the `clear` CLI verb's full reset, as one
# S3-locked operation (N7/S3, fix-batch): removes the marker, resets state to
# the default (phase ac), clears any M1 mirror, and logs MARKER-CLEARED.
# Public, so bp-ac-watch.pl no longer reaches into a private sub guarded by
# `defined &` to do this (a rename here used to risk silently skipping the
# state reset while still logging success).
sub clear {
    my ($data_dir, $reason) = @_;
    my $marker_path = _marker_path($data_dir);
    _with_state_lock($data_dir, 10, sub {
        unlink $marker_path if -e $marker_path;
        _write_state($data_dir, _default_state());
    });
    _mirror_resume_on($data_dir);
    log_event($data_dir, 'cli', 'MARKER-CLEARED', {}, $reason);
    return 1;
}

# ---------------------------------------------------------------------------
# log_event -- 2.2. The only writer of ac-cycle.log.
# ---------------------------------------------------------------------------

# L5 (redteam-1): the characters log_event never lets into a log line --
# C0 controls, DEL, C1 controls (incl. NEL U+0085) and the Unicode line and
# paragraph separators.
my $LOG_CTRL = qr/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}]/;

# _log_chars($s) -- a byte string that is valid UTF-8 is decoded to
# characters first, so the C1 range above matches real C1 code points and
# never the continuation bytes of an ordinary UTF-8 character (e.g. the 0x94
# inside an em dash). A string that is not valid UTF-8 is left as is (its
# bytes then read as Latin-1, where 0x80-0x9f ARE the C1 controls).
sub _log_chars {
    my ($s) = @_;
    return $s if utf8::is_utf8($s) || $s !~ /[\x80-\xff]/;
    my $copy = $s;
    return utf8::decode($copy) ? $copy : $s;
}

sub log_event {
    my ($data_dir, $src, $event, $kv, $reason) = @_;
    return 0 unless defined $data_dir && length $data_dir;
    return 0 unless defined $event && length $event;
    $kv = {} unless ref $kv eq 'HASH';
    $src = '-' unless defined $src && length $src;
    $reason = '-' unless defined $reason && length $reason;
    $reason = _log_chars($reason);
    $reason =~ s/$LOG_CTRL/ /g;
    $reason =~ s/^\s+|\s+$//g;
    $reason = '-' unless length $reason;

    my $now = time();
    my @parts = ("src=$src");
    for my $k (sort keys %$kv) {
        my $v = $kv->{$k};
        $v = '-' unless defined $v && length("$v");
        $v = _log_chars("$v");
        # L5 (redteam-1): flatten every control/separator character, not only
        # \s -- an ESC or NUL in an unvalidated payload field (tool=) used to
        # reach the log and replay as a terminal escape under `cat`.
        $v =~ s/(?:\s|$LOG_CTRL)+/_/g;
        push @parts, "$k=$v";
    }
    my $line = sprintf('%s %s %s %s -- %s', _iso_utc($now), _iso_local($now), $event, join(' ', @parts), $reason);
    $line =~ s/[\r\n]+/ /g;

    my $dsdir = _dsdir($data_dir);
    return 0 unless _mkpath($dsdir);
    my $path = log_path($data_dir);
    my $bytes = "$line\n";
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    my $ok = eval {
        require Fcntl;
        sysopen(my $fh, $path, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_APPEND())
            or return 0;
        binmode($fh);
        my $w = syswrite($fh, $bytes);
        close($fh);
        return (defined $w && $w == length($bytes)) ? 1 : 0;
    };
    return $ok ? 1 : 0;
}

# ---------------------------------------------------------------------------
# lock helper -- ac-state.lock, 10s default timeout (2.3 step 2).
# ---------------------------------------------------------------------------

sub _flock_timeout {
    my ($fh, $secs) = @_;
    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "bp-ac-watch-lock-timeout\n" };
        alarm($secs);
        $got = flock($fh, LOCK_EX);
        alarm(0);
    };
    alarm(0);
    return $got ? 1 : 0;
}

# S3 (fix-batch, reviewer-1/redteam-1): a small helper so every
# read-modify-write of ac-state.json takes ac-state.lock, not just observe().
# _with_state_lock($data_dir, $timeout, sub { ... }) -> the sub's own return
# value, or undef if the lock could not be taken at all (open or timeout
# failure) -- the caller decides what "could not lock" means for it. The sub
# runs with the lock held; it is passed nothing and closes over whatever it
# needs.
sub _with_state_lock {
    my ($data_dir, $timeout, $cb) = @_;
    _mkpath(_dsdir($data_dir));
    my $lock_path = _lock_path($data_dir);
    open(my $lfh, '>>', $lock_path) or return undef;
    unless (_flock_timeout($lfh, $timeout)) {
        close $lfh;
        return undef;
    }
    my @r = eval { $cb->() };
    my $err = $@;
    flock($lfh, LOCK_UN);
    close $lfh;
    die $err if $err;
    return wantarray ? @r : $r[0];
}

# ---------------------------------------------------------------------------
# observe($data_dir, %o) -- 2.3. %o = (src, probe => CODE?, now => INT?,
# force => BOOL?, lock_timeout => INT?).
# ---------------------------------------------------------------------------

sub observe {
    my ($data_dir, %o) = @_;
    my $src = $o{src} // '-';
    my $force = $o{force} ? 1 : 0;
    my $now = defined $o{now} ? $o{now} : time();
    my $lock_timeout = defined $o{lock_timeout} ? $o{lock_timeout} : 10;

    my $peek = _read_state($data_dir);
    my $interval = _probe_interval();
    my $probed = 0;
    my $reading = $peek->{source} // 'unknown';
    # L2 (redteam-1): a probed_at in the FUTURE (the clock stepped back, an
    # RTC reset after a dead battery, or a forged state) is stale, not
    # fresh -- otherwise `now - probed_at < interval` holds until the clock
    # catches up and AC loss goes undetected for that whole time.
    my $probed_at = $peek->{probed_at};
    $probed_at = 0 unless defined $probed_at && !ref($probed_at) && $probed_at =~ /\A-?\d+(?:\.\d+)?\z/;
    if ($force || $probed_at > $now || ($now - $probed_at) >= $interval) {
        $reading = probe_source(%o);
        $probed = 1;
    }

    _mkpath(_dsdir($data_dir));
    my $lock_path = _lock_path($data_dir);
    open(my $lfh, '>>', $lock_path) or return {
        phase => $peek->{phase}, source => $peek->{source}, probed => 0,
        dc_since => $peek->{dc_since}, grace_until => $peek->{grace_until}, transitions => [],
    };
    unless (_flock_timeout($lfh, $lock_timeout)) {
        close $lfh;
        return {
            phase => $peek->{phase}, source => $peek->{source}, probed => 0,
            dc_since => $peek->{dc_since}, grace_until => $peek->{grace_until}, transitions => [],
        };
    }

    my $state = _read_state($data_dir);
    my %orig = %$state;
    # S1 (fix-batch, reviewer-1): queue the log lines a transition implies,
    # but do not emit them until _write_state (below) actually succeeds --
    # otherwise a write failure leaves the log claiming a transition that
    # never took effect, and the next observe() re-logs it again.
    my @pending;   # [event, kv, reason]
    my $grace_s = _grace_seconds();

    if ($state->{phase} eq 'ac') {
        if ($reading eq 'dc') {
            $state->{dc_since} = $now;
            $state->{grace_until} = $now + $grace_s;
            $state->{phase} = 'grace';
            push @pending, ['AC-LOSS-DETECTED', {}, 'AC power lost; starting the grace timer'];
            push @pending, ['GRACE-START', { until => _iso_utc($state->{grace_until}) }, 'grace period started'];
        }
    }
    elsif ($state->{phase} eq 'grace') {
        if ($reading eq 'dc') {
            my $cur_grace_until = $state->{grace_until} // ($now + $grace_s);
            my $cur_probed_at = $state->{probed_at} // 0;
            if ($now < $cur_grace_until && ($now - $cur_probed_at) <= 2 * $grace_s) {
                # no-op: still within grace, no staleness.
            }
            elsif (($now - $cur_probed_at) > 2 * $grace_s) {
                $state->{dc_since} = $now;
                $state->{grace_until} = $now + $grace_s;
                push @pending, ['GRACE-START', { until => _iso_utc($state->{grace_until}), basis => 'restart' },
                    'grace restarted after a long gap since the last probe (host likely slept)'];
            }
            elsif ($now >= $cur_grace_until) {
                $state->{phase} = 'expired';
                push @pending, ['GRACE-EXPIRED', { on_battery_since => _iso_utc($state->{dc_since}) },
                    'grace period expired with no AC reconnect'];
            }
        }
        elsif ($reading eq 'ac') {
            $state->{phase} = 'ac';
            $state->{dc_since} = undef;
            $state->{grace_until} = undef;
            push @pending, ['AC-RESTORED-IN-GRACE', {}, 'AC restored before the grace period expired'];
        }
        # unknown: no-op -- expiry needs a confirmed dc.
    }
    elsif ($state->{phase} eq 'expired' || $state->{phase} eq 'standing-down' || $state->{phase} eq 'monitoring') {
        if ($reading eq 'ac') {
            $state->{phase} = 'reconnected';
            $state->{reconnected_at} = $now;
            $state->{reconnect_basis} = 'ac';
            push @pending, ['AC-RECONNECT-DETECTED', {}, 'AC power has returned'];
        }
    }
    # reconnected: no-op -- only the director's resume clears it.

    if ($probed) {
        $state->{source} = $reading;
        $state->{probed_at} = $now;
    }
    my $saved = _write_state($data_dir, $state);

    if ($saved) {
        for my $ev (@pending) {
            log_event($data_dir, $src, @$ev);
        }
    }
    elsif (@pending) {
        log_event($data_dir, $src, 'WATCH-ERROR', {},
            'state write failed; the pending transition was skipped and will be retried');
    }

    flock($lfh, LOCK_UN);
    close $lfh;

    my $out = $saved ? $state : \%orig;
    return {
        phase => $out->{phase}, source => $out->{source}, probed => ($saved ? $probed : 0),
        dc_since => $out->{dc_since}, grace_until => $out->{grace_until},
        transitions => ($saved ? [ map { $_->[0] } @pending ] : []),
    };
}

# host_step($data_dir, %o) -> \%v (package 09, spec 2.1). The host-wide
# counterpart of observe(): one probe-or-not tick of the SAME state machine,
# plus the two safety nets observe() alone does not have (a stale-state
# reset, and a fail-open lift after ten unknown readings) and the resume log
# line host_step owns outright. Never dies; any internal failure degrades to
# hold/error with no transitions, so a caller's reconcile/decide path always
# gets a usable hash back.
sub host_step {
    my ($data_dir, %o) = @_;
    my $result = eval {
        my $now = defined $o{now} ? $o{now} : time();
        my $src = (defined $o{src} && length $o{src}) ? $o{src} : 'host-awake';
        my $lock_timeout = defined $o{lock_timeout} ? $o{lock_timeout} : 10;
        my @t;   # event names this call logged, in order.

        # Step 2: reset any state this code cannot interpret back to ac,
        # fail-open, logging once. Three cases, all handled the same way
        # (red-team m1, Decision 29(b)):
        #  - a released phase whose last probe is too old (or missing, or
        #    future-dated) to trust -- otherwise a long-dead host-ac state
        #    (the machine was off for days) would read as a fresh release
        #    the moment anything asks again;
        #  - a phase this code does not even recognise (a future/past code
        #    version, a manual edit, or an operator-run verb pointed at
        #    host-ac) -- left alone, battery_verdict's V1 holds on it
        #    forever with nothing to notice or heal it (red-team m1
        #    scenario A);
        #  - `grace` with a non-numeric/missing `grace_until` -- observe()
        #    substitutes `now + grace` on EVERY tick in that case, so grace
        #    never expires (red-team m1 scenario B).
        # Decision 29(c)/red-team m6: the log line is written only after
        # _write_state actually succeeds, never unconditionally -- a write
        # failure must not claim a reset that did not happen.
        _with_state_lock($data_dir, $lock_timeout, sub {
            my $state = _read_state($data_dir);
            my $phase = $state->{phase};
            my $unknown_phase = !_is_known_phase($phase);
            my $bad_grace = (!$unknown_phase && defined $phase && $phase eq 'grace')
                && (!defined $state->{grace_until} || ref($state->{grace_until})
                    || "$state->{grace_until}" !~ /\A\d+(?:\.\d+)?\z/);
            my $stale_release = 0;
            if (!$unknown_phase && !$bad_grace && _is_release_phase($phase)) {
                my $probed_at = $state->{probed_at};
                # 1s tolerance on the future-dated check -- see
                # battery_verdict's own header for why (sub-second JSON
                # round-trip rounding, not a real clock step-back).
                $stale_release = (!defined $probed_at || ref($probed_at) || "$probed_at" !~ /\A\d+(?:\.\d+)?\z/)
                    || $probed_at > $now + 1
                    || ($now - $probed_at) > BpAwakeConst::AC_STALE();
            }
            # red-team m5: a clock stepped BACK while in grace is caught
            # here too -- grace_until was set to (dc_since + GRACE) at the
            # time grace started, so a *numeric* grace_until sitting more
            # than one grace period ahead of `now` can only mean the clock
            # moved backwards since. Restart grace from `now` rather than a
            # full reset to ac -- the machine really is still on battery.
            my $grace_clock_back = 0;
            if (!$unknown_phase && !$bad_grace && !$stale_release
                    && defined $phase && $phase eq 'grace') {
                my $gu = $state->{grace_until};
                $grace_clock_back = (defined $gu) && ("$gu" =~ /\A\d+(?:\.\d+)?\z/)
                    && ($gu > $now + _grace_seconds() + 1);
            }
            return unless $unknown_phase || $bad_grace || $stale_release || $grace_clock_back;

            if ($grace_clock_back) {
                $state->{dc_since} = $now;
                $state->{grace_until} = $now + _grace_seconds();
                my $saved = _write_state($data_dir, $state);
                if ($saved) {
                    log_event($data_dir, $src, 'GRACE-START',
                        { until => _iso_utc($state->{grace_until}), basis => 'clock-step' },
                        'grace restarted after the clock stepped back; the previous grace_until could not be trusted');
                    push @t, 'GRACE-START';
                }
                return;
            }

            my $saved = _write_state($data_dir, _default_state());
            if ($saved) {
                log_event($data_dir, $src, 'WATCH-ERROR', { basis => 'stale-reset' },
                    'host battery state was stale; restarting from ac');
                push @t, 'WATCH-ERROR';
            }
        });

        # Step 3: one observe() call, not forced -- it probes at most once
        # per _probe_interval(), same as every other observe() caller.
        my %obs_opts = (src => $src, now => $now, lock_timeout => $lock_timeout);
        $obs_opts{probe} = $o{probe} if ref $o{probe} eq 'CODE';
        my $obs = observe($data_dir, %obs_opts);
        push @t, @{ $obs->{transitions} } if ref $obs eq 'HASH' && ref $obs->{transitions} eq 'ARRAY';

        # Step 4: unknown run (fail-open), mirroring monitor_loop's own
        # UNKNOWN_LIMIT -- ten consecutive unknown readings WHILE released
        # lift the override, because a probe that cannot tell ac from dc
        # must never be trusted to keep holding the override indefinitely.
        # Decision 29(a) (fix-batch): the counter lives in the host-ac state
        # itself, under its own lock, rather than in a per-process package
        # hash -- a per-process counter restarts at 0 on every refresher
        # handover, so the fail-open window could repeat across restarts
        # with no bound (red-team m3).
        if (ref $obs eq 'HASH' && $obs->{probed}) {
            my $should_count = (($obs->{source} // '') eq 'unknown' && _is_release_phase($obs->{phase})) ? 1 : 0;
            my $tripped = 0;
            _with_state_lock($data_dir, $lock_timeout, sub {
                my $state = _read_state($data_dir);
                my $cnt = $should_count ? (($state->{unknown_count} // 0) + 1) : 0;
                if ($cnt >= UNKNOWN_LIMIT && _is_release_phase($state->{phase})) {
                    $state->{phase} = 'reconnected';
                    $state->{reconnected_at} = $now;
                    $state->{reconnect_basis} = 'probe-failed';
                    $state->{unknown_count} = 0;
                    $tripped = _write_state($data_dir, $state) ? 1 : 0;
                }
                else {
                    $state->{unknown_count} = $cnt;
                    _write_state($data_dir, $state);
                }
            });
            if ($tripped) {
                log_event($data_dir, $src, 'WATCH-ERROR', { basis => 'probe-failed' },
                    'ten consecutive unknown probe readings while released for battery; holding again fail-open');
                push @t, 'WATCH-ERROR';
            }
        }

        # Step 5: lift. A "reconnected" phase (set either by observe() just
        # above, seeing a real `ac` reading, or by step 4's fail-open) is
        # cleared back to ac here, and ONLY here -- this never calls
        # resume_director_side, never touches ac-standdown.json and never
        # mirrors to _alt_data_dir, because this is the host-wide instance,
        # not any project's drive-solo stand-down (spec 09 2.1 step 5).
        # red-team m6: RESUME is logged only after the write succeeds (it
        # used to log first), so a write failure never claims a lift that
        # left the state sitting at "reconnected" on the very next tick.
        my $lift_basis;
        _with_state_lock($data_dir, $lock_timeout, sub {
            my $state = _read_state($data_dir);
            return unless ($state->{phase} // '') eq 'reconnected';
            my $basis = $state->{reconnect_basis} // 'ac';
            my $outage = defined $state->{dc_since} ? ($now - $state->{dc_since}) : undef;
            $state->{phase} = 'ac';
            $state->{dc_since} = undef;
            $state->{grace_until} = undef;
            $state->{reconnected_at} = undef;
            $state->{reconnect_basis} = undef;
            my $saved = _write_state($data_dir, $state);
            return unless $saved;
            log_event($data_dir, $src, 'RESUME', {
                basis => $basis, marker => 'absent',
                outage_s => (defined $outage ? int($outage) : '-'),
            }, 'host battery override lifted; holding by intent again');
            push @t, 'RESUME';
            $lift_basis = $basis;
        });

        # Step 6.
        my $st = read_state($data_dir);
        my $v = battery_verdict($st, $now);
        # review m4: battery_verdict's own basis for phase "ac" is correctly
        # just "ac" (V1, pinned by AC1) -- but a journal record for THIS
        # tick, the one that just lifted the override, is more useful
        # naming WHY it lifted (probe-failed / stale-reset) than the
        # post-lift phase name. Only this returned hash gets the override;
        # battery_verdict() itself stays exactly as specified.
        $v->{basis} = $lift_basis if defined $lift_basis;
        return {
            %$v, phase => $st->{phase}, source => $st->{source}, probed_at => $st->{probed_at},
            dc_since => $st->{dc_since}, grace_until => $st->{grace_until}, transitions => \@t,
        };
    };
    return (ref $result eq 'HASH') ? $result : { verdict => 'hold', basis => 'error', transitions => [] };
}

# ---------------------------------------------------------------------------
# standdown_director_side($data_dir, %o) -- 2.4.
# ---------------------------------------------------------------------------

sub standdown_director_side {
    my ($data_dir, %o) = @_;
    my $now = defined $o{now} ? $o{now} : time();
    my $inflight = (ref $o{inflight} eq 'ARRAY') ? $o{inflight} : [];
    my $settle = $o{keepawake_settle};
    my $lock_timeout = defined $o{lock_timeout} ? $o{lock_timeout} : 10;

    # S3: the expired-phase check + STANDDOWN-BEGIN log is a read-modify
    # decision on ac-state.json, so it takes the lock even though the write
    # itself (phase -> standing-down) happens later in this function.
    my $was_expired = _with_state_lock($data_dir, $lock_timeout, sub {
        my $state = _read_state($data_dir);
        my $expired = ($state->{phase} eq 'expired') ? 1 : 0;
        if ($expired) {
            my $inflight_str = @$inflight
                ? join(',', map { (($_->{blueprint} // '?') . '/' . ($_->{package} // '?')) } @$inflight)
                : '-';
            log_event($data_dir, 'director', 'STANDDOWN-BEGIN', { inflight => $inflight_str },
                'stand-down beginning: AC grace has expired');
        }
        return $expired;
    });
    $was_expired = $was_expired ? 1 : 0;

    my $marker_path = _marker_path($data_dir);
    unless (-e $marker_path) {
        my $payload = {
            v => 1, since => $now, since_iso => _iso_utc($now),
            reason => 'ac-loss', inflight => $inflight,
        };
        # S2: log STANDDOWN-SIGNAL-SET only once the marker write actually
        # succeeded -- the marker is the only thing the guard and the
        # acstanddown atom see, so a failed write must not claim it happened.
        if (_write_json_atomic($marker_path, $payload)) {
            log_event($data_dir, 'director', 'STANDDOWN-SIGNAL-SET', {},
                'stand-down marker written; subagent tool calls will now be refused');
        }
        else {
            log_event($data_dir, 'director', 'WATCH-ERROR', {},
                'stand-down marker write failed; subagent tool calls are NOT being refused');
        }
    }

    my $kept_path = _dsdir($data_dir) . '/keepawake.pid';
    my $was_held = (-e $kept_path) ? 'held' : 'absent';
    eval { $settle->() if ref $settle eq 'CODE' };
    my $now_held = (-e $kept_path) ? 'held' : 'absent';
    log_event($data_dir, 'director', 'KEEPAWAKE-RELEASED', { was => $was_held, now => $now_held },
        'releasing the drive-solo wake-lock for AC-loss stand-down');

    if ($was_expired) {
        _with_state_lock($data_dir, $lock_timeout, sub {
            my $state = _read_state($data_dir);
            $state->{phase} = 'standing-down';
            _write_state($data_dir, $state);
        });
    }

    my $ml = monitor_live($data_dir);
    log_event($data_dir, 'director', 'STANDDOWN-ACTION', { monitor_live => $ml },
        'stand-down action computed; the director reports ac-stand-down');

    my $state = _read_state($data_dir);

    # M1: mirror the signal to CLAUDE_PROJECT_DIR's data dir too, when it
    # differs from this (director-resolved) one -- see _alt_data_dir.
    if (-e $marker_path) {
        my $marker_payload = _read_json($marker_path);
        _mirror_standdown_on($data_dir, $marker_payload, $state) if ref $marker_payload eq 'HASH';
    }

    return {
        action => 'ac-stand-down',
        reason => 'ac-loss',
        on_battery_since_iso => (defined $state->{dc_since} ? _iso_utc($state->{dc_since}) : '-'),
        grace_expired_iso => (defined $state->{grace_until} ? _iso_utc($state->{grace_until}) : '-'),
        inflight => $inflight,
        monitor_live => ($ml ? JSON::PP::true() : JSON::PP::false()),
        # H1 (fix-batch, reviewer-1/redteam-1): the absolute data dir the
        # director just used, so the CLI's own real caller (the drive-solo
        # skill's Bash tool, which has neither CCPRAXIS_DATA_DIR nor
        # BP_PROJECT_ROOT set) can pass it straight through as --data-dir.
        data_dir => _dd($data_dir),
        log => log_path($data_dir),
    };
}

# ---------------------------------------------------------------------------
# resume_director_side($data_dir, %o) -- 2.4.
# ---------------------------------------------------------------------------

sub resume_director_side {
    my ($data_dir, %o) = @_;
    my $now = defined $o{now} ? $o{now} : time();
    my $lock_timeout = defined $o{lock_timeout} ? $o{lock_timeout} : 10;

    my $marker_path = _marker_path($data_dir);
    my $had_marker = -e $marker_path ? 1 : 0;
    unlink $marker_path if $had_marker;

    _with_state_lock($data_dir, $lock_timeout, sub {
        my $state = _read_state($data_dir);
        my $basis = $state->{reconnect_basis} // 'ac';
        my $outage = defined $state->{dc_since} ? ($now - $state->{dc_since}) : undef;
        log_event($data_dir, 'director', 'RESUME', {
            basis => $basis,
            marker => ($had_marker ? 'removed' : 'absent'),
            outage_s => (defined $outage ? int($outage) : '-'),
        }, 'resuming after AC reconnect; clearing stand-down state');

        $state->{phase} = 'ac';
        $state->{dc_since} = undef;
        $state->{grace_until} = undef;
        $state->{reconnected_at} = undef;
        $state->{reconnect_basis} = undef;
        _write_state($data_dir, $state);
    });

    _mirror_resume_on($data_dir);   # M1: clear the mirrored signal too.
    return 1;
}

# ---------------------------------------------------------------------------
# revert_reconnect_to_monitoring($data_dir, %o) -- M2 (fix-batch,
# redteam-1): the director calls this instead of resume_director_side when
# a FRESH probe taken at resume time contradicts a stored "reconnected"
# phase (the monitor saw ac and exited, but by the time the director got
# around to resuming, a fresh reading is dc -- a flicker, or a fail-open
# resume after 10 unknown readings that was itself wrong). Reverts the
# phase to "monitoring" (the monitor process has already exited by
# definition, so the caller's own ac-stand-down path restarts it) instead
# of resuming onto battery with the wake-lock re-asserted. A no-op
# (returns 0) unless the phase is actually "reconnected" right now.
# ---------------------------------------------------------------------------

sub revert_reconnect_to_monitoring {
    my ($data_dir, %o) = @_;
    my $lock_timeout = defined $o{lock_timeout} ? $o{lock_timeout} : 10;
    my $did = _with_state_lock($data_dir, $lock_timeout, sub {
        my $state = _read_state($data_dir);
        return 0 unless ($state->{phase} // '') eq 'reconnected';
        $state->{phase} = 'monitoring';
        $state->{reconnected_at} = undef;
        $state->{reconnect_basis} = undef;
        my $ok = _write_state($data_dir, $state);
        log_event($data_dir, 'director', 'WATCH-ERROR', { basis => 'reconnect-reverted' },
            'a fresh probe at resume time read dc; the reconnect was premature -- reverting to monitoring')
            if $ok;
        return $ok ? 1 : 0;
    });
    return $did ? 1 : 0;
}

# ---------------------------------------------------------------------------
# monitor_live($data_dir) -- 2.4.
# ---------------------------------------------------------------------------

sub monitor_live {
    my ($data_dir) = @_;
    _mkpath(_dsdir($data_dir));
    my $path = _monlock_path($data_dir);
    open(my $fh, '>>', $path) or return 0;
    my $got = flock($fh, LOCK_EX | LOCK_NB);
    if ($got) {
        flock($fh, LOCK_UN);
        close $fh;
        return 0;
    }
    close $fh;
    return 1;
}

# ---------------------------------------------------------------------------
# guard_active($data_dir) -- 2.4.
# ---------------------------------------------------------------------------

sub guard_active {
    my ($data_dir) = @_;
    my $marker_path = _marker_path($data_dir);
    return 0 unless -e $marker_path;

    # L1 (todo 20261003-004707-628d0000, redteam-1): the guard fails CLOSED
    # under a present marker. _read_state() maps an undecodable, unreadable
    # or missing ac-state.json to the default phase "ac", which used to let
    # a corrupt or momentarily unopenable state file (a sharing violation
    # mid-rename) wave every subagent call through. Here only a state that
    # actually decodes to a JSON object with a non-active phase disarms the
    # guard; anything else counts as active (the H3 staleness self-heal and
    # `bp-ac-watch.pl clear` below remain the way out).
    my $raw = _read_json(_state_path($data_dir));
    if (ref $raw eq 'HASH' && !ref $raw->{phase}) {
        my $phase = $raw->{phase} // 'ac';
        return 0 unless ($phase eq 'expired' || $phase eq 'standing-down' || $phase eq 'monitoring');
    }

    # H3 (fix-batch, redteam-1): nothing resumes a stand-down whose session
    # or monitor died (or that was simply abandoned) -- left alone, this
    # refuses every subagent of every session in the project forever, with
    # no reachable heal path outside drive-solo (worse yet in a sandbox,
    # where enabled() is false and the drive-solo resume path never runs at
    # all). Self-heal when the marker is older than STALE_AFTER AND no
    # monitor currently holds ac-monitor.lock -- a live monitor is the one
    # legitimate reason the marker can be this old while still meaning
    # something.
    my @mst = stat($marker_path);
    my $marker_age = @mst ? (time() - $mst[9]) : 0;
    return 1 unless $marker_age > STALE_AFTER && !monitor_live($data_dir);

    # The self-heal is a read-modify-write of ac-state.json like every other,
    # so it takes ac-state.lock too (it was the one unlocked state write).
    # Safe from the PreToolUse path: the guard is a fresh process that holds
    # no other ac-* lock, monitor_live() is a non-blocking probe of a
    # DIFFERENT lock (ac-monitor.lock), and no lock holder waits on anything
    # the guard holds -- so there is no re-entry and no lock-order cycle. The
    # wait is bounded by GUARD_LOCK_TIMEOUT. If the lock cannot be taken in
    # time, this call is allowed without writing anything (the marker was
    # already judged stale, which was always an allow) and the heal itself
    # is retried on the next tool call. The staleness is re-checked under
    # the lock, since a resume or a fresh stand-down may have raced in.
    my $outcome = _with_state_lock($data_dir, GUARD_LOCK_TIMEOUT, sub {
        my @st = stat($marker_path);
        return 'gone' unless @st;
        my $age = time() - $st[9];
        return 'fresh' unless $age > STALE_AFTER && !monitor_live($data_dir);
        unlink $marker_path;
        _write_state($data_dir, _default_state());
        log_event($data_dir, 'guard', 'MARKER-CLEARED', { marker_age_s => int($age) },
            'stale stand-down marker with no live monitor; self-healing to ac');
        return 'healed';
    });
    return 0 unless defined $outcome;   # lock unavailable: allow, heal later.
    return ($outcome eq 'fresh') ? 1 : 0;
}

# ---------------------------------------------------------------------------
# status($data_dir) -- 2.4. No probe, no spawn.
# ---------------------------------------------------------------------------

sub status {
    my ($data_dir) = @_;
    my $state = _read_state($data_dir);
    return {
        phase => $state->{phase},
        source => $state->{source},
        probed_at_iso => ($state->{probed_at} ? _iso_utc($state->{probed_at}) : '-'),
        on_battery_since_iso => (defined $state->{dc_since} ? _iso_utc($state->{dc_since}) : '-'),
        grace_until_iso => (defined $state->{grace_until} ? _iso_utc($state->{grace_until}) : '-'),
        marker => (-e _marker_path($data_dir) ? 1 : 0),
        monitor_live => monitor_live($data_dir),
        log => log_path($data_dir),
    };
}

# ---------------------------------------------------------------------------
# production seam defaults for monitor_loop -- never exercised directly by
# any test (every ac-watch.t/ac-watch-cli.t call injects its own seams, or
# the probe file seam, which bypasses these). Best-effort; any failure here
# degrades to a safe, inert value rather than dying.
# ---------------------------------------------------------------------------

sub _legacy_dir {
    return eval {
        require "$DIR/BpContinuityLease.pm" unless defined &BpContinuityLease::legacy_dir;
        BpContinuityLease::legacy_dir();
    };
}

sub _default_arms {
    my $ldir = _legacy_dir();
    return [] unless defined $ldir;
    my $root = eval { BpContinuityLease::store_root_for($ldir) };
    return [] unless defined $root;
    my $arms = eval { BpContinuityLease::live_arms($root) };
    return [] unless ref $arms eq 'ARRAY';
    return [ map { substr(($_->{sid} // ''), 0, 8) } @$arms ];
}

# _default_sources() -> [ids] (package 09, spec 2.1 monitor additions). The
# other half of the arm set reconcile already builds (counting_ids) -- so the
# monitor's own may-sleep message names everything a battery override would
# have to beat, not just host arms. Same test guard as HostAwake::publish:
# under a direct .t run with no BUTLER_STATE_DIR, this is never pointed at a
# real registry under the operator's HOME.
sub _default_sources {
    my $bsd = $ENV{BUTLER_STATE_DIR};
    return [] if defined $0 && $0 =~ /\.t\z/ && !(defined $bsd && length $bsd);
    my $root = eval { BpContinuityLease::store_root_for(_legacy_dir()) };
    my $ids = eval {
        require "$DIR/HostAwake.pm" unless defined &HostAwake::counting_ids;
        HostAwake::counting_ids($root, time());
    };
    my @out = (ref $ids eq 'ARRAY') ? @$ids : ();
    # review m3: reconcile and decide both count a fresh OLD-style sandbox
    # hold (sandbox_holds -- a pre-08 launcher's --hold file) alongside
    # counting_ids. While a pre-08 launcher is alive (Decision 7's exemption
    # window), omitting it here would under-count what a battery override
    # actually has to beat.
    my $holds = eval {
        require "$DIR/BpPowerPlan.pm" unless defined &BpPowerPlan::sandbox_holds;
        BpPowerPlan::sandbox_holds($root);
    };
    push @out, map { "hold:$_" } @$holds if ref $holds eq 'ARRAY';
    return \@out;
}

sub _default_reconcile {
    my (@args) = @_;
    my $ok = eval {
        require "$DIR/BpPowerPlan.pm" unless defined &BpPowerPlan::reconcile;
        1;
    };
    return { outcome => 'error', reason => 'power-plan-unavailable' } unless $ok;
    return eval { BpPowerPlan::reconcile(@args) } // { outcome => 'error', reason => 'reconcile-died' };
}

sub _default_wakelock_state {
    return 'unknown' if $ENV{CCPRAXIS_NO_WAKELOCK};
    my $ldir = _legacy_dir();
    return 'released' unless defined $ldir;
    my $ok = eval {
        require "$DIR/BpContinuityLease.pm" unless defined &BpContinuityLease::state;
        1;
    };
    return 'unknown' unless $ok;
    my $stale_after = eval { $BpContinuityLease::TICK_SECONDS * BpContinuityLease::stale_ticks() } // BpAwakeConst::AC_STALE();
    my $wl = eval {
        BpContinuityLease::state($ldir, pid_alive => sub {
            my $pf = BpContinuityLease::wakelock_pid_file($ldir);
            my @st = stat($pf);
            return 0 unless @st;
            my $age = time() - $st[9];
            return 1 if $age < 0;
            return $age < $stale_after ? 1 : 0;
        });
    };
    return (defined $wl && length $wl) ? $wl : 'unknown';
}

sub _drive_solo_lock_state {
    my ($data_dir) = @_;
    my @st = stat(_dsdir($data_dir) . '/keepawake.pid');
    return 'absent' unless @st;
    my $age = time() - $st[9];
    return ($age < BpAwakeConst::HELPER_LEASE()) ? 'held' : 'absent';
}

# ---------------------------------------------------------------------------
# monitor_loop($data_dir, %o) -- 2.4, behaviour 3.7/3.8. Returns the exit
# code (never calls exit itself); the CLI is the only caller that exits.
# ---------------------------------------------------------------------------

sub monitor_loop {
    my ($data_dir, %o) = @_;
    my $probe_cb      = $o{probe};
    my $now_cb        = $o{now}            // sub { time() };
    my $sleep_cb      = $o{sleep}          // sub { select(undef, undef, undef, $_[0]) };
    my $arms_cb       = $o{arms}           // sub { _default_arms() };
    my $sources_cb    = $o{sources}        // sub { _default_sources() };
    my $wakelock_cb   = $o{wakelock_state}  // sub { _default_wakelock_state() };
    my $reconcile_cb  = $o{reconcile}       // \&_default_reconcile;
    my $out_cb        = $o{out}            // sub { print STDOUT $_[0], "\n" };
    my $tick          = defined $o{tick} ? $o{tick} : _monitor_tick();

    my $terminated = 0;
    local $SIG{TERM} = sub { $terminated = 1 };
    local $SIG{INT}  = sub { $terminated = 1 };
    local $SIG{HUP}  = sub { $terminated = 1 };

    _mkpath(_dsdir($data_dir));
    my $lockpath = _monlock_path($data_dir);
    open(my $lfh, '>>', $lockpath) or return 1;
    unless (flock($lfh, LOCK_EX | LOCK_NB)) {
        close $lfh;
        $out_cb->('ac-monitor already running; this call exits.');
        return 3;
    }

    my $prior_phase = _with_state_lock($data_dir, 10, sub {
        my $state = _read_state($data_dir);
        my $prior = $state->{phase};
        if ($prior eq 'expired' || $prior eq 'standing-down') {
            $state->{phase} = 'monitoring';
            _write_state($data_dir, $state);
        }
        return $prior;
    });
    $prior_phase = _read_state($data_dir)->{phase} unless defined $prior_phase;
    log_event($data_dir, 'monitor', 'MONITOR-ENTER', { pid => $$, prior_phase => $prior_phase },
        'the AC-reconnect monitor is entering; the host may now sleep');

    my $live_arms = eval { $arms_cb->() } // [];
    $live_arms = [] unless ref $live_arms eq 'ARRAY';
    my $n_arms = scalar @$live_arms;
    my $arm_sids = $n_arms ? join(',', @$live_arms) : '-';
    # Package 09: the same arm set reconcile now builds for everyone --
    # host arms plus every counting registry entry (sandbox/fleet/solo) --
    # so the monitor's own text names everything a battery override has to
    # beat, not just host arms.
    my $src_ids = eval { $sources_cb->() } // [];
    $src_ids = [] unless ref $src_ids eq 'ARRAY';
    $src_ids = [ map { "$_" } grep { defined $_ && !ref $_ } @$src_ids ];
    my $n_sources = scalar @$src_ids;
    my $source_ids_str = $n_sources ? join(',', @$src_ids) : '-';
    my $wl = eval { $wakelock_cb->() };
    $wl = 'unknown' unless defined $wl && length $wl;
    my $dsl = _drive_solo_lock_state($data_dir);
    log_event($data_dir, 'monitor', 'STANDDOWN-VERIFY',
        { live_arms => $n_arms, arm_sids => $arm_sids, wake_lock => $wl, drive_solo_lock => $dsl,
          sources => $n_sources, source_ids => $source_ids_str },
        'verifying stand-down state before the AC poll');

    if ($n_arms == 0) {
        my $ldir = _legacy_dir();
        my $res = eval { $reconcile_cb->($ldir, why => 'ac-loss', journal_noop => 1) } // {};
        $res = {} unless ref $res eq 'HASH';
        my $outcome = $res->{outcome} // 'error';
        my $found = $res->{found_guid} // '-';
        my $wanted = $res->{wanted_guid} // '-';
        # Since package 03, reconcile restores the RECORDED prior plan, not
        # always the battery saver scheme -- the old fixed "Balanced" wording
        # was wrong the moment that landed. $name names whatever plan
        # reconcile actually chose.
        my $name = $res->{wanted_name} // $res->{wanted_guid} // 'unknown';
        my $reason = $outcome eq 'corrected' ? "restored $name"
                   : $outcome eq 'correct'   ? "left $name"
                   : ($res->{reason} // $outcome);
        log_event($data_dir, 'monitor', 'POWER-PLAN',
            { result => $outcome, found => $found, wanted => $wanted, reason => $reason },
            'power plan reconciled for AC-loss stand-down');
    }
    else {
        log_event($data_dir, 'monitor', 'POWER-PLAN', { result => 'skipped', reason => 'arms-remaining' },
            'another armed session is still live; leaving the power plan alone');
    }

    # Package 09: when anything (a host arm or a counting source) would
    # survive a battery override, the may-sleep line names it -- otherwise
    # byte-identical to the pre-09 text.
    my @holders = ((map { "arm:$_" } @$live_arms), @$src_ids);
    my $sleep_line = @holders
        ? sprintf('%s ac-monitor watching for AC every %ss; the host may sleep: battery overrides %d awake source(s): %s',
            _hhmm_local($now_cb->()), $tick, scalar(@holders), join(',', @holders))
        : sprintf('%s ac-monitor watching for AC every %ss; the host may sleep', _hhmm_local($now_cb->()), $tick);
    $out_cb->($sleep_line);

    my $unknown_count = 0;
    my $prev_tick_time = $now_cb->();
    my $rc;
    TICK: while (1) {
        $sleep_cb->($tick);
        if ($terminated) {
            log_event($data_dir, 'monitor', 'MONITOR-EXIT', { reason => 'signal' }, 'monitor terminated by a signal');
            $rc = 143;
            last TICK;
        }

        my $t_now = $now_cb->();
        my $gap = $t_now - $prev_tick_time;
        if ($gap > GAP_FACTOR * $tick) {
            log_event($data_dir, 'monitor', 'SUSPEND-GAP',
                { from => _iso_utc($prev_tick_time), to => _iso_utc($t_now), gap_s => int($gap) },
                'wall clock jumped between monitor ticks; the host likely slept');
        }
        $prev_tick_time = $t_now;

        my %obs_opts = (src => 'monitor', force => 1, now => $t_now);
        $obs_opts{probe} = $probe_cb if ref $probe_cb eq 'CODE';
        my $obs = observe($data_dir, %obs_opts);
        my $reading = (ref $obs eq 'HASH') ? ($obs->{source} // 'unknown') : 'unknown';

        if ($reading eq 'ac') {
            $unknown_count = 0;
            log_event($data_dir, 'monitor', 'MONITOR-EXIT', { reason => 'ac-restored' }, 'AC restored; exiting the monitor');
            $out_cb->(sprintf(
                'AC restored at %s. Resume: butler-continuity on --thread <your thread> --role driver --goal \'<what this run is for>\', then bp-drive-next.pl next.',
                _iso_utc($t_now)));
            $rc = 0;
            last TICK;
        }
        elsif ($reading eq 'unknown') {
            $unknown_count++;
            if ($unknown_count >= UNKNOWN_LIMIT) {
                _with_state_lock($data_dir, 10, sub {
                    my $st = _read_state($data_dir);
                    $st->{phase} = 'reconnected';
                    $st->{reconnected_at} = $t_now;
                    $st->{reconnect_basis} = 'probe-failed';
                    _write_state($data_dir, $st);
                });
                log_event($data_dir, 'monitor', 'MONITOR-EXIT', { reason => 'probe-failed' },
                    'ten consecutive unknown probe readings; resuming fail-open');
                $out_cb->(sprintf(
                    'AC probe failed %d times in a row; resuming fail-open. Resume: butler-continuity on --thread <your thread> --role driver --goal \'<what this run is for>\', then bp-drive-next.pl next.',
                    UNKNOWN_LIMIT));
                $rc = 2;
                last TICK;
            }
        }
        else {
            $unknown_count = 0;
        }
    }

    flock($lfh, LOCK_UN);
    close $lfh;
    return $rc;
}

1;
