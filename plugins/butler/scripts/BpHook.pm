# BpHook.pm -- the shared hook core (package 03 of blueprint hook-continuity-remake).
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/03-hook-core-spec.md
# Architecture: plugins/butler/docs/hook-architecture.md ("BpHook core API",
# "Arm state storage and format", "Holder protocol", "Command binding").
#
# The only place that decides "is this session running butler work"
# (Decision 3). Additive only (Decision 19): nothing here is registered.
#
# Conventions, following BpState.pm: nothing is exported; callers use
# BpHook::name(...). Directories are read with opendir/readdir, never glob
# (glob splits on whitespace and drops fragments of a path with spaces).
# Only core modules are used (JSON::PP, Digest::SHA, Fcntl, File::Path, Cwd).
# BpProjectRoot.pm is loaded with require (an explicit path via this file's
# own directory) and never copied.
#
# Pid discipline (DC3, project CLAUDE.md "Windows landmines"): the only pids
# read are holder pids, written by a holder's own $$ and read back through
# /proc/<pid>/cmdline in the SAME (MSYS) namespace. Never /proc/*/stat,
# /proc/*/status or /proc/*/winpid; never ps -W, tasklist, taskkill or
# Get-Process; never a WINPID compared with an MSYS pid.
package BpHook;
use strict;
use warnings;
use JSON::PP ();
use Encode ();
use Digest::SHA qw(sha1_hex);
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT O_EXCL);
use File::Basename qw(dirname);
use Cwd ();
use B qw(svref_2object SVp_POK);
use Time::HiRes ();
use POSIX ();
use File::Spec ();

# never-halt 09-gb-h-residuals (spec sec 2.1, E1): the wall-clock stamp for
# "hook process start", taken as the FIRST statement of main() and local'd
# to that one call -- so an in-process caller that invokes main() again (the
# test suites do) never sees a stale stamp from a previous call, and a
# GuardHarness::run_module() call that never goes through main() at all sees
# undef (today's behaviour, unchanged).
our $MAIN_STARTED_AT;

sub started_at { return $MAIN_STARTED_AT }

my $SID_RE    = qr/\A[A-Za-z0-9_-]{1,128}\z/;
my $AGENT_RE  = qr/\A[A-Za-z0-9_-]{1,64}\z/;
my $TUID_RE   = qr/\A[A-Za-z0-9_-]{1,128}\z/;
my $TOKEN_RE  = qr/\A[0-9a-f]{8}\z/;

my %READER_BLACKLIST = map { ($_ => 1) } qw(echo printf grep rg cat sed awk head tail);

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
my $BPPROJROOT_LOADED = 0;

# --------------------------------------------------------------- errors -----

my $LAST_ERROR;
sub _clear_error { $LAST_ERROR = undef; return }
sub _set_error   { my ($m) = @_; $LAST_ERROR = $m; return }
sub last_error   { return $LAST_ERROR }

# ------------------------------------------------------------- byte/char ----

sub _is_plain_string {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $flags = svref_2object(\$v)->FLAGS;
    return ($flags & SVp_POK()) ? 1 : 0;
}

# Filesystem-path bytes: encode a character string to UTF-8 bytes, and turn
# backslashes into forward slashes. A byte string with no utf8 flag is
# assumed to already be the correct on-disk byte sequence and is left alone
# apart from the slash conversion.
sub _to_bytes {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) {
        utf8::encode($v);
    }
    else {
        # Perl keeps a string unflagged whenever every character fits in a
        # byte, even one built from a \x{..} escape (DC1: "Andr\x{e9}" is 5
        # chars, unflagged, single byte 0xE9 -- indistinguishable at the SV
        # level from a genuine byte string). Probe: if the raw bytes already
        # form valid UTF-8 (utf8::decode succeeds), they are ALREADY the
        # target encoding and must not be re-encoded (that would double-
        # encode "Andr\xC3\xA9" into "Andr\xC3\x83\xC2\xA9"). If decode
        # fails (a lone lead byte such as 0xE9 has no continuation bytes),
        # this is Perl's own per-byte character storage, and utf8::encode
        # correctly expands each such byte into its UTF-8 form.
        my $probe = $v;
        my $already_utf8 = utf8::decode($probe);
        unless ($already_utf8) {
            utf8::encode($v);
        }
    }
    $v =~ tr{\\}{/};
    return $v;
}

# A character string suitable for JSON::PP->utf8->encode: decode a
# non-flagged byte string once if it holds valid UTF-8, so nothing is ever
# encoded twice (Andre stored as bytes 41 6E 64 72 C3 A9, never doubly
# encoded as ...C3 83 C2 A9).
sub _decode_maybe {
    my ($s) = @_;
    return undef unless defined $s;
    return $s if ref $s;
    my $v = $s;
    unless (utf8::is_utf8($v)) {
        my $copy = $v;
        if (utf8::decode($copy)) { $v = $copy }
    }
    return $v;
}

# Argv-key bytes: encode a character string to UTF-8 bytes for hashing,
# WITHOUT the path helper's backslash-to-slash fold (m1/L3: argv is not a
# path, and folding \ to / would let 'a\b' and 'a/b' collide on one ticket
# key).
sub _utf8_bytes {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) {
        utf8::encode($v);
    }
    else {
        my $probe = $v;
        my $already_utf8 = utf8::decode($probe);
        unless ($already_utf8) {
            utf8::encode($v);
        }
    }
    return $v;
}

sub _to_json_path {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = _decode_maybe($s);
    $v =~ tr{\\}{/};
    return $v;
}

sub _is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

# -------------------------------------------------------------- state_dir ---

sub state_dir {
    my $bsd = $ENV{BUTLER_STATE_DIR};
    if (defined $bsd && length $bsd) {
        return undef unless _is_abs($bsd);
        my $v = _to_bytes($bsd);
        $v =~ s{/+$}{};
        return "$v/continuity";
    }
    for my $var (qw(HOME USERPROFILE)) {
        my $val = $ENV{$var};
        next unless defined $val && length $val && _is_abs($val);
        my $v = _to_bytes($val);
        $v =~ s{/+$}{};
        return "$v/.claude/butler-state/continuity";
    }
    return undef;
}

sub _ensure_bpprojroot {
    return 1 if $BPPROJROOT_LOADED;
    my $path = "$SELF_DIR/BpProjectRoot.pm";
    return 0 unless -f $path;
    my $ok = eval { require $path; 1 };
    $BPPROJROOT_LOADED = 1 if $ok;
    return $ok ? 1 : 0;
}

sub data_dir {
    my ($p) = @_;
    my $ccp = $ENV{CCPRAXIS_DATA_DIR};
    if (defined $ccp && length $ccp && _is_abs($ccp)) {
        return _to_bytes($ccp);
    }
    my $root;
    my $cpd = $ENV{CLAUDE_PROJECT_DIR};
    if (defined $cpd && length $cpd) {
        $root = $cpd;
    }
    elsif (ref $p eq 'HASH' && defined $p->{cwd} && length $p->{cwd} && _is_abs($p->{cwd})) {
        my $cwd_cand = _to_bytes($p->{cwd});
        if (-d $cwd_cand) {
            my $saved = Cwd::getcwd();
            if (defined $saved && chdir($cwd_cand)) {
                if (_ensure_bpprojroot()) {
                    $root = eval { BpProjectRoot::resolve() };
                }
                chdir($saved);
            }
        }
    }
    return undef unless defined $root && length $root;
    my $root_b = _to_bytes($root);
    my $dd = "$root_b/.ccpraxis-local-data";
    return -d $dd ? $dd : undef;
}

# ------------------------------------------------------------------ io ------

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
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

sub _basename_of {
    my ($p) = @_;
    $p =~ s{.*/}{};
    return $p;
}

sub _write_json_atomic {
    my ($path, $data) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*$}{};
    unless (-d $dir) {
        eval { require File::Path; File::Path::make_path($dir) };
    }
    return 0 unless -d $dir;
    my $json = eval { JSON::PP->new->utf8->canonical->encode($data) };
    return 0 unless defined $json;
    my $tmp = "$dir/." . _basename_of($path) . ".tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} $json . "\n";
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, $path);
    my $e = "$!";
    unlink $tmp;
    _set_error("io: $e");
    return 0;
}

sub _open_armlock {
    my ($root, $sid) = @_;
    my $lockdir = "$root/armlock";
    eval { require File::Path; File::Path::make_path($lockdir) };
    my $lockpath = "$lockdir/$sid";
    open(my $lockfh, '>>', $lockpath) or return undef;
    return $lockfh;
}

sub _flock_with_timeout {
    my ($fh, $secs) = @_;
    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "bphook-lock-timeout\n" };
        alarm($secs);
        $got = flock($fh, LOCK_EX);
        alarm(0);
    };
    alarm(0);
    return $got ? 1 : 0;
}

sub _iso_now {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _word_count {
    my ($s) = @_;
    return 0 unless defined $s;
    my @w = grep { length } split /\s+/, $s;
    return scalar @w;
}

# -------------------------------------------------------- session/agent ----

sub session_id {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    my $v = $p->{session_id};
    return undef unless defined $v && !ref($v) && _is_plain_string($v);
    return ($v =~ $SID_RE) ? $v : undef;
}

sub agent_id {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    return undef unless exists $p->{agent_id};
    my $v = $p->{agent_id};
    return undef unless defined $v;
    return '?' if ref $v;
    return ($v =~ $AGENT_RE) ? $v : '?';
}

sub _env_role_kind {
    my $ledger = $ENV{BP_LEDGER};
    if (defined $ledger && length $ledger) {
        my $role = $ENV{BP_ROLE};
        return 'coordinator' if !defined $role || $role eq '' || $role eq 'coordinator';
        return 'judge';
    }
    return 'none';
}

sub role {
    my ($p) = @_;
    my $k = _env_role_kind();
    return 'coordinator' if $k eq 'coordinator';
    return 'judge'       if $k eq 'judge';
    my $sid = session_id($p);
    return 'manual' unless defined $sid;
    my $root = state_dir();
    return 'manual' unless defined $root;
    my $data = _read_json("$root/armed/$sid");
    return 'manual' unless ref $data eq 'HASH';
    my $r = $data->{role};
    return (defined $r && ($r eq 'driver' || $r eq 'reporter')) ? $r : 'manual';
}

sub is_armed {
    my ($sid) = @_;
    my $k = _env_role_kind();
    return 1 if $k eq 'coordinator';
    return 0 if $k eq 'judge';
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    return -e "$root/armed/$sid" ? 1 : 0;
}

# ------------------------------------------------------------- arm/disarm ---

sub arm {
    my ($sid, %opts) = @_;
    _clear_error();
    unless (defined $sid && $sid =~ $SID_RE) { _set_error('bad session id'); return 0 }
    my $role = $opts{role};
    unless (defined $role && ($role eq 'driver' || $role eq 'reporter' || $role eq 'manual')) {
        _set_error('bad role');
        return 0;
    }
    my $by = $opts{by};
    unless (defined $by && $by =~ /^[a-z][a-z0-9-]{0,31}$/) { _set_error('bad role'); return 0 }
    my $root = state_dir();
    unless (defined $root) { _set_error('no state root'); return 0 }
    if (defined $opts{goal} && ref $opts{goal}) { _set_error('bad goal'); return 0 }
    my $lockdir = "$root/armlock";
    eval { require File::Path; File::Path::make_path($lockdir) };
    my $lockpath = "$lockdir/$sid";
    open(my $lockfh, '>>', $lockpath) or do { my $e = "$!"; _set_error("io: $e"); return 0 };
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        _set_error('io: lock timeout');
        return 0;
    }
    my $offpath = "$root/off/$sid";
    if (-e $offpath && $by ne 'on') {
        flock($lockfh, LOCK_UN);
        close $lockfh;
        _set_error('off');
        return 0;
    }
    my $goal;
    if (defined $opts{goal} && length $opts{goal}) {
        $goal = _decode_maybe($opts{goal});
    }
    else {
        my $prior = _read_json("$root/armed/$sid");
        if (ref $prior eq 'HASH' && defined $prior->{goal} && !ref $prior->{goal} && length $prior->{goal}) {
            $goal = $prior->{goal};
        }
    }
    my $rec = { session_id => $sid, role => $role, by => $by, at => _iso_now() };
    if (defined $opts{transcript_path}) { $rec->{transcript_path} = _to_json_path($opts{transcript_path}) }
    if (defined $goal) { $rec->{goal} = $goal }
    my $ok = _write_json_atomic("$root/armed/$sid", $rec);
    if ($ok && $by eq 'on') { unlink($offpath) }
    flock($lockfh, LOCK_UN);
    close $lockfh;
    unless ($ok) { _set_error('io: write failed'); return 0 }
    return 1;
}

