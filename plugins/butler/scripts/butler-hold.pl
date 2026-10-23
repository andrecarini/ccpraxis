#!/usr/bin/env perl
# butler-hold.pl -- the one continuity holder (package 05 of blueprint
# hook-continuity-remake).
#
#   butler-hold [--token <8hex>] <item> [<item> ...]
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 05-holder-spec.md. Architecture: docs/hook-architecture.md ("Holder
# protocol", "BpHook core API", "Command binding").
#
# One command, one or more work items, a fixed 50-minute deadline, no
# duration argument of any kind. The process that becomes the holder never
# spawns a child of its own: it is the background task's own process for as
# long as it runs, so its own pid is what a live check ever needs to see
# (bug 20260922-211901-2cad). Re-invocation while a holder is alive merges
# items and pushes the deadline forward under a lock, then exits at once
# (bug 20260922-213451-6382, stacked holders).
#
# NO SESSION SELECTOR. This command never reads the caller's environment for
# a session identity; it learns its session only from a hook-written ticket
# (BpHook::take_ticket) or, when a Stop denial minted one, a one-shot token
# passed with --token. Additive only (Decision 19): nothing else changes.
#
# Exit codes: 0 normal release (off, finished, deadline, superseded, EXTEND);
# 1 refusal or internal error; 143 killed by a signal; 3 PROMPT (never-halt
# package 06, Decision 9/40) -- a subagent of this holder's own session
# recorded a permission prompt after this holder's start or latest
# extension; the holder prints one line, `PROMPT <agent_id>: <message>`,
# and exits immediately, with no `released:` line and no item report.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use Time::HiRes qw(sleep time);
use Encode qw(encode_utf8);

# Signals and the top-level eval are installed before any other work (spec
# 2.8, review M1, red-team M4): a die anywhere below, including a failed
# require of BpHook.pm, prints one stdout line and exits nonzero, and a
# TERM/INT/HUP before the loop is not the default action.
our $SIGNALLED = 0;
$SIG{TERM} = sub { $SIGNALLED = 1 };
$SIG{INT}  = sub { $SIGNALLED = 1 };
$SIG{HUP}  = sub { $SIGNALLED = 1 };

# The require, and everything that can die, happens inside main() (below),
# which runs under the top-level eval at the bottom of this file.

use constant HOLD_DEFAULT => 3000;
# QUIET below is 2 x TICK_DEFAULT. BpHook.pm's $HELD_QUIET_SECONDS (running_work,
# spec 38 sec 2.2) duplicates this 60 s window on purpose -- it judges the same
# holder record from the gate side, when no /proc read on this process is
# possible. Keep the two numbers equal if either changes.
use constant TICK_DEFAULT => 30;
use constant TAIL_BYTES   => 8 * 1024 * 1024;

my $ITEM_RE = qr/\A[A-Za-z0-9_-]{1,64}\z/;

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

sub out_line {
    my ($line) = @_;
    print STDOUT $line . "\n";
    return;
}

sub refuse {
    my ($msg) = @_;
    out_line("butler-hold: $msg");
    exit 1;
}

sub sid8_of { return substr($_[0], 0, 8) }

sub to_bytes_path {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) { utf8::encode($v) }
    $v =~ s{\\}{/}g;
    return $v;
}

sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub read_bytes_file {
    my ($p) = @_;
    return undef unless defined $p;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub read_json_file {
    my ($p) = @_;
    my $raw = read_bytes_file($p);
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

# ------------------------------------------------------------- test seam ----

sub _is_abs_path {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

sub _test_mode_enabled {
    my $m = $ENV{BUTLER_HOLD_TEST_MODE};
    return 0 unless defined $m && $m eq '1';
    return 0 unless _is_abs_path($ENV{BUTLER_STATE_DIR});
    return 1;
}

sub hold_seconds {
    return HOLD_DEFAULT unless _test_mode_enabled();
    my $v = $ENV{BUTLER_HOLD_TEST_SECONDS};
    return HOLD_DEFAULT unless defined $v && $v =~ /^[0-9]+$/;
    return HOLD_DEFAULT if $v < 1 || $v > 3000;
    return $v + 0;
}

sub tick_seconds {
    return TICK_DEFAULT unless _test_mode_enabled();
    my $v = $ENV{BUTLER_HOLD_TEST_TICK};
    return TICK_DEFAULT unless defined $v && $v =~ /^[0-9]+(?:\.[0-9]+)?$/;
    return TICK_DEFAULT if $v < 0.01 || $v > 30;
    return $v + 0;
}

# --------------------------------------------------------- record writing ---

my $LAST_WRITE_ERR;

sub write_record_atomic {
    my ($path, $data) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*$}{};
    my $json = eval { JSON::PP->new->utf8->canonical->encode($data) };
    unless (defined $json) { $LAST_WRITE_ERR = 'encode failed'; return 0 }
    for my $attempt (1 .. 5) {
        my $tmp = "$dir/.holdtmp.$$." . $attempt;
        if (open(my $fh, '>:raw', $tmp)) {
            print {$fh} $json;
            my $closed = close($fh);
            if ($closed && rename($tmp, $path)) { return 1 }
            $LAST_WRITE_ERR = "$!";
            unlink $tmp;
        }
        else {
            $LAST_WRITE_ERR = "$!";
        }
        sleep(0.02) if $attempt < 5;
    }
    return 0;
}

# --------------------------------------------------------------- pid/fp -----

sub compute_fp {
    my $c = read_bytes_file("/proc/$$/cmdline");
    return (defined $c && length $c) ? sha1_hex($c) : '';
}

sub proc_alive {
    my ($pid, $fp) = @_;
    return 0 unless defined $pid && "$pid" =~ /^[1-9][0-9]{0,9}$/;
    if (defined $fp && length $fp && -r '/proc/self/cmdline') {
        my $cmdline = read_bytes_file("/proc/$pid/cmdline");
        return 0 unless defined $cmdline && length $cmdline;
        return sha1_hex($cmdline) eq $fp ? 1 : 0;
    }
    return kill(0, $pid) ? 1 : 0;
}

sub resolve_self_task_id {
    # Red-team H1: a holder must never be able to hold its own background
    # task, which would silence the gate for as long as it re-invokes
    # itself. This process's own background-task id, if any, is the
    # basename of its own stdout redirect target -- resolved the same way
    # the spec resolves any other item's output file (2.7).
    my $link = readlink("/proc/$$/fd/1");
    return undef unless defined $link && length $link;
    $link =~ s{\\}{/}g;
    return undef unless $link =~ m{([^/]+)\.output$};
    return $1;
}

sub rand_token {
    my $bytes;
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, 8);
        close $fh;
    }
    if (defined $bytes && length($bytes) == 8) {
        return lc(unpack('H*', $bytes));
    }
    return substr(sha1_hex(time() . $$ . rand()), 0, 16);
}

