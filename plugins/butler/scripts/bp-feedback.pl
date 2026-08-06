#!/usr/bin/env perl
# bp-feedback.pl — one-command capture of a single piece of operator feedback
# (b25-feedback-intake, R-06).
#
# An agent mid-task fires this, gets one line of output (the path it wrote),
# and returns to what it was doing. It writes exactly one new file per
# invocation, feedback-<n>.txt, into the current batch under
# <data>/corrections/, with a small provenance header, and exits.
#
# It does NOT: interpret, classify or summarise the text; prompt or open an
# editor; run a sub-task; edit any existing file; open any existing file for
# writing or appending; write into a batch that already has a DECOMPOSED.md
# by default (it opens the next one instead — see _resolve_batch_dir below);
# or read a skill. All of that judgement work belongs to the
# feedback skill (plugins/butler/skills/feedback/), not to this CLI.
#
# Usage:
#   bp-feedback.pl [options] [--] [text ...]
# See _usage() below for the option list. Text is taken from the positional
# arguments if any are given, else read from stdin to EOF. Never detects
# whether stdin is an interactive terminal — that would hang the moment an
# agent fires this with nothing piped in and nothing typed.
#
# Exit codes: 0 captured (also --help); 1 usage error; 2 no content;
# 3 control-byte refusal; 4 filesystem/path error; 5 invalid UTF-8.
# Every diagnostic goes to STDERR, prefixed "bp-feedback: ".

use strict;
use warnings;

use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Errno qw(EEXIST);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(getcwd abs_path);
use IO::Handle;
use Encode qw(decode encode);
use JSON::PP ();

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------

sub _usage {
    return <<'EOF';
bp-feedback.pl [options] [--] [text ...]

  --source <token>     override the source token (default "chat", or
                       "transcript" when --from-session supplied the body)
  --from-session <id>  take the body from that session's transcript instead of
                       argv/stdin, so the operator's bytes are never retyped by
                       an agent. Pair with --command to lift the exact
                       <command-args> payload of a slash-command invocation.
  --command <name>     with --from-session: the slash command whose arguments
                       are the feedback (e.g. butler:feedback). Without it, the
                       last plainly-typed user message is used.
  --blueprint <name>   record this blueprint name; overrides detection
  --batch <name>       target batch directory name
                       (default: the newest OPEN batch, i.e. one with no
                        DECOMPOSED.md; if the newest batch is closed, or
                        there are none, a new batch-<max+1> is created and
                        used)
  --data-dir <path>    override <data> resolution
  -h, --help           print usage to STDOUT and exit 0

Reads the feedback body from the positional arguments if any are given,
otherwise from stdin (read to EOF, in binary). Captures verbatim, byte for
byte; interprets nothing.

When piping into this tool, prefer `set -o pipefail` in the calling shell: a
producer that dies mid-pipe closes stdin early, which this tool cannot
distinguish from a short, complete message, and pipefail is what surfaces
the producer's own exit code to the caller.
EOF
}

# ---------------------------------------------------------------------------
# Failure helper — every non-zero exit goes through here so the message
# shape ("bp-feedback: <fragment>") and STDOUT-stays-empty rule hold
# uniformly. (House diagnostic style; a plain `die` cannot carry the fixed
# per-failure-class exit code the spec's table requires.)
# ---------------------------------------------------------------------------

sub _fail {
    my ($code, $msg, %opt) = @_;
    print STDERR "bp-feedback: $msg\n";
    print STDERR _usage() if $opt{usage};
    exit $code;
}

# ---------------------------------------------------------------------------
# Option parsing — hand-rolled @ARGV walk, house style throughout butler.
# ---------------------------------------------------------------------------

my $opt_source      = 'chat';
my $source_explicit = 0;
my $from_session;
my $opt_command;
my $blueprint_override;
my $batch_override;
my $data_dir_override;
my $help = 0;
my @positional;

