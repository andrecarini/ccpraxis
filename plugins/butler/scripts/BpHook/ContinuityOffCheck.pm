# BpHook::ContinuityOffCheck -- the PreToolUse module behind
# hooks/next/continuity-off-check.sh (package 04 of blueprint
# hook-continuity-remake). Writes command tickets for every predictable
# butler-continuity/butler-hold/butler-fork-ok/almanac-bug invocation
# (package 28, Decision 105; almanac-bug added by package 12,
# 12-bug-claimant-and-triaging -- this module is the one and only ticket
# writer for all four names), and tells an operator-typed
# `/butler:continuity off` apart from anything an agent could produce.
# `emergency-stop` (blueprint judged-continuity-disarm, package 06) is also
# recognized here; its operator flag is always false (only `off`'s branch
# computes operator_off()).
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 04-continuity-command-spec.md SS2.3/2.4; 28-fork-guard-bash-cost-spec.md
# SS2.2. Evidence for the discriminator:
# reports/04-continuity-command/evidence/off-record-shapes.md.
#
# ADDITIVE ONLY (Decision 19): BpHook.pm is never edited. run() never denies
# and never prints -- it only ever writes tickets, and always returns 0.
package BpHook::ContinuityOffCheck;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}

# Guarded the same way BpContinuityLease.pm guards BpSession.pm: by module
# basename in %INC, not by the literal path string this file computed --
# two different absolute prefixes for the same file is exactly the bug that
# produced two %INC keys and silently redefined every sub in it.
require "$SELF_DIR/../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;

# @THREAD_GATED -- blueprint where-things-go, package 03-thread-sessions,
# spec 2.9/2.7: every almanac-thread.pl write verb, mirrored exactly from
# that script's own @GATED_VERBS (parity-tested by continuity-off-check.t).
our @THREAD_GATED = qw(create archive archive-if-done add edit move reorder status
                       add-packages event attach detach switch take-over);

