#!/usr/bin/env perl
# platform: any
#
# Oracle for blueprint butler-gate-ergonomics, package 05-bug-path-discoverability.
# Spec: .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/05-bug-path-discoverability-spec.md
#
# Parses global-config/CLAUDE.md (the payload installed to ~/.claude/CLAUDE.md, loaded in every
# session on this machine) from disk and asserts the fix's acceptance criteria. THE FIX DOES NOT
# EXIST YET at the time this file is written; the AC1/AC2/AC4 assertions below are expected to fail
# until plugins/butler/tests/t's companion implementation package adds the pointer.
#
# AC mapping (spec section 3):
#   AC1 -> section "A" below: a pointer naming almanac-bug.pl as the destination for a ccpraxis
#          tooling defect, in the vicinity of "ccpraxis"/"defect"/"bug" language (not a bare
#          coincidental substring match anywhere in the file).
#   AC2 -> section "B" below: the same text (or an adjacent sentence) distinguishes this from a
#          Claude Code product defect, AND no sentence mentioning SendFeedback tells the reader to
#          avoid/suppress/stop using it.
#   AC3 -> this file's own existence and method: it parses the real file from disk rather than
#          asserting against a mock or a description of the file. No separate assertion carries
#          this; A and B already satisfy it by construction.
#   AC4 -> section "C" below: every PRE-EXISTING line survives, unmodified, in its original relative
#          order (an additive-only diff). Implemented via a baseline of per-line MD5 hashes taken
#          from the file's content at the time this test was written (see "Technique" below), rather
#          than embedding the file's own text a second time inside this one (the file contains
#          non-ASCII characters and emoji; re-deriving assertions from a byte-identical copy would
#          make this test an echo of the fixture instead of an independent check, and risks
#          mangling those bytes through this tool's own write path). No prior test in this suite
#          does a whole-file additive-only check (searched: grep -rl additive across the repo's *.t
#          files turned up partial "additive change" mentions in unrelated guard tests, none doing
#          a full before/after file diff), so this is a fresh technique for this package, documented
#          in place rather than borrowed.
#   AC5 -> a documentation/process criterion (the ledger's cause-investigation requirement, already
#          satisfied by the spec's own section 1). No code assertion applies; not tested here.
#
# Technique for C (AC4): a line-hash subsequence check. BASELINE_LINE_HASHES below is the ordered
# list of MD5 hashes of every line in global-config/CLAUDE.md as it existed when this test was
# written (2026-09-22, pre-fix, 102 lines, no mention of almanac-bug/SendFeedback/bug-report
# anywhere -- verified by grep before writing this file). At run time this test re-hashes the
# CURRENT file's lines and asserts BASELINE_LINE_HASHES is a SUBSEQUENCE of the current hash list:
# every baseline line must still appear, in the same relative order, though other lines (the fix's
# insertion) may appear interspersed or appended. This proves the fix is additive-only without ever
# re-embedding the file's actual (non-ASCII-bearing) prose in this source file. A line that is
# edited, reordered relative to its neighbours, or deleted breaks the subsequence and fails C1.
#
# Runs standalone: perl this file

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $CLAUDE_MD = "$REPO_ROOT/global-config/CLAUDE.md";
ok(-f $CLAUDE_MD, 'global-config/CLAUDE.md exists (tracked payload, per project CLAUDE.md)')
    or BAIL_OUT("no such file: $CLAUDE_MD");

sub read_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or BAIL_OUT("cannot open $path: $!");
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

my $raw = read_raw($CLAUDE_MD);

# The installed ~/.claude/CLAUDE.md is built from the shared file plus one
# platform part (GlobalClaudeMd), so the payload as a whole -- what sections B
# and C guard -- is every part, in GlobalClaudeMd::all_part_relpaths() order.
use lib "$Bin/../../../steward/scripts";
use GlobalClaudeMd ();
my $all = join '', map { -f "$REPO_ROOT/$_" ? read_raw("$REPO_ROOT/$_") : '' } GlobalClaudeMd::all_part_relpaths();
ok(length($raw) > 0, 'global-config/CLAUDE.md is non-empty') or BAIL_OUT('empty file, nothing to check');

# ---------------------------------------------------------------------------
# Helper: does a sentence (a run of text bounded by '.', or by start/end of
# string) containing $needle_re also match $context_re within the SAME
# sentence, so a bare substring match anywhere in a 100-line file cannot
# satisfy the criterion by accident?
# ---------------------------------------------------------------------------
sub sentence_matches {
    my ($text, $needle_re, $context_re) = @_;
    # Split on sentence-ish boundaries but keep it simple: a paragraph
    # (blank-line-delimited block) is the unit, since this file's prose runs
    # long single-sentence bullets that may themselves contain periods (e.g.
    # inside inline code or abbreviations like "e.g.").
    for my $para (split /\n{2,}/, $text) {
        next unless $para =~ $needle_re;
        return 1 if $para =~ $context_re;
    }
    return 0;
}

