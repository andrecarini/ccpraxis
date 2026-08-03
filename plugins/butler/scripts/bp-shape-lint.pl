#!/usr/bin/env perl
# bp-shape-lint.pl — flag oracle assertions that pin the WHOLE SHAPE of a
# shared artifact, rather than the package's own contribution.
#
# WHY
#
# Six times in one blueprint an assertion froze a total over something other
# packages must be able to extend, and each time a later package doing exactly
# what it was mandated to do turned a done sibling red:
#
#   * t/25  pinned coordinator-protocol/SKILL.md at exactly 12 '## ' headings,
#           forcing b14 and b20 to demote their sections to '###'.
#   * FOUR oracles pinned launcher.pl's literal 10-second poll cadence, which
#           s17 was REQUIRED to replace with a named constant.
#   * t/56  froze container/settings.json's entire key set, which s17 was
#           REQUIRED to add a key to.
#   * t/87  pinned "exactly 57 ledgers cite a SYN- decision" — which broke on
#           ordinary ledger prose citing SYN-21, having already been corrected
#           once from 32.
#
# The standing rule is: assert YOUR package's contribution, never the whole
# tree's shape, because the latter forbids every later package from extending
# it. t/64's AC-36 shows the fix — `cmp_ok(scalar(@$pre), '>=', 4)` with a
# comment recording the old `is(..., 4)`.
#
# WHAT THIS IS NOT
#
# Not a correctness checker, and deliberately not silent-clean. Per-fixture
# counts on locally-built data ("exactly one relaunch", "exactly one needs-you
# file") are correct and must NOT be flagged; the whole skill is telling those
# apart from corpus pins. So this reports CANDIDATES with the evidence that
# made each suspicious, and a human decides. It fails loudly rather than
# pretending precision it does not have.
#
# Usage:
#   bp-shape-lint.pl <test-file-or-dir>...
# Exit: 0 = no candidates, 1 = candidates found (report on stdout), 2 = usage.

use strict;
use warnings;

@ARGV or do { print STDERR "usage: bp-shape-lint.pl <file-or-dir>...\n"; exit 2 };

my @files;
for my $arg (@ARGV) {
    if (-d $arg) {
        opendir(my $dh, $arg) or next;
        push @files, map { "$arg/$_" } sort grep { /\.t$/ } readdir($dh);
        closedir $dh;
    } elsif (-f $arg) {
        push @files, $arg;
    }
}

# Words that suggest the counted thing is a SHARED artifact rather than a
# fixture the test just built. Tuned against the six known real cases.
# Nouns naming a SHARED, extensible artifact. Deliberately narrow: an earlier
# draft also matched "package" and "entry" and produced 47 candidates, most of
# them legitimate per-fixture event counts. Precision matters more than recall
# here, because a noisy lint is one nobody runs.
my $SHARED = qr/heading|section|key\s+(?:path|set)|glyph\s*table|citing|corpus|SKILL\.md|settings\.json/xi;

# Words that mark a count as local scaffolding, suppressing the flag.
my $LOCAL  = qr/FIXTURE|fixture|sanity|synthetic|scaffold/;

# Verbs describing a RUNTIME EVENT count — "exactly one relaunch", "three
# packages were attempted". Those are a package asserting its own behaviour on
# data it built, which is correct and must never be flagged.
my $EVENTY = qr/attempt|launch|relaunch|call|spawn|file[ds]?\b|queue|emit|render|write|remove|add(?:ed)?|create|consume|refresh|tick|retry/i;

my @hits;

for my $file (@files) {
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        next if $line =~ /^\s*#/;                       # comment
        my $ctx = join('', @lines[ $i .. ($i + 1 > $#lines ? $#lines : $i + 1) ]);

        # (a) a count pinned with `is(..., N)` where N > 2
        if ($ctx =~ /\bis\s*\(\s*scalar[^,]*,\s*(\d+)\s*,\s*(['"])(.*?)\2/s) {
            my ($n, $desc) = ($1, $3);
            next if $n <= 2;                            # 0/1/2 are almost always local
            next if $desc =~ $LOCAL;
            next if $desc =~ $EVENTY;

            push @hits, [$file, $i + 1, "count pinned at $n", $desc]
                if $desc =~ $SHARED;
        }

        # (b) a bare scalar pinned with `is($some_count, N)` where the name
        #     itself says it counts a shared thing
        if ($ctx =~ /\bis\s*\(\s*\$(\w*(?:count|total|headings|keys)\w*)\s*,\s*(\d+)\s*,\s*(['"])(.*?)\3/si) {
            my ($var, $n, $desc) = ($1, $2, $4);
            next if $n <= 2 || $desc =~ $LOCAL || $desc =~ $EVENTY;
            push @hits, [$file, $i + 1, "count pinned at $n (\$$var)", $desc] if $desc =~ $SHARED;
        }

        # (c) a magic integer inside a regex that also names a source-file
        #     identifier — the shape that pinned launcher.pl's poll cadence.
        if ($line =~ /qr\{?\/?[^\n]*\$(\w+)\\s\*>=\\s\*(\d+)/) {
            my ($var, $val) = ($1, $2);
            # NOT a pin when the assertion is that the literal is GONE — an
            # `unlike` here is the CORRECT shape (t/54's C8 asserts the old
            # bare 10 no longer appears), and flagging it would tell people to
            # undo the very fix this lint exists to encourage.
            next if $ctx =~ /\b(?:src_)?unlike\s*\(/;
            # NOT a pin when the value is a guard threshold rather than a
            # tunable: `$hs >= 1` is real logic, not a frozen constant.
            next if $val <= 2;
            push @hits, [$file, $i + 1, "literal value $val pinned against \$$var",
                          "a tunable constant frozen as a literal in a pattern"];
        }
    }
}

my %seen; @hits = grep { !$seen{"$$_[0]|$$_[3]"}++ } @hits;
if (!@hits) { print "bp-shape-lint: no shared-shape candidates found.\n"; exit 0 }

print "bp-shape-lint: " . scalar(@hits) . " candidate(s). Each is a SUGGESTION —\n";
print "a count over a fixture this test built is fine; a count over a shared\n";
print "artifact forbids later packages from extending it. Retarget those to the\n";
print "package's own contribution, or to a floor (see t/64 AC-36).\n\n";
for my $h (@hits) {
    my ($file, $line, $what, $desc) = @$h;
    $desc =~ s/\s+/ /g;
    $desc = substr($desc, 0, 96);
    printf "  %s:%d\n      %s\n      %s\n", $file, $line, $what, $desc;
}
exit 1;
