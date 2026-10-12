# BpHook::Guards::TrackDispatch -- tracks Task/Agent dispatch (package 14 of
# blueprint hook-continuity-remake), successor to the old separate
# dispatch-logging and solo-worker tracking/untracking hooks, now merged
# into hooks/track-dispatch.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 2.5 (the driver marker shape) and sec 3.6 (this
# successor's own contract). Architecture: plugins/butler/docs/
# hook-architecture.md ("track-dispatch" successor row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints nothing on any path
# except the coordinator Pre single-writer-interlock deny, through
# BpHook::deny(@lines) (budget: 1 line). Everything bp-dispatch-log.pl and
# bp-write-guard.pl would have done via `perl ...` is done in-process by
# requiring those files (their own `unless (caller)` CLI guards never fire
# under require) -- a require failure is caught and the rule it feeds is
# skipped (fail open), per sec 2.2.
package BpHook::Guards::TrackDispatch;
use strict;
use warnings;
use JSON::PP ();
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;
# F1 (review B1, blocker, package 16 fix-batch): needed so _driver_pre can
# ask BindDispatch's pure decision function whether THIS dispatch would be
# denied, and skip writing the per-dispatch marker when it would. A require
# failure here is not fatal -- _driver_pre below checks "can I even call
# this" before relying on it, and degrades to "write the marker" (today's
# behaviour) rather than to a deny.
eval {
    require "$SELF_DIR/../BindDispatch.pm"
        unless grep { m{(?:^|/)BpHook/BindDispatch\.pm$} } keys %INC;
};

my $DISPATCH_LOG_OK;
my $WRITE_GUARD_OK;

# ---------------------------------------------------------------------------
# _require_dispatch_log() / _require_write_guard() -- lazy, cached, eval-
# guarded requires of the sibling scripts (sec 2.2: "require failures are
# caught; the rule that needed them is skipped"). Never spawn a process.
# ---------------------------------------------------------------------------
sub _require_dispatch_log {
    return $DISPATCH_LOG_OK if defined $DISPATCH_LOG_OK;
    $DISPATCH_LOG_OK = eval { require "$SELF_DIR/../../bp-dispatch-log.pl"; 1 } ? 1 : 0;
    return $DISPATCH_LOG_OK;
}

sub _require_write_guard {
    return $WRITE_GUARD_OK if defined $WRITE_GUARD_OK;
    $WRITE_GUARD_OK = eval { require "$SELF_DIR/../../bp-write-guard.pl"; 1 } ? 1 : 0;
    return $WRITE_GUARD_OK;
}

# ---------------------------------------------------------------------------
# small local helpers (never touch BpHook's private internals).
# ---------------------------------------------------------------------------
sub _is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _write_bytes {
    my ($path, $bytes) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    open(my $fh, '>:raw', $path) or return 0;
    print {$fh} $bytes;
    close $fh;
    return 1;
}

sub _write_bytes_atomic {
    my ($path, $bytes) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    return 0 unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} $bytes;
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, $path);
    unlink $tmp;
    return 0;
}

sub _ascii64 {
    my ($s) = @_;
    return '' unless defined $s;
    (my $v = $s) =~ s/[^\x20-\x7E]//g;
    return length($v) > 64 ? substr($v, 0, 64) : $v;
}