sub disarm {
    my ($sid, %opts) = @_;
    _clear_error();
    unless (defined $sid && $sid =~ $SID_RE) { _set_error('bad session id'); return 0 }
    my $actor = $opts{actor};
    unless (defined $actor && ($actor eq 'agent' || $actor eq 'operator')) { _set_error('bad role'); return 0 }
    my $reason = $opts{reason};
    my $root = state_dir();
    unless (defined $root) { _set_error('no state root'); return 0 }
    my $lockdir = "$root/armlock";
    eval { require File::Path; File::Path::make_path($lockdir) };
    my $lockpath = "$lockdir/$sid";
    open(my $lockfh, '>>', $lockpath) or do { my $e = "$!"; _set_error("io: $e"); return 0 };
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        _set_error('io: lock timeout');
        return 0;
    }
    my $armed_data = _read_json("$root/armed/$sid");
    my $tp = (ref $armed_data eq 'HASH' && defined $armed_data->{transcript_path} && length $armed_data->{transcript_path})
        ? $armed_data->{transcript_path}
        : undef;
    unlink("$root/armed/$sid");
    unlink("$root/silence/$sid");
    unlink("$root/running/$sid");
    unlink("$root/holder/$sid.json");
    revoke_stop_token($sid);
    revoke_disarm_otp($sid);
    my $rec = { session_id => $sid, actor => $actor, reason => _decode_maybe($reason), at => _iso_now() };
    if (defined $tp) { $rec->{transcript_path} = $tp }
    my $ok = _write_json_atomic("$root/off/$sid", $rec);
    flock($lockfh, LOCK_UN);
    close $lockfh;
    unless ($ok) { _set_error('io: write failed'); return 0 }
    return 1;
}

sub latest_is_off {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    return -e "$root/off/$sid" ? 1 : 0;
}

# ------------------------------------------------------------ prompt marker -
# never-halt package 11 (Decision 43, N3/N5): prompt_marker is the one path
# formula shared by the bash shim (arm-nudge-prompt.sh, which reproduces this
# by hand since it cannot call perl) and this module's own readers below.
# last_prompt_epoch and operator_off are pure readers, used by the chart
# reminder's N5 nudge; neither ever dies on bad input.

sub prompt_marker {
    my ($sid) = @_;
    return undef unless defined $sid && !ref($sid) && $sid =~ $SID_RE;
    my $root = state_dir();
    return undef unless defined $root;
    return "$root/prompted/$sid";
}

sub last_prompt_epoch {
    my ($sid) = @_;
    my $path = prompt_marker($sid);
    return undef unless defined $path;
    my $raw = _read_bytes($path);
    return undef unless defined $raw;
    return undef unless $raw =~ /\A([0-9]{1,12})\r?\n?\z/;
    return $1 + 0;
}

sub operator_off {
    my ($sid) = @_;
    return 0 unless defined $sid && !ref($sid) && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    my $data = _read_json("$root/off/$sid");
    return (ref $data eq 'HASH' && defined $data->{actor} && !ref($data->{actor}) && $data->{actor} eq 'operator') ? 1 : 0;
}

# ------------------------------------------------------------------ silence -

sub set_silence {
    my ($sid, %opts) = @_;
    _clear_error();
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $reason = $opts{reason};
    return 0 unless defined $reason && _word_count($reason) >= 2;
    my $root = state_dir();
    unless (defined $root) { _set_error('no state root'); return 0 }
    my $lockfh = _open_armlock($root, $sid);
    unless ($lockfh) { my $e = "$!"; _set_error("io: $e"); return 0 }
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        _set_error('io: lock timeout');
        return 0;
    }
    my $rec = { session_id => $sid, by => 'butler-continuity', reason => _decode_maybe($reason), at => _iso_now() };
    my $ok = _write_json_atomic("$root/silence/$sid", $rec) ? 1 : 0;
    flock($lockfh, LOCK_UN);
    close $lockfh;
    return $ok;
}

sub take_silence {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    my $lockfh = _open_armlock($root, $sid);
    return 0 unless $lockfh;
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        return 0;
    }
    my $path = "$root/silence/$sid";
    my $data = _read_json($path);
    my $valid = 0;
    if (ref $data eq 'HASH'
        && defined $data->{session_id} && $data->{session_id} eq $sid
        && defined $data->{by} && $data->{by} eq 'butler-continuity'
        && defined $data->{reason} && _word_count($data->{reason}) >= 2)
    {
        $valid = 1;
    }
    my $unlinked = unlink($path) ? 1 : 0;
    flock($lockfh, LOCK_UN);
    close $lockfh;
    return ($valid && $unlinked) ? 1 : 0;
}

# ------------------------------------------------------------------- holder -

sub holder {
    my ($sid) = @_;
    return undef unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return undef unless defined $root;
    my $data = _read_json("$root/holder/$sid.json");
    return (ref $data eq 'HASH' && defined $data->{session_id} && $data->{session_id} eq $sid) ? $data : undef;
}

sub holder_live {
    my ($sid, $p) = @_;
    return 0 unless defined $sid;
    my $h = holder($sid);
    return 0 unless ref $h eq 'HASH';
    my $now = time();
    my $deadline = $h->{deadline};
    return 0 unless defined $deadline && $deadline =~ /^-?\d+$/ && $deadline > $now && $deadline <= $now + 3600;

    my $role = role($p);
    my $is_coord = ($role eq 'coordinator') ? 1 : 0;

    my $items = (ref $h->{items} eq 'ARRAY') ? $h->{items} : [];

    if ($is_coord) {
        my %item_set = map { (defined $_ ? ($_ => 1) : ()) } @$items;
        my $bg = (ref $p eq 'HASH') ? $p->{background_tasks} : undef;
        return 0 unless ref $bg eq 'ARRAY';
        my $found = 0;
        for my $entry (@$bg) {
            next unless ref $entry eq 'HASH';
            next unless defined $entry->{status} && $entry->{status} eq 'running';
            next unless defined $entry->{id} && $item_set{$entry->{id}};
            next unless defined $entry->{type} && $entry->{type} eq 'subagent';
            $found = 1;
            last;
        }
        return $found ? 1 : 0;
    }

    # Non-coordinator (Decision 130 M1+S3, extended by Decision 131): a live
    # holder process (pid+fp) whose record still holds items IS the
    # evidence -- no background_tasks cross-check at all. This holds even
    # when the held id reads completed, is absent from the payload, or only
    # unheld work is running: the fixed holder already prunes finished
    # items and holds a resumed agent on its own. An empty items record
    # never counts, another session's holder never counts (holder($sid) is
    # already scoped to this sid), and a dead holder never passes.
    return 0 unless @$items;
    return 0 unless _holder_proc_alive($h);
    return 1;
}

# _holder_proc_alive($h) -> 1|0 -- holder_live's step 3, shared with
# running_work (spec 38 sec 2.2): the record's pid is alive and, where
# /proc exists, its cmdline still hashes to the record's fp, so a recycled
# pid never reads as the holder. Same MSYS pid namespace as the writer.
sub _holder_proc_alive {
    my ($h) = @_;
    return 0 unless ref $h eq 'HASH';
    my $pid = $h->{pid};
    return 0 unless defined $pid && "$pid" =~ /^[1-9][0-9]{0,9}$/;
    if (-r '/proc/self/cmdline') {
        my $fp = $h->{fp};
        return 0 unless defined $fp && length $fp;
        return 0 if $fp eq sha1_hex('');
        my $cmdline = _read_bytes("/proc/$pid/cmdline");
        return 0 unless defined $cmdline && length $cmdline;
        return sha1_hex($cmdline) eq $fp ? 1 : 0;
    }
    return kill(0, $pid) ? 1 : 0;
}

# ------------------------------------------------------------ running work -

# butler-hold's QUIET window (2 x its default 30 s tick, see TICK_DEFAULT
# and its cross-reference comment in butler-hold.pl): a held item whose
# activity file changed this recently is running work (Decision 129), but
# ONLY when the holder is dead (Decision 130, M1+S3) -- while the holder
# process is alive, holder_live's non-empty-items check is itself the live
# evidence, so a live holder never needs this window and G8 allows before
# running_work is even reached for its own tracked ids.
my $HELD_QUIET_SECONDS = 60;

# running_work($sid, $p) -> list of {id, type} (spec 38 sec 2.2, Decision
# 129, amended by Decision 130 M1+S3). The union of (a) the Stop payload's
# running background_tasks, in payload order, and (b) -- only when the
# holder is dead -- the ids a holder record for this session holds whose
# activity file (subagents/agent-<id>.jsonl beside the payload's
# transcript, or the record's cached .output) changed within QUIET: a
# SendMessage-resumed agent may be missing from background_tasks. While the
# holder is alive, its own items are not added here at all (holder_live
# already covers them for G8); adding them here too would let a live
# holder's ids leak into the RUNNING text once the holder later dies mid-
# item, which is not a case this window needs to solve. Deduped by id. With
# a live holder, (a) drops every non-subagent entry, because the holder is
# itself a running shell task and the gate must never tell the agent to
# hold its own holder. Stats and at most one JSON read and one /proc read;
# never a process.
sub running_work {
    my ($sid, $p) = @_;
    return () unless defined $sid && $sid =~ $SID_RE && ref $p eq 'HASH';
    my $h = holder($sid);
    my $holder_alive = (ref $h eq 'HASH' && _holder_proc_alive($h)) ? 1 : 0;
    my (@work, %have);

    my $bg = $p->{background_tasks};
    if (ref $bg eq 'ARRAY') {
        for my $e (@$bg) {
            next unless ref $e eq 'HASH';
            next unless _is_plain_string($e->{status}) && $e->{status} eq 'running';
            my $id = $e->{id};
            next unless _is_plain_string($id) && $id =~ $AGENT_RE;
            my $type = _is_plain_string($e->{type}) ? $e->{type} : 'task';
            next if $holder_alive && $type ne 'subagent';
            next if $have{$id}++;
            push @work, { id => $id, type => $type };
        }
    }

    if (!$holder_alive && ref $h eq 'HASH' && ref $h->{items} eq 'ARRAY') {
        my $tp = _is_plain_string($p->{transcript_path}) && length $p->{transcript_path}
            ? $p->{transcript_path} : $h->{transcript_path};
        my $sdir;
        if (_is_plain_string($tp) && length $tp) {
            $sdir = dirname(_to_bytes($tp)) . "/$sid/subagents";
        }
        my $outputs = (ref $h->{outputs} eq 'HASH') ? $h->{outputs} : {};
        my $cutoff = time() - $HELD_QUIET_SECONDS;
        for my $id (@{ $h->{items} }) {
            next unless _is_plain_string($id) && $id =~ $AGENT_RE;
            next if $have{$id};
            my @files;
            push @files, "$sdir/agent-$id.jsonl" if defined $sdir;
            push @files, _to_bytes($outputs->{$id}) if _is_plain_string($outputs->{$id}) && length $outputs->{$id};
            my $fresh = 0;
            for my $f (@files) {
                my $mt = (stat($f))[9];
                if (defined $mt && $mt >= $cutoff) { $fresh = 1; last }
            }
            next unless $fresh;
            my $is_agent = (defined $sdir && (-e "$sdir/agent-$id.jsonl" || -e "$sdir/agent-$id.meta.json")) ? 1 : 0;
            $have{$id} = 1;
            push @work, { id => $id, type => ($is_agent ? 'subagent' : 'task') };
        }
    }
    return @work;
}

