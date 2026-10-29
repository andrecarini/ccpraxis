#!/usr/bin/env perl
# lint-msys2-guard.pl — defense-in-depth lint for the MSYS2 path-conversion
# bug (see global-config/CLAUDE.md "MSYS2 path-conversion mangles `:`-separated
# args"). Walks every .pl in the repo, finds files that invoke podman
# natively (system/exec/backticks), and asserts each one sets
# $ENV{MSYS2_ARG_CONV_EXCL}='*' near the top.
#
# Why: the perl-side guard in launcher.pl + bootstrap.pl is the actual fix,
# the .sh/.ps1 shims export the env var as a belt-and-suspenders, and the
# runtime `;C`-corruption detector in launcher.pl catches escaped cases at
# podman-create time. This lint is the FOURTH layer — it catches a NEW perl
# script that introduces a podman call without the guard, BEFORE that script
# ever runs and silently corrupts someone's project.
#
# Note: the pattern matchers below still scan for `docker` invocations too —
# even though ccpraxis no longer uses Docker, that's defensive coverage for
# any future third-party plugin that contributes a docker-calling script.
#
# Exit codes: 0 = all matching files have the guard, 1 = one or more
# missing.
#
# Usage:
#   perl scripts/lint-msys2-guard.pl
# Intended to run as a pre-flight in /backup and any other "before commit"
# context. Safe to run on Linux/macOS too — the lint doesn't depend on
# being on Windows, it just enforces the cross-platform-correct pattern.

use strict;
use warnings;
use FindBin qw($Bin);
use File::Find;
use File::Spec;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $REPO_ROOT = File::Spec->rel2abs("$Bin/..");
my $SELF      = File::Spec->rel2abs(__FILE__);

# Loose-on-purpose regexes for "this file invokes docker or podman natively".
# We'd rather false-positive (a comment that quotes a docker invocation) and
# get a redundant guard than false-negative and ship corruption. If a real
# false positive becomes annoying, add an inline `# msys2-guard-not-required`
# marker and extend the lint to honor it.
my @DOCKER_PATTERNS = (
    qr/system\s*\(\s*['"](?:docker|podman)(?:\.exe)?['"]\s*,/,
    qr/system\s*\(\s*\$(?:DOCKER|PODMAN)\b/,
    qr/exec\s*\(\s*['"](?:docker|podman)(?:\.exe)?['"]\s*,/,
    qr/exec\s*\(\s*\$(?:DOCKER|PODMAN)\b/,
    qr/`\s*\$(?:DOCKER|PODMAN)\b/,
    qr/`\s*(?:docker|podman)(?:\.exe)?\b/,
    qr/qx[\(\{\[\<\/]\s*\$(?:DOCKER|PODMAN)\b/,
    qr/qx[\(\{\[\<\/]\s*(?:docker|podman)(?:\.exe)?\b/,
);

my $GUARD_PATTERN = qr/MSYS2_ARG_CONV_EXCL/;

my @issues;

find(
    {
        wanted => sub {
            return unless -f $_;
            return unless /\.pl$/;
            my $abs = File::Spec->rel2abs($File::Find::name);
            return if $abs eq $SELF;
            check_file($File::Find::name);
        },
        no_chdir => 1,
    },
    $REPO_ROOT,
);

sub check_file {
    my $path = shift;
    open my $fh, '<:raw', $path or return;
    my $content = do { local $/; <$fh> };
    close $fh;

    # Strip line comments + pod blocks before pattern matching, so a comment
    # like `# example: system('docker', ...)` doesn't trip the lint. Cheap
    # approximation — doesn't try to parse string literals, just kills `#...`
    # to end of line and `=pod`/`=cut` blocks.
    my $scannable = $content;
    $scannable =~ s/^=\w[\s\S]*?^=cut\s*$//gm;
    $scannable =~ s/(?<!\$)#.*$//gm;

    my $hit_pat;
    my $hit_line;
    for my $pat (@DOCKER_PATTERNS) {
        if ($scannable =~ $pat) {
            $hit_pat = $pat;
            # Find the line number of the match in the *original* content.
            my $prematch = substr($scannable, 0, $-[0]);
            $hit_line = ($prematch =~ tr/\n//) + 1;
            last;
        }
    }
    return unless defined $hit_pat;

    return if $content =~ $GUARD_PATTERN;

    push @issues, {
        path => $path,
        line => $hit_line,
    };
}

if (!@issues) {
    print "lint-msys2-guard.pl: OK — every .pl file invoking podman/docker has the MSYS2_ARG_CONV_EXCL guard.\n";
    exit 0;
}

my $n = scalar @issues;
print STDERR "lint-msys2-guard.pl: $n file(s) invoke podman/docker natively but DON'T set MSYS2_ARG_CONV_EXCL:\n\n";
for my $issue (@issues) {
    my $rel = File::Spec->abs2rel($issue->{path}, $REPO_ROOT);
    $rel =~ s|\\|/|g;
    print STDERR "  $rel:$issue->{line}\n";
}
print STDERR "\nFix: add this near the top of each flagged file (after `use strict; use warnings;`):\n\n";
print STDERR "    # Disable MSYS2 argv path conversion on Windows — otherwise podman -v\n";
print STDERR "    # HOST:CONTAINER mount specs get split on `:` and re-joined with `;`,\n";
print STDERR "    # silently corrupting bind mounts. See global-config/CLAUDE.md.\n";
print STDERR "    \$ENV{MSYS2_ARG_CONV_EXCL} = '*' if \$^O =~ /^(MSWin32|cygwin|msys)\$/;\n\n";
print STDERR "Background: global-config/CLAUDE.md \"MSYS2 path-conversion mangles `:`-separated args\".\n";

exit 1;