sub _iso_now {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _tool_use_id {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    my $v = $p->{tool_use_id};
    return undef unless defined $v && !ref($v) && length $v;
    return ($v =~ /^[A-Za-z0-9_-]{1,128}$/) ? $v : undef;
}

# dispatch_key(DESCRIPTION) -- pure, total text transform (sec 3.6, verbatim
# with track-dispatch.sh's bp_dispatch_key_of). undef when empty ("no key" --
# the caller omits the field, never stamps '').
sub _dispatch_key {
    my ($d) = @_;
    $d = defined $d ? $d : '';
    $d = lc($d);
    $d =~ s/[^a-z0-9]/-/g;
    $d =~ s/-+/-/g;
    $d =~ s/^-+//;
    $d =~ s/-+\z//;
    $d = substr($d, 0, 48);
    $d =~ s/-+\z//;
    return length($d) ? $d : undef;
}

# _attribution_tokens() -> ($bptok, $pkgtok) from BP_BLUEPRINT/BP_PACKAGE,
# validated and omitted (undef) when unset/empty/malshaped; '.'/'..' rejected.
sub _attribution_tokens {
    my $bp = $ENV{BP_BLUEPRINT};
    my $bptok = (defined $bp && $bp =~ /^[A-Za-z0-9._-]{1,64}$/ && $bp ne '.' && $bp ne '..') ? $bp : undef;
    my $pkg = $ENV{BP_PACKAGE};
    my $pkgtok = (defined $pkg && $pkg =~ /^[A-Za-z0-9._-]{1,64}$/ && $pkg ne '.' && $pkg ne '..') ? $pkg : undef;
    return ($bptok, $pkgtok);
}

# _is_post($p) -- sec 3.6: PostToolUse, or absent hook_event_name with a
# top-level tool_response key -> Post; otherwise Pre.
sub _is_post {
    my ($p) = @_;
    if (exists $p->{hook_event_name} && defined $p->{hook_event_name} && !ref($p->{hook_event_name})) {
        return ($p->{hook_event_name} eq 'PostToolUse') ? 1 : 0;
    }
    return (!exists $p->{hook_event_name} && exists $p->{tool_response}) ? 1 : 0;
}

sub _is_true_json {
    my ($v) = @_;
    return 0 unless defined $v;
    return $v ? 1 : 0 if ref $v;
    return ($v eq 'true' || $v eq '1') ? 1 : 0;
}

# redteam H1: Claude Code 2.1.280 auto-backgrounds a Task/Agent dispatch
# that sends no background key, so PostToolUse fires at LAUNCH (~176ms
# after Pre) carrying tool_response.isAsync/status:"async_launched" while
# the worker is still running -- neither marker may be cleared, and the
# record may not be resolved/closed, on that Post. Completion is signalled
# only by the matching SubagentStop.
sub _is_async_post {
    my ($p) = @_;
    my $tr = (ref $p->{tool_response} eq 'HASH') ? $p->{tool_response}
           : (ref $p->{tool_use_result} eq 'HASH') ? $p->{tool_use_result}
           : undef;
    return 0 unless defined $tr;
    return 1 if _is_true_json($tr->{isAsync});
    return 1 if defined $tr->{status} && !ref($tr->{status}) && $tr->{status} eq 'async_launched';
    return 0;
}

# GuardBash::_stale_min's own convention (CCPRAXIS_VALIDATION_STALE_MIN,
# default 180 minutes) -- redteam M6/TM6: a coordinator marker crashed
# writers never clear must not block a writer dispatch forever.
sub _stale_min {
    my $v = $ENV{CCPRAXIS_VALIDATION_STALE_MIN};
    return $v + 0 if defined $v && $v =~ /^[0-9]+$/ && $v > 0;
    return 180;
}

sub _marker_fresh {
    my ($path, $stale_min) = @_;
    my @st = stat($path);
    return 0 unless @st;
    my $mtime = $st[9];
    return 0 unless defined $mtime;
    my $now = time();
    return 0 if $mtime > $now; # future mtime -- do not trust as fresh
    my $age_min = ($now - $mtime) / 60;
    return $age_min < $stale_min ? 1 : 0;
}

sub _stop_signal_active {
    my ($bpdir_fs, $pkg) = @_;
    return 1 if -e "$bpdir_fs/runs/.shutdown";
    return 1 if -e "$bpdir_fs/runs/$pkg.force-stop";
    return 1 if -e "$bpdir_fs/runs/.paused";
    return 0;
}

# ---------------------------------------------------------------------------
# _over_cap_alarm_and_prune($root, $logdir, $now) -- sec 3.6: over 2000
# record files -> one alarm line (skipped when the alarm file is already
# >= 64 KiB), run BpDispatchLog::prune_records, treat as claimed.
# ---------------------------------------------------------------------------
sub _over_cap_alarm_and_prune {
    my ($root, $logdir, $now) = @_;
    return unless _require_dispatch_log();
    my $alarm = eval { BpDispatchLog::alarm_path($root) };
    if (defined $alarm) {
        my $sz = (-f $alarm) ? (-s $alarm) : 0;
        $sz = 0 unless defined $sz;
        if ($sz < 65536) {
            eval {
                BpDispatchLog::_mkdir_p($logdir);
                open(my $fh, '>>', $alarm) or die "cannot open $alarm: $!\n";
                print {$fh} "$now track-dispatch.sh stood aside: over 2000 records, "
                          . "this dispatch went unrecorded; running a prune\n";
                close $fh;
            };
        }
    }
    eval { BpDispatchLog::prune_records($root, $now) };
    return;
}

# ---------------------------------------------------------------------------
# _record_dispatch($ti, $type) -- sec 3.6's dedup-scan-then-write step. Never
# dies, never denies; every failure degrades to "no record written".
# ---------------------------------------------------------------------------
sub _record_dispatch {
    my ($ti, $type) = @_;
    return unless _require_dispatch_log() && _require_write_guard();

    my $base = $type;
    $base =~ s/^.*://;
    return unless $base =~ /^[A-Za-z0-9._-]{1,64}$/ && $base =~ /^bp-/;

    my $root = $ENV{BP_PROJECT_ROOT};
    return unless defined $root && _is_abs($root);

    my $now = time();
    my $desc = (defined $ti->{description} && !ref($ti->{description})) ? $ti->{description} : undef;
    my $key = _dispatch_key($desc);
    my ($bptok, $pkgtok) = _attribution_tokens();

    my $logdir = eval { BpDispatchLog::log_dir($root) };
    return unless defined $logdir;

    my @files;
    if (-d $logdir) {
        if (opendir(my $dh, $logdir)) {
            @files = sort grep { /\.json\z/ } readdir($dh);
            closedir $dh;
        }
    }

    if (scalar(@files) > 2000) {
        _over_cap_alarm_and_prune($root, $logdir, $now);
        return; # this dispatch is treated as claimed
    }

    my $claimed = 0;
    for my $f (@files) {
        my $path = "$logdir/$f";
        open(my $fh, '<:raw', $path) or next;
        my $chunk = '';
        read($fh, $chunk, 8192);
        close $fh;
        next unless defined $chunk && length $chunk;
        next unless $chunk =~ /"status"\s*:\s*"running"/;
        next unless $chunk =~ /"worker_type"\s*:\s*"([^"]*)"/;
        my $rt = $1;
        $rt =~ s/^.*://;
        next unless $rt eq $base;
        if ($chunk =~ /"package"\s*:\s*"([^"]*)"/) {
            next unless defined $pkgtok && $1 eq $pkgtok;
        }
        next unless $chunk =~ /"started_at"\s*:\s*(-?[0-9]+)/;
        my $sa = $1 + 0;
        my $d = $now - $sa;
        $d = -$d if $d < 0;
        next unless $d <= 120;
        if ($chunk =~ /"dispatch_key"\s*:\s*"([^"]*)"/) {
            my $rk = $1;
            next unless (defined $key && length $key && $rk eq $key);
        }
        $claimed = 1;
        last;
    }
    return if $claimed;

    my $id = 'hk-' . (defined $bptok ? $bptok : 'nobp') . '-' . (defined $pkgtok ? $pkgtok : 'nopkg')
           . "-$base-$now-$$-" . int(rand(32768));
    my $rec = {
        id             => $id,
        worker_type    => $base,
        started_at     => $now,
        budget_seconds => 1800,
        status         => 'running',
        role           => 'worker',
    };
    $rec->{blueprint}    = $bptok if defined $bptok;
    $rec->{package}      = $pkgtok if defined $pkgtok;
    $rec->{dispatch_key} = $key    if defined $key;

    eval { BpDispatchLog::_mkdir_p($logdir) };
    my $path = eval { BpDispatchLog::record_path($root, $id) };
    return unless defined $path;
    eval {
        BpWrite::guarded_write({
            site  => 'track-dispatch.pre',
            path  => $path,
            valid => sub { return undef },
            mutate => sub { return JSON::PP->new->canonical->encode($rec) },
        });
    };
    eval { BpDispatchLog::prune_records($root, $now) };
    return;
}