# _valid_work(\@work) -> arrayref of clean {id, type}; invalid entries dropped.
sub _valid_work {
    my ($work) = @_;
    my @out;
    return \@out unless ref $work eq 'ARRAY';
    for my $e (@$work) {
        next unless ref $e eq 'HASH';
        next unless _is_plain_string($e->{id}) && $e->{id} =~ $AGENT_RE;
        my $type = _is_plain_string($e->{type}) && length $e->{type} ? $e->{type} : 'task';
        push @out, { id => $e->{id}, type => $type };
    }
    return \@out;
}

# running/<sid> exists iff the latest armed, non-coordinator Stop of the
# session was denied while work was running (spec 38 sec 2.2). The Stop
# gate writes it; `butler-continuity silence` reads it.
sub set_running_snapshot {
    my ($sid, $work) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    my $clean = _valid_work($work);
    return 0 unless @$clean;
    return _write_json_atomic("$root/running/$sid",
        { session_id => $sid, at => _iso_now(), work => $clean }) ? 1 : 0;
}

sub clear_running_snapshot {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    return unlink("$root/running/$sid") ? 1 : 0;
}

sub running_snapshot {
    my ($sid) = @_;
    return undef unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return undef unless defined $root;
    my $d = _read_json("$root/running/$sid");
    return undef unless ref $d eq 'HASH' && _is_plain_string($d->{session_id}) && $d->{session_id} eq $sid;
    my $clean = _valid_work($d->{work});
    return @$clean ? $clean : undef;
}

# --------------------------------------------------------------- reasons ---

sub log_reason {
    my ($sid, $actor, $verb, $text, $project) = @_;
    my $root = state_dir();
    return 0 unless defined $root;
    eval { require File::Path; File::Path::make_path($root) };
    my $path = "$root/reasons.log";
    if (-f $path) {
        my $size = (stat($path))[7];
        if (defined $size && $size > 1024 * 1024) {
            rename($path, "$path.1");
        }
    }
    my $flatten = sub {
        my ($v) = @_;
        $v = (defined $v && length $v) ? $v : '-';
        $v = _decode_maybe($v);
        $v =~ s/[\t\r\n]/ /g;
        return $v;
    };
    my $f_sid   = $flatten->($sid);
    my $f_actor = $flatten->($actor);
    my $f_verb  = $flatten->($verb);
    my $f_proj  = $flatten->($project);
    my $flat = $flatten->($text);
    $flat = substr($flat, 0, 300);
    my $line = join("\t", _iso_now(), $f_sid, $f_actor, $f_verb, $f_proj, $flat) . "\n";
    my $bytes = $line;
    if (utf8::is_utf8($bytes)) { utf8::encode($bytes) }
    sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT) or return 0;
    binmode($fh, ':raw');
    my $ok = syswrite($fh, $bytes);
    close $fh;
    return defined $ok ? 1 : 0;
}

sub gc_sessions {
    my $root = state_dir();
    return 0 unless defined $root;
    my %sids;
    for my $sub (qw(armed off)) {
        my $dir = "$root/$sub";
        next unless -d $dir;
        opendir(my $dh, $dir) or next;
        for my $e (readdir($dh)) {
            next if $e eq '.' || $e eq '..';
            next unless $e =~ $SID_RE;
            $sids{$e} = 1;
        }
        closedir $dh;
    }
    my $count = 0;
    for my $sid (sort keys %sids) {
        my $armed = _read_json("$root/armed/$sid");
        my $off   = _read_json("$root/off/$sid");
        my $tp;
        if (ref $armed eq 'HASH' && defined $armed->{transcript_path} && length $armed->{transcript_path}) {
            $tp = $armed->{transcript_path};
        }
        elsif (ref $off eq 'HASH' && defined $off->{transcript_path} && length $off->{transcript_path}) {
            $tp = $off->{transcript_path};
        }
        next unless defined $tp;
        my $path_bytes = _to_bytes($tp);
        next if -e $path_bytes;
        my $lockfh = _open_armlock($root, $sid);
        next unless $lockfh;
        unless (_flock_with_timeout($lockfh, 10)) { close $lockfh; next }
        unlink("$root/armed/$sid");
        unlink("$root/off/$sid");
        unlink("$root/silence/$sid");
        unlink("$root/running/$sid");
        unlink("$root/holder/$sid.json");
        # The Stop gate's break-glass state (StopGate.pm): the refusal streak
        # and the state-dir fallback request file. Both are per-session and
        # only ever cleared by that session's own later Stop, so a session
        # that ends mid-streak would otherwise leave them forever.
        unlink("$root/stop-refusals/$sid");
        unlink("$root/break-glass/$sid.json");
        revoke_stop_token($sid);
        revoke_disarm_otp($sid);
        flock($lockfh, LOCK_UN);
        close $lockfh;
        unlink("$root/armlock/$sid");
        log_reason($sid, 'gc', 'gc', "transcript gone: $tp", undef);
        $count++;
    }
    return $count;
}

# --------------------------------------------------------------- tickets ---

sub _normalize_ticket_name {
    my ($name) = @_;
    return undef unless defined $name && length $name;
    my $b = $name;
    $b =~ s{.*[/\\]}{};
    $b =~ s/\.(?:pl|sh)$//;
    return ($b eq 'butler-continuity' || $b eq 'butler-hold' || $b eq 'butler-fork-ok'
         || $b eq 'almanac-bug' || $b eq 'almanac-thread' || $b eq 'almanac-todo') ? $b : undef;
}

sub write_ticket {
    my ($p, $name, $argv, %opts) = @_;
    my $norm = _normalize_ticket_name($name);
    return 0 unless defined $norm;
    my $sid = session_id($p);
    return 0 unless defined $sid;
    my $tuid = (ref $p eq 'HASH') ? $p->{tool_use_id} : undef;
    return 0 unless defined $tuid && !ref($tuid) && $tuid =~ $TUID_RE;
    return 0 unless ref $argv eq 'ARRAY';
    return 0 if grep { !defined $_ } @$argv;
    my @bytes_argv = map { _utf8_bytes($_) } @$argv;
    return 0 if grep { index($_, "\0") >= 0 } @bytes_argv;
    my $root = state_dir();
    return 0 unless defined $root;
    my $k = sha1_hex(join("\0", $norm, @bytes_argv));
    my $aid = agent_id($p);
    my $rec = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        agent_id        => $aid,
        operator        => ($opts{operator} ? JSON::PP::true() : JSON::PP::false()),
        background      => ($opts{background} ? JSON::PP::true() : JSON::PP::false()),
        transcript_path => _to_json_path($p->{transcript_path}),
        cwd             => _to_json_path($p->{cwd}),
        at              => time(),
    };
    return _write_json_atomic("$root/tickets/$k/$sid.$tuid.json", $rec);
}

sub _rmdir_ticket_key_if_empty {
    my ($dir) = @_;
    if (opendir(my $dh2, $dir)) {
        my @remaining = grep { $_ ne '.' && $_ ne '..' } readdir($dh2);
        closedir $dh2;
        rmdir($dir) if @remaining == 0;
    }
    return;
}

sub take_ticket {
    my ($name, $argv) = @_;
    my $norm = _normalize_ticket_name($name);
    return undef unless defined $norm;
    return undef unless ref $argv eq 'ARRAY';
    my $root = state_dir();
    return undef unless defined $root;
    my @bytes_argv = map { _utf8_bytes($_) } @$argv;
    my $k = sha1_hex(join("\0", $norm, @bytes_argv));
    my $dir = "$root/tickets/$k";
    return undef unless -d $dir;
    opendir(my $dh, $dir) or return undef;
    my @entries = grep { /\.json$/ } readdir($dh);
    closedir $dh;
    my $now = time();
    my @live;
    for my $e (@entries) {
        my $full = "$dir/$e";
        my $data = _read_json($full);
        if (ref $data ne 'HASH'
            || !defined $data->{at} || $data->{at} !~ /^-?\d+$/
            || $data->{at} < $now - 30 || $data->{at} > $now + 30)
        {
            unlink $full;
            next;
        }
        push @live, { file => $full, data => $data };
    }
    return undef if @live == 0;

    if (@live == 1) {
        my $file = $live[0]{file};
        my $claimed = "$file.claimed.$$";
        return undef unless rename($file, $claimed);
        my $data = _read_json($claimed);
        unlink($claimed);
        _rmdir_ticket_key_if_empty($dir);
        return ref $data eq 'HASH' ? $data : undef;
    }

    # 2+ live entries. Ambiguity is only ever across sessions (task 50, spec
    # 2.5): same-session duplicates (a guard-blocked attempt plus its retry)
    # bind instead of refusing. agent_id differing (undef counts as its own
    # value) also stays ambiguous -- a main-thread call and a subagent call
    # must never merge.
    my %sids = map { (defined $_->{data}{session_id} ? $_->{data}{session_id} : "\0undef") => 1 } @live;
    return 'ambiguous' if scalar(keys %sids) > 1;

    my %aids = map { (defined $_->{data}{agent_id} ? $_->{data}{agent_id} : "\0undef") => 1 } @live;
    return 'ambiguous' if scalar(keys %aids) > 1;

    # One session, one agent: claim every entry. An entry another process
    # claimed first (rename failed) is skipped, not fatal.
    my @claimed;
    for my $ent (@live) {
        my $c = "$ent->{file}.claimed.$$";
        next unless rename($ent->{file}, $c);
        my $d = _read_json($c);
        unlink($c);
        next unless ref $d eq 'HASH';
        push @claimed, { file => $ent->{file}, data => $d };
    }
    _rmdir_ticket_key_if_empty($dir);
    return undef unless @claimed;

    # Base record: the claimed entry with the greatest `at`; ties broken by
    # file name, lexically last.
    my @sorted = sort {
        (($b->{data}{at} // 0) <=> ($a->{data}{at} // 0))
            || ($b->{file} cmp $a->{file})
    } @claimed;
    my $base      = $sorted[0]{data};
    my $base_file = $sorted[0]{file};
    my $base_at   = $base->{at};

    # operator: true only if EVERY claimed entry has operator true -- a
    # stale ticket can never upgrade a call to operator.
    my $operator_all = 1;
    for my $e (@claimed) {
        $operator_all = 0 unless $e->{data}{operator};
    }

    # background: the base record's value, except that if another claimed
    # entry shares the SAME greatest `at` with a different background, the
    # conservative answer (false) wins.
    my $background = $base->{background} ? 1 : 0;
    for my $e (@claimed) {
        next if $e->{file} eq $base_file;
        next unless ($e->{data}{at} // 0) == $base_at;
        my $eb = $e->{data}{background} ? 1 : 0;
        $background = 0 if $eb != $background;
    }

    my %result = %$base;
    $result{operator}   = $operator_all ? JSON::PP::true()  : JSON::PP::false();
    $result{background} = $background   ? JSON::PP::true() : JSON::PP::false();
    return \%result;
}

# local_utc_hhmm($epoch) -> "HH:MM (HH:MMZ)" -- local half from localtime,
# UTC half from gmtime, both from the SAME integer epoch, both truncated to
# the minute. `localtime` is evaluated at the call: no zone is hard-coded,
# $ENV{TZ} is never assigned here, and no zone NAME/abbreviation (%Z) is
# ever printed (Git for Windows derives abbreviations from the Windows zone
# name, which is how "W. Europe Standard Time" became "WEST").
sub local_utc_hhmm {
    my ($epoch) = @_;
    return undef unless defined $epoch && !ref($epoch) && $epoch =~ /^-?\d+$/;
    my @l = localtime($epoch);
    my @g = gmtime($epoch);
    return sprintf('%02d:%02d (%02d:%02dZ)', $l[2], $l[1], $g[2], $g[1]);
}

# ------------------------------------------------------------- stop tokens --

sub _rand_token {
    my $bytes;
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, 4);
        close $fh;
    }
    if (defined $bytes && length($bytes) == 4) {
        return lc(unpack('H*', $bytes));
    }
    return substr(sha1_hex(time() . $$ . rand()), 0, 8);
}

sub _write_current_token {
    my ($root, $sid, $token) = @_;
    my $dir = "$root/stop-tokens";
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    my $tmp = "$dir/.$sid.current.tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} "$token\n";
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, "$dir/$sid.current");
    unlink $tmp;
    return 0;
}

