package SessionFork;

# Resume a HOST Claude Code session inside the sandbox as a point-in-time
# fork: copy the host transcript into the sandbox claude-home's projects
# dir under a fresh session UUID, rewriting only the top-level `sessionId`
# and `cwd` fields so `claude --resume <new>` accepts it inside the
# container. The host transcript is opened read-only and NEVER modified,
# renamed, touched, or deleted.
#
# Spec: .ccpraxis-local-data/blueprints/sandbox-session-ux/
#       specs/07-host-session-fork-spec.md (S2.1)
#
# Contract: never dies, never warns, no console output, no spawning. Core
# modules only. Paths are opaque byte strings.

use strict;
use warnings;

use JSON::PP ();
use Encode ();
use File::Path ();
use File::Basename ();
use Digest::SHA ();
use Time::HiRes ();
use POSIX ();
use IO::Handle ();

# SessionIndex.pm lives next to us -- reuse its top-level-span scanner so
# this module never has its own (divergent) idea of what a "top-level key"
# is.
BEGIN {
    my $dir = File::Basename::dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; $f });
    unshift @INC, $dir unless grep { $_ eq $dir } @INC;
}
require SessionIndex;

# ---------------------------------------------------------------------------
# Test seams (package globals, `local`-ized by the test).
# ---------------------------------------------------------------------------
our $CONTAINER_CWD = '/project';   # cwd written into rewritten records
our $UUID_GEN;                     # coderef returning a uuid string; undef = real generator
our $WRITE_LIMIT;                  # undef, or N = the writer fails as "disk full" once N bytes are written

my $_JSON_STR = JSON::PP->new->allow_nonref->canonical;
my $_uuid_counter = 0;

# ---------------------------------------------------------------------------
# encode_project_path($path) -> $dirname   -- pure, no fs.
#
# Decode as UTF-8, then replace every character outside [A-Za-z0-9] with a
# dash. A character above U+FFFF becomes TWO dashes (Claude Code, being
# JavaScript, walks UTF-16 code units; inferred, unverified -- spec S5).
# ---------------------------------------------------------------------------
sub encode_project_path {
    my ($path) = @_;
    return '' unless defined $path && length $path;
    my $decoded = eval { Encode::decode('UTF-8', $path, Encode::FB_DEFAULT()) };
    $decoded = $path unless defined $decoded;
    my $out = '';
    for my $ch (split //, $decoded) {
        if ($ch =~ /\A[A-Za-z0-9]\z/) {
            $out .= $ch;
        } elsif (ord($ch) > 0xFFFF) {
            $out .= '--';
        } else {
            $out .= '-';
        }
    }
    # The Encode::decode() above leaves $out internally UTF8-flagged (even
    # though every char it can contain is plain ASCII), which corrupts any
    # non-ASCII bytes it later gets concatenated with (e.g. a
    # $claude_config_dir containing a literal UTF-8-encoded accented
    # character, such as this host's `C:\Users\André`): Perl upgrades the
    # byte string to match the flag, double-encoding it. Per this module's
    # own contract ("Paths are opaque byte strings"), collapse back to an
    # unflagged byte string before returning.
    utf8::encode($out) if utf8::is_utf8($out);
    return $out;
}

# ---------------------------------------------------------------------------
# host_sessions_dir($claude_config_dir, $path) -> $dir   -- pure, no fs.
# ---------------------------------------------------------------------------
sub host_sessions_dir {
    my ($claude_config_dir, $path) = @_;
    $claude_config_dir = '' unless defined $claude_config_dir;
    return "$claude_config_dir/projects/" . encode_project_path($path);
}