# ---------------------------------------------------------------------------
# _resolve_and_close($ti, $type, $now) -- sec 3.6 Post (1): pick the matching
# running record via BpDispatchLog::resolve_plan and close it 'done' via
# main::_close_record(..., {use_guard => 1}). Never dies, never prints.
# ---------------------------------------------------------------------------
sub _resolve_and_close {
    my ($ti, $type, $now) = @_;
    return unless defined $type && length $type;
    return unless _require_dispatch_log() && _require_write_guard();

    my $base = $type;
    $base =~ s/^.*://;
    return unless $base =~ /^[A-Za-z0-9._-]{1,64}$/ && $base =~ /^bp-/;

    my $root = $ENV{BP_PROJECT_ROOT};
    return unless defined $root && _is_abs($root);

    my $desc = (defined $ti->{description} && !ref($ti->{description})) ? $ti->{description} : undef;
    my $key = _dispatch_key($desc);
    my ($bptok, $pkgtok) = _attribution_tokens();

    my $ids = eval { BpDispatchLog::list_records($root) } || [];
    my @entries = map { { id => $_, rec => eval { BpDispatchLog::read_record($root, $_) } } } @$ids;

    my $crit = { worker_type => $base };
    $crit->{blueprint}    = $bptok if defined $bptok;
    $crit->{package}      = $pkgtok if defined $pkgtok;
    $crit->{dispatch_key} = $key    if defined $key;

    my $chosen = eval { BpDispatchLog::resolve_plan(\@entries, $crit) };
    return unless defined $chosen;

    my $rec = eval { BpDispatchLog::read_record($root, $chosen) };
    return unless ref $rec eq 'HASH';

    eval { main::_close_record($root, $chosen, $rec, 'done', $now, { use_guard => 1 }) };
    return;
}