# ------------------------------------------------------------- evidence -----

sub read_tail {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    my $p = to_bytes_path($path);
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $size = -s $fh;
    if (defined $size && $size > TAIL_BYTES) {
        seek($fh, $size - TAIL_BYTES, 0);
    }
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub finished_status_in_tail {
    my ($tail, $id) = @_;
    return undef unless defined $tail && length $tail;
    my $open_tag = "<task-id>$id</task-id>";
    my $last;
    for my $line (split /\n/, $tail) {
        my $pos = index($line, $open_tag);
        next if $pos < 0;
        my $window_end = $pos + length($open_tag) + 2000;
        $window_end = length($line) if $window_end > length($line);
        my $window = substr($line, $pos, $window_end - $pos);
        if ($window =~ /<status>([^<]*)<\/status>/) {
            $last = $1;
        }
    }
    return $last;
}

# last_event_in_tail($tail, $id) -> 'live' | 'terminal' | undef (spec 38
# sec 2.1). The kind of the LAST event for $id in the tail's byte order:
# a <task-id>$id</task-id> notification (its first <status> within 2000
# bytes on the same line; 'running' is live, anything else terminal), or a
# SendMessage resume marker `resumedAgentId":"$id"` in its plain or
# JSON-escaped form (live). A resume writes no notification, so without
# this a stale `stopped` stays the latest status and the resumed id is
# pruned while it works (bug 20260926-101917-85c6).
#
# Linear, like resolve_output_path_in_tail (red-team H2): a line without
# $id is skipped by index(); each `resumedAgentId` is found by index() and
# checked by one anchored match at its own position, never by a regex that
# can backtrack across the line.
sub last_event_in_tail {
    my ($tail, $id) = @_;
    return undef unless defined $tail && length $tail;
    my $open_tag = "<task-id>$id</task-id>";
    my $marker   = 'resumedAgentId';
    my $mlen     = length $marker;
    my $resume_re = qr/\G\\?"\s*:\s*\\?"\Q$id\E\\?"/;
    my $last;
    for my $line (split /\n/, $tail) {
        next if index($line, $id) < 0;
        my ($best_pos, $best_kind) = (-1, undef);
        my $pos = index($line, $open_tag);
        if ($pos >= 0) {
            my $window_end = $pos + length($open_tag) + 2000;
            $window_end = length($line) if $window_end > length($line);
            my $window = substr($line, $pos, $window_end - $pos);
            if ($window =~ /<status>([^<]*)<\/status>/) {
                ($best_pos, $best_kind) = ($pos, ($1 eq 'running' ? 'live' : 'terminal'));
            }
        }
        my $from = 0;
        while (1) {
            my $m = index($line, $marker, $from);
            last if $m < 0;
            $from = $m + $mlen;
            pos($line) = $from;
            if ($line =~ /$resume_re/gc) {
                ($best_pos, $best_kind) = ($m, 'live') if $m > $best_pos;
            }
        }
        $last = $best_kind if defined $best_kind;
    }
    return $last;
}

# subagent_paths($record, $id) -> (agent-<id>.jsonl, agent-<id>.meta.json)
# under <dirname(transcript_path)>/<sid>/subagents, or () without a
# transcript path. Either existing makes <id> a subagent item.
sub subagent_paths {
    my ($record, $id) = @_;
    my $tp  = $record->{transcript_path};
    my $sid = $record->{session_id};
    return () unless defined $tp && length $tp && defined $sid;
    (my $tpn = $tp) =~ s{\\}{/}g;
    my $sdir = dirname($tpn) . "/$sid/subagents";
    return ("$sdir/agent-$id.jsonl", "$sdir/agent-$id.meta.json");
}

# file_stat($path) -> (size, mtime) | () -- hi-res mtime where the platform
# gives one; a vanished or unreadable file is simply absent.
sub file_stat {
    my ($path) = @_;
    my $b = to_bytes_path($path);
    return () unless defined $b && -e $b;
    my @s = Time::HiRes::stat($b);
    return () unless @s && defined $s[9];
    return ($s[7], $s[9]);
}

sub resolve_output_path_in_tail {
    # A linear index()-based scan (red-team H2 / review m3): the previous
    # lazy regex backtracked from every '/' in the tail, which cost minutes
    # to hours on a tail with a long slash-heavy run (base64 image data).
    # This walks forward with index(), then bounds each candidate's
    # backward extraction by the nearest quote/angle-bracket/whitespace, so
    # the whole scan is O(length of tail) with no backtracking.
    my ($tail, $id) = @_;
    return undef unless defined $tail && length $tail;
    my $marker = "$id.output";
    my $mlen   = length $marker;
    my $tlen   = length $tail;
    my $found;
    my $pos = 0;
    while (1) {
        my $idx = index($tail, $marker, $pos);
        last if $idx < 0;
        $pos = $idx + 1;
        next if $idx == 0;
        my $anchor = substr($tail, $idx - 1, 1);
        next unless $anchor eq '/' || $anchor eq '\\';
        my $left = $idx - 1;
        while ($left > 0) {
            my $c = substr($tail, $left - 1, 1);
            last if $c eq '"' || $c eq '<' || $c eq '>' || $c =~ /\s/;
            $left--;
        }
        my $cand = substr($tail, $left, $idx + $mlen - $left);
        next unless $cand =~ m{^(?:[A-Za-z]:|/)};
        $found = $cand;    # keep the last hit, as the old scan did
    }
    return undef unless defined $found;
    $found =~ s/\\\\/\\/g;
    $found =~ s/\\/\//g;
    return undef unless -e $found;
    # Decode once (review M2): the tail was read ':raw', so a non-ASCII
    # path here is still raw UTF-8 bytes. Mark it as characters now, so the
    # canonical JSON encoder (utf8 mode) emits it once, not twice.
    utf8::decode($found);
    return $found;
}

# %SEEN -- path => [size, mtime] as of the last evaluation, in memory only
# (spec 38 sec 2.1). A change since then is growth even when the mtime's
# resolution hides it.
my %SEEN;

# An id that stays `unknown` is pruned like a finished one, after QUIET:
# nothing the transcript, the subagent dir or an output file shows stands
# behind it, so holding it would let every stop through for the full hold on
# a name alone (red-team SF-2, judged-continuity-disarm/05, todo
# 20261023-082209-24290000). QUIET is the grace for a just-dispatched id whose
# evidence has not reached disk yet. Pruning one only wakes the session early.
my %UNKNOWN_SINCE;

# item_gone($record, $id, $tail) -> 'finished' | 'unseen' | undef.
sub item_gone {
    my ($record, $id, $tail) = @_;
    my $st = item_status($record, $id, $tail, \%SEEN)->{status};
    if ($st ne 'unknown') {
        delete $UNKNOWN_SINCE{$id};
        return $st eq 'finished' ? 'finished' : undef;
    }
    my $grace = unseen_grace_seconds();
    return undef unless defined $grace;
    my $now = time();
    $UNKNOWN_SINCE{$id} //= $now;
    return ($now - $UNKNOWN_SINCE{$id} >= $grace) ? 'unseen' : undef;
}

# unseen_grace_seconds() -> QUIET, or in test mode BUTLER_HOLD_TEST_UNSEEN_GRACE
# (undef when unset). Most holder fixtures hold bare made-up ids to exercise
# other behaviour, so test mode opts in to the prune rather than out of it.
sub unseen_grace_seconds {
    return 2 * tick_seconds() unless _test_mode_enabled();
    my $v = $ENV{BUTLER_HOLD_TEST_UNSEEN_GRACE};
    return undef unless defined $v && $v =~ /^[0-9]+(?:\.[0-9]+)?$/;
    return $v + 0;
}

# item_status($record, $id, $tail, $seen) -> {status=>'finished'|'running'|'unknown', mtime=>epoch?}
#
# A subagent item (subagents/agent-<id>.jsonl or .meta.json exists) is
# judged from real activity: finished only when its last event is terminal
# AND no activity file grew within QUIET (2 ticks). A task item keeps the
# notification-status rule exactly (spec 38 sec 2.1).
sub item_status {
    my ($record, $id, $tail, $seen) = @_;
    $seen = \%SEEN unless ref $seen eq 'HASH';
    $tail = read_tail($record->{transcript_path}) unless defined $tail;

    my ($jsonl, $meta) = subagent_paths($record, $id);
    my $is_subagent = (defined $jsonl && (-e to_bytes_path($jsonl) || -e to_bytes_path($meta))) ? 1 : 0;
    return subagent_status($record, $id, $tail, $seen, $jsonl, $meta) if $is_subagent;

    if (defined $tail) {
        my $st = finished_status_in_tail($tail, $id);
        if (defined $st && $st ne 'running') {
            return { status => 'finished' };
        }
    }

    my $tp  = $record->{transcript_path};
    my $sid = $record->{session_id};
    my @candidates;
    if (defined $tp && length $tp) {
        (my $tpn = $tp) =~ s{\\}{/}g;
        my $sdir = dirname($tpn) . "/$sid";
        push @candidates, "$sdir/subagents/agent-$id.jsonl";
        push @candidates, "$sdir/subagents/agent-$id.meta.json";
    }
    my $outputs = (ref $record->{outputs} eq 'HASH') ? $record->{outputs} : {};
    push @candidates, $outputs->{$id} if defined $outputs->{$id};

    for my $c (@candidates) {
        next unless defined $c;
        my $cb = to_bytes_path($c);
        if (defined $cb && -e $cb) {
            my $mt = (stat($cb))[9];
            return { status => 'running', mtime => $mt } if defined $mt;
        }
    }

    my $found_now = defined $tail ? resolve_output_path_in_tail($tail, $id) : undef;
    if (defined $found_now) {
        my $cb = to_bytes_path($found_now);
        if (defined $cb && -e $cb) {
            my $mt = (stat($cb))[9];
            return { status => 'running', mtime => $mt } if defined $mt;
        }
    }

    return { status => 'unknown' };
}

sub subagent_status {
    my ($record, $id, $tail, $seen, $jsonl, $meta) = @_;
    my $quiet = 2 * tick_seconds();
    my $now = time();

    my @activity;
    push @activity, $jsonl;
    my $outputs = (ref $record->{outputs} eq 'HASH') ? $record->{outputs} : {};
    push @activity, $outputs->{$id} if defined $outputs->{$id} && length $outputs->{$id};

    my ($growing, $newest) = (0, undef);
    for my $f (@activity) {
        my ($size, $mtime) = file_stat($f);
        next unless defined $mtime;
        $growing = 1 if $mtime >= $now - $quiet;
        my $prev = $seen->{$f};
        $growing = 1 if ref $prev eq 'ARRAY' && ($prev->[0] != $size || $prev->[1] != $mtime);
        $seen->{$f} = [$size, $mtime];
        $newest = $mtime if !defined $newest || $mtime > $newest;
    }

    my $last = last_event_in_tail($tail, $id);
    return { status => 'finished' } if defined $last && $last eq 'terminal' && !$growing;
    return { status => 'running', mtime => int($newest) } if defined $newest;

    my ($msize, $mmtime) = file_stat($meta);
    return { status => 'running', mtime => int($mmtime) } if defined $mmtime;

    my $found_now = defined $tail ? resolve_output_path_in_tail($tail, $id) : undef;
    if (defined $found_now) {
        my ($osize, $omtime) = file_stat($found_now);
        return { status => 'running', mtime => int($omtime) } if defined $omtime;
    }
    return { status => 'unknown' };
}

sub all_finished {
    my ($record, $seen) = @_;
    my $items = (ref $record->{items} eq 'ARRAY') ? $record->{items} : [];
    return 0 unless @$items;
    my $tail = read_tail($record->{transcript_path});
    for my $id (@$items) {
        my $st = item_status($record, $id, $tail, $seen);
        return 0 unless $st->{status} eq 'finished';
    }
    return 1;
}

sub resolved_outputs_for {
    my ($tail, @ids) = @_;
    my %out;
    return \%out unless defined $tail;
    for my $id (@ids) {
        my $op = resolve_output_path_in_tail($tail, $id);
        $out{$id} = $op if defined $op;
    }
    return \%out;
}

# ---------------------------------------------------------------------------
# main -- everything below runs inside the top-level eval at the end of
# this file (spec 2.8, review M1). A die anywhere in here, including a
# failed require of BpHook.pm, is caught there; `exit` is not eval-caught
# and keeps every existing exit code below exactly as it is.
# ---------------------------------------------------------------------------

sub main {

require "$Bin/BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$Bin/BpDataRoot.pm"
    unless grep { m{(?:^|/)BpDataRoot\.pm$} } keys %INC;
require "$Bin/BpHook/PromptWatch.pm"
    unless grep { m{(?:^|/)BpHook/PromptWatch\.pm$} } keys %INC;

$| = 1;
binmode(STDOUT, ':raw');
$SIG{__WARN__} = sub { };

# ---------------------------------------------------------------------------
# never-halt package 06 (Decision 9/40): prompt watching. Resolved ONCE per
# process from the process's own cwd and env (Decision 11 (8)) -- never from
# a payload. If the resolved data dir is not an existing directory, prompt
# watching is OFF for this whole process: no error, no output, no behaviour
# change (spec sec 2.8, edge case 1/6).
# ---------------------------------------------------------------------------
my $WATCH_DATA = eval { BpDataRoot::resolve()->{data_dir} };
my $WATCHING   = (defined $WATCH_DATA && -d $WATCH_DATA) ? 1 : 0;
my $PROMPTS    = $WATCHING ? "$WATCH_DATA/.drive-solo/prompts.jsonl" : undef;

# ---------------------------------------------------------------------------
# argv parsing (by hand -- no option-parsing module of any kind)
# ---------------------------------------------------------------------------

my @ARGV_RAW = @ARGV;

my ($token_val, $token_seen) = (undef, 0);
my @item_words;
{
    my @a = @ARGV;
    while (@a) {
        my $w = shift @a;
        if ($w eq '--token') {
            refuse('takes ids only, plus --token from a stop message; the hold is always 50 minutes.')
                if $token_seen;
            $token_seen = 1;
            $token_val = shift @a;
            next;
        }
        if ($w =~ /^-/) {
            refuse('takes ids only, plus --token from a stop message; the hold is always 50 minutes.');
        }
        push @item_words, $w;
    }
}

if ($token_seen) {
    unless (defined $token_val && $token_val =~ /^[0-9a-f]{8}$/) {
        refuse('--token takes the 8-character token from the stop message.');
    }
}

refuse('name at least one subagent or background task id.') unless @item_words;

my (@ITEMS, %seen_item);
for my $w (@item_words) {
    my $id = $w;
    if ($id =~ /^agent-(.*)$/s) { $id = $1 }
    refuse("ids are letters, digits, '-' and '_' only.") unless $id =~ $ITEM_RE;
    next if $seen_item{$id}++;
    push @ITEMS, $id;
}

# Red-team H1: a holder can never hold its own background task. Checked
# for every become and every extend, before anything is read or written.
my $SELF_TASK_ID = resolve_self_task_id();
if (defined $SELF_TASK_ID && grep { $_ eq $SELF_TASK_ID } @ITEMS) {
    refuse('a holder cannot hold itself.');
}

# ---------------------------------------------------------------------------
# step 2: state root
# ---------------------------------------------------------------------------

my $ROOT = BpHook::state_dir();
refuse('no continuity state directory (set HOME, or an absolute BUTLER_STATE_DIR).')
    unless defined $ROOT;

# ---------------------------------------------------------------------------
# step 3: binding
# ---------------------------------------------------------------------------

my ($SID, $AID, $BIND_TP, $BACKGROUND);

# R6-M5 (red-team MEDIUM-5, Decision 51): for a ticket-bound call, whether
# the --token's ownership gets CHECKED is deferred past the point where we
# would refuse a foreground BECOME -- otherwise take_stop_token's one-shot
# consumption burns the escape before the caller ever learns the call was
# refused (the token would never be usable by a later, correct, background
# retry). $DEFERRED_TOKEN_CHECK is resolved once is_alive/BACKGROUND are
# both known, below.
my $DEFERRED_TOKEN_CHECK = 0;

my $ticket = BpHook::take_ticket('butler-hold', \@ARGV_RAW);

if (ref $ticket eq 'HASH') {
    $SID        = $ticket->{session_id};
    $AID        = $ticket->{agent_id};
    $BIND_TP    = $ticket->{transcript_path};
    $BACKGROUND = ($ticket->{background} ? 1 : 0);
    $DEFERRED_TOKEN_CHECK = 1 if $token_seen;
}
elsif (!defined $ticket || $ticket eq 'ambiguous') {
    if ($token_seen) {
        my $s2 = BpHook::take_stop_token($token_val);
        if (defined $s2) {
            $SID        = $s2;
            $AID        = undef;
            $BIND_TP    = undef;
            $BACKGROUND = 1;
        }
        else {
            refuse('no session binding; use the --token from the stop message, or quote ids plainly.');
        }
    }
    else {
        refuse('no session binding; use the --token from the stop message, or quote ids plainly.');
    }
}
else {
    refuse('no session binding; use the --token from the stop message, or quote ids plainly.');
}

if (defined $AID) {
    refuse('only the main session holds; a subagent may not.');
}

my $SID8 = sid8_of($SID);

# ---------------------------------------------------------------------------
# step 4: become or extend, under the lock
# ---------------------------------------------------------------------------

my $HOLDER_DIR = "$ROOT/holder";
eval { require File::Path; File::Path::make_path($HOLDER_DIR) };

my $LOCK_PATH = "$HOLDER_DIR/$SID.lock";
my $RECORD_PATH = "$HOLDER_DIR/$SID.json";

sub take_lock_or_refuse {
    my ($lock_path) = @_;
    my $lockfh;
    unless (open($lockfh, '>>', $lock_path)) {
        refuse('holder state is busy; run it again.');
    }
    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "bp-hold-lock-timeout\n" };
        alarm(10);
        $got = flock($lockfh, LOCK_EX);
        alarm(0);
    };
    alarm(0);
    unless ($got) {
        close $lockfh;
        refuse('holder state is busy; run it again.');
    }
    return $lockfh;
}