# ---------------------------------------------------------------------------
# new_uuid() -> lowercase RFC-4122 v4 string.
# ---------------------------------------------------------------------------
sub new_uuid {
    my $bytes;
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        my $n = read($fh, $bytes, 16);
        close $fh;
        undef $bytes unless defined($n) && $n == 16;
    }
    if (!defined $bytes) {
        $_uuid_counter++;
        my $seed = Time::HiRes::time() . ':' . $$ . ':' . rand() . ':' . $_uuid_counter;
        $bytes = substr(Digest::SHA::sha256($seed), 0, 16);
    }
    my @b = unpack('C16', $bytes);
    $b[6] = ($b[6] & 0x0f) | 0x40;   # version 4
    $b[8] = ($b[8] & 0x3f) | 0x80;   # variant 10xx
    my $hex = unpack('H*', pack('C16', @b));
    return lc(sprintf('%s-%s-%s-%s-%s',
        substr($hex, 0, 8), substr($hex, 8, 4), substr($hex, 12, 4),
        substr($hex, 16, 4), substr($hex, 20, 12)));
}

# ---------------------------------------------------------------------------
# is_uuid($s) -> 0|1
# ---------------------------------------------------------------------------
sub is_uuid {
    my ($s) = @_;
    return 0 unless defined $s && !ref $s;
    return $s =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i ? 1 : 0;
}

# ---------------------------------------------------------------------------
# is_uuid_shaped($s) -> 0|1 -- a permissive "is this shaped like a session
# id" check (8-4-4-4-12 hyphenated groups of word characters), for
# CALLER-SUPPLIED ids this module did not itself generate: a real host
# session id is always hex, but a session filename is not guaranteed to be
# (nothing in this codebase mints them), so read_provenance and any CLI
# caller validating a foreign id use this instead of the strict is_uuid()
# above -- which stays hex-only because it also asserts things about ids
# THIS module generates (new_uuid's v4 version/variant nibbles). Still
# rejects "/" and "." (blocks path traversal) and the wrong grouping.
# ---------------------------------------------------------------------------
sub is_uuid_shaped {
    my ($s) = @_;
    return 0 unless defined $s && !ref $s;
    return $s =~ /\A[0-9A-Za-z]{8}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{12}\z/ ? 1 : 0;
}

# ---------------------------------------------------------------------------
# short_id($uuid) -> lc first 8 chars
# ---------------------------------------------------------------------------
sub short_id {
    my ($uuid) = @_;
    return '' unless defined $uuid && !ref $uuid;
    return lc(substr("$uuid", 0, 8));
}

# ---------------------------------------------------------------------------
# _slurp_raw($path) -> $bytes | undef -- never dies.
# ---------------------------------------------------------------------------
sub _slurp_raw {
    my ($path) = @_;
    my $fh;
    return undef unless open($fh, '<:raw', $path);
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return defined($bytes) ? $bytes : '';
}

# ---------------------------------------------------------------------------
# read_provenance($sandbox_projects_dir, $uuid) -> \%prov | undef
# ---------------------------------------------------------------------------
sub read_provenance {
    my ($dir, $uuid) = @_;
    return undef unless defined $dir && length $dir && defined $uuid && length $uuid;
    my $path = "$dir/$uuid.ccpraxis-fork.json";
    return undef unless -f $path;
    my $bytes = _slurp_raw($path);
    return undef unless defined $bytes && length $bytes;
    my $data = eval { JSON::PP->new->utf8->decode($bytes) };
    return undef unless ref $data eq 'HASH';
    my $sid = $data->{source_session_id};
    return undef unless defined $sid && is_uuid_shaped($sid);
    return {
        source_session_id => $sid,
        forked_at         => $data->{forked_at},
        origin            => $data->{origin},
    };
}

# ---------------------------------------------------------------------------
# _json_string($s) -> a JSON string literal for $s (quoted + escaped).
# ---------------------------------------------------------------------------
sub _json_string {
    my ($s) = @_;
    return $_JSON_STR->encode("$s");
}

