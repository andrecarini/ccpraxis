#!/usr/bin/env perl
# 123-h01-prose-qualifiers.t — oracle for done criterion 5 (h01 spec §2.6/§2.7,
# AC5): the prose is fixed too, as the EXPLANATION, not the mechanism.
#
# THE CONTRADICTION THIS PINS. coordinator-protocol/SKILL.md tells agents, in
# the instruction sentence itself ("The pattern: launch in the background, end
# the turn, resume on the notification..."), to background-and-end-turn — with
# NO qualifier in that sentence, even though a scoping blockquote already sits
# six lines above it ("This section is for MULTI-TURN sessions only"). A
# reader who quotes or excerpts the instruction sentence out of context (as a
# harvest judge effectively did) recovers the unqualified, wrong instruction.
# §2.6's contract is explicit: the qualifier must be IN the instruction
# sentence, not only in the blockquote above it — so this test extracts ONLY
# that sentence/paragraph and asserts against it, never the whole file (a
# whole-file scan would pass today already, vacuously, because the blockquote
# already exists).
#
# Eight agent files (§2.7) get the same qualification added to their own
# `## Hard limits` section — confirmed absent in ALL eight today (grepped
# fresh: no file mentions background/foreground/run_in_background anywhere).
#
# Runs standalone: perl plugins/butler/tests/t/123-h01-prose-qualifiers.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $SKILL = "$Bin/../../skills/coordinator-protocol/SKILL.md";
my $AGENTS_DIR = "$Bin/../../agents";

ok(-f $SKILL, 'coordinator-protocol/SKILL.md exists') or BAIL_OUT('skill file missing');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ===========================================================================
# A. THE INSTRUCTION SENTENCE ITSELF, not the file as a whole.
#    Extract the paragraph starting at "**The pattern:" up to the next blank
#    line (paragraph boundary) -- this isolates exactly the sentence §2.6
#    names, excluding the blockquote six lines above it.
# ===========================================================================
{
    my $skill = slurp($SKILL);
    ok(defined $skill && length $skill, 'A0: SKILL.md is readable');

    my ($para) = $skill =~ /(\*\*The pattern:.*?)\n\n/s;
    ok(defined $para && length $para,
       'A1: the "The pattern:" paragraph can be located in SKILL.md '
     . '(if this fails, the paragraph text itself has changed -- re-locate before trusting A2+)');

    # Sanity check: confirm we captured the RIGHT paragraph (it must still
    # carry run_in_background / end your turn), not some other span --
    # otherwise A3 could pass or fail for the wrong reason entirely.
    SKIP: {
        skip 'could not locate paragraph', 2 unless defined $para;
        like($para, qr/run_in_background/,
             'A2: sanity — the extracted paragraph is the backgrounding instruction '
           . '(confirms the regex captured the right span before A3 is trusted)');

        like($para, qr/multi-turn|coordinator|driver/i,
             'A3: the instruction sentence ITSELF now carries the multi-turn-only '
           . 'qualifier -- not only the blockquote six lines above it. A reader who '
           . 'quotes only this sentence must not recover the unqualified original.')
            or diag('today this paragraph carries NO such qualifier at all -- only the '
                  . 'blockquote above it does, which is precisely the defect §2.6 names');
    }
}

# ===========================================================================
# B. The blockquote above it is UNTOUCHED (§2.6: "No other line in this
#    section needs to change"). Regression guard against an implementation
#    that deletes the blockquote while adding the sentence-level qualifier.
# ===========================================================================
{
    my $skill = slurp($SKILL);
    like($skill, qr/MULTI-TURN sessions only/,
         'B1: the existing scoping blockquote survives unchanged');
    like($skill, qr/Foreground is the documented default for validation/,
         'B2: the existing foreground-for-validation paragraph survives unchanged');
}

# ===========================================================================
# C. Eight agent files each get the qualification in their own
#    "## Hard limits" section (§2.7). Testable, case-insensitive content:
#    the literal string run_in_background, and the word foreground.
# ===========================================================================
my @AGENTS = qw(
    bp-harvest-judge bp-implementer bp-test-writer bp-ui-prober
    bp-reviewer bp-redteam bp-resolve-judge bp-conformance-judge
);

for my $name (@AGENTS) {
    my $path = "$AGENTS_DIR/$name.md";
  SKIP: {
        ok(-f $path, "$name.md exists") or skip("$name.md missing", 4);
        my $content = slurp($path);
        ok(defined $content && length $content, "$name.md is readable")
            or skip("$name.md unreadable", 3);

        my ($section) = $content =~ /(##\s*Hard limits.*)\z/s;
        $section //= '';
        ok(length($section), "$name.md has a ## Hard limits section")
            or diag('the spec targets this heading explicitly; if it is missing/renamed, '
                  . 'the contract has no home');

        like($section, qr/run_in_background/i,
             "$name.md's Hard limits section mentions run_in_background "
           . "(currently absent -- confirmed by fresh grep before writing this oracle)");
        like($section, qr/foreground/i,
             "$name.md's Hard limits section mentions foreground");
    }
}

done_testing();