{
    my @argv = @ARGV;
    my $no_more_opts = 0;
    # Red-team R1/R2/R4: option words occurring INSIDE the operator's own
    # feedback text were being recognised as options wherever they appeared
    # in @ARGV, silently deleting/misfiling the operator's own words (or, for
    # -h/--help, discarding the entire capture with exit 0). The usage line
    # ("[options] [--] [text ...]") already documents the conventional POSIX
    # boundary: options are only recognised BEFORE the first positional
    # token (or before an explicit --). Once the first positional token is
    # seen, every remaining token — including one that looks like an option
    # — is verbatim text. This does not change any invocation that already
    # puts its options first, which is every case the oracle exercises.
    my $positional_started = 0;
    my %needs_value = map { ($_ => 1) } ('--source', '--blueprint', '--batch', '--data-dir',
                                         '--from-session', '--command');

    while (@argv) {
        my $a = shift @argv;

        if ($no_more_opts || $positional_started) {
            push @positional, $a;
            next;
        }
        if ($a eq '--') {
            $no_more_opts = 1;
            next;
        }
        if ($a eq '-h' || $a eq '--help') {
            $help = 1;
            next;
        }
        if ($needs_value{$a}) {
            unless (@argv) {
                # Deliberate divergence from the spec's F1-F5 table, which
                # marks "+ usage" against F1 (unknown option) only: a
                # missing option value is exactly the moment usage helps
                # most, and the one-command constraint means the calling
                # agent should never have to go read anything else to
                # recover. No test asserts usage is absent here.
                _fail(1, "[$a requires a value]", usage => 1);
            }
            my $v = shift @argv;
            if ($a eq '--source') {
                $opt_source = $v;
                $source_explicit = 1;
            } elsif ($a eq '--from-session') {
                $from_session = $v;
            } elsif ($a eq '--command') {
                $opt_command = $v;
            } elsif ($a eq '--blueprint') {
                if (!length $v) {
                    # See divergence note above; same rationale applies.
                    _fail(1, '[--blueprint requires a value]', usage => 1);
                }
                $blueprint_override = $v;
            } elsif ($a eq '--batch') {
                $batch_override = $v;
            } elsif ($a eq '--data-dir') {
                $data_dir_override = $v;
            }
            next;
        }
        if ($a =~ /^-/) {
            _fail(1, "[unknown option]: $a", usage => 1);
        }
        # First positional token: option parsing is over from here on.
        $positional_started = 1;
        push @positional, $a;
    }
}

if ($help) {
    print _usage();
    exit 0;
}

# --source token shape (F4). Anchored with \z, not $: Perl's $ matches before
# a trailing newline, so a token like "file\n" would otherwise pass this
# check and land the header/body separator one line early (R7).
if ($opt_source !~ m{^[A-Za-z0-9._:/-]{1,64}\z}) {
    _fail(1, "[invalid source token]: $opt_source");
}

# --batch name shape (F3): plain component, no path separators, no '.' / '..'.
# \z, not $ — see the --source comment above (R7/R12: a trailing newline in
# the batch name broke both F3 rejection and the "one clean line" contract).
if (defined $batch_override) {
    if ($batch_override eq '.' || $batch_override eq '..'
        || $batch_override !~ /^[A-Za-z0-9._-]+\z/) {
        _fail(1, "[invalid batch name]: $batch_override");
    }
}

# Shape shared by every value that can land in a header field (R6):
# --blueprint, $ENV{BP_BLUEPRINT}, and a blueprint *directory* name found on
# disk. A single-line, printable, filesystem-safe token — deliberately the
# same charset as --batch. \z (not $) closes the same trailing-newline hole
# as R7/R12 would otherwise reopen here.
my $BP_NAME_RE = qr/^[A-Za-z0-9._-]{1,128}\z/;

if (defined $blueprint_override && $blueprint_override !~ $BP_NAME_RE) {
    _fail(1, "[invalid blueprint name]: $blueprint_override");
}

# --from-session takes a session id, which is a filesystem component (the
# transcript is <root>/projects/<project>/<id>.jsonl). Same \z discipline as
# every other header/path-bound token above.
if (defined $from_session && $from_session !~ /^[A-Za-z0-9._-]{1,128}\z/) {
    _fail(1, "[invalid session id]: $from_session");
}

# --command names a slash command (e.g. butler:feedback). Colons are legal
# here -- plugin skills are <plugin>:<verb> -- but nothing path-like is.
if (defined $opt_command && $opt_command !~ m{^[A-Za-z0-9._:-]{1,64}\z}) {
    _fail(1, "[invalid command name]: $opt_command");
}