sub mint_stop_token {
    my ($sid, $p) = @_;
    return undef unless defined $sid && $sid =~ $SID_RE;
    return undef unless ref $p eq 'HASH';
    return undef unless defined $p->{hook_event_name} && $p->{hook_event_name} eq 'Stop';
    return undef if defined agent_id($p);
    my $root = state_dir();
    return undef unless defined $root;

    revoke_stop_token($sid);

    my $dir = "$root/stop-tokens";
    eval { require File::Path; File::Path::make_path($dir) };
    my ($token, $created);
    for (1 .. 5) {
        $token = _rand_token();
        if (sysopen(my $fh, "$dir/$token", O_WRONLY | O_CREAT | O_EXCL)) {
            binmode($fh, ':raw');
            my $json = JSON::PP->new->utf8->canonical->encode({ session_id => $sid, minted_at => time() });
            my $ok = print {$fh} $json . "\n";
            $ok &&= close($fh);
            unless ($ok) { unlink "$dir/$token"; next }
            $created = 1;
            last;
        }
    }
    return undef unless $created;
    unless (_write_current_token($root, $sid, $token)) {
        unlink "$dir/$token";
        return undef;
    }
    return $token;
}

sub revoke_stop_token {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    my $cur_path = "$root/stop-tokens/$sid.current";
    my $removed_tok = 0;
    if (open(my $fh, '<:raw', $cur_path)) {
        local $/;
        my $t = <$fh>;
        close $fh;
        if (defined $t) {
            $t =~ s/\s+$//;
            if ($t =~ $TOKEN_RE) {
                $removed_tok = unlink("$root/stop-tokens/$t") ? 1 : 0;
            }
        }
    }
    my $removed_cur = unlink($cur_path) ? 1 : 0;
    return ($removed_tok || $removed_cur) ? 1 : 0;
}

sub take_stop_token {
    my ($t) = @_;
    return undef unless defined $t && $t =~ $TOKEN_RE;
    my $root = state_dir();
    return undef unless defined $root;
    my $path = "$root/stop-tokens/$t";
    my $claimed = "$path.taken.$$";
    return undef unless rename($path, $claimed);
    my $sid;
    my $ok = 0;
    my $data = _read_json($claimed);
    if (ref $data eq 'HASH' && defined $data->{session_id} && $data->{session_id} =~ $SID_RE) {
        $sid = $data->{session_id};
        my $lockfh = _open_armlock($root, $sid);
        if ($lockfh && _flock_with_timeout($lockfh, 10)) {
            my $cur_path = "$root/stop-tokens/$sid.current";
            if (open(my $fh, '<:raw', $cur_path)) {
                local $/;
                my $cur = <$fh>;
                close $fh;
                if (defined $cur) { $cur =~ s/\s+$//; $ok = 1 if $cur eq $t }
            }
            unlink($cur_path) if $ok;
            flock($lockfh, LOCK_UN);
        }
        close $lockfh if $lockfh;
    }
    unlink($claimed);
    return $ok ? $sid : undef;
}

# ------------------------------------------------------------ disarm OTPs --
# judged-continuity-disarm package 02 (spec sec 2.1): mirrors the stop-token
# trio above structurally, but stores the sanitized --reason and the gate
# result on the OTP record so off-confirm can replay today's hand-off logic
# without re-running the gate.

our $DISARM_OTP_TTL = 900;

sub _write_current_disarm_otp {
    my ($root, $sid, $otp) = @_;
    my $dir = "$root/disarm-otps";
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    my $tmp = "$dir/.$sid.current.tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} "$otp\n";
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, "$dir/$sid.current");
    unlink $tmp;
    return 0;
}

sub mint_disarm_otp {
    my ($sid, %opts) = @_;
    _clear_error();
    unless (defined $sid && !ref($sid) && $sid =~ $SID_RE) { _set_error('bad session id'); return undef }
    my $reason = $opts{reason};
    unless (defined $reason && !ref($reason) && length($reason)) { _set_error('bad args'); return undef }
    my $gate_result = $opts{gate_result};
    unless (ref $gate_result eq 'HASH') { _set_error('bad args'); return undef }
    my $broken = $gate_result->{broken};
    unless (defined $broken && !ref($broken) && ($broken eq '0' || $broken eq '1' || $broken eq '2')) {
        _set_error('bad args');
        return undef;
    }
    my $thread = $gate_result->{thread};
    if (defined $thread) {
        unless (!ref($thread) && length($thread)) { _set_error('bad args'); return undef }
    }
    my $root = state_dir();
    unless (defined $root) { _set_error('no state root'); return undef }

    revoke_disarm_otp($sid);

    my $dir = "$root/disarm-otps";
    eval { require File::Path; File::Path::make_path($dir) };
    my ($otp, $created);
    for (1 .. 5) {
        $otp = _rand_token();
        if (sysopen(my $fh, "$dir/$otp", O_WRONLY | O_CREAT | O_EXCL)) {
            binmode($fh, ':raw');
            my $rec = {
                session_id  => $sid,
                minted_at   => time(),
                reason      => _decode_maybe($reason),
                gate_result => { thread => $thread, broken => $broken + 0 },
            };
            my $json = JSON::PP->new->utf8->canonical->encode($rec);
            my $ok = print {$fh} $json . "\n";
            $ok &&= close($fh);
            unless ($ok) { unlink "$dir/$otp"; next }
            $created = 1;
            last;
        }
    }
    unless ($created) { _set_error('io: could not create otp file'); return undef }
    unless (_write_current_disarm_otp($root, $sid, $otp)) {
        unlink "$dir/$otp";
        _set_error('io: write failed');
        return undef;
    }
    return $otp;
}

sub revoke_disarm_otp {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    my $cur_path = "$root/disarm-otps/$sid.current";
    my $removed_otp = 0;
    if (open(my $fh, '<:raw', $cur_path)) {
        local $/;
        my $t = <$fh>;
        close $fh;
        if (defined $t) {
            $t =~ s/\s+$//;
            if ($t =~ $TOKEN_RE) {
                $removed_otp = unlink("$root/disarm-otps/$t") ? 1 : 0;
            }
        }
    }
    my $removed_cur = unlink($cur_path) ? 1 : 0;
    return ($removed_otp || $removed_cur) ? 1 : 0;
}

sub take_disarm_otp {
    my ($otp, $sid) = @_;
    return (undef, 'malformed') unless defined $otp && !ref($otp) && $otp =~ $TOKEN_RE;
    return (undef, 'malformed') unless defined $sid && !ref($sid) && $sid =~ $SID_RE;
    my $root = state_dir();
    return (undef, 'no-state-root') unless defined $root;
    my $dir = "$root/disarm-otps";
    my $path = "$dir/$otp";
    my $claimed = "$path.taken.$$";
    unless (rename($path, $claimed)) {
        return (undef, (-e "$dir/$sid.current") ? 'unknown' : 'no-live-otp');
    }

    # Consumed from here: the .taken.$$ file is unlinked before returning,
    # on every remaining path.
    my $data = _read_json($claimed);
    unlink($claimed);

    unless (ref $data eq 'HASH'
        && defined $data->{session_id} && !ref($data->{session_id}) && $data->{session_id} =~ $SID_RE
        && defined $data->{minted_at} && !ref($data->{minted_at}) && $data->{minted_at} =~ /^-?\d+$/) {
        return (undef, 'corrupt');
    }

    if ($data->{session_id} ne $sid) {
        return (undef, 'foreign-session');
    }

    my $lockfh = _open_armlock($root, $sid);
    return (undef, 'lock-timeout') unless $lockfh;
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        return (undef, 'lock-timeout');
    }

    my $cur_path = "$dir/$sid.current";
    my $cur;
    if (open(my $fh, '<:raw', $cur_path)) {
        local $/;
        $cur = <$fh>;
        close $fh;
        if (defined $cur) { $cur =~ s/\s+$// }
    }
    my $code;
    if (!defined $cur || $cur ne $otp) {
        $code = 'superseded';
    }
    else {
        unlink($cur_path);
        if (time() - $data->{minted_at} > $DISARM_OTP_TTL) {
            $code = 'expired';
        }
    }
    flock($lockfh, LOCK_UN);
    close $lockfh;
    return (undef, $code) if defined $code;

    my $gr = (ref $data->{gate_result} eq 'HASH') ? $data->{gate_result} : {};
    my $rec = {
        session_id  => $data->{session_id},
        minted_at   => $data->{minted_at},
        reason      => $data->{reason},
        gate_result => { thread => $gr->{thread}, broken => $gr->{broken} },
    };
    return ($rec, undef);
}

# --------------------------------------------------------------- stop bug --
# judged-continuity-disarm package 06 (spec sec 2.1): the ONE place that
# spawns almanac-bug.pl. Both the emergency-stop verb and the Stop gate's
# break-glass off call this. select()-polled, never alarm (measured note,
# bp-ledger.pl:100-107): a real fork via `open($fh, '-|')` with no LIST.

our $BUG_FILE_TIMEOUT = 10;

# _flat_bug_text($s) -- the title/body/area sanitizer (spec 2.1 step 4):
# decode if needed, fold every control/separator byte to a space, collapse
# runs of whitespace, trim both ends.
sub _flat_bug_text {
    my ($s) = @_;
    return '' unless defined $s;
    my $v = _decode_maybe($s);
    $v =~ s/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}]/ /g;
    $v =~ s/\s+/ /g;
    $v =~ s/^\s+|\s+\z//g;
    return $v;
}

# _bug_fail_result($err) -- the shared {id=>undef, error=>$err, note=>...}
# shape (spec 2.1 step 7): the note is the error, flattened and cut to at
# most 100 characters.
sub _bug_fail_result {
    my ($err) = @_;
    my $e = (defined $err && length("$err")) ? "$err" : 'unknown error';
    my $cut = _flat_bug_text($e);
    $cut = substr($cut, 0, 97) . '...' if length($cut) > 100;
    return { id => undef, error => $e, note => "bug report: FAILED ($cut)" };
}