sub unlock_and_close {
    my ($lockfh) = @_;
    flock($lockfh, LOCK_UN);
    close $lockfh;
    return;
}

sub armed_transcript_path {
    my ($root, $sid) = @_;
    my $data = read_json_file("$root/armed/$sid");
    return (ref $data eq 'HASH' && defined $data->{transcript_path} && length $data->{transcript_path})
        ? $data->{transcript_path}
        : undef;
}

sub resolve_transcript_path {
    my ($bind_tp, $existing, $root, $sid) = @_;
    return $bind_tp if defined $bind_tp && length $bind_tp;
    if (ref $existing eq 'HASH' && defined $existing->{transcript_path} && length $existing->{transcript_path}) {
        return $existing->{transcript_path};
    }
    return armed_transcript_path($root, $sid);
}

my $HOLD = hold_seconds();
my $TICK = tick_seconds();

# Red-team H2 / review m3: the tail read and output-path resolution run
# BEFORE the holder lock is taken at all, so a slow scan (even the linear
# one above, on a very large tail) never holds `holder/<sid>.lock` and
# never stalls a concurrent extend, a concurrent become, or this holder's
# own tick. A quick unlocked peek at the existing record is enough to pick
# the transcript path; the authoritative record is re-read under the lock
# below before anything is decided or written.
my $peek        = BpHook::holder($SID);
my $peek_tp     = resolve_transcript_path($BIND_TP, $peek, $ROOT, $SID);
my $peek_tail   = defined $peek_tp ? read_tail($peek_tp) : undef;
my $peek_outputs = resolved_outputs_for($peek_tail, @ITEMS);