# ---------------------------------------------------------------------------
# _rewrite_line($content, $new_id) -> $rewritten_content
#
# $content is one line's bytes WITHOUT its line terminator. Rewrites the
# top-level `sessionId` value (if a string) to $new_id and the top-level
# `cwd` value (if a string) to $CONTAINER_CWD. Splices rightmost span
# first so earlier offsets stay valid. Anything else -- unparsable lines,
# nested fields, non-string values -- is left byte-for-byte alone.
# ---------------------------------------------------------------------------
sub _rewrite_line {
    my ($content, $new_id) = @_;

    return $content
        unless index($content, '"sessionId"') >= 0 || index($content, '"cwd"') >= 0;

    my $spans = eval { SessionIndex::_scan_top_level($content) };
    return $content unless ref $spans eq 'HASH';

    my @edits;
    if (exists $spans->{sessionId}) {
        my $sp = $spans->{sessionId};
        if (substr($content, $sp->[0], 1) eq '"') {
            push @edits, [ $sp->[0], $sp->[1], _json_string($new_id) ];
        }
    }
    if (exists $spans->{cwd}) {
        my $sp = $spans->{cwd};
        if (substr($content, $sp->[0], 1) eq '"') {
            push @edits, [ $sp->[0], $sp->[1], _json_string($CONTAINER_CWD) ];
        }
    }
    return $content unless @edits;

    @edits = sort { $b->[0] <=> $a->[0] } @edits;   # rightmost first
    my $out = $content;
    for my $e (@edits) {
        $out = substr($out, 0, $e->[0]) . $e->[2] . substr($out, $e->[1]);
    }
    return $out;
}

