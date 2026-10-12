# BpHook::PromptWatch -- record-only hooks for never-halt package 06
# (specs/06-prompt-watch-spec.md, Decisions 2, 9, 11, 40). Two shims
# (record-prompt.sh on Notification/permission_prompt, record-denial.sh on
# PermissionDenied) share this module. run() NEVER prints, NEVER dies,
# NEVER emits a permission decision of any kind -- it only appends one JSON
# line to prompts.jsonl or denials.jsonl under the resolved data root's
# .drive-solo/ directory, or does nothing at all.
#
# Must NOT require BpHook.pm at file scope (spec sec 2.3): the director and
# bp-denials.pl load this module standalone, without BpHook ever being
# loaded. run() may call BpHook:: functions -- they exist whenever run() is
# reached through BpHook::main, and a test calling run() in-process is
# required (by the spec) to require BpHook.pm first.
package BpHook::PromptWatch;
use strict;
use warnings;
use JSON::PP ();
use Encode ();
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT);
use File::Basename qw(dirname);
use Cwd ();
use B qw(svref_2object SVp_POK);

our $TOOL_INPUT_MAX_BYTES = 2048;   # denial tool_input
our $TEXT_MAX_BYTES       = 1024;   # prompt message, denial reason
our $NAME_MAX_BYTES       = 128;    # tool_name, agent_type
our $LOCK_WAIT_SECONDS    = 2;

my $AGENT_RE = qr/\A[A-Za-z0-9_-]{1,64}\z/;

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
my $BPDATAROOT_LOADED = 0;

sub _ensure_bpdataroot {
    return 1 if $BPDATAROOT_LOADED || defined &BpDataRoot::resolve;
    my $path = "$SELF_DIR/../BpDataRoot.pm";
    return 0 unless -f $path;
    my $ok = eval { require $path; 1 };
    $BPDATAROOT_LOADED = 1 if $ok;
    return $ok ? 1 : 0;
}

# ------------------------------------------------------------- byte/char ----

sub _is_plain_string {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $flags = svref_2object(\$v)->FLAGS;
    return ($flags & SVp_POK()) ? 1 : 0;
}

# cut(v, n) -- the longest prefix of v whose UTF-8 encoding is <= n bytes and
# is valid UTF-8 (never splits a character). A non-string source value
# becomes "".
sub _cut {
    my ($v, $n) = @_;
    return '' unless _is_plain_string($v) && length($v);
    my $bytes = Encode::encode_utf8($v);
    return $v if length($bytes) <= $n;
    my $prefix = substr($bytes, 0, $n);
    while (length($prefix)) {
        my $dec = eval { Encode::decode('UTF-8', $prefix, Encode::FB_CROAK) };
        return $dec if defined $dec;
        $prefix = substr($prefix, 0, length($prefix) - 1);
    }
    return '';
}

sub _utf8_byte_len {
    my ($v) = @_;
    return 0 unless _is_plain_string($v);
    return length(Encode::encode_utf8($v));
}