sub take_off_check_or_end {
    # Review m1: `off` (BpHook::disarm) and this become/extend must
    # serialise on the SAME lock, or an off that completes between this
    # process's read of the (now-absent) record and its write can be
    # resurrected. `disarm` takes `armlock/<sid>` for its whole
    # unlink-and-write-off-record critical section, so taking that same
    # lock here, and holding it across our own write, closes the window
    # from this side without touching package 04's files.
    my ($root, $sid) = @_;
    my $almfh = BpHook::_open_armlock($root, $sid);
    unless ($almfh) {
        return (undef, 0);
    }
    unless (BpHook::_flock_with_timeout($almfh, 10)) {
        close $almfh;
        return (undef, 0);
    }
    return ($almfh, 1);
}

my $lockfh = take_lock_or_refuse($LOCK_PATH);
my ($almfh, $almok) = take_off_check_or_end($ROOT, $SID);
unless ($almok) {
    unlock_and_close($lockfh);
    refuse('holder state is busy; run it again.');
}
if (BpHook::latest_is_off($SID)) {
    flock($almfh, LOCK_UN);
    close $almfh;
    unlock_and_close($lockfh);
    out_line('continuity is off; holder ended.');
    exit 0;
}

my $existing = BpHook::holder($SID);
my $is_alive = (ref $existing eq 'HASH') ? proc_alive($existing->{pid}, $existing->{fp}) : 0;

