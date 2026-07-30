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
# feedback-intake skill, not to this CLI.
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

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------

sub _usage {
    return <<'EOF';
bp-feedback.pl [options] [--] [text ...]

  --source <token>     override the source token (default "chat"; e.g. --source file)
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
my $blueprint_override;
my $batch_override;
my $data_dir_override;
my $help = 0;
my @positional;

{
    my @argv = @ARGV;
    my $no_more_opts = 0;
    my %needs_value = map { ($_ => 1) } ('--source', '--blueprint', '--batch', '--data-dir');

    while (@argv) {
        my $a = shift @argv;

        if ($no_more_opts) {
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
        push @positional, $a;
    }
}

if ($help) {
    print _usage();
    exit 0;
}

# --source token shape (F4).
if ($opt_source !~ m{^[A-Za-z0-9._:/-]{1,64}$}) {
    _fail(1, "[invalid source token]: $opt_source");
}

# --batch name shape (F3): plain component, no path separators, no '.' / '..'.
if (defined $batch_override) {
    if ($batch_override eq '.' || $batch_override eq '..'
        || $batch_override !~ /^[A-Za-z0-9._-]+$/) {
        _fail(1, "[invalid batch name]: $batch_override");
    }
}

# ---------------------------------------------------------------------------
# Body acquisition — argv first (word-joined), else all of stdin to EOF.
# Never probes whether stdin is a terminal (see header comment).
# ---------------------------------------------------------------------------

my $body;
if (@positional) {
    $body = join(' ', @positional);
} else {
    binmode STDIN;
    local $/ = undef;
    $body = <STDIN>;
    $body = '' unless defined $body;
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

# F8: UTF-8 validity, checked on a copy so $body stays the untouched raw bytes.
{
    my $copy = $body;
    my $ok = eval { utf8::decode($copy) };
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
        return $ENV{CCPRAXIS_DATA_DIR};
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
        return ($ENV{BP_BLUEPRINT}, undef);
    }

    my $bp_root = File::Spec->catdir($data_dir, 'blueprints');
    return (undef, undef) unless -d $bp_root;

    opendir(my $dh, $bp_root) or return (undef, undef);
    my @running;
    for my $ent (readdir $dh) {
        next if $ent eq '.' || $ent eq '..';
        my $md = File::Spec->catfile($bp_root, $ent, 'blueprint.md');
        next unless -f $md;
        open(my $fh, '<', $md) or next;
        local $/ = undef;
        my $text = <$fh>;
        close $fh;
        next unless defined $text;
        if ($text =~ /^\s*status:\s*(.+)$/m) {
            my $val = $1;
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

my $tmp = "$final.tmp.$$";

my $write_ok = eval {
    open(my $fh, '>:raw', $tmp) or die "open $tmp: $!\n";
    print { $fh } $header, "\n", $body or die "print $tmp: $!\n";
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

unless (rename($tmp, $final)) {
    # On POSIX, rename() silently replaces an existing destination
    # regardless of its size, so the first rename above already succeeds
    # and this branch never runs there. This fallback exists for Windows,
    # where rename() onto an existing file fails outright. The safety
    # here does NOT come from the size check below — it comes entirely
    # from the O_CREAT|O_EXCL reservation at the top of this block: no
    # other process can hold this name, so $final can only be the
    # zero-byte placeholder we ourselves created. The -s == 0 check is
    # just a belt-and-braces assertion of that invariant on the one
    # platform where this code path can run at all; it is not itself
    # what makes replacing $final safe.
    if (-f $final && -s $final == 0) {
        unlink $final;
    }
    unless (rename($tmp, $final)) {
        my $why = $!;
        unlink $tmp if -e $tmp;
        _fail(4, "[rename] $tmp -> $final: $why");
    }
}

print "$final\n";
exit 0;