sub _iso_now {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# agent_id per spec sec 2.4: the payload's agent_id if a string matching
# \A[A-Za-z0-9_-]{1,64}\z; '?' if present but invalid; 'main' if absent/null.
sub _agent_id_for {
    my ($p) = @_;
    return 'main' unless ref $p eq 'HASH' && exists $p->{agent_id};
    my $v = $p->{agent_id};
    return 'main' unless defined $v;
    return '?' unless _is_plain_string($v);
    return ($v =~ $AGENT_RE) ? $v : '?';
}

# ------------------------------------------------------------ data root -----

sub _cwd_candidate {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    my $c = $p->{cwd};
    return undef unless _is_plain_string($c) && length $c;
    (my $norm = $c) =~ s{\\}{/}g;
    return undef unless $norm =~ m{^/} || $norm =~ m{^[A-Za-z]:/};
    return -d $norm ? $c : undef;
}

sub _resolve_data_dir {
    my ($p) = @_;
    return undef unless _ensure_bpdataroot();
    my $cwd = _cwd_candidate($p);
    my $res = eval { BpDataRoot::resolve(defined $cwd ? (cwd => $cwd) : ()) };
    return undef unless ref $res eq 'HASH';
    my $raw = $res->{data_dir};
    return undef unless defined $raw && length $raw;
    (my $data = $raw) =~ s{\\}{/}g;
    return undef unless $data =~ m{^/} || $data =~ m{^[A-Za-z]:/};
    return undef unless -d $data;
    return $data;
}

sub _resolve_drive_solo_dir {
    my ($data) = @_;
    return undef unless defined $data;
    my $ds = "$data/.drive-solo";
    unless (-d $ds) {
        mkdir($ds);
    }
    return -d $ds ? $ds : undef;
}

# ------------------------------------------------------------ append I/O ----

sub _do_append {
    my ($path, $bytes) = @_;
    my $ok = sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT);
    return 0 unless $ok;
    binmode($fh, ':raw');
    # L3 (red-team, never-halt package 06 fix-batch): a writer killed
    # mid-write, or interleaving under MSYS's emulated O_APPEND when a
    # concurrent writer's lock wait timed out, can leave the file's last
    # byte something other than "\n". Gluing this record directly onto that
    # fragment would merge two records into one unparsable line, silently
    # losing both. Lead with a newline first when the file is non-empty and
    # does not already end in one; O_APPEND still places every write at the
    # true end regardless of this read's seek position.
    my $size = -s $fh;
    if (defined $size && $size > 0) {
        seek($fh, $size - 1, 0);
        my $last = '';
        sysread($fh, $last, 1);
        syswrite($fh, "\n") if $last ne "\n";
    }
    syswrite($fh, $bytes);
    close($fh);
    return 1;
}

sub _append_record {
    my ($ds, $file, $line) = @_;
    my $target = "$ds/$file";
    # $line is already raw UTF-8 bytes: it is "<json>\n" where <json> came
    # from JSON::PP->new->utf8->... ->encode, whose ->utf8 mode means the
    # OUTPUT is already octets. Re-encoding it here would double-encode
    # every multi-byte character.
    my $bytes = $line;
    my $lockfile = "$ds/prompt-watch.lock";
    my $lockfh;
    my $locked = 0;
    if (open($lockfh, '>>', $lockfile)) {
        eval {
            local $SIG{ALRM} = sub { die "bp-prompt-watch-lock-timeout\n" };
            alarm($LOCK_WAIT_SECONDS);
            $locked = flock($lockfh, LOCK_EX) ? 1 : 0;
            alarm(0);
        };
        alarm(0);
    }
    _do_append($target, $bytes);
    if ($lockfh) {
        flock($lockfh, LOCK_UN) if $locked;
        close($lockfh);
    }
    return;
}

# ------------------------------------------------------------- record -----

sub _prompt_record {
    my ($p, $sid) = @_;
    my $agent_type;
    if (ref $p eq 'HASH' && _is_plain_string($p->{agent_type}) && length($p->{agent_type})) {
        $agent_type = _cut($p->{agent_type}, $NAME_MAX_BYTES);
    }
    return {
        ts         => _iso_now(),
        session_id => $sid,
        agent_id   => _agent_id_for($p),
        agent_type => $agent_type,
        message    => _cut((ref $p eq 'HASH' ? $p->{message} : undef), $TEXT_MAX_BYTES),
    };
}