# _file_stop_bug_inner(%o) -- file_stop_bug's body, called inside file_stop_
# bug's own eval. Returns the result hash on every predictable path; a die
# here (an unexpected internal failure) is caught by the caller.
sub _file_stop_bug_inner {
    my (%o) = @_;
    my $source  = $o{source};
    my $session = $o{session};
    my $actor   = $o{actor};
    my $reason  = $o{reason};
    die "file_stop_bug: bad args\n"
        unless defined $source && length($source)
            && defined $session && length($session)
            && defined $actor && length($actor)
            && defined $reason && length($reason);

    # Step 1: the goal, read BEFORE any disarm (disarm unlinks this file).
    my $goal = '(no goal recorded)';
    my $root_state = state_dir();
    if (defined $root_state) {
        my $rec = _read_json("$root_state/armed/$session");
        if (ref $rec eq 'HASH' && defined $rec->{goal} && !ref($rec->{goal}) && length($rec->{goal})) {
            $goal = $rec->{goal};
        }
    }

    # Step 2: project root.
    my $dd = data_dir({ cwd => $o{cwd} });
    return _bug_fail_result('no project data directory to file the bug report in')
        unless defined $dd;
    (my $root = $dd) =~ s{/\.ccpraxis-local-data/?$}{};

    # Step 3: script.
    my $pl = "$SELF_DIR/../../almanac/scripts/almanac-bug.pl";
    return _bug_fail_result('almanac is not installed beside butler (no almanac-bug.pl)')
        unless -f $pl;

    # Step 4: compose.
    my $title = _flat_bug_text("$source: $reason");
    my $body  = "Filed automatically by $source for session $session (actor $actor).\n\n"
              . "Reason: " . _flat_bug_text($reason) . "\n\n"
              . "Session goal: " . _flat_bug_text($goal) . "\n";
    my $area = (defined $o{area} && length(_flat_bug_text($o{area})))
        ? _flat_bug_text($o{area}) : 'butler';

    my @argv = ($^X, $pl, 'file', '--project', _to_bytes($root),
        '--title', _utf8_bytes($title), '--body', _utf8_bytes($body),
        '--severity', 'high', '--area', _utf8_bytes($area));

    # Step 5: spawn (house pattern, bp-ledger.pl:114-149).
    my $pid = open(my $fh, '-|');
    return _bug_fail_result("could not start almanac-bug.pl: $!") unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', File::Spec->devnull);
        open(STDERR, '>&STDOUT');
        # "exec ... or" -- a separate statement after exec draws perl's
        # "Statement unlikely to be reached" compile warning, which every
        # hook loading this module would then print.
        exec(@argv) or POSIX::_exit(126);
    }

    my $out = '';
    my $deadline = time() + $BUG_FILE_TIMEOUT;
    my $timed_out = 0;
    while (1) {
        my $remaining = $deadline - time();
        if ($remaining <= 0) { $timed_out = 1; last }
        my $rin = '';
        vec($rin, fileno($fh), 1) = 1;
        my $wait = $remaining > 1 ? 1 : $remaining;
        my $nfound = select($rin, undef, undef, $wait);
        if ($nfound && $nfound > 0) {
            my $buf;
            my $n = sysread($fh, $buf, 65536);
            last unless defined $n && $n > 0;    # EOF or read error -> child is done
            $out .= $buf;
        }
    }

    if ($timed_out) {
        eval { kill('KILL', $pid) };
        eval { waitpid($pid, 0) };
        eval { close($fh) };
        return _bug_fail_result('almanac-bug.pl timed out after 10s');
    }

    close($fh);
    waitpid($pid, 0);
    my $code = (defined $? ? $? : 0) >> 8;

    my @lines;
    for my $l (split /\n/, $out) {
        $l =~ s/\s+\z//;
        push @lines, $l if length $l;
    }

    if ($code == 0) {
        if (@lines && $lines[-1] =~ m{([^/\\]+)\.md\z}) {
            my $id = $1;
            return { id => $id, error => undef, note => "bug report: $id" };
        }
        return _bug_fail_result('almanac-bug.pl printed no report path');
    }

    my $err = @lines ? $lines[0] : "almanac-bug.pl exited $code";
    return _bug_fail_result($err);
}

# file_stop_bug(%o) -- spec 2.1. Never dies: the whole body runs inside
# eval, and a die becomes error => <first line of $@>. Exactly one of
# `id` and `error` is defined on return.
sub file_stop_bug {
    my (%o) = @_;
    my $res = eval { _file_stop_bug_inner(%o) };
    return $res if ref $res eq 'HASH' && (defined $res->{id} || defined $res->{error});
    my $e = (defined $@ && length("$@")) ? "$@" : 'unknown error';
    $e =~ s/\r?\n.*\z//s;
    return _bug_fail_result($e);
}

# ----------------------------------------------------------- invocations ---