if (defined $opt_command && !defined $from_session) {
    _fail(1, '[--command requires --from-session]; it selects WHICH entry of a '
           . 'transcript to lift, and without a transcript there is nothing to select from');
}

# Provenance follows the route automatically: a body lifted from a transcript
# is not "chat" (an agent's paraphrase might be), so unless the caller said
# otherwise, say where it really came from. Set before the body is acquired so
# a later fall-back to argv can honestly put it back (see below).
$opt_source = 'transcript' if defined $from_session && !$source_explicit;

# ---------------------------------------------------------------------------
# Transcript capture (--from-session). The point of this route is that the
# operator's bytes reach disk WITHOUT passing through an agent that might
# reflow, summarise or clip them on the way. Claude Code has already done the
# hard part: a typed slash command is recorded as a user entry whose content is
#
#     <command-message>butler:feedback</command-message>
#     <command-name>/butler:feedback</command-name>
#     <command-args>...the operator's exact text...</command-args>
#
# with the payload stored UNESCAPED and UNTRUNCATED, and nothing after the
# closing tag. So the command name is already separated from the arguments and
# no prefix-stripping heuristic is needed -- which matters, because a naive
# "strip a leading /token" would happily eat the first component of a body that
# opens with a POSIX path like /c/Users/....
#
# Deliberately NOT used: the `last-prompt` entry's `lastPrompt` field. It is
# truncated (~200 chars) and would silently lose most of a long batch -- the
# exact failure this route exists to prevent.
# ---------------------------------------------------------------------------

# Candidate roots holding <project>/<session>.jsonl, most explicit first.
# Cheap and non-fatal by design: a missing root is skipped, never an error,
# because the caller can still fall back to argv.
sub _transcript_roots {
    my ($data_dir_override) = @_;
    my @roots;

    push @roots, File::Spec->catdir($ENV{CLAUDE_CONFIG_DIR}, 'projects')
        if defined $ENV{CLAUDE_CONFIG_DIR} && length $ENV{CLAUDE_CONFIG_DIR};
    for my $home (grep { defined && length } ($ENV{HOME}, $ENV{USERPROFILE})) {
        push @roots, File::Spec->catdir($home, '.claude', 'projects');
    }
    # In a sandbox the container's ~/.claude/projects IS the bind-mounted
    # claude-home, so the HOME entry above already covers it; this handles the
    # host-side view of the same tree (reading a container session's transcript
    # from outside), which HOME does not reach.
    for my $d (grep { defined && length } ($data_dir_override, $ENV{CCPRAXIS_DATA_DIR})) {
        push @roots, File::Spec->catdir($d, 'claude-home', 'projects');
    }
    {
        my $dir = getcwd();
        while (1) {
            push @roots, File::Spec->catdir($dir, '.ccpraxis-local-data', 'claude-home', 'projects');
            my $parent = abs_path(File::Spec->catdir($dir, File::Spec->updir));
            last if !defined $parent || $parent eq $dir;
            $dir = $parent;
        }
    }

    my (@out, %seen);
    for my $r (@roots) {
        next if $seen{$r}++;
        push @out, $r if -d $r;
    }
    return @out;
}

sub _find_transcript {
    my ($session_id, $data_dir_override) = @_;
    for my $root (_transcript_roots($data_dir_override)) {
        opendir(my $dh, $root) or next;
        my @projects = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $p (@projects) {
            my $cand = File::Spec->catfile($root, $p, "$session_id.jsonl");
            return $cand if -f $cand;
        }
    }
    return undef;
}

