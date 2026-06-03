#!/usr/bin/perl
# lint-readme-paths.pl — verify every backtick-quoted path in README.md
# that *unambiguously refers to a ccpraxis file* resolves to a file or
# directory that actually exists on disk.
#
# The heuristic is intentionally narrow — we only lint backticks that
# clearly point at the ccpraxis tree (or a known live-install location
# like `~/.claude/...`), and skip everything else (conceptual paths
# like `.claude/skills/` that describe a per-project layout, command
# fragments, slash commands, env vars, etc.). False positives waste
# the user's attention; false negatives just mean a stale path slips
# the lint and is caught by the human reviewer. We err toward the latter.
#
# Catches drift like "you renamed scripts/sandbox-launcher.pl to
# plugins/sandbox/scripts/launcher.pl but the README still mentions
# the old name." Run from /backup as a pre-flight, or manually.
#
# Usage: perl lint-readme-paths.pl [README.md]
#
# Defaults to <repo-root>/README.md.
#
# What gets linted (any of these matched at start of the backtick):
#   1. `~/.claude/...`           — absolute live install path
#   2. `<top-level-subdir>/...`  — relative to repo root, where top-level
#                                  subdir is one of:
#                                    scripts/, plugins/, skills/,
#                                    global-config/, container-config/,
#                                    references/, .claude-plans/
#
# Additional skip rules (a candidate matching the above is still skipped):
#   - contains '<' or '>' (placeholder)
#   - contains whitespace
#   - contains shell metacharacters: $ [ ] ( ) | & ; * ?
#
# Path resolution:
#   - `~/...`     → relative to $HOME
#   - everything else → relative to <repo-root>
#
# Exit codes: 0 = all paths resolve, 1 = one or more missing, 2 = error

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Cwd qw(abs_path);

my $REPO_ROOT = abs_path("$Bin/..");
my $README    = $ARGV[0] // "$REPO_ROOT/README.md";
my $HOME      = $ENV{HOME} // $ENV{USERPROFILE} // '';

unless (-f $README) {
    print STDERR "lint-readme-paths.pl: README not found: $README\n";
    exit 2;
}

# Top-level subdirs of the ccpraxis repo that anchor a "real path" reference.
# Anything starting with `<one of these>/...` is treated as repo-relative.
my @REPO_TOP_DIRS = qw(
    scripts plugins skills global-config container-config references .claude-plans
);
my $REPO_TOP_RE = join '|', map { quotemeta $_ } @REPO_TOP_DIRS;

# Load the explicit allowlist of backtick contents that LOOK like ccpraxis
# paths but aren't host-side paths (e.g. container-internal paths described
# in prose). One literal per line; '#' begins a comment.
my %ALLOW;
my $ALLOW_FILE = "$Bin/lint-readme-paths.allow";
if (-f $ALLOW_FILE) {
    open my $afh, '<', $ALLOW_FILE or die "Cannot open allowlist $ALLOW_FILE: $!\n";
    while (my $a = <$afh>) {
        chomp $a;
        $a =~ s/\s*#.*$//;       # strip trailing comment
        $a =~ s/^\s+|\s+$//g;    # trim
        next unless length $a;
        $ALLOW{$a} = 1;
    }
    close $afh;
}

# Read README.
open my $fh, '<', $README or do { print STDERR "Cannot open $README: $!\n"; exit 2 };
my @lines = <$fh>;
close $fh;

my $in_fence = 0;
my @findings;  # { line, raw, resolved, exists }

for my $i (0 .. $#lines) {
    my $line = $lines[$i];

    # Toggle fenced-code-block state on ``` (with optional language tag).
    if ($line =~ /^```/) {
        $in_fence = !$in_fence;
        next;
    }
    next if $in_fence;

    # Walk every backtick-quoted span on this line.
    while ($line =~ /`([^`]+)`/g) {
        my $raw = $1;

        next if $ALLOW{$raw};            # explicit sidecar allowlist
        next if $raw =~ /\s/;            # commands, slash-command [arg]
        next if $raw =~ /[<>\[\]\(\)\|\&\;\*\?\$]/;

        # Decide if this looks like a ccpraxis path.
        my $candidate;
        if ($raw =~ m{^~/}) {
            $candidate = $raw;
        } elsif ($raw =~ m{^(?:$REPO_TOP_RE)/}) {
            $candidate = $raw;
        } else {
            next;  # not unambiguously a ccpraxis path
        }

        # Trim trailing punctuation that markdown often leaves attached.
        $candidate =~ s/[.,;:!?]+$//;
        # Trim a trailing slash (so we can check the dir entry directly).
        my $stripped = $candidate;
        $stripped =~ s{/+\z}{};

        # Resolve.
        my $resolved;
        if ($stripped =~ m{^~/(.*)\z}) {
            $resolved = length($1) ? "$HOME/$1" : $HOME;
        } else {
            $resolved = "$REPO_ROOT/$stripped";
        }

        my $exists = (-e $resolved) ? 1 : 0;

        push @findings, {
            line     => $i + 1,
            raw      => $raw,
            resolved => $resolved,
            exists   => $exists,
        };
    }
}

my @missing = grep { !$_->{exists} } @findings;

if (!@missing) {
    printf "lint-readme-paths.pl: OK — %d backticked path(s) all resolve.\n",
        scalar(@findings);
    exit 0;
}

printf STDERR "lint-readme-paths.pl: %d missing path(s) of %d checked:\n\n",
    scalar(@missing), scalar(@findings);

for my $m (@missing) {
    printf STDERR "  README.md:%d  `%s`\n", $m->{line}, $m->{raw};
    printf STDERR "      resolves to: %s\n", $m->{resolved};
    printf STDERR "      (not found)\n\n";
}

print STDERR "Fix: either correct the path in README.md, or — if it's an\n";
print STDERR "intentional placeholder/example — wrap it with <...> markers\n";
print STDERR "so the linter skips it.\n";

exit 1;