# never-halt/01 fix-batch 3 (reports/01-redteam-3.md M1): _segments() is now
# the ONE lexer pass over the whole text. Earlier batches computed a
# quote-aware mask in a SEPARATE walk (_whole_text_quote_mask), used it to
# strip heredoc bodies in a second walk (_strip_heredocs), and only THEN ran
# the segment-splitting walk below -- three passes, two of which (the mask
# and the heredoc strip) never knew about the OTHER's territory. An
# apostrophe or odd quote inside a heredoc body or a "#" comment therefore
# flipped the mask's quote state for the rest of the text, either hiding a
# later real heredoc/command (false denial) or exposing a later quoted
# "'<<X'" as if it were a real heredoc operator (bypass).
#
# Both failure directions are gone once heredoc and comment detection are
# folded into the SAME walk that tracks quote/substitution state: a heredoc
# operator or a comment is only ever recognised while the CURRENT frame's
# quote state is 'none' (checked live, not from a separately-computed mask),
# and once recognised, its body/rest-of-line is skipped WITHOUT ever being
# fed to the quote-tracking code below -- so the odd quote inside it can
# never desync anything.
#
# Quote state lives PER FRAME (not one shared scalar), so "$(" / a backtick
# seen while the CURRENT frame is dquote (or none) opens a fresh frame whose
# own quote state starts 'none' -- a command substitution's body is always
# parsed for real commands, even when it sits inside an outer pair of double
# quotes. Its matching ')'/backtick pops back to the enclosing frame, which
# resumes with whatever quote state it had frozen at push time.
sub _segments {
    my ($text) = @_;
    # never-halt/01 fix-batch 3 (M2): work on a BYTE copy. A decoded
    # character string with even one non-ASCII character makes substr()'s
    # per-character walk below effectively quadratic (Perl must locate each
    # codepoint's byte offset from scratch). Every shell metacharacter this
    # lexer looks for is ASCII, and UTF-8 continuation bytes are all at or
    # above 0x80, so scanning bytes is equivalent -- and it makes substr()
    # a flat O(1) index into a byte string.
    utf8::encode($text) if utf8::is_utf8($text);

    my @segs;
    my @stack = ({ closer => undef, buf => '', quote => 'none' });
    my $len = length($text);
    my $i = 0;
    my @pending_heredocs; # ops ('$dash, $word') queued on the CURRENT line

    # never-halt 09-gb-h-residuals sec 3.5 (r2-N7c, r3-N2, r4-S1b): a bounded
    # look-ahead that recognises an arithmetic span ("$((" anywhere, or "(("
    # in command position) and reports where it ends, so the whole span can
    # be replaced by a single unpredictable placeholder -- nothing inside it
    # (heredoc operator, redirect, separator) is ever lexed. $start is the
    # index of the FIRST "(" of the "((" pair. $arith_hwm is a high-water
    # mark: once a look-ahead has failed up to some index j, any later
    # attempt starting below that mark is known to fail too and skips the
    # scan outright -- this keeps total look-ahead work linear in the text.
    my $arith_hwm = -1;
    my $try_arith = sub {
        my ($start) = @_;
        return undef if $start <= $arith_hwm;
        my $j = $start + 2;
        my $depth = 0;
        while ($j < $len) {
            my $cj = substr($text, $j, 1);
            # never-halt 09-gb-h-residuals MUST-FIX 1 (red-team H1): fail the
            # look-ahead (fall back to ordinary lexing) on '{', '}' or '\' too,
            # the same way it already fails on quotes and '$('. Without this,
            # parens embedded in ${...} pattern text (e.g. "${x//(/}") or
            # escaped with a backslash are counted as real nesting, letting
            # the scan's depth diverge from bash's and read past the true
            # closing "))" through injected commands to a later inert "))".
            if ($cj eq "\n" || $cj eq "'" || $cj eq '"' || $cj eq "\x60"
                || $cj eq '{' || $cj eq '}' || $cj eq '\\') {
                $arith_hwm = $j if $j > $arith_hwm;
                return undef;
            }
            if ($cj eq '$' && $j + 1 < $len && substr($text, $j + 1, 1) eq '(') {
                $arith_hwm = $j if $j > $arith_hwm;
                return undef;
            }
            if ($cj eq '(') { $depth++; $j++; next }
            if ($cj eq ')') {
                if ($depth > 0) { $depth--; $j++; next }
                if ($j + 1 < $len && substr($text, $j + 1, 1) eq ')') { return $j + 2 }
                $arith_hwm = $j if $j > $arith_hwm;
                return undef;
            }
            $j++;
        }
        $arith_hwm = $j if $j > $arith_hwm;
        return undef;
    };
    my $ARITH_CMD_POS_RE = qr/^[ \t]*(?:(?:if|elif|while|until|for|then|do|else|!|time)[ \t]+)*$/;

    # Consumes, verbatim and WITHOUT ever feeding the quote/frame state
    # machine above, the body of each queued heredoc (in textual order),
    # advancing $i to the first line after the last body's delimiter line.
    # Uses index()/substr() bounded by each body LINE, never the whole
    # remaining text, so cost is proportional to the bodies' own length.
    my $consume_pending_heredocs = sub {
        for my $op (@pending_heredocs) {
            my ($dash, $word) = @$op;
            while ($i <= $len) {
                my $nl = index($text, "\n", $i);
                my $line_end = ($nl >= 0) ? $nl : $len;
                my $check = substr($text, $i, $line_end - $i);
                $check =~ s/^[ \t]+// if $dash;
                $i = ($nl >= 0) ? $nl + 1 : $len;
                last if $check eq $word;
                last if $nl < 0; # unterminated heredoc: consumed to EOF
            }
        }
        @pending_heredocs = ();
    };

    while ($i < $len) {
        my $c = substr($text, $i, 1);
        my $frame = $stack[-1];
        if ($frame->{quote} eq 'squote') {
            $frame->{buf} .= $c;
            $frame->{quote} = 'none' if $c eq "'";
            $i++;
            next;
        }
        # redteam-3 S5: ANSI-C $'...' quoting -- backslash escapes the next
        # character (so \' does NOT end the quote), and it ends on an
        # unescaped "'". Entered below when "$'" is seen in 'none' state.
        if ($frame->{quote} eq 'ansic') {
            if ($c eq '\\' && $i + 1 < $len) {
                $frame->{buf} .= $c . substr($text, $i + 1, 1);
                $i += 2;
                next;
            }
            if ($c eq "'") { $frame->{buf} .= $c; $frame->{quote} = 'none'; $i++; next }
            $frame->{buf} .= $c;
            $i++;
            next;
        }
        if ($frame->{quote} eq 'dquote') {
            if ($c eq '\\' && $i + 1 < $len) {
                $frame->{buf} .= $c . substr($text, $i + 1, 1);
                $i += 2;
                next;
            }
            if ($c eq '"') {
                $frame->{buf} .= $c;
                $frame->{quote} = 'none';
                $i++;
                next;
            }
            if (substr($text, $i, 3) eq '$((') {
                # never-halt 09 sec 3.5: an arithmetic span inside a double-
                # quoted word ("$(( 3 > 2 ))") is recognised too -- on
                # success it is folded into the same unpredictable
                # placeholder as the unquoted case, so nothing inside it
                # (not even a literal '"') is re-lexed. On failure, fall
                # through to today's "$(" substitution-frame handling below.
                my $end = $try_arith->($i + 1);
                if (defined $end) {
                    $frame->{buf} .= '${_bp_arith}';
                    $i = $end;
                    next;
                }
            }
            if (substr($text, $i, 2) eq '$(') {
                # never-halt/01 M1: do NOT flush the enclosing word's buf here --
                # a quoted "$(...)" host word (e.g. "$(pwd)/.git") must stay one
                # word. The frame's dquote state is preserved on the frame
                # object itself, so pushing a new stack entry for the subst
                # body and popping back to this one resumes dquote correctly.
                push @stack, { closer => ')', buf => '', quote => 'none' };
                $i += 2;
                next;
            }
            if ($c eq "\x60") {
                push @stack, { closer => "\x60", buf => '', quote => 'none' };
                $i++;
                next;
            }
            $frame->{buf} .= $c;
            $i++;
            next;
        }
        # never-halt 09 sec 3.5: an arithmetic span starting here ("$((" at
        # any point, or "((" when this frame's buf is still in "command
        # position" -- only if/elif/while/until/for/then/do/else/!/time
        # keywords precede it) is tried BEFORE anything else in this
        # quote=='none' zone, so a "<<" or "(args to lex) inside it is never
        # mistaken for a heredoc operator or a real redirect/separator. A
        # failed look-ahead changes nothing: every check below still runs
        # against the very same '(' or '$' character (E7 -- no new bypass).
        if (substr($text, $i, 3) eq '$((') {
            my $end = $try_arith->($i + 1);
            if (defined $end) {
                $frame->{buf} .= '${_bp_arith}';
                $i = $end;
                next;
            }
        }
        elsif (substr($text, $i, 2) eq '((' && $frame->{buf} =~ $ARITH_CMD_POS_RE) {
            my $end = $try_arith->($i);
            if (defined $end) {
                $frame->{buf} .= '${_bp_arith}';
                $i = $end;
                next;
            }
        }
        # never-halt 09 sec 3.6: a frame opened by $(/<(/>() keeps its OWN
        # paren depth -- an unquoted '(' inside it is just more text (bumps
        # the depth), and a ')' only closes the frame once that depth is
        # back at 0. The top-level frame (closer undef) is untouched.
        if ($c eq '(' && defined $frame->{closer} && $frame->{closer} eq ')') {
            $frame->{depth} = ($frame->{depth} // 0) + 1;
            $frame->{buf} .= $c;
            $i++;
            next;
        }
        if (defined $frame->{closer} && $c eq $frame->{closer}) {
            if ($frame->{closer} eq ')' && ($frame->{depth} // 0) > 0) {
                # never-halt 09-gb-h-residuals MUST-FIX 2 (red-team H2 /
                # reviewer M1): an unquoted ')' that brings this frame's
                # depth back to 0 must END the segment here, exactly like
                # the existing top-level behavior below (closer undef) --
                # not be appended to the buffer. Appending let a subshell
                # like "$( (rm -rf .git) )" or a case-statement "(a)"
                # pattern-closer survive as unlexed text inside the outer
                # buf instead of being split into its own segment.
                $frame->{depth}--;
                push @segs, $frame->{buf};
                $frame->{buf} = '';
                $i++;
                next;
            }
            # never-halt/01 M1: the substitution body is still emitted as its
            # own segment (parsed as a command in its own right, Decision
            # 22 S6), but the enclosing word's buf is NOT reset by the open --
            # so on pop, append an unpredictable placeholder (the same
            # convention _tokenize_words already uses for $VAR/${VAR}) to the
            # now-current frame's buf instead of starting a new segment. That
            # keeps the host word whole and unresolvable, while any literal
            # text after the closer (e.g. "/.git") still lands in the same
            # word's tail.
            push @segs, $frame->{buf};
            pop @stack;
            $stack[-1]{buf} .= '${_bp_subst}';
            $i++;
            next;
        }
        # M1: a REAL (unquoted) heredoc operator, recognised LIVE (only
        # reached when the current frame's quote state is 'none') -- queue
        # it and keep scanning the rest of the line normally (more text, or
        # another heredoc operator, may still follow on the same line). The
        # match is anchored with pos()/\G so it never copies the remaining
        # text, and it cannot span a newline (every alternative excludes
        # "\n"), so cost is bounded by the operator+delimiter text alone.
        # The prev-char guard excludes "<<<" (a here-string, not a heredoc),
        # mirroring the old (?<!<) lookbehind.
        if ($c eq '<' && $i + 1 < $len && substr($text, $i + 1, 1) eq '<'
            && !($i > 0 && substr($text, $i - 1, 1) eq '<')) {
            pos($text) = $i;
            if ($text =~ /\G<<(-)?[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|\\([A-Za-z_][A-Za-z0-9_.-]*)|([A-Za-z_][A-Za-z0-9_.-]*))/gc) {
                my $word = defined $2 ? $2 : defined $3 ? $3 : defined $4 ? $4 : $5;
                if (defined $word && length $word) {
                    push @pending_heredocs, [ (defined $1 ? 1 : 0), $word ];
                    $i = pos($text);
                    next;
                }
            }
            # not a real heredoc operator (no valid delimiter word follows)
            # -- fall through and treat '<' as an ordinary character.
        }
        # R8-RTM1 (review M1): a '#' at word start (start of text, or right
        # after whitespace/;/|/&/() outside quotes starts a comment that
        # runs to end of line. Its text (backticks, $(...), ; and all) must
        # never be re-parsed for $( )/backtick command substitution -- skip
        # it wholesale, unlike the default per-character walk below. Bounded
        # by index(), never a per-character scan to the newline.
        if ($c eq '#') {
            my $buf = $frame->{buf};
            if ($buf eq '' || substr($buf, -1, 1) =~ /[ \t;|&(]/) {
                push @segs, $buf;
                $frame->{buf} = '';
                my $nl = index($text, "\n", $i);
                $i = ($nl >= 0) ? $nl : $len;
                next;
            }
        }
        if ($c eq "'") { $frame->{quote} = 'squote'; $frame->{buf} .= $c; $i++; next }
        if (substr($text, $i, 2) eq "\$'") {
            $frame->{quote} = 'ansic';
            $frame->{buf} .= "\$'";
            $i += 2;
            next;
        }
        if ($c eq '"') { $frame->{quote} = 'dquote'; $frame->{buf} .= $c; $i++; next }
        if ($c eq '\\' && $i + 1 < $len) { $frame->{buf} .= $c . substr($text, $i + 1, 1); $i += 2; next }
        if (substr($text, $i, 2) eq '$(') {
            # never-halt/01 M1: see the dquote '$(' branch above -- do not
            # flush the enclosing (unquoted) word's buf either, so
            # "rm -rf $(pwd)/.git" keeps "/.git" attached to the same word.
            push @stack, { closer => ')', buf => '', quote => 'none' };
            $i += 2;
            next;
        }
        if ($c eq '`') {
            push @stack, { closer => '`', buf => '', quote => 'none' };
            $i++;
            next;
        }
        if (substr($text, $i, 2) eq '<(' || substr($text, $i, 2) eq '>(') {
            push @stack, { closer => ')', buf => '', quote => 'none' };
            $i += 2;
            next;
        }
        if ($c eq ')' && !defined $frame->{closer}) {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            $i++;
            next;
        }
        if ($c eq ';' || $c eq '|') {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            $i++;
            next;
        }
        if ($c eq "\n") {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            $i++;
            $consume_pending_heredocs->() if @pending_heredocs;
            next;
        }
        if ($c eq '&') {
            my $prev = length($frame->{buf}) ? substr($frame->{buf}, -1, 1) : '';
            my $nextc = ($i + 1 < $len) ? substr($text, $i + 1, 1) : '';
            if ($prev eq '>' || $prev eq '<' || $nextc eq '>') {
                $frame->{buf} .= $c;
                $i++;
                next;
            }
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            $i++;
            next;
        }
        $frame->{buf} .= $c;
        $i++;
    }
    for my $frame (@stack) { push @segs, $frame->{buf} }
    return @segs;
}

sub _tokenize_words {
    my ($seg) = @_;
    # never-halt/01 fix-batch 3 (M2): same byte-copy reasoning as _segments()
    # -- a decoded character segment makes every substr() below quadratic.
    utf8::encode($seg) if utf8::is_utf8($seg);
    my @words;
    my $len = length($seg);
    my $i = 0;
    while ($i < $len) {
        my $c = substr($seg, $i, 1);
        if ($c eq ' ' || $c eq "\t") { $i++; next }
        my $word_start = $i;
        my $value = '';
        my @flags; # per-character: 1 iff that character of $value is unpredictable
        my $unpredictable = 0;
        my $first = 1;
        while ($i < $len) {
            my $cc = substr($seg, $i, 1);
            last if $cc eq ' ' || $cc eq "\t";
            # redteam-3 S5: $'...' (ANSI-C quoting) is ONE quoted word --
            # backslash escapes the next character (so \' does not end it),
            # and it ends on an unescaped "'". Checked before the generic
            # "'" and "$" branches below, or the "'" branch would end the
            # "quote" at the FIRST embedded "'" (even an escaped one),
            # desyncing every walk downstream (report row: printf $'it\'s').
            if ($cc eq '$' && $i + 1 < $len && substr($seg, $i + 1, 1) eq "'") {
                $unpredictable = 1;
                $value .= '$' . "'";
                push @flags, 1, 1;
                $i += 2;
                while ($i < $len) {
                    my $c2 = substr($seg, $i, 1);
                    if ($c2 eq '\\' && $i + 1 < $len) {
                        $value .= substr($seg, $i + 1, 1);
                        push @flags, 1;
                        $i += 2;
                        next;
                    }
                    last if $c2 eq "'";
                    $value .= $c2;
                    push @flags, 1;
                    $i++;
                }
                if ($i < $len && substr($seg, $i, 1) eq "'") { $value .= "'"; push @flags, 1; $i++ }
                $first = 0;
                next;
            }
            if ($cc eq "'") {
                $i++;
                while ($i < $len && substr($seg, $i, 1) ne "'") {
                    $value .= substr($seg, $i, 1);
                    push @flags, 0;
                    $i++;
                }
                $i++ if $i < $len;
                $first = 0;
                next;
            }
            if ($cc eq '"') {
                $i++;
                while ($i < $len && substr($seg, $i, 1) ne '"') {
                    my $c2 = substr($seg, $i, 1);
                    if ($c2 eq '\\' && $i + 1 < $len) {
                        $unpredictable = 1;
                        $value .= substr($seg, $i + 1, 1);
                        push @flags, 1;
                        $i += 2;
                        next;
                    }
                    my $f = ($c2 eq '$' || $c2 eq '`') ? 1 : 0;
                    $unpredictable = 1 if $f;
                    $value .= $c2;
                    push @flags, $f;
                    $i++;
                }
                $i++ if $i < $len;
                $first = 0;
                next;
            }
            if ($cc eq '\\' && $i + 1 < $len) {
                $value .= substr($seg, $i + 1, 1);
                push @flags, 0;
                $i += 2;
                $first = 0;
                next;
            }
            if ($cc eq '$' || $cc eq '`' || $cc eq '*' || $cc eq '?' || $cc eq '[' || $cc eq '{') {
                $unpredictable = 1;
                $value .= $cc;
                push @flags, 1;
                $i++;
                $first = 0;
                next;
            }
            if ($cc eq '~' && $first) {
                $unpredictable = 1;
                $value .= $cc;
                push @flags, 1;
                $i++;
                $first = 0;
                next;
            }
            $value .= $cc;
            push @flags, 0;
            $i++;
            $first = 0;
        }
        # A bare { or } word (never glued to anything else) is a transparent
        # grouping token, not brace expansion, so it is always a literal
        # (RV-M3/RT-M4: '{ butler-continuity status; }' must be recognised).
        if ($value eq '{' || $value eq '}') { $unpredictable = 0 }
        # R8-B1 (Decision 55, review B1/redteam H1): a word with an
        # unexpandable prefix (~/..., $HOME/..., ${VAR}/..., $VAR/...) still
        # carries a fully literal basename after its LAST unquoted '/' or
        # '\'. Record that basename as 'tail' whenever every character after
        # that last slash is itself predictable -- so a variable or glob
        # inside the basename itself (not just the directory) still leaves
        # tail undef, per spec.
        my $tail;
        {
            my $lastslash = -1;
            for (my $k = 0; $k < length($value); $k++) {
                my $ch = substr($value, $k, 1);
                if ($ch eq '/' || $ch eq '\\') { $lastslash = $k }
            }
            if ($lastslash >= 0) {
                my $tailstr = substr($value, $lastslash + 1);
                if (length($tailstr)) {
                    my $ok = 1;
                    for my $k ($lastslash + 1 .. $#flags) { $ok = 0 if $flags[$k] }
                    $tail = $tailstr if $ok;
                }
            }
        }
        my $raw = substr($seg, $word_start, $i - $word_start);
        push @words, { literal => ($unpredictable ? undef : $value), tail => $tail, raw => $raw };
    }
    return \@words;
}

sub _strip_redirection_words {
    my (@words) = @_;
    my @out;
    my $j = 0;
    my $n = scalar @words;
    while ($j < $n) {
        my $lit = $words[$j]{literal};
        if (defined $lit && $lit =~ /^[0-9]*(?:>>?|<|>&|<&|&>)(.*)$/) {
            my $rest = $1;
            $j++;
            if ($rest eq '') { $j++ if $j < $n }
            next;
        }
        push @out, $lit;
        $j++;
    }
    return @out;
}

sub _reduce_and_match {
    my ($words, $name) = @_;
    # A leading '(' glued to the command word, e.g. "(butler-continuity status)",
    # is a subshell open with no space after it. Strip it from the first
    # word's literal (RV-M3/RT-M4); the closing ')' is already a segment
    # separator, so nothing else is needed.
    if (@$words && defined $words->[0]{literal} && $words->[0]{literal} =~ /^\(+(.*)$/) {
        my $rest = $1;
        if (length $rest) {
            $words = [ { literal => $rest }, @{$words}[1 .. $#$words] ];
        }
        else {
            $words = [ @{$words}[1 .. $#$words] ];
        }
    }
    my $n = scalar @$words;
    return undef if $n == 0;
    my $first_lit = $words->[0]{literal};
    return undef if defined $first_lit && $READER_BLACKLIST{$first_lit};

    my $i = 0;
    while ($i < $n && defined $words->[$i]{literal} && ($words->[$i]{literal} eq '(' || $words->[$i]{literal} eq '{')) {
        $i++;
    }

    my $progress = 1;
    while ($progress) {
        $progress = 0;
        while ($i < $n) {
            my $lit = $words->[$i]{literal};
            my $raw = $words->[$i]{raw};
            if (defined $lit && $lit =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $i++; $progress = 1; next }
            # R8-M2 (redteam M2): an env-assignment prefix whose VALUE
            # contains an expansion ($PWD/a, etc) makes the whole word
            # unpredictable (literal undef), but the assignment's NAME= part
            # is never itself expanded, so it is still a transparent prefix
            # regardless of how unpredictable its value is. Detected off the
            # raw (unquoted) text, since quoting never touches the name.
            if (!defined $lit && defined $raw && $raw =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $i++; $progress = 1; next }
            if (defined $lit && $lit =~ /^[0-9]*(?:>>?|<|>&|<&|&>)(.*)$/) {
                my $rest = $1;
                $i++;
                if ($rest eq '') { $i++ if $i < $n }
                $progress = 1;
                next;
            }
            last;
        }
        last unless $i < $n && defined $words->[$i]{literal};
        my $lit = $words->[$i]{literal};
        if ($lit eq 'timeout') {
            $i++;
            $progress = 1;
            while ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^-/) {
                my $opt = $words->[$i]{literal};
                if ($opt =~ /^(?:--kill-after=|--signal=)/) {
                    $i++;
                }
                elsif ($opt eq '-k' || $opt eq '-s' || $opt eq '--kill-after' || $opt eq '--signal') {
                    $i++;
                    $i++ if $i < $n;
                }
                else {
                    # --preserve-status, --foreground, -v, or an unknown flag
                    $i++;
                }
            }
            $i++ if $i < $n;
        }
        elsif ($lit eq 'env') {
            $i++;
            $progress = 1;
            if ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} eq '-i') { $i++ }
            while ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $i++ }
        }
        elsif ($lit eq 'nice') {
            $i++;
            $progress = 1;
            if ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} eq '-n') { $i += 2 }
        }
        elsif ($lit eq 'nohup' || $lit eq 'command' || $lit eq 'exec') {
            $i++;
            $progress = 1;
        }
        elsif ($lit eq 'then' || $lit eq 'do' || $lit eq 'else' || $lit eq 'elif'
            || $lit eq '!' || $lit eq 'time')
        {
            $i++;
            $progress = 1;
        }
    }

    if ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^(?:perl|bash|sh)$/) {
        $i++;
        while ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^-/) { $i++ }
    }

    return undef unless $i < $n;
    my $cmd = $words->[$i]{literal};
    # R8-B1 (Decision 55, review B1/redteam H1): the command word itself may
    # be unpredictable (~/..., $HOME/..., ${VAR}/..., $VAR/...) while its
    # basename after the last unquoted '/' or '\' is fully literal -- fall
    # back to that literal basename ONLY at this, the command-word position.
    # Argv words never consult 'tail'.
    $cmd = $words->[$i]{tail} unless defined $cmd;
    return undef unless defined $cmd;
    my $base = $cmd;
    $base =~ s{.*[/\\]}{};
    return undef unless $base =~ /^\Q$name\E(?:\.sh|\.pl)?$/;

    my @argv_words = @{$words}[($i + 1) .. ($n - 1)];
    my @argv = _strip_redirection_words(@argv_words);
    return \@argv;
}

sub invocations {
    my ($command, $name) = @_;
    return () unless defined $command && defined $name && length $name;
    my @segs = _segments($command);
    my @results;
    for my $seg (@segs) {
        my $words = _tokenize_words($seg);
        my $argv = _reduce_and_match($words, $name);
        push @results, $argv if defined $argv;
    }
    return @results;
}

# sole_invocation($command, $name): the argv only when $command is EXACTLY
# one invocation of $name and nothing else -- no other segment (no &&/||/;
# tail, no other pipeline stage) and no trailing background '&' job.
# invocations()==1 cannot express this (RV-M3/RT-M4): 'butler-hold a1 &&
# sleep 999' and 'butler-hold a1; long-job' each yield exactly one match from
# invocations(), which over-exempts the whole compound command for any
# consumer using that count as a sole-call predicate.
sub sole_invocation {
    my ($command, $name) = @_;
    return undef unless defined $command && defined $name && length $name;
    my $trimmed = $command;
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+$//;
    return undef unless length $trimmed;
    # A trailing background '&' job (not part of a redirection) means the
    # command is not solely the invocation.
    if ($trimmed =~ /(?<![<>&])&\s*$/) {
        return undef;
    }
    my @segs = _segments($trimmed);
    my @nonempty = grep { /\S/ } @segs;
    return undef unless scalar(@nonempty) == 1;
    my $words = _tokenize_words($nonempty[0]);
    return _reduce_and_match($words, $name);
}

# --------------------------------------------------------------- payload ---

my $PAYLOAD_CACHE  = {};
my $PAYLOAD_LOADED = 0;
my $PAYLOAD_OK     = 0;
my $PARSE_COUNT    = 0;
my $PAYLOAD_RAW_LEN = 0;

# Decision 25: the raw byte length of the last load_payload() input, counted
# BEFORE any decode -- exposed so a guard (GuardBash: Decision 25 (2)) can
# deny a too-large Bash payload without paying for or waiting on the decode
# itself. Always counted as UTF-8 BYTES, never characters, whether $raw
# already carries Perl's internal utf8 flag (a test fixture built in
# memory) or is a plain byte string (the real stdin-read case).
sub _byte_len {
    my ($s) = @_;
    return 0 unless defined $s;
    if (utf8::is_utf8($s)) {
        my $copy = $s;
        utf8::encode($copy);
        return length($copy);
    }
    return length($s);
}

# R6-M2 (red-team MEDIUM-2, Decision 51): JSON::PP's decode dies outright on
# a lone (unpaired) UTF-16 surrogate escape -- one bad code unit sliced out
# of free text such as last_assistant_message, or a Node JSON.stringify
# artefact of an unpaired surrogate -- rather than treating it as ordinary
# malformed JSON. Left unhandled, that turns a single bad code unit into a
# fail-open {} for the WHOLE payload (session_id and hook_event_name lost
# too), which is exactly the "stranding" red-team found. Repair every lone
# \uD800-\uDFFF escape (one that is not one half of a valid high+low pair)
# to � (U+FFFD) BEFORE decoding, so the rest of an otherwise well-formed
# payload still comes through. A genuinely paired surrogate escape is left
# byte-for-byte untouched.
sub _repair_lone_surrogates {
    my ($raw) = @_;
    return $raw unless defined $raw && length $raw;
    # Pass 1: a high surrogate (\uD800-\uDBFF, case-insensitive hex digits --
    # a real Node/JSON.stringify artefact is lowercase, e.g. \ud800)
    # immediately followed by a low surrogate (\uDC00-\uDFFF) is a valid
    # pair -- leave it alone, byte for byte. A high surrogate with no such
    # follower is lone -> the literal JSON escape "�" (U+FFFD), so the
    # SUBSEQUENT decode turns it into one replacement character.
    $raw =~ s{
        \\u([Dd][89abAB][0-9A-Fa-f]{2})
        (\\u[Dd][c-fC-F][0-9A-Fa-f]{2})?
    }{
        defined $2 ? "\\u$1$2" : "\\ufffd"
    }gex;
    # Pass 2: any low surrogate escape that survives pass 1 was never
    # preceded by a matching high surrogate, so it is lone too.
    $raw =~ s{\\u[Dd][c-fC-F][0-9A-Fa-f]{2}}{\\ufffd}gx;
    return $raw;
}

# Decision 25 (1): JSON::PP->new->utf8->decode() re-scans a decoded non-ASCII
# string character by character internally, which is quadratic-feeling in
# practice for a large payload padded with non-ASCII text -- 32.2s measured
# for a 524 KB command that is all U+00E9 (driver measurement). Rewrite every
# non-ASCII UTF-8 byte sequence in the RAW bytes to its \uXXXX escape (a
# surrogate pair above U+FFFF, exactly as JSON itself would encode it), in
# ONE linear regex substitution over the byte string, then decode the
# resulting PURE-ASCII text with the plain (non-->utf8) decoder, which never
# has to look past a single byte per character. Must be byte-for-byte
# equivalent to JSON::PP->new->utf8->decode($raw) for every valid UTF-8
# input (AC-56); any malformed UTF-8 byte sequence makes this return undef so
# the caller falls back to today's path unchanged (AC-57).
# Decodes exactly one well-formed multi-byte UTF-8 sequence (already matched
# by the precise per-length byte-range regex below) into its \uXXXX escape,
# by bit arithmetic alone -- no Encode::decode() call per character, which
# is what made an earlier version of this pay per-call XS/exception-handling
# overhead for every one of half a million characters. Returns undef (and
# leaves $_[1] set) for a sequence that is well-formed BYTE-RANGE-wise but
# an invalid Unicode scalar value: overlong (a shorter encoding existed), a
# UTF-16 surrogate half (never legal in UTF-8), or above U+10FFFF.
sub _utf8_seq_escape {
    my ($seq, $bad_ref) = @_;
    my @b = unpack('C*', $seq);
    my $cp;
    if (@b == 2) {
        $cp = (($b[0] & 0x1F) << 6) | ($b[1] & 0x3F);
    }
    elsif (@b == 3) {
        if (($b[0] == 0xE0 && $b[1] < 0xA0) || ($b[0] == 0xED && $b[1] >= 0xA0)) {
            $$bad_ref = 1;
            return '';
        }
        $cp = (($b[0] & 0x0F) << 12) | (($b[1] & 0x3F) << 6) | ($b[2] & 0x3F);
    }
    elsif (@b == 4) {
        if (($b[0] == 0xF0 && $b[1] < 0x90) || ($b[0] == 0xF4 && $b[1] > 0x8F)) {
            $$bad_ref = 1;
            return '';
        }
        $cp = (($b[0] & 0x07) << 18) | (($b[1] & 0x3F) << 12) | (($b[2] & 0x3F) << 6) | ($b[3] & 0x3F);
    }
    else {
        $$bad_ref = 1;
        return '';
    }
    return $cp > 0xFFFF
        ? do {
            my $v = $cp - 0x10000;
            sprintf('\u%04x\u%04x', 0xD800 + ($v >> 10), 0xDC00 + ($v & 0x3FF));
          }
        : sprintf('\u%04x', $cp);
}

# Decision 25 (1): JSON::PP->new->utf8->decode() re-scans a decoded non-ASCII
# string character by character internally, which is quadratic-feeling in
# practice for a large payload padded with non-ASCII text -- 32.2s measured
# for a 524 KB command that is all U+00E9 (driver measurement). Rewrite every
# non-ASCII UTF-8 byte sequence in the RAW bytes to its \uXXXX escape (a
# surrogate pair above U+FFFF, exactly as JSON itself would encode it), in
# ONE linear regex substitution over the byte string, then decode the
# resulting PURE-ASCII text with the plain (non-->utf8) decoder, which never
# has to look past a single byte per character. Must be byte-for-byte
# equivalent to JSON::PP->new->utf8->decode($raw) for every valid UTF-8
# input (AC-56); any malformed UTF-8 byte sequence makes this return undef so
# the caller falls back to today's path unchanged (AC-57). The regex only
# matches BYTE-RANGE-well-formed sequences (a correct number of continuation
# bytes, and a lead byte that cannot start an overlong/out-of-range
# sequence); anything else -- a stray continuation byte, a truncated
# sequence, a lead byte with too few followers -- simply does not match and
# is caught by the leftover-high-byte check below.
sub _fast_ascii_escape_decode {
    my ($raw) = @_;
    return undef unless defined $raw && length $raw;
    my $esc = $raw;
    my $bad = 0;
    $esc =~ s{
        ( [\xC2-\xDF][\x80-\xBF]
        | [\xE0-\xEF][\x80-\xBF]{2}
        | [\xF0-\xF4][\x80-\xBF]{3}
        )
    }{
        _utf8_seq_escape($1, \$bad)
    }gex;
    return undef if $bad;
    # A stray/malformed byte that never matched the pattern above (a lone
    # continuation byte, a truncated multi-byte sequence, an invalid lead
    # byte such as 0xC0/0xC1/0xF5-0xFF) is left as a raw high byte -- never
    # silently hand that to the ascii-only decoder below (it would treat it
    # as a Latin-1 code point instead of failing), fall back instead.
    return undef if $esc =~ /[\x80-\xFF]/;
    my $out = eval { JSON::PP->new->decode($esc) };
    my $err = $@;
    # never-halt 09-gb-h-residuals (Decision 30, red-team 4 N1): a die
    # raised mid-decode here is otherwise swallowed by this very eval and
    # never reaches load_payload's own alarm re-throw below -- re-die it
    # now (ALRM-shaped only, never a JSON::PP parse-error that merely
    # mentions "alarm") so it propagates like any other decode attempt's.
    if (!defined $out && defined $err && length $err
        && $err =~ /alarm/i && $err !~ /at character offset/)
    {
        die $err;
    }
    return $out;
}

sub load_payload {
    my ($raw) = @_;
    $PARSE_COUNT++;
    my $ok = 1;
    my $data;
    $PAYLOAD_RAW_LEN = _byte_len($raw);
    if (!defined $raw) {
        $ok = 0;
    }
    else {
        $data = eval { _fast_ascii_escape_decode($raw) };
        my $fast_err = $@;
        if ((!defined $data || ref($data) ne 'HASH')
            && defined $fast_err && length $fast_err
            && $fast_err =~ /alarm/i && $fast_err !~ /at character offset/)
        {
            # never-halt 09-gb-h-residuals (Decision 30, red-team 4 N1): an
            # ALRM die that fires mid-fast-path must never be swallowed into
            # a slow-path retry -- load_payload's own eval around the fast
            # path would otherwise treat the alarm's die exactly like an
            # ordinary decode failure and fall through to the slow
            # JSON::PP->utf8->decode path, which is the very
            # quadratic-for-non-ASCII cost the fast path exists to avoid.
            # Re-throw so the caller's own alarm handling sees it. Excluded:
            # a JSON::PP-shaped "at character offset" die, which carries that
            # phrase for every real parse error -- a malformed payload whose
            # text happens to contain the word "alarm" must stay an ordinary
            # swallowed decode failure.
            die $fast_err;
        }
        if (!defined $data || ref($data) ne 'HASH') {
            # Decision 26 (2): the slow fallback (JSON::PP->new->utf8->decode
            # plus the lone-surrogate repair) runs only when the raw payload
            # is at most 64 KiB -- above that, a fast-path failure is treated
            # like today's undecodable-payload outcome directly, so one
            # invalid byte can never force the slow (quadratic-for-non-ASCII)
            # path onto a large payload.
            if (defined $PAYLOAD_RAW_LEN && $PAYLOAD_RAW_LEN <= 65536) {
                $data = eval { JSON::PP->new->utf8->decode($raw) };
                my $slow_err = $@;
                if ((!defined $data || ref($data) ne 'HASH')
                    && defined $slow_err && length $slow_err
                    && $slow_err =~ /alarm/i && $slow_err !~ /at character offset/)
                {
                    die $slow_err;
                }
                if (!defined $data || ref($data) ne 'HASH') {
                    my $repaired = _repair_lone_surrogates($raw);
                    if ($repaired ne $raw) {
                        $data = eval { JSON::PP->new->utf8->decode($repaired) };
                        my $slow_err2 = $@;
                        if ((!defined $data || ref($data) ne 'HASH')
                            && defined $slow_err2 && length $slow_err2
                            && $slow_err2 =~ /alarm/i && $slow_err2 !~ /at character offset/)
                        {
                            die $slow_err2;
                        }
                    }
                }
            }
            if (!defined $data || ref($data) ne 'HASH') {
                $ok = 0;
                if (defined $@ && length $@) {
                    my $err = $@;
                    $err =~ s/\s+\z//;
                    warn "BpHook: payload decode failed: $err\n";
                }
            }
        }
    }
    if ($ok && defined $ENV{BP_PAYLOAD_TRUNCATED} && $ENV{BP_PAYLOAD_TRUNCATED} eq '1') { $ok = 0 }
    if ($ok) {
        $PAYLOAD_CACHE = $data;
        $PAYLOAD_OK = 1;
    }
    else {
        $PAYLOAD_CACHE = {};
        $PAYLOAD_OK = 0;
    }
    $PAYLOAD_LOADED = 1;
    return;
}

sub payload    { return $PAYLOAD_CACHE }
sub payload_ok { return $PAYLOAD_OK ? 1 : 0 }
sub parse_count { return $PARSE_COUNT }
sub raw_length  { return $PAYLOAD_RAW_LEN }

sub _read_stdin_bulk {
    binmode(STDIN, ':raw');
    my $buf = '';
    my $cap = 8 * 1024 * 1024 + 1;
    while (length($buf) < $cap) {
        my $chunk;
        my $n = sysread(STDIN, $chunk, 65536);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    if (length($buf) > 8 * 1024 * 1024) {
        $ENV{BP_PAYLOAD_TRUNCATED} = 1;
        $buf = substr($buf, 0, 8 * 1024 * 1024);
    }
    return $buf;
}

sub _append_hook_error {
    my ($tag, $msg) = @_;
    my $root = state_dir();
    return unless defined $root;
    eval {
        require File::Path;
        File::Path::make_path($root);
        my $path = "$root/hook-errors.log";
        if (-f $path) {
            my $size = (stat($path))[7];
            if (defined $size && $size > 256 * 1024) { rename($path, "$path.1") }
        }
        my $first = defined $msg ? $msg : '';
        $first =~ s/\r?\n.*$//s;
        $first = substr($first, 0, 300);
        my $line = _iso_now() . "\t" . (defined $tag ? $tag : '?') . "\t" . $first . "\n";
        my $bytes = $line;
        if (utf8::is_utf8($bytes)) { utf8::encode($bytes) }
        sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT) or return;
        binmode($fh, ':raw');
        syswrite($fh, $bytes);
        close $fh;
    };
    return;
}

sub main {
    local $MAIN_STARTED_AT = Time::HiRes::time();
    my ($module, @args) = @_;
    # R8-RVM1 (review M1): track whether the warn handler actually fired
    # for THIS invocation, not whether payload_ok() is true -- payload_ok()
    # is also false for a JSON array/null payload and for a
    # BP_PAYLOAD_TRUNCATED=1 truncation of an otherwise well-formed payload,
    # and load_payload() never warns in any of those cases, so gating on
    # payload_ok() alone left a missing/require-failing module unlogged in
    # exactly those cases.
    my $decode_warned = 0;
    local $SIG{__WARN__} = sub { $decode_warned = 1; _append_hook_error($module, $_[0]) };
    my $raw = _read_stdin_bulk();

    return 0 unless defined $module && $module =~ /^[A-Za-z][A-Za-z0-9_]*(?:::[A-Za-z][A-Za-z0-9_]*)*$/;

    # Decision 26 (1): the Bash guard's raw-size/truncation deny must run
    # BEFORE any JSON decode -- load_payload() decoding first (fast path,
    # then the slow path) meant an 8 MiB or truncated Bash payload still
    # paid the whole decode cost before GuardBash's own post-decode check
    # (Decision 25 (2)) ever ran. The hook matcher (guard-bash.sh) only ever
    # invokes this module for a Bash tool_name call, so the module name
    # alone -- known here without decoding anything -- is enough to act on
    # the raw bytes' length. No decoder of any kind runs on this path.
    if ($module eq 'Guards::GuardBash') {
        $PAYLOAD_RAW_LEN = _byte_len($raw);
        my $truncated = defined $ENV{BP_PAYLOAD_TRUNCATED} && $ENV{BP_PAYLOAD_TRUNCATED} eq '1';
        if ($truncated || (defined $PAYLOAD_RAW_LEN && $PAYLOAD_RAW_LEN > 1024 * 1024)) {
            my $require_ok = eval { require "BpHook/Guards/GuardBash.pm"; 1 };
            unless ($require_ok) {
                _append_hook_error($module, $@);
                return 0;
            }
            return BpHook::Guards::GuardBash::deny_oversize_raw();
        }
    }

    load_payload($raw);

    my $relpath = $module;
    $relpath =~ s{::}{/}g;

    my $require_ok = eval {
        require "BpHook/$relpath.pm";
        1;
    };
    unless ($require_ok) {
        # Only skip this when a payload-decode failure has ALREADY been
        # recorded (via the $SIG{__WARN__} handler above) for this same
        # invocation -- a missing module on top of unparseable input adds
        # no information beyond "nothing ran", and R7-warn requires exactly
        # one hook-errors.log line per malformed payload. Otherwise (no
        # decode warning fired -- payload was valid JSON, just not usable,
        # or truncated) the missing module IS the only thing worth logging.
        _append_hook_error($module, $@) unless $decode_warned;
        return 0;
    }

    my $ret;
    my $ok = eval {
        my $fn = "BpHook::${module}::run";
        no strict 'refs';
        $ret = &$fn(payload(), @args);
        1;
    };
    unless ($ok) {
        _append_hook_error($module, $@);
        return 0;
    }

    my $rs = defined $ret ? "$ret" : '';
    return ($rs =~ /^\s*2\s*$/) ? 2 : 0;
}

# ---------------------------------------------------------- deny/context ---

sub deny {
    my (@lines) = @_;
    binmode(STDERR, ':raw');
    for my $l (@lines) {
        my $b = defined $l ? _decode_maybe($l) : '';
        utf8::encode($b) if utf8::is_utf8($b);
        print STDERR $b . "\n";
    }
    return 2;
}

sub context {
    my ($text) = @_;
    my $p = payload();
    my $event = (ref $p eq 'HASH' && defined $p->{hook_event_name} && length $p->{hook_event_name})
        ? $p->{hook_event_name}
        : 'PostToolUse';
    $text = _decode_maybe($text);
    my $out = { hookSpecificOutput => { hookEventName => $event, additionalContext => $text } };
    my $json = eval { JSON::PP->new->utf8->canonical->encode($out) };
    binmode(STDOUT, ':raw');
    print STDOUT (defined $json ? $json : '{}') . "\n";
    return 0;
}

1;