# Returns ($bytes, $route) or (undef, undef). $bytes are UTF-8 ENCODED bytes:
# JSON::PP hands back character strings, and everything downstream of here
# (the control-byte scan, the UTF-8 gate, the ':raw' publish) works on bytes.
sub _extract_from_transcript {
    my ($path, $command) = @_;

    open(my $fh, '<:raw', $path) or return (undef, undef);
    my $json = JSON::PP->new->utf8;
    my ($cmd_args, $typed);

    while (my $line = <$fh>) {
        # Cheap prefilter: every entry we care about carries "user" as both
        # type and role. Decoding all ~20k lines of a long transcript would
        # dominate the runtime of a tool whose whole contract is "one command
        # and nothing else".
        next unless index($line, '"user"') >= 0;
        my $j = eval { $json->decode($line) } or next;
        next unless ref($j) eq 'HASH';
        next unless ($j->{type} // '') eq 'user';
        next if $j->{isMeta} || $j->{isSidechain};
        next unless ref($j->{message}) eq 'HASH';
        my $c = $j->{message}{content};
        next unless defined $c && !ref $c;

        if (defined $command && $c =~ m{<command-name>/\Q$command\E</command-name>}) {
            # Greedy to the LAST closing tag: nothing follows it in this
            # format, so greediness is what survives a body that itself
            # contains the literal string </command-args>.
            if ($c =~ m{<command-args>(.*)</command-args>}s) {
                $cmd_args = $1;
            } else {
                # Bare invocation with no arguments. Record it as an empty
                # capture rather than falling through to an OLDER message --
                # silently capturing the wrong turn is worse than capturing
                # nothing, because nothing is visible and wrong is not.
                $cmd_args = '';
            }
            next;
        }

        # A plainly-typed message. `promptSource` marks these; the injected
        # local-command bookkeeping entries (<command-name>, <command-message>,
        # <local-command-stdout>) do not carry it. Keep the tag check as a
        # fallback for transcripts written before that field existed.
        next if $c =~ m{\A\s*<(?:command-(?:name|message|args)|local-command-)}s;
        $typed = $c if defined $j->{promptSource} || $c !~ m{\A\s*<[a-z-]+>}s;
    }
    close $fh;

    my ($text, $route);
    if (defined $cmd_args)  { ($text, $route) = ($cmd_args, 'command-args') }
    elsif (defined $typed)  { ($text, $route) = ($typed,    'typed-message') }
    else                    { return (undef, undef) }

    return (encode('UTF-8', $text), $route);
}

# ---------------------------------------------------------------------------
# Body acquisition — transcript first when asked, else argv (word-joined),
# else all of stdin to EOF. Never probes whether stdin is a terminal (see
# header comment).
# ---------------------------------------------------------------------------

my $body;
if (defined $from_session) {
    my $path = _find_transcript($from_session, $data_dir_override);
    if (!defined $path) {
        print STDERR "bp-feedback: [transcript] no transcript for session $from_session "
                   . "under any known root; falling back to argv\n";
    } else {
        my ($text, $route) = _extract_from_transcript($path, $opt_command);
        if (defined $text) {
            $body = $text;
            print STDERR "bp-feedback: captured " . length($body)
                       . " bytes verbatim from $path ($route)\n";
        } else {
            print STDERR "bp-feedback: [transcript] $path yielded no usable user entry"
                       . (defined $opt_command ? " for command /$opt_command" : '')
                       . "; falling back to argv\n";
        }
    }
    # Deliberately argv-only on fallback, never stdin: --from-session is a
    # non-interactive route, and dropping into a stdin slurp here would hang a
    # human who typo'd a session id, which is exactly the hang the header
    # comment forbids.
    if (!defined $body) {
        $body = @positional ? join(' ', @positional) : '';
        $opt_source = 'chat' if !$source_explicit;   # honest: this is not a transcript capture
    }
}

if (defined $body) {
    # already acquired above
} elsif (@positional) {
    $body = join(' ', @positional);
} else {
    binmode STDIN;
    local $/ = undef;
    $! = 0;
    $body = <STDIN>;
    # R18: a pipe closing early because its producer died mid-write is
    # ordinarily indistinguishable from a short, complete message — Perl's
    # readline can't tell "closed" from "EOF". The one case it CAN surface is
    # a genuine read error (e.g. EIO), which leaves $body undef/partial with
    # $! set; a clean EOF (including on an empty pipe) never sets $!. Catch
    # that one distinguishable case loudly rather than silently keeping
    # whatever partial bytes arrived.
    if (!defined($body) && $!) {
        _fail(4, "[stdin read error]: $!");
    }
    $body = '' unless defined $body;
    # R18: emit the captured byte count so a caller piping into this tool has
    # something to sanity-check the volume against what it sent — the cheap
    # observability half of the mitigation for the truncation cases (e.g. a
    # producer killed mid-pipe) that cannot be detected structurally.
    print STDERR 'bp-feedback: captured ' . length($body) . " bytes from stdin\n";
}

# F6: no content at all (incl. whitespace-only).
if ($body !~ /\S/) {
    _fail(2, '[no feedback text] on argv or stdin; nothing written');
}

# F7: C0/DEL refusal. Hardcoded class (Pre-settled #1 of the b25 spec);
# canonical origin is the house C0/DEL rule in plugins/butler/scripts/
# bp-orchestrator.pl (locate it there by grepping for the class itself,
# e.g. tr/\x00-\x08\x0B\x0C\x0E-\x1F\x7F//d;) — deliberately NOT cited by
# line number: that file is edited by several live packages and the line
# moved twice during this package's own development, so a positional
# citation rots (SYN-23). Runs before the UTF-8 check
# so a NUL always reports as a control byte, never as an encoding error.
if ($body =~ /([\x00-\x08\x0B\x0C\x0E-\x1F\x7F])/) {
    my $byte   = ord($1);
    my $offset = $-[1];
    _fail(3, sprintf(
        '[refusing to write control byte] 0x%02X at offset %d; nothing written. '
      . 'Spell the escape as text (e.g. \0) instead of emitting the byte.',
        $byte, $offset));
}

# F8: UTF-8 validity, checked on a copy so $body stays the untouched raw
# bytes. R10: utf8::decode accepts Perl's own extended internal utf8 (lone
# surrogates, 5/6-byte sequences, code points above U+10FFFF) — a superset of
# RFC 3629 — so it under-enforces this gate; Encode's FB_CROAK mode is strict
# RFC 3629 and rejects all of those while still accepting everything
# utf8::decode already correctly refused (overlong forms, truncated
# sequences, Latin-1 high bytes).
{
    my $copy = $body;
    my $ok = eval { decode('UTF-8', $copy, Encode::FB_CROAK); 1 };
    unless ($ok) {
        _fail(5, '[input is not valid UTF-8]; nothing written');
    }
}

# ---------------------------------------------------------------------------
# <data> resolution: --data-dir > $ENV{CCPRAXIS_DATA_DIR} > git toplevel >
# walk up from cwd for a dir containing .ccpraxis-local-data.
# ---------------------------------------------------------------------------

sub _resolve_data_dir {
    my ($override) = @_;

    if (defined $override) {
        unless (-d $override) {
            _fail(4, "[--data-dir is not a directory]: $override");
        }
        return $override;
    }

    if (defined $ENV{CCPRAXIS_DATA_DIR} && length $ENV{CCPRAXIS_DATA_DIR}) {
        # R5: apply the same -d gate --data-dir gets. A stale/typo'd env
        # var (the relocated-project scenario CLAUDE.md warns about)
        # otherwise materialises a phantom corrections/ tree elsewhere,
        # silently, at exit 0.
        my $env_dir = $ENV{CCPRAXIS_DATA_DIR};
        unless (-d $env_dir) {
            _fail(4, "[CCPRAXIS_DATA_DIR is not a directory]: $env_dir");
        }
        return $env_dir;
    }

    my $top = `git rev-parse --show-toplevel 2>/dev/null`;
    if (defined $top) {
        chomp $top;
        if (length $top) {
            my $candidate = File::Spec->catdir($top, '.ccpraxis-local-data');
            return $candidate if -d $candidate;
        }
    }

    my $dir = getcwd();
    while (1) {
        my $candidate = File::Spec->catdir($dir, '.ccpraxis-local-data');
        return $candidate if -d $candidate;
        my $parent = abs_path(File::Spec->catdir($dir, File::Spec->updir));
        last if !defined $parent || $parent eq $dir;
        $dir = $parent;
    }

    _fail(4, '[cannot locate <data>]: tried CCPRAXIS_DATA_DIR > git toplevel > '
        . 'walk-up for .ccpraxis-local-data. Set CCPRAXIS_DATA_DIR=<project>/.ccpraxis-local-data '
        . '(or pass --data-dir) and retry.');
}

my $data_dir = _resolve_data_dir($data_dir_override);

# ---------------------------------------------------------------------------
# Batch resolution — the open/closed rule (G1 of the b25 spec). Newest
# numbered batch is consulted; open (no DECOMPOSED.md) is reused; closed (or
# none at all) means create-and-use the next one. --batch overrides all of
# it, including onto a closed batch.
# ---------------------------------------------------------------------------

sub _resolve_batch_dir {
    my ($data_dir, $override) = @_;
    my $corrections = File::Spec->catdir($data_dir, 'corrections');

    if (defined $override) {
        return File::Spec->catdir($corrections, $override);
    }

    my @nums;
    if (-d $corrections) {
        opendir(my $dh, $corrections) or return File::Spec->catdir($corrections, 'batch-1');
        for my $ent (readdir $dh) {
            next unless $ent =~ /^batch-(\d+)$/;
            my $n = $1 + 0;
            my $p = File::Spec->catdir($corrections, $ent);
            push @nums, $n if -d $p;
        }
        closedir $dh;
    }

    return File::Spec->catdir($corrections, 'batch-1') unless @nums;

    my @sorted = sort { $a <=> $b } @nums;
    my $max = $sorted[-1];
    my $newest = File::Spec->catdir($corrections, "batch-$max");
    my $decomposed = File::Spec->catfile($newest, 'DECOMPOSED.md');
    return $newest unless -e $decomposed;

    return File::Spec->catdir($corrections, 'batch-' . ($max + 1));
}

my $batch_dir = _resolve_batch_dir($data_dir, $batch_override);

# F11 / red-team: the resolved batch path exists and is not usable as a
# directory. A symlink that resolves to a real directory is accepted, with
# an observability note; a symlink to nothing (or to a non-directory) is F11.
if (-l $batch_dir) {
    if (-d $batch_dir) {
        my $target = readlink($batch_dir);
        $target = '?' unless defined $target;
        print STDERR "bp-feedback: note: $batch_dir is a symlink -> $target\n";
    } else {
        _fail(4, "[$batch_dir exists and is not a directory]; nothing written");
    }
} elsif (-e $batch_dir && !-d $batch_dir) {
    _fail(4, "[$batch_dir exists and is not a directory]; nothing written");
}

# F12: directory creation. make_path can die on malformed trees (e.g. an
# ancestor component that is a plain file); catch via eval and re-check.
unless (-d $batch_dir) {
    eval { make_path($batch_dir) };
    unless (-d $batch_dir) {
        my $why = $@ || $! || 'unknown';
        chomp $why;
        _fail(4, "[make_path] $batch_dir: $why");
    }
}

# ---------------------------------------------------------------------------
# Numbering — S = { k : feedback-<k>.txt exists, k =~ /^\d+$/ }; n_start =
# max(S)+1 or 1. Gaps are never filled. Symlinks/dirs/dangling links
# matching the pattern DO count (G1).
# ---------------------------------------------------------------------------

sub _next_start_number {
    my ($dir) = @_;
    my $max = 0;
    opendir(my $dh, $dir) or return 1;
    for my $ent (readdir $dh) {
        next unless $ent =~ /^feedback-(\d+)\.txt$/;
        # R9: a suffix long enough to overflow into floating point (e.g. a
        # hand-planted feedback-99999999999999999999.txt) would otherwise
        # both (a) be re-stringified as "1e+20", writing a filename that
        # violates this tool's own ^feedback-(\d+)\.txt$ contract, and (b)
        # make every later $n++ a silent no-op once $n itself is that NV,
        # permanently denying capture into the batch. 15 digits stays well
        # inside the exact-integer range of both a 64-bit IV and an NV
        # (< 2**53), so no realistic count is excluded.
        next if length($1) > 15;
        my $k = $1 + 0;
        $max = $k if $k > $max;
    }
    closedir $dh;
    return $max + 1;
}

my $n = _next_start_number($batch_dir);

# ---------------------------------------------------------------------------
# Reserve — O_CREAT|O_EXCL is the sole atomicity primitive; it also fails
# EEXIST on an existing symlink (even a dangling one) and never follows it,
# so a squatting name is stepped over rather than written through.
# ---------------------------------------------------------------------------

my $final;
my $reserved = 0;
my $tries = 0;
while ($tries < 1000) {
    $final = File::Spec->catfile($batch_dir, "feedback-$n.txt");
    if (sysopen(my $rfh, $final, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
        close $rfh;
        $reserved = 1;
        last;
    }
    unless ($! == EEXIST) {
        _fail(4, "[reserve] $final: $!");
    }
    $n++;
    $tries++;
}
unless ($reserved) {
    _fail(4, "[could not reserve a free feedback-$n.txt] in $batch_dir after 1000 attempts");
}

my $tmp = "$final.tmp.$$";

# R16: a signal in the write window (operator Ctrl-C, a harness timeout, an
# orchestrator killing the turn, or SIGXFSZ from a write-size limit) never
# returns from print/close, so the eval-based cleanup a few lines down can't
# run. Install the handler immediately after the reservation succeeds — NOT
# just before the eval — so the reservation-to-header-assembly window (header
# construction, blueprint scan) is also covered; a signal landing there would
# otherwise leave the zero-byte placeholder reserved with no handler in
# place. Catch the everyday signals and perform the same cleanup: unlink the
# temp file, and unlink $final only if it is still our own zero-byte
# placeholder. SIGKILL is deliberately left unhandled — that one genuinely
# cannot be caught, and the spec documents the zero-byte-placeholder-survives
# degradation for exactly that case.
my $signal_cleanup = sub {
    unlink $tmp if -e $tmp;
    unlink $final if -f $final && !-l $final && -s $final == 0;
    print STDERR "bp-feedback: [signal] interrupted during write; nothing written\n";
    exit 4;
};
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = $SIG{XFSZ} = $signal_cleanup;

# ---------------------------------------------------------------------------
# Provenance header — fixed field order Captured / Source / Blueprint, then
# exactly one blank line, then the body verbatim.
# ---------------------------------------------------------------------------

sub _iso_now {
    my @t = gmtime(time);
    return sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

# --blueprint > $ENV{BP_BLUEPRINT} > scan <data>/blueprints/*/blueprint.md
# for a single `status: running` fenced line. Zero or many => omit the
# field entirely; ambiguity never costs the feedback (G5).
sub _resolve_blueprint {
    my ($data_dir, $override) = @_;
    return ($override, undef) if defined $override;

    if (defined $ENV{BP_BLUEPRINT} && length $ENV{BP_BLUEPRINT}) {
        # R6: a malformed/hostile $ENV{BP_BLUEPRINT} (e.g. embedded
        # newlines) must never reach the header. This is provenance
        # metadata, not the operator's own words, so an invalid value is
        # treated the same as "unset" (fall through to the scan) rather
        # than failing the whole capture — ambiguity never costs the
        # feedback (G5).
        return ($ENV{BP_BLUEPRINT}, undef) if $ENV{BP_BLUEPRINT} =~ $BP_NAME_RE;
    }

    my $bp_root = File::Spec->catdir($data_dir, 'blueprints');
    return (undef, undef) unless -d $bp_root;

    opendir(my $dh, $bp_root) or return (undef, undef);
    my @running;
    for my $ent (readdir $dh) {
        next if $ent eq '.' || $ent eq '..';
        # R6: a blueprint *directory name* reaches the header verbatim with
        # no flag or env var involved. Skip anything that doesn't already
        # look like a safe single-line token rather than trusting the
        # filesystem.
        next unless $ent =~ $BP_NAME_RE;
        my $md = File::Spec->catfile($bp_root, $ent, 'blueprint.md');
        next unless -f $md;
        open(my $fh, '<', $md) or next;
        local $/ = undef;
        my $text = <$fh>;
        close $fh;
        next unless defined $text;
        # R11: the old check took the FIRST `status:` line anywhere in the
        # file, in scalar context, with no fence/frontmatter discipline — a
        # real "status: running" appearing after an earlier example/template
        # line in the same file was missed entirely (false negative). G5's
        # authoritative-line intent is: within the file's own fenced
        # metadata block, the line that actually governs is the LAST one
        # that matches, not the first. Restrict the scan to the first fenced
        # code block if one is present (that is where this house format's
        # metadata lives), then iterate every match with /g and keep the
        # last one.
        my $scan = $text;
        if ($text =~ /^```[^\n]*\n(.*?)\n```/ms) {
            $scan = $1;
        }
        my $val;
        while ($scan =~ /^\s*status:\s*(.+)$/mg) {
            $val = $1;
        }
        if (defined $val) {
            $val =~ s/#.*$//;
            $val =~ s/^\s+|\s+$//g;
            push @running, $ent if $val eq 'running';
        }
    }
    closedir $dh;

    return (undef, undef) if @running == 0;
    return ($running[0], undef) if @running == 1;

    my $count = scalar @running;
    return (undef, "$count blueprints are running; blueprint provenance omitted");
}

my ($blueprint, $blueprint_note) = _resolve_blueprint($data_dir, $blueprint_override);
if (defined $blueprint_note) {
    print STDERR "bp-feedback: $blueprint_note\n";
}

my @header_lines = (
    '**Captured:** ' . _iso_now(),
    '**Source:** ' . $opt_source,
);
push @header_lines, '**Blueprint:** ' . $blueprint if defined $blueprint;
my $header = join("\n", @header_lines) . "\n";

# ---------------------------------------------------------------------------
# Publish — same-dir temp, ':raw' (NOT ':encoding(UTF-8)': the body is
# already UTF-8-encoded bytes from @ARGV/stdin, and an encoding layer would
# encode it a second time, corrupting every non-ASCII byte it contains — do
# not "fix" this), error-checked close, rename onto our own zero-byte
# placeholder.
# ---------------------------------------------------------------------------

my $write_ok = eval {
    # R3: '>' follows symlinks. A pre-planted symlink at the temp-file path
    # (guessable/forceable via $$) would make this write clobber an
    # out-of-tree target, and the rename below would then publish the
    # symlink itself as the batch member. sysopen with O_EXCL is the same
    # primitive already used for the $final reservation above: it refuses to
    # follow a symlink and refuses an existing file, turning a planted or
    # leftover name into a loud failure instead of a silent clobber.
    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644) or die "open $tmp: $!\n";
    binmode($fh, ':raw');
    print { $fh } $header, "\n", $body or die "print $tmp: $!\n";
    # R13: nothing forced the temp file's bytes to stable storage before
    # rename; the caller had already been handed exit 0 and a path on a
    # system where the write was still only in page cache. sync (fsync(2))
    # before close closes the one remaining "printed a path, wrote nothing
    # durable" gap; IO::Handle's sync works on this lexical filehandle
    # because IO::Handle is loaded above.
    $fh->flush or die "flush $tmp: $!\n";
    $fh->sync  or die "sync $tmp: $!\n";
    close($fh) or die "close $tmp: $!\n";
    1;
};
unless ($write_ok) {
    my $why = $@ || 'unknown';
    chomp $why;
    unlink $tmp if -e $tmp;
    unlink $final if -f $final && -s $final == 0;
    _fail(4, "[write] $tmp: $why");
}

# R17: rename(2) on POSIX replaces the destination unconditionally,
# regardless of its contents — so the previous check-after-rename below
# never actually ran on this platform. The O_CREAT|O_EXCL reservation
# guarantees no OTHER invocation of this tool can hold this name, but it
# does not stop a third party (a human `cp`/`mv`, a restore script) from
# writing into the reserved placeholder during this window. Check
# immediately BEFORE publishing and fail loudly rather than clobber, so the
# invariant is actually enforced rather than merely asserted in
# unreachable code.
if (-e $final && !(-f $final && !-l $final && -s $final == 0)) {
    unlink $tmp if -e $tmp;
    _fail(4, "[rename] $tmp -> $final: refused; $final is no longer our empty placeholder");
}

unless (rename($tmp, $final)) {
    # On POSIX this branch is now unreachable: the check just above already
    # guarantees $final is either absent or our own zero-byte placeholder,
    # and rename() onto either succeeds unconditionally. This fallback
    # exists for Windows, where rename() onto an existing file fails
    # outright even when that file is our own just-verified placeholder.
    if (-f $final && -s $final == 0) {
        unlink $final;
    }
    unless (rename($tmp, $final)) {
        my $why = $!;
        unlink $tmp if -e $tmp;
        _fail(4, "[rename] $tmp -> $final: $why");
    }
}

# R8: the capture is durable on disk by this point (rename above has already
# succeeded) — a broken STDOUT (closed fd, or a downstream reader like
# `| head -c0` that hangs up early and delivers SIGPIPE) is a reporting
# failure, not a capture failure, and must not be conflated with the usage
# error (exit 1) or an undocumented SIGPIPE exit (141) that would make a
# caller retry and duplicate the capture. Ignore SIGPIPE for this print, and
# treat any failure to deliver the path as a STDERR-only warning: exit 0
# either way, because the file is the source of truth by now.
{
    local $SIG{PIPE} = 'IGNORE';
    unless (print "$final\n") {
        print STDERR "bp-feedback: [stdout] could not print $final: $!\n";
    }
}
exit 0;