# ===========================================================================
# A. AC1 -- a pointer naming almanac-bug.pl (or the exact invocation shape
#    bug-report/SKILL.md documents) as the destination for a ccpraxis
#    tooling defect.
# ===========================================================================
{
    like($raw, qr/almanac-bug\.pl/,
        'A1: global-config/CLAUDE.md names almanac-bug.pl somewhere')
        or diag('no mention of almanac-bug.pl at all -- the fix has not landed yet');

    ok(sentence_matches($raw, qr/almanac-bug\.pl/, qr/ccpraxis/i),
        'A2: the paragraph naming almanac-bug.pl also mentions ccpraxis (not a coincidental '
      . 'substring match elsewhere in the file)');

    ok(sentence_matches($raw, qr/almanac-bug\.pl/, qr/\b(bug|defect)\b/i),
        'A3: the paragraph naming almanac-bug.pl frames it as the destination for a bug/defect, '
      . 'not an unrelated mention of the script');
}

# ===========================================================================
# B. SUPERSEDED. Package 05's original AC2 required global-config/CLAUDE.md to
#    distinguish a ccpraxis tooling defect from a Claude Code product defect
#    by pointing the latter at SendFeedback, and forbade any language telling
#    the reader to avoid it. Bug 20260922-205201-f421 / operator instruction
#    reversed that: SendFeedback is now denied globally (permissions.deny, in
#    both global-config/settings.json and plugins/sandbox/container/
#    settings.json) and the CLAUDE.md pointer to it was deliberately removed
#    -- a denied tool is not a real destination to route a defect to. This
#    section now asserts the OPPOSITE of the original AC2: no dangling
#    pointer to a channel that no longer exists.
# ===========================================================================
{
    unlike($all, qr/SendFeedback/,
        'B1 (superseded): global-config/CLAUDE.md no longer mentions SendFeedback -- '
      . 'it is denied globally, so no prose should point a reader at it');
}