# ---------------------------------------------------------------------------
# _ledger_desc($ti) -- description, else the first prompt line, cut to 100
# characters (sec 3.6 Post (2)).
# ---------------------------------------------------------------------------
sub _ledger_desc {
    my ($ti) = @_;
    my $desc;
    if (defined $ti->{description} && !ref($ti->{description}) && length $ti->{description}) {
        $desc = $ti->{description};
    }
    else {
        my $prompt = (defined $ti->{prompt} && !ref($ti->{prompt})) ? $ti->{prompt} : '';
        ($desc) = split /\n/, $prompt, 2;
        $desc = '' unless defined $desc;
    }
    return substr($desc, 0, 100);
}

# ---------------------------------------------------------------------------
# _append_ledger($ti, $type, $bpdir_fs, $pkg) -- sec 3.6 Post (2): under
# flock of runs/$pkg.ledger.lock (5s; timeout skips), append the header (once)
# then the bullet line. Never dies, never prints.
# ---------------------------------------------------------------------------
sub _append_ledger {
    my ($ti, $type, $bpdir_fs, $pkg) = @_;
    my $ledger = $ENV{BP_LEDGER};
    return unless defined $ledger && length $ledger;

    my $lockpath = "$bpdir_fs/runs/$pkg.ledger.lock";
    my $lockdir = $lockpath;
    $lockdir =~ s{/[^/]*\z}{};
    unless (-d $lockdir) { eval { require File::Path; File::Path::make_path($lockdir) } }
    open(my $lk, '>>', $lockpath) or return;

    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "track-dispatch-lock-timeout\n" };
        alarm(5);
        $got = flock($lk, LOCK_EX);
        alarm(0);
    };
    alarm(0);
    unless ($got) { close $lk; return; }

    eval {
        my $existing = _read_bytes($ledger);
        $existing = '' unless defined $existing;

        my $typetxt = (defined $type && length $type) ? $type : 'task';
        my $desc = _ledger_desc($ti);
        my $ts = _iso_now();
        my $dot = "\x{00B7}"; # U+00B7 MIDDLE DOT, a CHARACTER (not bytes)

        # review B2/redteam M4: build the whole line out of decoded Perl
        # characters, then utf8::encode it exactly ONCE right before the
        # print on this :raw handle. Mixing an already-encoded byte string
        # ($dot as "\xC2\xB7") with characters upgrades and mojibakes it;
        # printing decoded characters straight to :raw skips encoding
        # entirely and drops anything above Latin-1 to a single invalid
        # byte. Encoding once, here, is the only safe order.
        my $body = '';
        $body .= "\n## Dispatch log (auto)\n" unless $existing =~ /^## Dispatch log \(auto\)/m;
        $body .= "- $ts $dot $typetxt $dot $desc\n";
        utf8::encode($body);

        if (open(my $ofh, '>>:raw', $ledger)) {
            print {$ofh} $body;
            close $ofh;
        }
    };

    flock($lk, LOCK_UN);
    close $lk;
    return;
}

