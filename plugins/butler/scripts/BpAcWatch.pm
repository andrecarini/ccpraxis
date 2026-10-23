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

use constant GRACE         => 300;
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
    my $r = eval { BpPowerJournal::run_bounded($argv, $BpPowerJournal::PROBE_TIMEOUT_SECONDS) };
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
    };
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
    my $stale_after = eval { $BpContinuityLease::TICK_SECONDS * BpContinuityLease::stale_ticks() } // 1800;
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
    return ($age < 900) ? 'held' : 'absent';
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
    my $wl = eval { $wakelock_cb->() };
    $wl = 'unknown' unless defined $wl && length $wl;
    my $dsl = _drive_solo_lock_state($data_dir);
    log_event($data_dir, 'monitor', 'STANDDOWN-VERIFY',
        { live_arms => $n_arms, arm_sids => $arm_sids, wake_lock => $wl, drive_solo_lock => $dsl },
        'verifying stand-down state before the AC poll');

    if ($n_arms == 0) {
        my $ldir = _legacy_dir();
        my $res = eval { $reconcile_cb->($ldir, why => 'ac-loss', journal_noop => 1) } // {};
        $res = {} unless ref $res eq 'HASH';
        my $outcome = $res->{outcome} // 'error';
        my $found = $res->{found_guid} // '-';
        my $wanted = $res->{wanted_guid} // '-';
        my $reason = $outcome eq 'corrected' ? 'switched to Balanced'
                   : $outcome eq 'correct'   ? 'already Balanced'
                   : ($res->{reason} // $outcome);
        log_event($data_dir, 'monitor', 'POWER-PLAN',
            { result => $outcome, found => $found, wanted => $wanted, reason => $reason },
            'power plan reconciled for AC-loss stand-down');
    }
    else {
        log_event($data_dir, 'monitor', 'POWER-PLAN', { result => 'skipped', reason => 'arms-remaining' },
            'another armed session is still live; leaving the power plan alone');
    }

    $out_cb->(sprintf('%s ac-monitor watching for AC every %ss; the host may sleep', _hhmm_local($now_cb->()), $tick));

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