# ---------------------------------------------------------------------------
# run($p) -> 0, always. Never denies, never prints.
# ---------------------------------------------------------------------------
sub run {
    my ($p) = @_;
    return 0 unless ref $p eq 'HASH';
    return 0 unless defined $p->{tool_name} && !ref($p->{tool_name}) && $p->{tool_name} eq 'Bash';
    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $cmd = $ti->{command};
    return 0 unless defined $cmd && !ref($cmd);

    my $background = $ti->{run_in_background} ? 1 : 0;

    my $off_cache;
    my $off_computed = 0;

    for my $name (qw(butler-continuity butler-hold butler-fork-ok)) {
        my @invocations = BpHook::invocations($cmd, $name);
        for my $argv (@invocations) {
            next if ref $argv ne 'ARRAY';
            next if grep { !defined $_ } @$argv;

            if ($name eq 'butler-continuity') {
                my $v0 = $argv->[0];
                next unless defined $v0
                    && ($v0 eq 'on' || $v0 eq 'off' || $v0 eq 'off-confirm' || $v0 eq 'silence' || $v0 eq 'status'
                        || $v0 eq 'emergency-stop');
            }

            my $operator = 0;
            if ($name eq 'butler-continuity'
                && defined $argv->[0] && $argv->[0] eq 'off'
                && !defined BpHook::agent_id($p))
            {
                unless ($off_computed) {
                    $off_cache = operator_off($p);
                    $off_computed = 1;
                }
                $operator = $off_cache ? 1 : 0;
            }

            BpHook::write_ticket($p, $name, $argv, operator => $operator, background => $background);
        }
    }

    # almanac-bug (package 12, Decision 31): a bug-triage CLAIM needs the
    # caller's session identity, which only this hook can supply. Two command
    # shapes are predictable -- a direct almanac-bug.pl invocation, and the
    # almanac.pl dispatcher's `bug set-status`/`bug takeover`. Only the two
    # verbs that touch the claim (`set-status`, `takeover`) ever need a
    # ticket; every other almanac-bug verb needs no identity at all.
    for my $argv (BpHook::invocations($cmd, 'almanac-bug')) {
        next if ref $argv ne 'ARRAY';
        next if grep { !defined $_ } @$argv;
        my $v0 = $argv->[0];
        next unless defined $v0 && ($v0 eq 'set-status' || $v0 eq 'takeover');
        BpHook::write_ticket($p, 'almanac-bug', $argv, operator => 0, background => $background);
    }
    # almanac-thread / almanac-todo (package 03, Decision 18 F6/F7): every
    # thread-write verb and `todo promote` need the caller's identity, for
    # the same reason almanac-bug's claim does.
    my %thread_gated = map { $_ => 1 } @THREAD_GATED;
    for my $argv (BpHook::invocations($cmd, 'almanac-thread')) {
        next if ref $argv ne 'ARRAY';
        next if grep { !defined $_ } @$argv;
        my $v0 = $argv->[0];
        next unless defined $v0 && $thread_gated{$v0};
        BpHook::write_ticket($p, 'almanac-thread', $argv, operator => 0, background => $background);
    }
    for my $argv (BpHook::invocations($cmd, 'almanac-todo')) {
        next if ref $argv ne 'ARRAY';
        next if grep { !defined $_ } @$argv;
        my $v0 = $argv->[0];
        next unless defined $v0 && $v0 eq 'promote';
        BpHook::write_ticket($p, 'almanac-todo', $argv, operator => 0, background => $background);
    }

    for my $argv (BpHook::invocations($cmd, 'almanac')) {
        next if ref $argv ne 'ARRAY';
        next if grep { !defined $_ } @$argv;
        my $v0 = $argv->[0];
        if (defined $v0 && $v0 eq 'bug') {
            my $v1 = $argv->[1];
            next unless defined $v1 && ($v1 eq 'set-status' || $v1 eq 'takeover');
            BpHook::write_ticket($p, 'almanac-bug', [ @{$argv}[1 .. $#$argv] ],
                                  operator => 0, background => $background);
        }
        elsif (defined $v0 && $v0 eq 'thread') {
            my $v1 = $argv->[1];
            next unless defined $v1 && $thread_gated{$v1};
            BpHook::write_ticket($p, 'almanac-thread', [ @{$argv}[1 .. $#$argv] ],
                                  operator => 0, background => $background);
        }
        elsif (defined $v0 && $v0 eq 'todo') {
            my $v1 = $argv->[1];
            next unless defined $v1 && $v1 eq 'promote';
            BpHook::write_ticket($p, 'almanac-todo', [ @{$argv}[1 .. $#$argv] ],
                                  operator => 0, background => $background);
        }
    }

    return 0;
}

# ---------------------------------------------------------------------------
# operator_off($p) -> 1|0 -- the transcript-based discriminator.
# ---------------------------------------------------------------------------
sub operator_off {
    my ($p) = @_;
    return 0 unless ref $p eq 'HASH';
    my $tp_raw = $p->{transcript_path};
    return 0 unless defined $tp_raw && !ref($tp_raw) && length $tp_raw;
    my $path = BpHook::_to_bytes($tp_raw);   # also folds \ to / (review m1)
    return 0 unless defined $path && length $path;

    my $data = _read_tail($path, 1024 * 1024);
    return 0 unless defined $data;

    my @lines = split /\n/, $data;

    # R4-H1 (redteam HIGH-1 / Decision 49): a candidate is only eligible if
    # it precedes the assistant tool_use whose id is THIS command's own
    # ticket tool_use_id -- a record appended after that tool_use (e.g. by a
    # second Bash call racing the first) is never eligible. When that
    # tool_use cannot be located in the tail we hold, the boundary falls
    # back to "the whole tail", i.e. today's behaviour: nothing here narrows
    # what already-passing cases (which never carry a matching assistant
    # record at all) accept.
    my $tu_idx;
    my $tool_use_id = $p->{tool_use_id};
    if (defined $tool_use_id && !ref($tool_use_id) && length $tool_use_id) {
        LINE: for my $i (0 .. $#lines) {
            next unless length $lines[$i];
            my $rec = eval { JSON::PP->new->utf8->decode($lines[$i]) };
            next unless ref $rec eq 'HASH';
            next unless defined $rec->{type} && $rec->{type} eq 'assistant';
            my $msg = $rec->{message};
            next unless ref $msg eq 'HASH';
            my $content = $msg->{content};
            next unless ref $content eq 'ARRAY';
            for my $block (@$content) {
                next unless ref $block eq 'HASH';
                if (defined $block->{type} && $block->{type} eq 'tool_use'
                    && defined $block->{id} && $block->{id} eq $tool_use_id)
                {
                    $tu_idx = $i;
                    last LINE;
                }
            }
        }
    }
    my $limit = defined $tu_idx ? $tu_idx - 1 : $#lines;

    my $candidate;
    for my $i (reverse 0 .. $limit) {
        next if $i < 0;
        next unless length $lines[$i];
        my $rec = eval { JSON::PP->new->utf8->decode($lines[$i]) };
        next unless ref $rec eq 'HASH';
        next unless _is_candidate($rec);
        $candidate = $rec;
        last;
    }
    return 0 unless defined $candidate;
    return 0 unless is_operator_off_record($candidate);

    # Arm gate (anti-replay): candidate's timestamp must be at or after the
    # current arm's 'at', if one exists.
    my $sid = $p->{session_id};
    return 0 unless defined $sid && !ref($sid) && length $sid;
    my $root = BpHook::state_dir();
    return 1 unless defined $root;
    my $armed_path = "$root/armed/$sid";
    return 1 unless -f $armed_path;

    my $armed_raw = _slurp($armed_path);
    return 0 unless defined $armed_raw;
    my $armed = eval { JSON::PP->new->utf8->decode($armed_raw) };
    return 0 unless ref $armed eq 'HASH' && defined $armed->{at};
    my $armed_epoch = _parse_iso($armed->{at});
    return 0 unless defined $armed_epoch;

    my $rec_epoch = _parse_iso($candidate->{timestamp});
    return 0 unless defined $rec_epoch;

    return ($rec_epoch >= $armed_epoch) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# is_operator_off_record($r) -> 1|0 -- the shape predicate on one decoded
# JSONL record. Assumes _is_candidate($r) has already been checked by the
# caller for the "first candidate decides" rule, but re-checks it here so
# the predicate is correct when called standalone too.
# ---------------------------------------------------------------------------
sub is_operator_off_record {
    my ($rec) = @_;
    return 0 unless _is_candidate($rec);
    my $msg = $rec->{message};
    return 0 unless ref $msg eq 'HASH';
    my $content = $msg->{content};
    return 0 if ref $content;
    return 0 unless defined $content;

    my $origin = $rec->{origin};
    return 0 unless ref $origin eq 'HASH' && defined $origin->{kind} && $origin->{kind} eq 'human';

    my $trimmed = $content;
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+$//;

    my $re = qr{
        ^(?:<command-message>butler:continuity</command-message>\s*)?
        <command-name>/butler:continuity</command-name>\s*
        <command-args>\s*off\s*</command-args>$
    }x;
    return ($trimmed =~ $re) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# internal
# ---------------------------------------------------------------------------

sub _is_candidate {
    my ($rec) = @_;
    return 0 unless ref $rec eq 'HASH';
    return 0 unless defined $rec->{type} && $rec->{type} eq 'user';
    my $msg = $rec->{message};
    return 0 unless ref $msg eq 'HASH';
    return 0 unless defined $msg->{role} && $msg->{role} eq 'user';

    for my $k (qw(isMeta isSynthetic isCompactSummary toolUseResult sourceToolUseID)) {
        return 0 if $rec->{$k};
    }

    my $content = $msg->{content};
    my $text;
    if (!ref $content) {
        $text = defined $content ? $content : '';
    }
    elsif (ref $content eq 'ARRAY') {
        for my $block (@$content) {
            next unless ref $block eq 'HASH';
            return 0 if defined $block->{type} && $block->{type} eq 'tool_result';
        }
        $text = join('', map {
            (ref $_ eq 'HASH' && defined $_->{type} && $_->{type} eq 'text' && defined $_->{text})
                ? $_->{text} : ''
        } @$content);
    }
    else {
        return 0;
    }

    my $trimmed = $text;
    $trimmed =~ s/^\s+//;
    for my $prefix ('<task-notification>', 'Stop hook feedback', '<system-reminder>',
                    '<local-command', '[Request interrupted by user')
    {
        return 0 if index($trimmed, $prefix) == 0;
    }
    return 1;
}

sub _read_tail {
    my ($path, $cap) = @_;
    $cap //= 1024 * 1024;
    # R4-L-fifo (redteam LOW-6): a FIFO or a directory must never be opened
    # for a slurp -- a FIFO blocks until a writer closes it (or forever),
    # and this check is what keeps that from ever happening. -f is also the
    # cheapest possible guard: it needs no open() at all.
    return undef unless -f $path;
    my $size = (stat($path))[7];
    return undef unless defined $size;
    open(my $fh, '<:raw', $path) or return undef;
    my $start = ($size > $cap) ? ($size - $cap) : 0;
    seek($fh, $start, 0) if $start > 0;

    # Bounded read(), never local $/'s unbounded slurp: even though -f above
    # already rules out a FIFO, a plain read() with an explicit byte cap
    # costs nothing and cannot ever block past that cap regardless of what
    # the file turns into between the stat above and this read.
    my $data = '';
    my $remaining = $cap;
    while ($remaining > 0) {
        my $chunk;
        my $want = $remaining < 65536 ? $remaining : 65536;
        my $n = read($fh, $chunk, $want);
        last unless defined $n && $n > 0;
        $data .= $chunk;
        $remaining -= $n;
    }
    close $fh;
    return undef unless length $data;
    if ($start > 0) {
        my $nl = index($data, "\n");
        $data = ($nl >= 0) ? substr($data, $nl + 1) : '';
    }
    return $data;
}

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _parse_iso {
    my ($s) = @_;
    return undef unless defined $s && !ref($s);
    if ($s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/) {
        my ($y, $mo, $d, $h, $mi, $se) = ($1, $2, $3, $4, $5, $6);
        my $epoch = eval { require Time::Local; Time::Local::timegm($se, $mi, $h, $d, $mo - 1, $y) };
        return $epoch;
    }
    return undef;
}

1;