# ---------------------------------------------------------------------------
# Coordinator branch.
# ---------------------------------------------------------------------------
sub _coord_pre {
    my ($p, $ti, $type) = @_;
    my $bp_dir = $ENV{BP_DIR};
    (my $bpdir_fs = $bp_dir) =~ tr{\\}{/};
    $bpdir_fs =~ s{/+\z}{};
    my $pkg = $ENV{BP_PACKAGE};
    $pkg = 'pkg' unless defined $pkg && length $pkg;

    return 0 if _stop_signal_active($bpdir_fs, $pkg);
    return 0 unless defined $type && length $type;

    my $marker = "$bpdir_fs/runs/$pkg.active-worker";
    my $writer = BpHook::Guards::Common::is_writer($type);
    if (defined $writer) {
        if (-f $marker && _marker_fresh($marker, _stale_min())) {
            my $cur = _read_bytes($marker);
            $cur = '' unless defined $cur;
            if (defined BpHook::Guards::Common::is_writer($cur)) {
                my $curf = _ascii64($cur);
                return BpHook::deny(BpHook::Guards::Common::fit(
                    "BLOCKED: a write-capable worker ($curf) is already in flight; "
                  . "at most one runs at a time, so dispatch $type after it returns."));
            }
        }
        _write_bytes($marker, $type);
    }

    unless (defined $ENV{BP_DISPATCH_LOG_OFF} && $ENV{BP_DISPATCH_LOG_OFF} eq '1') {
        eval { _record_dispatch($ti, $type) };
    }
    return 0;
}

sub _coord_post {
    my ($p, $ti, $type) = @_;
    my $bp_dir = $ENV{BP_DIR};
    (my $bpdir_fs = $bp_dir) =~ tr{\\}{/};
    $bpdir_fs =~ s{/+\z}{};
    my $pkg = $ENV{BP_PACKAGE};
    $pkg = 'pkg' unless defined $pkg && length $pkg;
    my $now = time();

    my $bg_true = (exists $ti->{run_in_background} && $ti->{run_in_background}) ? 1 : 0;
    my $async   = _is_async_post($p);
    unless ((defined $ENV{BP_DISPATCH_LOG_OFF} && $ENV{BP_DISPATCH_LOG_OFF} eq '1') || $bg_true || $async) {
        eval { _resolve_and_close($ti, $type, $now) };
    }

    eval { _append_ledger($ti, $type, $bpdir_fs, $pkg) };

    if (!$async && defined $type && length $type) {
        my $marker = "$bpdir_fs/runs/$pkg.active-worker";
        if (-f $marker) {
            my $cur = _read_bytes($marker);
            if (defined $cur && $cur eq $type) { unlink $marker }
        }
    }
    return 0;
}