# ===========================================================================
# C. AC4 -- additive only. Every pre-existing line survives unmodified, in
#    its original relative order. See "Technique" in the file header.
# ===========================================================================
{
    # Baseline: ordered MD5 hashes of every line of the global payload --
    # global-config/CLAUDE.md, then CLAUDE.macos.md, then CLAUDE.windows.md
    # (GlobalClaudeMd::all_part_relpaths order) -- as of 2026-10-30, when the
    # payload was split per platform on the operator's instruction ("ccpraxis
    # should put into the live machinery only the relevant parts"): promote
    # now builds ~/.claude/CLAUDE.md from the shared file plus this host's
    # part, so the "## Host platform" selection rule was dropped, the Glob
    # non-ASCII-path rule moved into the Windows part, and the python house
    # rule lost its host names. The 2026-10-29 floor (149 lines) had been
    # regenerated during an unattended run for the platform-sections layout
    # this split replaces; the one before it (2026-09-22, 103 lines) followed
    # the operator-instructed SendFeedback removal (section B above, bug
    # 20260922-205201-f421). This IS the floor additive-only checks against,
    # not a historical snapshot. 146 lines.
    my @BASELINE_LINE_HASHES = (
        '39dbf6c7953b868bed9faa8584f53aa8',
        'd41d8cd98f00b204e9800998ecf8427e',
        '16ae688fb52f0a493c59e6ac00a165a0',
        'd41d8cd98f00b204e9800998ecf8427e',
        '9b49f1f3b736bb77b12449df35651000',
        'd41d8cd98f00b204e9800998ecf8427e',
        'f544c4f9cae93927a60e49c4cb020e66',
        '9c2ec4c315271ef50d60a8108c5013ce',
        'd41d8cd98f00b204e9800998ecf8427e',
        '22a71ec5e8321ec16190cc76bae6a58b',
        'd41d8cd98f00b204e9800998ecf8427e',
        'f95cdefa621195db8ab58b063845b522',
        'd41d8cd98f00b204e9800998ecf8427e',
        'ad79d37c2f3987734918e057945a7356',
        'd41d8cd98f00b204e9800998ecf8427e',
        'c3c9d7ed3685dd18ba038fe29f21c4db',
        '71a9ec0eff5b2d2b88c2095dff18464f',
        'eab874c2e736192f1d833b230156cf2f',
        'd41d8cd98f00b204e9800998ecf8427e',
        'fa9d197f74bc48c847dc70b5d7bfa460',
        'd41d8cd98f00b204e9800998ecf8427e',
        '6795c68c1697bfba5413dee42d4b4973',
        'd41d8cd98f00b204e9800998ecf8427e',
        '65ac19f4fbf85918ab695cf5747a1e47',
        'e61888658e1b228a89ffd7267657b76e',
        '8ab8189ea04d3204c47d7ed9cfd7c2a7',
        '0897df65d2242b4013ab48d1820786af',
        'cc197e05b96fa328958f898cd558e438',
        '2a564dc64e2518a0b3eaa9429e44c6f5',
        'd41d8cd98f00b204e9800998ecf8427e',
        '0e9e24723f07977060690e5341ed0262',
        'd41d8cd98f00b204e9800998ecf8427e',
        '707e228d58961bd5612e32f47f81c820',
        'd41d8cd98f00b204e9800998ecf8427e',
        '3350b37fc0674ecf914b82bbf8c09f94',
        'd41d8cd98f00b204e9800998ecf8427e',
        '5f35a6b57dc01953c216143005077495',
        'd41d8cd98f00b204e9800998ecf8427e',
        'b775238d005a6e5ad88c677a18bd91d6',
        '113485088cd95f98b7f152df317d1c7c',
        '0e28a87a7c1e2ace9d012e97c057ee16',
        '55ef4bf5f0d04b943d333f2ffe6a837a',
        'b4159efd6a1d3983495c8244d19e2f31',
        '5d30f0dbefec0be27834152bc6a31d10',
        'd41d8cd98f00b204e9800998ecf8427e',
        '5c6ed9e30722e93e2869038c2200fdda',
        'd41d8cd98f00b204e9800998ecf8427e',
        '9ad29bc1f1e0d4cfcfd8cebd1f8847a5',
        'd41d8cd98f00b204e9800998ecf8427e',
        'f308dd2246aa7eacf1578367780ac599',
        'd41d8cd98f00b204e9800998ecf8427e',
        '4d7bd8cf93e1fe8c2ec85445c23aea7f',
        'f307e14c551211ac5cbeb6291fe0bddc',
        'fefa5157557d4db2b1cb804816bff7f2',
        'cc75f53c0fd38792c202d95dc8c990f8',
        '3b9c948e8537fc4b187df288455c639c',
        'dd2b958d654b3a3dbd02ea8243e1333b',
        'd41d8cd98f00b204e9800998ecf8427e',
        '42bf0e8cd444fa78383caf4bff18cfba',
        'd41d8cd98f00b204e9800998ecf8427e',
        'e01ee21e179274a7fdad9080c433565b',
        'd41d8cd98f00b204e9800998ecf8427e',
        'cefaa52865fd0c6942580de7cfa4952d',
        'd41d8cd98f00b204e9800998ecf8427e',
        '62da7702a48084a3482ead4e2510fc01',
        'd41d8cd98f00b204e9800998ecf8427e',
        'bea1f6e5836460d48afa9ba45c074ae6',
        'd41d8cd98f00b204e9800998ecf8427e',
        'ad7e3ed279653ffb42a7965db303c7d0',
        'd41d8cd98f00b204e9800998ecf8427e',
        '0c7b0b1538d13a734e5553195269ae15',
        'd41d8cd98f00b204e9800998ecf8427e',
        'c033b17b8e4215336ce603f595d3c80e',
        'a37cdee939e47d363e4ff5d0feabd2f7',
        'd41d8cd98f00b204e9800998ecf8427e',
        'd41a010f6f00405202e74637f2e8b4af',
        '8c1e8526a8755b42df35561f8c75766e',
        '20f04fcb322afef6f33d21d3f6ea5487',
        'd0421f842d5c47aadcd61567d60f121e',
        '21475491bb80442b8e1898a9b656be61',
        '87bf35d4769a4d66e3a6fafa92764845',
        '9cec9540823250b67625027216d6597f',
        'f47f86b0d1909d5fdb9d9ecaddbb9936',
        '37c30bc1c22a55a004d6213c0af98a5e',
        'aaa9e793f53bcd08b2674602414d7953',
        '640bcf0eba4bf0be54e1dfab20f81303',
        'd41d8cd98f00b204e9800998ecf8427e',
        '14601e3e7b83516dc68e1dcb425b27c0',
        'd41d8cd98f00b204e9800998ecf8427e',
        '756eaf050da93158d068e45cfab8a614',
        'd41d8cd98f00b204e9800998ecf8427e',
        'bce35cf9e065541867c4b08e02af5da4',
        'd41d8cd98f00b204e9800998ecf8427e',
        '4406441c9717f82a8d07fa40f004432f',
        'd41d8cd98f00b204e9800998ecf8427e',
        '12a0c8bba47bba0020ac4dccc3cdc907',
        'd41d8cd98f00b204e9800998ecf8427e',
        'c620060a032ac4277a86bcffa0ed6a9f',
        'd41d8cd98f00b204e9800998ecf8427e',
        '99977daad8b4bd9b5b5bef92584ef4f2',
        'd41d8cd98f00b204e9800998ecf8427e',
        'a8b76dc77ce2e831797ff39d2a33a028',
        'd41d8cd98f00b204e9800998ecf8427e',
        '4a57b909cc7d6414e0e416f2b5ab9fb0',
        'd41d8cd98f00b204e9800998ecf8427e',
        'dfa1786988e8348ca648e7ad7244d8dd',
        'd41d8cd98f00b204e9800998ecf8427e',
        '31bdbb4273fd3c747ee77c61783c0966',
        '0db3aa88b017c50d886d2f760609ce91',
        'a74b33444fc7099fc61d32737f69bfb3',
        'd41d8cd98f00b204e9800998ecf8427e',
        '4dbd2a8ac13ec5d26eeca714728ae593',
        'd41d8cd98f00b204e9800998ecf8427e',
        'c5c5dfcbab632fcc3feb8a1877ccbec3',
        '92a068f6949ca1645a5587d792762140',
        'dc33f39f6d1726973535958646b49a6c',
        'e6244b07c53de0bbc364072d23c80c4c',
        '5c7234bc18312f50b93bf07f8e20de88',
        'da2b4ffb8c531762b17603bde70c1245',
        'd41d8cd98f00b204e9800998ecf8427e',
        'ca539df2ad22f286455dac06c375274b',
        'd41d8cd98f00b204e9800998ecf8427e',
        '3e626c5329f3e13934176a4aac9c6cff',
        '87e21bb95a062534f5e79c35b9081762',
        '10bc9031cada64a97f0c336badafcc60',
        'd41d8cd98f00b204e9800998ecf8427e',
        'b2118a5aace38d2c0a133095d2207ed2',
        'd41d8cd98f00b204e9800998ecf8427e',
        'da6ed318e24c41497cced69edc83f2f7',
        'd41d8cd98f00b204e9800998ecf8427e',
        '2bbc4f319111323aba9f3008fc6674c4',
        'd41d8cd98f00b204e9800998ecf8427e',
        '1c8f508bb65d149f05af03fdcc47cbbc',
        'd41d8cd98f00b204e9800998ecf8427e',
        'b439c1dcc51965aaa12b26a3bc4ec002',
        'd41d8cd98f00b204e9800998ecf8427e',
        'b5aefdcba3f3921ee1c4c9a02c58eecb',
        'd41d8cd98f00b204e9800998ecf8427e',
        '6e01962e0fb8e6c8c50a3d15f3c526cc',
        'd41d8cd98f00b204e9800998ecf8427e',
        'bf3db15e652b491f4b4fbb2017ebaf3c',
        'd41d8cd98f00b204e9800998ecf8427e',
        '4d6552e99a760c88a6e33cb9770d237b',
        'c25754e0c6c5e180f9c8bb0b6ef50cb4',
        'e4c45f96d1a4aacdbe6c5deb0760c009',
        'b81a80ad04ee375504da3b8d523d7ce3',
    );

    is(scalar(@BASELINE_LINE_HASHES), 146,
        'C0: baseline itself carries the expected 146 lines (sanity check on this test, not the fixture)');

    # Re-hash the CURRENT file's lines the same way the baseline was produced:
    # split on \n, strip a trailing \r (tolerate either line-ending style),
    # md5 each line's text.
    my @current_lines = split /\n/, $all, -1;
    pop @current_lines if @current_lines && $current_lines[-1] eq '';
    my @current_hashes = map { my $l = $_; $l =~ s/\r\z//; md5_hex($l) } @current_lines;

    ok(scalar(@current_hashes) >= scalar(@BASELINE_LINE_HASHES),
        'C1: the current payload has at least as many lines as the baseline (additive, never shrinks)')
        or diag(sprintf('current=%d baseline=%d', scalar(@current_hashes), scalar(@BASELINE_LINE_HASHES)));

    # Subsequence check: every baseline hash must appear in current_hashes,
    # in the same relative order (other lines may be interspersed).
    my $bi = 0;
    my $first_missing_baseline_index;
    for my $ci (0 .. $#current_hashes) {
        last if $bi > $#BASELINE_LINE_HASHES;
        $bi++ if $current_hashes[$ci] eq $BASELINE_LINE_HASHES[$bi];
    }
    $first_missing_baseline_index = $bi if $bi <= $#BASELINE_LINE_HASHES;

    ok(!defined($first_missing_baseline_index),
        'C2: every pre-existing line (baseline, 146 lines) is still present in the current file, '
      . 'in its original relative order -- an additive-only diff')
        or diag(defined($first_missing_baseline_index)
            ? "first baseline line not found as a subsequence element: baseline index $first_missing_baseline_index "
            . "(hash $BASELINE_LINE_HASHES[$first_missing_baseline_index]) -- a pre-existing line was "
            . "edited, reordered, or removed"
            : 'unexpected: no missing index computed');
}

done_testing();