# R6-M5: resolve the deferred ticket-bound --token check now -- but only
# once we know this call will NOT be refused for lacking run_in_background
# (is_alive, so it will EXTEND; or already BACKGROUND, so it may BECOME).
# On the about-to-be-refused foreground/no-holder path the token is left
# completely untouched, so it survives for a later, correct, retry.
if ($DEFERRED_TOKEN_CHECK && ($is_alive || $BACKGROUND)) {
    my $s2 = BpHook::take_stop_token($token_val);
    if (defined $s2 && $s2 ne $SID) {
        flock($almfh, LOCK_UN);
        close $almfh;
        unlock_and_close($lockfh);
        refuse('the --token belongs to another session.');
    }
}

if ($is_alive) {
    # -------------------------------------------------------------- EXTEND
    my @merged = @{ (ref $existing->{items} eq 'ARRAY') ? $existing->{items} : [] };
    my %have = map { $_ => 1 } @merged;
    my @new_ids;
    for my $id (@ITEMS) {
        next if $have{$id};
        push @merged, $id;
        $have{$id} = 1;
        push @new_ids, $id;
    }

    my $want_deadline = int(time()) + $HOLD;
    my $new_deadline = ($existing->{deadline} // 0);
    $new_deadline = $want_deadline if $want_deadline > $new_deadline;

    my $tp = resolve_transcript_path($BIND_TP, $existing, $ROOT, $SID);

    my $outputs = (ref $existing->{outputs} eq 'HASH') ? { %{ $existing->{outputs} } } : {};
    for my $id (@new_ids) {
        next if defined $outputs->{$id};
        $outputs->{$id} = $peek_outputs->{$id} if defined $peek_outputs->{$id};
    }

    # spec 2.2: `held` = old `held` (or old `items` when `held` is absent)
    # plus ids not already in it, order kept; `ext_seq` = (old ext_seq // 0)
    # + 1. A record without either field (written by an older holder) is
    # read as held = items, ext_seq = 0.
    my @old_held = @{ (ref $existing->{held} eq 'ARRAY') ? $existing->{held}
                     : (ref $existing->{items} eq 'ARRAY') ? $existing->{items}
                     : [] };
    my %held_have = map { $_ => 1 } @old_held;
    my @held = @old_held;
    for my $id (@ITEMS) {
        next if $held_have{$id};
        push @held, $id;
        $held_have{$id} = 1;
    }
    my $ext_seq = ($existing->{ext_seq} // 0) + 1;

    my $rec = {
        session_id      => $SID,
        token           => $existing->{token},
        pid             => $existing->{pid},
        fp              => $existing->{fp},
        items           => \@merged,
        held            => \@held,
        ext_seq         => $ext_seq,
        outputs         => $outputs,
        started_at      => $existing->{started_at},
        deadline        => $new_deadline,
        transcript_path => $tp,
    };

    # never-halt package 06, Decision 11 (10): re-base the extending
    # process's prompts_offset to its OWN watching state at the moment of
    # the extend -- "to the file's end at that moment" when watching is ON;
    # carry the prior value through when this process's watching is OFF.
    if ($WATCHING) {
        $rec->{prompts_offset} = (-s $PROMPTS) // 0;
    }
    elsif (defined $existing->{prompts_offset}) {
        $rec->{prompts_offset} = $existing->{prompts_offset};
    }

    # Written before the record becomes visible (review M5): the
    # accountability line must never be observable-after-the-fact as
    # missing just because a reader raced the record's own appearance.
    BpHook::log_reason($SID, 'butler-hold', 'extend', join(', ', @merged));
    my $ok = write_record_atomic($RECORD_PATH, $rec);
    flock($almfh, LOCK_UN);
    close $almfh;
    unlock_and_close($lockfh);
    unless ($ok) {
        refuse('could not write the holder record (' . ($LAST_WRITE_ERR // 'unknown') . ').');
    }
    out_line(sprintf('extended the running holder (pid %s) until %s; this call exits now, the holder keeps waiting',
        $existing->{pid}, BpHook::local_utc_hhmm($new_deadline)));
    exit 0;
}

# ------------------------------------------------------------------- BECOME
unless ($BACKGROUND) {
    flock($almfh, LOCK_UN);
    close $almfh;
    unlock_and_close($lockfh);
    refuse('start it with run_in_background: true.');
}

my $tp = resolve_transcript_path($BIND_TP, $existing, $ROOT, $SID);
my $token = rand_token();
my $fp = compute_fp();
my $now = int(time());
my $outputs = { %$peek_outputs };

# never-halt package 06: captured BEFORE the record is written (spec sec
# 2.8 BECOME). M2 (red-team): seed from the PREVIOUS holder record's
# last-known prompts_offset when one exists for this same session ($existing
# may be a stale/dead-process record left behind, same continuity-holder
# resumption pattern as the EXTEND branch above) -- otherwise a prompt
# written between a worker's dispatch and this BECOME, or between one holder
# ending and the next starting, is silently treated as already-seen. Only
# fall back to the file's current end when there is genuinely no prior
# record for this session.
my $prompt_off;
if ($WATCHING) {
    if (ref $existing eq 'HASH'
        && defined $existing->{prompts_offset}
        && !ref($existing->{prompts_offset})
        && $existing->{prompts_offset} =~ /\A\d+\z/) {
        $prompt_off = $existing->{prompts_offset} + 0;
    }
    else {
        $prompt_off = (-s $PROMPTS) // 0;
    }
}

my $rec = {
    session_id      => $SID,
    token           => $token,
    pid             => $$,
    fp              => $fp,
    items           => \@ITEMS,
    held            => [ @ITEMS ],
    ext_seq         => 0,
    outputs         => $outputs,
    started_at      => $now,
    deadline        => $now + $HOLD,
    transcript_path => $tp,
};
$rec->{prompts_offset} = $prompt_off if $WATCHING;

BpHook::log_reason($SID, 'butler-hold', 'hold', join(', ', @ITEMS));
my $ok = write_record_atomic($RECORD_PATH, $rec);
flock($almfh, LOCK_UN);
close $almfh;
unlock_and_close($lockfh);
unless ($ok) {
    refuse('could not write the holder record (' . ($LAST_WRITE_ERR // 'unknown') . ').');
}
out_line(sprintf('%s holding session %s until %s: %s',
    BpHook::local_utc_hhmm($now), $SID8, BpHook::local_utc_hhmm($rec->{deadline}), join(', ', @ITEMS)));

# ---------------------------------------------------------------------------
# the wait loop -- this process is the held work's own watcher, start to end.
# $SIGNALLED is the `our` variable whose handlers were installed at the very
# top of this file, before any other work (spec 2.8, review M1).
# ---------------------------------------------------------------------------

sub end_report {
    # spec 2.3: the released line, then Decision 9's unchanged item report,
    # one line per id of `held` (fallback `items`), in `held` order.
    my ($reason, $record, $code) = @_;
    $code //= 0;
    my @lines = (sprintf('%s released: %s', BpHook::local_utc_hhmm(int(time())), $reason));
    my @ids = (ref $record->{held} eq 'ARRAY') ? @{ $record->{held} }
            : (ref $record->{items} eq 'ARRAY') ? @{ $record->{items} }
            : ();
    my $tail = read_tail($record->{transcript_path});
    for my $id (@ids) {
        my $st = item_status($record, $id, $tail, \%SEEN);
        if ($st->{status} eq 'finished') {
            push @lines, "$id finished";
        }
        elsif ($st->{status} eq 'running') {
            push @lines, "$id still running (last activity " . iso_of($st->{mtime}) . ")";
        }
        else {
            push @lines, "$id unknown";
        }
    }
    print STDOUT join("\n", @lines) . "\n";
    exit $code;
}

sub sleep_watching_signal {
    my ($secs) = @_;
    my $remaining = $secs;
    my $chunk = 0.05;
    while ($remaining > 0 && !$SIGNALLED) {
        my $s = $remaining < $chunk ? $remaining : $chunk;
        sleep($s);
        $remaining -= $s;
    }
    return;
}

my $known_deadline = $rec->{deadline};
my $last_valid = $rec;

# 2.4 loop state: $last_seq is the ext_seq last reported (become writes 0,
# so this starts at 0); @last_items is items as of the last read or write.
my $last_seq = $rec->{ext_seq} // 0;
my @last_items = @{ (ref $rec->{items} eq 'ARRAY') ? $rec->{items} : [] };
my $dropped_unseen = 0;

# never-halt package 06: the in-memory byte offset into $PROMPTS, seeded
# from this BECOME's own prompts_offset (undef/OFF -> 0; never read before
# this process's own start).
my $PROMPT_OFFSET = $prompt_off // 0;

# SHOULD-FIX 3 (never-halt package 06 fix-batch): tracks, independently of
# $last_seq (which the extension-report coalescing logic owns and may
# advance from the LOCKED re-read in step 3/4), the highest ext_seq whose
# prompts_offset has actually been applied to rebase $PROMPT_OFFSET. An
# extension first observed inside the locked section advances $last_seq
# without ever going through the unlocked WATCHING block below, so using
# $last_seq here would make that extend's re-base silently never happen;
# $prompt_seen_seq only ever advances where the re-base itself is applied.
my $prompt_seen_seq = $rec->{ext_seq} // 0;

# report_extension_if_advanced($record) -- 2.4 step 1. Prints ONE extension
# line when $record's ext_seq has advanced past $last_seq, then updates
# $last_seq/@last_items from $record. Several extensions between two reads
# coalesce into one line, by construction (only the delta since the last
# report is ever printed).
#
# An anonymous sub assigned to a lexical, not a named `sub`: a named sub
# nested here would close over $last_seq/@last_items declared just above it
# by reference at compile time only, which perl warns about ("will not stay
# shared") and which would leak the warning to stderr (R5-M1/RT-M4 asserts
# an empty stderr on every code path). An anonymous sub closes over them
# properly.
my $report_extension_if_advanced = sub {
    my ($record) = @_;
    my $seq = $record->{ext_seq} // 0;
    return 0 unless $seq > $last_seq;
    my @items_now = @{ (ref $record->{items} eq 'ARRAY') ? $record->{items} : [] };
    my %had = map { $_ => 1 } @last_items;
    my @added = grep { !$had{$_} } @items_now;
    my $body = @added ? ('added: ' . join(', ', @added)) : 'no new ids';
    out_line(sprintf('%s extended until %s; %s',
        BpHook::local_utc_hhmm(int(time())), BpHook::local_utc_hhmm($record->{deadline}), $body));
    $last_seq = $seq;
    @last_items = @items_now;
    return 1;
};

while (1) {
    my $t0 = time();
    my $remaining_to_deadline = $known_deadline - $t0;
    my $sleep_for = $remaining_to_deadline > $TICK ? $TICK
                  : ($remaining_to_deadline < 0.01 ? 0.01 : $remaining_to_deadline);
    sleep_watching_signal($sleep_for);

    if ($SIGNALLED) {
        end_report('killed by a signal', $last_valid, 143);
    }

    my $rp = BpHook::holder($SID);
    if (ref($rp) ne 'HASH') {
        end_report('continuity is off', $last_valid, 0);
    }
    if (!defined $rp->{token} || $rp->{token} ne $token) {
        end_report('superseded by another holder', $rp, 0);
    }

    # 2.4 step 1 (unlocked read): an extension is reported as soon as it is
    # observed, before this tick's finish detection.
    $report_extension_if_advanced->($rp);

    # never-halt package 06 (Decision 9/40), spec sec 2.8 loop steps 1-4:
    # placed after the unlocked record read, the off/superseded checks and
    # the extension report, and BEFORE finish detection.
    if ($WATCHING) {
        my $rp_ext_seq = $rp->{ext_seq} // 0;
        if ($rp_ext_seq > $prompt_seen_seq
            && defined $rp->{prompts_offset}
            && !ref($rp->{prompts_offset})
            && $rp->{prompts_offset} =~ /\A\d+\z/) {
            $PROMPT_OFFSET = $rp->{prompts_offset} + 0;
        }
        $prompt_seen_seq = $rp_ext_seq if $rp_ext_seq > $prompt_seen_seq;
        my ($prompt_recs, $new_off) = BpHook::PromptWatch::read_from($PROMPTS, $PROMPT_OFFSET);
        $PROMPT_OFFSET = $new_off;
        for my $pr (@$prompt_recs) {
            next unless ref $pr eq 'HASH';
            next unless defined $pr->{session_id} && !ref($pr->{session_id}) && $pr->{session_id} eq $SID;
            my $paid = $pr->{agent_id};
            $paid = 'main' unless defined $paid && !ref($paid) && $paid =~ /\A[A-Za-z0-9_-]{1,64}\z/;
            my $pmsg = $pr->{message};
            $pmsg = '' unless defined $pmsg && !ref($pmsg);
            $pmsg =~ s/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}]+/ /g;
            $pmsg =~ s/\A\s+//;
            $pmsg =~ s/\s+\z//;
            $pmsg = '(no message)' unless length $pmsg;
            print STDOUT encode_utf8("PROMPT $paid: $pmsg\n");
            exit 3;
        }
    }

    # package 11 (tooling-backlog), spec sec 2.7: the AC-loss watch probe.
    # Runs once per loop iteration, after the PROMPT block and before finish
    # detection. A die anywhere in here is swallowed: the holder continues
    # and nothing is printed (spec's own "failure isolation" rule).
    if ($WATCHING) {
        eval {
            unless (defined &BpAcWatch::enabled) {
                require "$Bin/BpAcWatch.pm";
            }
            if (BpAcWatch::enabled()) {
                my $test_mode = (defined $ENV{BUTLER_HOLD_TEST_MODE} && $ENV{BUTLER_HOLD_TEST_MODE} eq '1') ? 1 : 0;
                my $probe_file_set = (defined $ENV{CCPRAXIS_AC_PROBE_FILE} && length $ENV{CCPRAXIS_AC_PROBE_FILE}) ? 1 : 0;
                if (!$test_mode || $probe_file_set) {
                    my $armdata = read_json_file("$ROOT/armed/$SID");
                    if (ref $armdata eq 'HASH' && defined $armdata->{role} && $armdata->{role} eq 'driver') {
                        my $obs = BpAcWatch::observe($WATCH_DATA, src => 'holder');
                        # S7 (fix-batch, reviewer-1): wake on expired OR
                        # standing-down OR monitoring, not just expired. With
                        # two drive-solo sessions in one project, the FIRST
                        # director's stand-down can move the shared phase
                        # straight to standing-down/monitoring before this
                        # (second) session's holder ever observes expired --
                        # it must still stand down, not keep holding the
                        # wake-lock and the Continuous plan for a run this
                        # project has already decided to sleep (P1).
                        if (ref $obs eq 'HASH' && defined $obs->{phase}
                            && ($obs->{phase} eq 'expired' || $obs->{phase} eq 'standing-down'
                                || $obs->{phase} eq 'monitoring')) {
                            my $since = $obs->{dc_since};
                            BpAcWatch::log_event($WATCH_DATA, 'holder', 'HOLDER-WAKE',
                                { on_battery_since => (defined $since ? BpAcWatch::_iso_utc($since) : '-') },
                                'battery grace expired; waking the holder');

                            my $lfh3;
                            if (open($lfh3, '>>', $LOCK_PATH)) {
                                eval {
                                    local $SIG{ALRM} = sub { die "bp-hold-ac-lock-timeout\n" };
                                    alarm(10);
                                    flock($lfh3, LOCK_EX);
                                    alarm(0);
                                };
                                alarm(0);
                            }
                            unlink($RECORD_PATH);
                            if ($lfh3) { flock($lfh3, LOCK_UN); close $lfh3 }

                            my $hhmm = defined $since ? BpHook::local_utc_hhmm(int($since)) : undef;
                            $hhmm = 'unknown' unless defined $hhmm;
                            out_line("ACLOSS on battery since $hhmm (grace expired); run bp-drive-next.pl next now");
                            end_report('AC power lost', $last_valid, 4);
                        }
                    }
                }
            }
        };
    }

    $known_deadline = $rp->{deadline};
    $last_valid = $rp;

    # 2.4 step 2: finish detection, one tail read, no write on a quiet tick
    # (AC-13: the record file must stay byte-identical when nothing finished
    # and nothing extended).
    my $t1 = time();
    my $items_ref = (ref $rp->{items} eq 'ARRAY') ? $rp->{items} : [];
    my $tail = read_tail($rp->{transcript_path});
    my @finished_ids = grep { defined item_gone($rp, $_, $tail) } @$items_ref;
    my $deadline_due = ($t1 >= $rp->{deadline});

    next unless @finished_ids || $deadline_due || !@$items_ref;

    # 2.4 step 3/4: prune and/or exit, under the lock.
    my $lfh2;
    my $locked2 = 0;
    if (open($lfh2, '>>', $LOCK_PATH)) {
        eval {
            local $SIG{ALRM} = sub { die "bp-hold-lock-timeout\n" };
            alarm(10);
            $locked2 = flock($lfh2, LOCK_EX);
            alarm(0);
        };
        alarm(0);
    }
    unless ($locked2) {
        close $lfh2 if $lfh2;
        next;
    }

    my $rp2 = BpHook::holder($SID);
    if (ref($rp2) ne 'HASH') {
        unlock_and_close($lfh2);
        end_report('continuity is off', $last_valid, 0);
    }
    if (!defined $rp2->{token} || $rp2->{token} ne $token) {
        unlock_and_close($lfh2);
        end_report('superseded by another holder', $rp2, 0);
    }

    # Re-apply step 1 to the re-read record: an extension may have landed
    # between the unlocked read above and taking the lock.
    $report_extension_if_advanced->($rp2);
    $known_deadline = $rp2->{deadline};
    $last_valid = $rp2;

    my $items2 = (ref $rp2->{items} eq 'ARRAY') ? $rp2->{items} : [];
    my $tail2 = read_tail($rp2->{transcript_path});
    my %gone2;
    for my $id (@$items2) {
        my $g = item_gone($rp2, $id, $tail2);
        $gone2{$id} = $g if defined $g;
    }
    my @finished2 = grep { exists $gone2{$_} } @$items2;

    my $prune_write_failed = 0;
    if (@finished2) {
        my @remaining = grep { !exists $gone2{$_} } @$items2;
        my $rec2 = { %$rp2 };
        $rec2->{items} = \@remaining;
        my $ok = write_record_atomic($RECORD_PATH, $rec2);
        if ($ok) {
            my $waiting_str = @remaining ? join(', ', @remaining) : 'nothing';
            for my $fid (@finished2) {
                my $what = $gone2{$fid} eq 'finished' ? 'finished'
                         : 'dropped, nothing shows it running';
                out_line(sprintf('%s %s: %s; still waiting on: %s',
                    BpHook::local_utc_hhmm(int(time())), $what, $fid, $waiting_str));
            }
            $dropped_unseen = 1 if grep { $_ eq q{unseen} } values %gone2;
            @last_items = @remaining;
            $last_valid = $rec2;
            $items2 = \@remaining;
        }
        else {
            # Edge case (spec 5): a finished line is never printed for a
            # prune that did not reach disk. M1 (Decision 103): this must
            # NOT `next` unconditionally -- past the deadline, the release
            # still has to happen this tick (on the un-pruned record), or a
            # holder whose disk write keeps failing loops forever instead of
            # ever releasing.
            $prune_write_failed = 1;
        }
    }

    my $now_empty = (!$prune_write_failed && scalar(@$items2) == 0);
    my $t2 = time();
    my $deadline_now = ($t2 >= $rp2->{deadline});

    if ($now_empty) {
        unlink($RECORD_PATH);
        unlock_and_close($lfh2);
        end_report($dropped_unseen ? 'every held item finished or was never seen' : 'every held item finished',
                   $last_valid, 0);
    }
    elsif ($deadline_now) {
        unlink($RECORD_PATH);
        unlock_and_close($lfh2);
        end_report('deadline reached', $last_valid, 0);
    }
    else {
        unlock_and_close($lfh2);
        next;
    }
}

return;

}    # sub main

# ---------------------------------------------------------------------------
# spec 2.8 / review M1: the whole program runs inside eval. `exit` (used by
# every refusal, `end_report`, and every extend/become success path above)
# is not caught by eval and leaves the process at once with its own exit
# code, so this only ever fires for an unforeseen `die`.
# ---------------------------------------------------------------------------
my $MAIN_OK = eval { main(); 1 };
unless ($MAIN_OK) {
    print STDOUT "butler-hold: internal error.\n";
    exit 1;
}
exit 0;