# ---------------------------------------------------------------------------
# Driver branch (sec 2.5's per-dispatch marker).
# ---------------------------------------------------------------------------
sub _driver_pre {
    my ($p, $ti, $type, $data_fs, $tuid) = @_;

    # F1 (review B1, blocker): a dispatch bind-dispatch DENIES must leave no
    # worker marker -- the parallel PreToolUse Task|Agent group runs
    # bind-dispatch.sh and track-dispatch.sh side by side, so without this
    # check a denied dispatch that Claude Code never actually runs still
    # leaves a marker nothing clears, wedging GuardBash's driver interlock
    # for up to 180 minutes. would_deny() is pure (no writes, no prints) and
    # fails toward 0 (write the marker, today's behaviour) on any error.
    if (defined &BpHook::BindDispatch::would_deny) {
        my $deny = eval { BpHook::BindDispatch::would_deny($p) };
        return 0 if !$@ && $deny;
    }

    my $w;
    if (defined $type && length $type) {
        $w = BpHook::Guards::Common::is_writer($type);
    }
    elsif (defined $ti->{description} && !ref($ti->{description})) {
        $w = BpHook::Guards::Common::is_writer(substr($ti->{description}, 0, 200));
    }
    elsif (defined $ti->{prompt} && !ref($ti->{prompt})) {
        $w = BpHook::Guards::Common::is_writer($ti->{prompt});
    }

    # Decision 101 B1: an exempt subagent_type (Decision 98's allowlist,
    # read from BindDispatch so the list stays single-sourced) also gets a
    # worker record written, even though is_writer() never recognises it --
    # WriteGuards' reports-only allowance (Decision 100/101 M2) reads this
    # record. GuardBash's OWN validation interlock is unaffected: it filters
    # worker records through this same is_writer() before treating one as a
    # live writer, so an exempt record written here is never counted there.
    my $is_exempt = (defined $type && length $type
        && defined &BpHook::BindDispatch::is_exempt_type
        && eval { BpHook::BindDispatch::is_exempt_type($type) }) ? 1 : 0;
    return 0 unless defined $w || $is_exempt;

    my $sid = BpHook::session_id($p);
    return 0 unless defined $sid;

    my $stype = (defined $type && length $type) ? $type : $w;
    my $dir = "$data_fs/.drive-solo/workers";
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    return 0 unless -d $dir;

    my $rec = { at => time(), session_id => $sid, subagent_type => $stype, tool_use_id => $tuid };
    my $json = eval { JSON::PP->new->utf8->canonical->encode($rec) };
    return 0 unless defined $json;
    _write_bytes_atomic("$dir/$tuid", $json . "\n");
    return 0;
}