sub _denial_record {
    my ($p, $sid) = @_;
    my $raw_tool_name = (ref $p eq 'HASH' && _is_plain_string($p->{tool_name})) ? $p->{tool_name} : undef;
    my $raw_tool_input = (ref $p eq 'HASH') ? $p->{tool_input} : undef;

    my $pre;
    if (defined $raw_tool_name && $raw_tool_name eq 'Bash'
        && ref $raw_tool_input eq 'HASH' && _is_plain_string($raw_tool_input->{command})) {
        $pre = $raw_tool_input->{command};
    }
    elsif (defined $raw_tool_input) {
        my $txt = eval { JSON::PP->new->canonical->encode($raw_tool_input) };
        $pre = defined $txt ? $txt : '';
    }
    else {
        $pre = '';
    }

    my $pre_len = _utf8_byte_len($pre);
    my $tool_input = _cut($pre, $TOOL_INPUT_MAX_BYTES);
    my $truncated = ($pre_len > $TOOL_INPUT_MAX_BYTES) ? JSON::PP::true : JSON::PP::false;

    return {
        ts                   => _iso_now(),
        session_id           => $sid,
        agent_id             => _agent_id_for($p),
        tool_name            => _cut($raw_tool_name, $NAME_MAX_BYTES),
        tool_input           => $tool_input,
        tool_input_truncated => $truncated,
        reason               => _cut((ref $p eq 'HASH' ? $p->{reason} : undef), $TEXT_MAX_BYTES),
    };
}

# ---------------------------------------------------------------- run() ----

sub _run_inner {
    my ($p, $mode) = @_;
    return unless defined $mode && ($mode eq 'prompt' || $mode eq 'denial');

    my $ledger = $ENV{BP_LEDGER};
    my $driver_ctx = (defined $ledger && length $ledger) ? 1 : 0;
    unless ($driver_ctx) {
        $driver_ctx = 1 if defined &BpHook::role && BpHook::role($p) eq 'driver';
    }
    return unless $driver_ctx;

    my $sid = (defined &BpHook::session_id) ? BpHook::session_id($p) : undef;
    return unless defined $sid;

    if ($mode eq 'prompt') {
        my $nt = (ref $p eq 'HASH') ? $p->{notification_type} : undef;
        return unless _is_plain_string($nt) && $nt eq 'permission_prompt';
    }

    my $data = _resolve_data_dir($p);
    return unless defined $data;
    my $ds = _resolve_drive_solo_dir($data);
    return unless defined $ds;

    my $rec = ($mode eq 'prompt') ? _prompt_record($p, $sid) : _denial_record($p, $sid);
    my $json = eval { JSON::PP->new->utf8->canonical->encode($rec) };
    return unless defined $json;
    my $line = $json . "\n";

    my $file = ($mode eq 'prompt') ? 'prompts.jsonl' : 'denials.jsonl';
    _append_record($ds, $file, $line);
    return;
}

sub run {
    my ($p, $mode, @ignored) = @_;
    eval { _run_inner($p, $mode); 1 };
    return 0;
}

# -------------------------------------------------------------- readers ----

# read_from($path, $offset) -> (\@hashrefs, $new_offset). Every COMPLETE
# line (ending "\n") starting at byte $offset that decodes as a JSON object,
# in file order; malformed lines and a trailing partial line are skipped.
# $new_offset is the byte just past the last complete line read (unchanged
# if none). If the file's size is below $offset, reads from 0. Missing file
# -> ([], 0). Never dies.
sub read_from {
    my ($path, $offset) = @_;
    $offset = 0 unless defined $offset && $offset =~ /\A\d+\z/;
    return ([], 0) unless defined $path && -f $path;
    my $size = -s $path;
    $size = 0 unless defined $size;
    # L2 (red-team, never-halt package 06 fix-batch): an offset past the
    # file's current size used to re-base to 0, which replays the whole file
    # from the start -- e.g. after an EXTEND resolves a different/larger
    # data root, or the file was truncated and regrown. After MUST-FIX 1
    # (butler-hold.pl no longer skips agent_id "main"), replaying old
    # own-session lines would fire a spurious PROMPT exit. Re-base to the
    # file's current end instead: a caller only ever wants NEW lines from
    # here on, never a replay.
    $offset = $size if $offset > $size;

    my @out;
    my $new_offset = $offset;
    my $ok = eval {
        open(my $fh, '<:raw', $path) or return 0;
        seek($fh, $offset, 0) or do { close $fh; return 0 };
        local $/;
        my $rest = <$fh>;
        close $fh;
        $rest = '' unless defined $rest;
        while ($rest =~ /\G([^\n]*)\n/gc) {
            my $line = $1;
            $new_offset += length($line) + 1;
            my $obj = eval { JSON::PP->new->utf8->decode($line) };
            push @out, $obj if !$@ && ref $obj eq 'HASH';
        }
        return 1;
    };
    return (\@out, $new_offset);
}