# ---------------------------------------------------------------------------
# fork_session($host_file, $sandbox_projects_dir) -> ($new_uuid, undef)
#                                                  | (undef, $error_text)
# ---------------------------------------------------------------------------
sub fork_session {
    my ($host_file, $sandbox_projects_dir) = @_;

    # --- Step 1: validate. Nothing created on failure. ---------------------
    unless (defined($host_file) && length($host_file) && -f $host_file && -r $host_file) {
        return (undef, "cannot read host transcript: not a readable regular file: " . (defined($host_file) ? $host_file : '(undef)'));
    }
    unless (defined($sandbox_projects_dir) && length($sandbox_projects_dir)) {
        return (undef, 'cannot read host transcript: sandbox_projects_dir is required');
    }
    my $dir = $sandbox_projects_dir;

    # Refuse a sandbox projects dir that is a symlink (lstat, not stat: a
    # container with write access to claude-home could otherwise replace the
    # dir with a symlink pointing anywhere the host user can write).
    if (lstat($dir)) {
        if (-l _) {
            return (undef, 'cannot use sandbox sessions dir: refusing a symlink');
        }
    }

    # --- Step 2: ensure the sandbox sessions dir exists. --------------------
    unless (-d $dir) {
        my $ok = eval { File::Path::make_path($dir); 1 };
        unless ($ok && -d $dir) {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+\z//;
            return (undef, "cannot create sandbox sessions dir: $err");
        }
    }

    # --- Step 3: pick a fresh, unused uuid (up to 5 attempts). --------------
    my $new;
    for (1 .. 5) {
        my $cand = $UUID_GEN ? $UUID_GEN->() : new_uuid();
        next unless is_uuid($cand // '');
        next if -e "$dir/$cand.jsonl" || -e "$dir/$cand.ccpraxis-fork.json";
        $new = $cand;
        last;
    }
    return (undef, 'no free session id') unless defined $new;

    my $tmp           = "$dir/.fork-$new.$$.tmp";
    my $sidecar_tmp   = "$dir/.fork-$new.$$.prov.tmp";
    my $final         = "$dir/$new.jsonl";
    my $sidecar_final = "$dir/$new.ccpraxis-fork.json";

    my $sidecar_renamed = 0;
    my $final_renamed   = 0;

    my $cleanup = sub {
        unlink $tmp           if -e $tmp;
        unlink $sidecar_tmp   if -e $sidecar_tmp;
        unlink $final         if $final_renamed   && -e $final;
        unlink $sidecar_final if $sidecar_renamed && -e $sidecar_final;
    };

    # --- Step 4: open source read-only, tmp for writing. --------------------
    my $in;
    unless (open($in, '<:raw', $host_file)) {
        $cleanup->();
        return (undef, "cannot read host transcript: $!");
    }
    my $out;
    unless (open($out, '>:raw', $tmp)) {
        close $in;
        $cleanup->();
        return (undef, "cannot open tmp file: $!");
    }

    # --- Step 5-7: stream complete lines, rewriting sessionId/cwd. ---------
    my $bytes_written  = 0;
    my $complete_count = 0;
    my $fail;

    my $write_bytes = sub {
        my ($bytes) = @_;
        return 1 unless length $bytes;
        if (defined($WRITE_LIMIT) && $bytes_written + length($bytes) > $WRITE_LIMIT) {
            return 0;
        }
        my $ok = eval { print {$out} $bytes };
        return 0 unless $ok;
        $bytes_written += length($bytes);
        return 1;
    };

    while (1) {
        my $raw_line = eval { local $/ = "\n"; <$in> };
        if (!defined $raw_line) {
            if ($in->error) {
                $fail = "read failed: $!";
            }
            last;   # true EOF (no fragment), or a read error caught above
        }
        if (substr($raw_line, -1) ne "\n") {
            # trailing unterminated fragment: dropped (a live host session may
            # be mid-append). Never written, never counted.
            last;
        }

        $complete_count++;
        my $content = substr($raw_line, 0, -1);
        my $term = "\n";
        if (length($content) && substr($content, -1) eq "\r") {
            $term = "\r\n";
            $content = substr($content, 0, -1);
        }

        my $rewritten = _rewrite_line($content, $new);
        unless ($write_bytes->($rewritten . $term)) {
            $fail = "write failed: could not write to tmp file ($!)";
            last;
        }
    }

    close $in;
    my $close_ok = close $out;

    if ($fail) {
        $cleanup->();
        return (undef, $fail);
    }
    unless ($close_ok) {
        $cleanup->();
        return (undef, "write failed: close: $!");
    }
    if ($complete_count == 0) {
        $cleanup->();
        return (undef, 'host transcript is empty');
    }
    my $tmp_size = -s $tmp;
    unless (defined($tmp_size) && $tmp_size == $bytes_written) {
        $cleanup->();
        return (undef, 'write failed: tmp file size mismatch after close');
    }

    # --- Step 8: write the provenance sidecar the same way. ----------------
    my $old_id = File::Basename::basename($host_file);
    $old_id =~ s/\.jsonl\z//i;

    my $prov_json = eval {
        JSON::PP->new->utf8->canonical->encode({
            forked_at          => POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time())),
            origin             => 'host',
            schema             => 1,
            source_session_id  => $old_id,
        });
    };
    unless (defined $prov_json) {
        $cleanup->();
        return (undef, 'write failed: could not encode provenance sidecar');
    }

    my $sc;
    unless (open($sc, '>:raw', $sidecar_tmp)) {
        $cleanup->();
        return (undef, "write failed: cannot open sidecar tmp: $!");
    }
    my $sc_print_ok = eval { print {$sc} $prov_json };
    unless ($sc_print_ok) {
        close $sc;
        $cleanup->();
        return (undef, "write failed: could not write sidecar ($!)");
    }
    my $sc_close_ok = close $sc;
    unless ($sc_close_ok) {
        $cleanup->();
        return (undef, "write failed: sidecar close: $!");
    }
    my $sc_size = -s $sidecar_tmp;
    unless (defined($sc_size) && $sc_size == length($prov_json)) {
        $cleanup->();
        return (undef, 'write failed: sidecar size mismatch after close');
    }

    # --- Step 9: rename sidecar first, then transcript. ---------------------
    unless (rename($sidecar_tmp, $sidecar_final)) {
        my $err = $!;
        $cleanup->();
        return (undef, "cannot finalize sidecar: $err");
    }
    $sidecar_renamed = 1;
    unless (rename($tmp, $final)) {
        # Step 10: the transcript rename failed AFTER the sidecar rename
        # already succeeded -- undo it so a transcript never appears without
        # its provenance, and never leave the sidecar as an orphan of THIS
        # failed call. Then remove whatever of our own tmp files remain.
        my $err = $!;
        unlink $sidecar_final if -e $sidecar_final;
        unlink $tmp           if -e $tmp;
        unlink $sidecar_tmp   if -e $sidecar_tmp;
        return (undef, "cannot finalize transcript: $err");
    }

    # --- Step 11: success. ---------------------------------------------------
    return ($new, undef);
}

1;
