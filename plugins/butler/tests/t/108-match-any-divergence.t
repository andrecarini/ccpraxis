#!/usr/bin/env perl
# t/108-match-any-divergence.t — a02-api-and-guard-defects, drift guard.
#
# match_any is defined TWICE:
#   plugins/butler/hooks/lib.sh      — the copy guard-writes.sh actually sources
#   plugins/butler/scripts/bp-lib.sh — the copy the bp-*.pl tooling sources
#
# The bodies are byte-identical today, so this file is GREEN on arrival. It is
# not pinning a defect; it is pinning the ABSENCE of one. match_any decides
# whether a path is inside a write set or is "a test", which makes it a
# security-relevant path matcher — and a duplicated security-relevant matcher
# with no drift guard is a defect waiting for the first divergent edit. If one
# copy gains a fix (say, specificity ranking) and the other does not, the hook
# and the tooling silently disagree about what is in scope, and nothing tells
# anyone.
#
# WHY BODY-COMPARISON AND NOT BEHAVIOUR-COMPARISON. A behavioural test would
# have to enumerate inputs, and the divergence that matters is precisely the
# input nobody thought to enumerate. Comparing the extracted function bodies
# catches every divergence, including the one the test author did not imagine.
#
# This test does NOT demand the duplication be removed. Collapsing the two into
# one shared file is a real option, but hooks/lib.sh is out of a02's write set,
# and a hook that sources a script-tree file is its own coupling decision. The
# test states the invariant; how it is satisfied is left open.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

(my $ROOT = "$Bin/../../..") =~ s{\\}{/}g;
my $HOOKS_LIB   = "$ROOT/butler/hooks/lib.sh";
my $SCRIPTS_LIB = "$ROOT/butler/scripts/bp-lib.sh";

# $Bin is plugins/butler/tests/t, so ../../.. is plugins/. Fall back to a
# repo-root layout if this file is ever run from a differently-nested copy.
unless (-f $HOOKS_LIB && -f $SCRIPTS_LIB) {
    (my $alt = "$Bin/../..") =~ s{\\}{/}g;
    $HOOKS_LIB   = "$alt/hooks/lib.sh";
    $SCRIPTS_LIB = "$alt/scripts/bp-lib.sh";
}

ok(-f $HOOKS_LIB,   "hooks/lib.sh exists at $HOOKS_LIB")
    or BAIL_OUT("cannot locate hooks/lib.sh — this test cannot verify anything");
ok(-f $SCRIPTS_LIB, "scripts/bp-lib.sh exists at $SCRIPTS_LIB")
    or BAIL_OUT("cannot locate scripts/bp-lib.sh — this test cannot verify anything");

# extract_match_any FILE -> normalized body text (or undef)
#
# Takes from the `match_any() {` line to the matching closing brace at column 0.
# Both copies are written in that flat style; if either is ever reindented so
# its terminator is not at column 0, this returns undef and the test fails
# LOUDLY rather than silently comparing two empty strings.
sub extract_match_any {
    my ($path) = @_;
    open my $fh, '<', $path or die "open $path: $!";
    my @body;
    my $in = 0;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        if (!$in) {
            $in = 1 if $line =~ /^match_any\(\)\s*\{/;
            next if $in;   # don't include the signature line itself
        } else {
            last if $line =~ /^\}/;
            push @body, $line;
        }
    }
    close $fh;
    return undef unless $in && @body;
    return join "\n", @body;
}

my $hooks_body   = extract_match_any($HOOKS_LIB);
my $scripts_body = extract_match_any($SCRIPTS_LIB);

ok(defined $hooks_body && length $hooks_body,
   'match_any() body extracted from hooks/lib.sh')
    or diag("extraction failed — was match_any renamed, removed, or reindented "
          . "so its closing brace is no longer at column 0?");

ok(defined $scripts_body && length $scripts_body,
   'match_any() body extracted from scripts/bp-lib.sh')
    or diag("extraction failed — was match_any renamed, removed, or reindented "
          . "so its closing brace is no longer at column 0?");

SKIP: {
    skip 'one or both bodies could not be extracted', 2
        unless defined $hooks_body && defined $scripts_body;

    # Guard against a vacuous pass: a matcher body this short is not the real
    # implementation, and comparing two stubs would prove nothing.
    cmp_ok(scalar(split /\n/, $hooks_body), '>=', 8,
           'extracted body is substantial enough to be the real implementation');

    is($scripts_body, $hooks_body,
       'match_any is byte-identical in hooks/lib.sh and scripts/bp-lib.sh')
        or diag(<<"EOD");
match_any has DIVERGED between its two definitions.

  hooks/lib.sh      <- sourced by guard-writes.sh (the enforcement path)
  scripts/bp-lib.sh <- sourced by the bp-*.pl tooling

This matters because match_any decides write-set membership and test-path
classification. Two copies that disagree mean the hook and the tooling disagree
about what is in scope, with no symptom until something is wrongly allowed or
wrongly denied.

Fix by making the change in BOTH copies, or by collapsing them into one shared
definition. Do NOT satisfy this test by relaxing it.

--- hooks/lib.sh ---
$hooks_body
--- scripts/bp-lib.sh ---
$scripts_body
EOD
}

done_testing();