sub read_records {
    my ($path) = @_;
    my ($recs, undef) = read_from($path, 0);
    return $recs;
}

sub denial_count {
    my ($data_dir) = @_;
    return 0 unless defined $data_dir && length $data_dir;
    my $recs = read_records("$data_dir/.drive-solo/denials.jsonl");
    return scalar @$recs;
}

# ------------------------------------------------- never-halt 07 readers ----
# Added for BpHook::DenialBreaker (specs/07-denial-circuit-breaker-spec.md
# sec 2.6). Public, never die, never print, add no file-scope require of
# BpHook.

# agent_key($p) -> exactly what _agent_id_for($p) returns.
sub agent_key {
    my ($p) = @_;
    return _agent_id_for($p);
}

# drive_solo_dir($p) -> "$data/.drive-solo" | undef. Resolves $data exactly
# as run() does. Never creates anything (unlike _resolve_drive_solo_dir).
sub drive_solo_dir {
    my ($p) = @_;
    my $data = _resolve_data_dir($p);
    return undef unless defined $data;
    my $ds = "$data/.drive-solo";
    return -d $ds ? $ds : undef;
}

# agent_denial_counts($path, $sid, $aid, $since) -> ($total, $since_count).
# Reads the file once. A record is a COMPLETE line (ending "\n") starting at
# byte offset $o. It qualifies when its bytes contain the literal substring
# '"session_id":"$sid"' AND it decodes (JSON::PP->new->utf8) to a hash with
# session_id eq $sid and agent_id eq $aid. $total is the count of qualifying
# records; $since_count is the count of qualifying records with $o >= $since.
# $since is treated as 0 when undef, not \A\d+\z, or greater than the file's
# current size. A missing or unreadable file, or an undef/empty $sid or $aid,
# gives (0, 0). Never dies.
sub agent_denial_counts {
    my ($path, $sid, $aid, $since) = @_;
    return (0, 0) unless defined $path && -f $path;
    return (0, 0) unless _is_plain_string($sid) && length($sid);
    return (0, 0) unless _is_plain_string($aid) && length($aid);

    my $size = -s $path;
    $size = 0 unless defined $size;
    my $since_ok = (defined $since && !ref($since) && $since =~ /\A\d+\z/ && $since <= $size)
        ? ($since + 0) : 0;

    my $needle = qq{"session_id":"$sid"};
    my $total = 0;
    my $since_count = 0;

    my $ok = eval {
        open(my $fh, '<:raw', $path) or return 0;
        local $/;
        my $content = <$fh>;
        close $fh;
        $content = '' unless defined $content;
        while ($content =~ /\G([^\n]*)\n/gc) {
            my $line = $1;
            my $o = pos($content) - length($line) - 1;
            if (index($line, $needle) >= 0) {
                my $obj = eval { JSON::PP->new->utf8->decode($line) };
                if (!$@ && ref $obj eq 'HASH'
                    && defined $obj->{session_id} && $obj->{session_id} eq $sid
                    && defined $obj->{agent_id} && $obj->{agent_id} eq $aid)
                {
                    $total++;
                    $since_count++ if $o >= $since_ok;
                }
            }
        }
        return 1;
    };
    return (0, 0) unless $ok;
    return ($total, $since_count);
}

1;