sub _driver_post {
    my ($p, $data_fs, $tuid) = @_;
    # redteam H1: an auto-backgrounded dispatch's Post fires at launch, not
    # completion -- never clear the marker there. Only SubagentStop (below)
    # or a genuinely synchronous (non-async) Post does.
    return 0 if _is_async_post($p);
    my $path = "$data_fs/.drive-solo/workers/$tuid";
    return 0 unless -f $path;
    my $raw = _read_bytes($path);
    return 0 unless defined $raw;
    my $rec = eval { JSON::PP->new->utf8->decode($raw) };
    return 0 unless ref $rec eq 'HASH';
    my $sid = BpHook::session_id($p);
    if (defined $rec->{session_id} && defined $sid && $rec->{session_id} eq $sid) {
        unlink $path;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# SubagentStop: the only reliable completion signal for an auto-backgrounded
# dispatch (redteam H1). Maps agent_id -> toolUseId via the same meta.json
# technique GuardBash's tree interlock already uses
# (Common::subagent_tool_use_id), then clears the matching per-dispatch
# driver marker if this session wrote it.
# ---------------------------------------------------------------------------
sub _handle_subagent_stop {
    my ($p) = @_;
    return _coord_subagent_stop($p) if defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};
    my $tuid = BpHook::Guards::Common::subagent_tool_use_id($p);
    return 0 unless defined $tuid;

    my $data = BpHook::data_dir($p);
    return 0 unless defined $data && length $data;
    (my $data_fs = $data) =~ tr{\\}{/};
    $data_fs =~ s{/+\z}{};
    my $path = "$data_fs/.drive-solo/workers/$tuid";
    return 0 unless -f $path;

    my $raw = _read_bytes($path);
    return 0 unless defined $raw;
    my $rec = eval { JSON::PP->new->utf8->decode($raw) };
    return 0 unless ref $rec eq 'HASH';
    my $sid = BpHook::session_id($p);
    if (defined $rec->{session_id} && defined $sid && $rec->{session_id} eq $sid) {
        unlink $path;
    }
    return 0;
}

# _coord_subagent_stop($p) -- the coordinator's completion path for a
# backgrounded writer (bug 20261012-013358-1404). _coord_post leaves the
# marker on an async Post, as it must; without this, nothing ever cleared it,
# and it refused every test run in the package (and its siblings, through the
# shared-tree interlock) until the 180-minute age-out. The marker holds only
# the writer's type, and _coord_pre refuses a second writer while one is in
# flight, so a type match identifies the dispatch. Only a direct child counts:
# a worker's own nested subagent of the same type must not clear it.
sub _coord_subagent_stop {
    my ($p) = @_;
    my $bp_dir = $ENV{BP_DIR};
    return 0 unless defined $bp_dir && length $bp_dir;
    my $role = $ENV{BP_ROLE};
    return 0 if defined $role && $role ne '' && $role ne 'coordinator';
    (my $bpdir_fs = $bp_dir) =~ tr{\\}{/};
    $bpdir_fs =~ s{/+\z}{};
    my $pkg = $ENV{BP_PACKAGE};
    $pkg = 'pkg' unless defined $pkg && length $pkg;

    my $meta = BpHook::Guards::Common::subagent_meta($p);
    return 0 unless ref $meta eq 'HASH';
    my $depth = $meta->{spawnDepth};
    return 0 if defined $depth && !ref($depth) && $depth =~ /^\d+$/ && $depth > 1;
    my $type = $meta->{agentType};
    return 0 unless defined $type && !ref($type) && length $type;

    my $marker = "$bpdir_fs/runs/$pkg.active-worker";
    return 0 unless -f $marker;
    my $cur = _read_bytes($marker);
    unlink $marker if defined $cur && $cur eq $type;
    return 0;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';

    my $event = $p->{hook_event_name};
    if (defined $event && !ref($event) && $event eq 'SubagentStop') {
        return eval { _handle_subagent_stop($p) } // 0;
    }

    my $tool = $p->{tool_name};
    return 0 unless defined $tool && !ref($tool) && ($tool eq 'Task' || $tool eq 'Agent');

    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};
    my $type = (defined $ti->{subagent_type} && !ref($ti->{subagent_type})) ? $ti->{subagent_type} : '';
    my $is_post = _is_post($p);

    my $ledger    = $ENV{BP_LEDGER};
    my $bp_dir    = $ENV{BP_DIR};
    my $role_env  = $ENV{BP_ROLE};
    my $is_coord  = (defined $ledger && length $ledger)
        && (!defined $role_env || $role_env eq '' || $role_env eq 'coordinator')
        && (defined $bp_dir && length $bp_dir);

    if ($is_coord) {
        return $is_post ? _coord_post($p, $ti, $type) : _coord_pre($p, $ti, $type);
    }

    if (!defined $ledger || $ledger eq '') {
        my $role = eval { BpHook::role($p) };
        if (defined $role && $role eq 'driver' && !defined BpHook::agent_id($p)) {
            my $tuid = _tool_use_id($p);
            if (defined $tuid) {
                my $data = BpHook::data_dir($p);
                if (defined $data && length $data) {
                    (my $data_fs = $data) =~ tr{\\}{/};
                    $data_fs =~ s{/+\z}{};
                    if (-d "$data_fs/.drive-solo") {
                        return $is_post
                            ? _driver_post($p, $data_fs, $tuid)
                            : _driver_pre($p, $ti, $type, $data_fs, $tuid);
                    }
                }
            }
        }
    }

    return 0;
}

1;
