#!/usr/bin/env perl
# 180 — NOTHING IS BUILT BEFORE THE OPERATOR HAS ANSWERED, and a version
# mismatch is not a question.
#
# WHY THIS EXISTS. Reported 2026-09-07: "I got to the screen where I choose the
# plugins skills etc. Then after a while I got the r vs c to rebuild vs
# continue dialog. It didn't make sense to me because some things were already
# being built before that step? and then things kept getting built?"
#
# All three observations were accurate:
#
#   The base image was built at the top of the launch, before the picker and
#   before the prompt. So minutes of building preceded the question about
#   whether to build.
#
#   Choosing Rebuild then force-built the image AGAIN, so a launch that began
#   with no image could build it twice with nothing able to change in between.
#
#   The prompt offered "Continue as-is — rebuild nothing" unconditionally,
#   including when there was no image to continue from — where continuing would
#   reach `podman create` against a nonexistent image.
#
# A fourth came from the operator afterwards: a container on a different Claude
# Code version than the host is not a configuration to be offered, because
# claude-home is shared through the bind mount and assumes one version wrote
# it. It is forced, following the B18 precedent rather than the prompt — that
# prompt defaults to "continue" AND returns "continue" on EOF, so anything
# routed through it is silently declinable in every headless launch.
#
# These are STRUCTURAL assertions over launcher.pl. The launcher is never
# executed here: doing so builds images and starts containers, which this repo
# forbids in tests and which would take minutes per case.
#
# AC1  no build call precedes the rebuild prompt
# AC2  exactly one build call remains on the decision path
# AC3  the build is reached only via "missing OR rebuild chosen"
# AC4  a version mismatch sets a forced flag and never enters @STALE_REASONS
# AC5  the prompt is passed what exists, and labels itself from it
# AC6  an absent hash record is not reported as drift
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $SRC = do {
    my $p = "$Bin/../../scripts/launcher.pl";
    open my $fh, '<:raw', $p or do { plan skip_all => "cannot read $p" };
    local $/;
    my $c = <$fh>;
    close $fh;
    $c;
};
ok(length $SRC, 'precondition: launcher.pl is readable');

# Comments name these constructs while explaining them, so a scan that counted
# comment lines would fail on the documentation of the fix — the exact failure
# t/66 had to correct once already.
my $CODE = $SRC;
$CODE =~ s/^[ \t]*#[^\n]*$//mg;

sub pos_of { my ($re) = @_; return ($CODE =~ /$re/) ? $-[0] : -1 }

# ---------------------------------------------------------------------------
# AC1 / AC2 — the build calls and where they sit.
# ---------------------------------------------------------------------------
my @build_at;
{
    my $p = 0;
    while ($CODE =~ /\bbuild_image\s*\(\s*\)/g) { push @build_at, $-[0] }
}
is(scalar @build_at, 1,
   'AC2 exactly one build_image() call remains on the launch path')
    or diag('  found ' . scalar(@build_at) . '; the second one was the double build: '
          . 'missing-image built once, then Rebuild built it again');

my $prompt_at = pos_of(qr/prompt_stale_action\s*\(/);
cmp_ok($prompt_at, '>', 0, 'AC1 liveness: the rebuild prompt call was located');

SKIP: {
    skip 'no build call found', 1 unless @build_at;
    cmp_ok($build_at[0], '>', $prompt_at,
        'AC1 the build happens AFTER the rebuild prompt, not before it')
        or diag('  a build before the prompt is minutes of work preceding the '
              . 'question about whether to do it');
}

# The probe that replaced the eager build must NOT build. It records existence.
like($CODE, qr/\$IMAGE_EXISTS\s*=\s*\(\s*\$\?\s*==\s*0\s*\)/,
     'AC1 the early image check only records existence');

# ---------------------------------------------------------------------------
# AC3 — the build is guarded by "missing OR rebuild", so it cannot run twice
# and cannot be skipped when the image is genuinely absent.
# ---------------------------------------------------------------------------
like($CODE, qr/\$need_build\s*=\s*\(\s*!\s*\$IMAGE_EXISTS\s*\|\|\s*\$do_rebuild\s*\)/,
     'AC3 the build condition is "image missing OR rebuild chosen"')
    or diag('  both conditions must collapse into ONE call, or the two-build bug returns');

# Continuing with a missing image must still build. Asserted as the absence of
# an early-exit: the build block is not inside the `if ($do_rebuild)` body.
{
    my $rebuild_block = pos_of(qr/if\s*\(\s*\$do_rebuild\s*\)\s*\{/);
    cmp_ok($rebuild_block, '>', 0, 'AC3 liveness: the rebuild block was located');
    SKIP: {
        skip 'no build call found', 1 unless @build_at;
        # The single build sits after the rebuild block closes, i.e. it is on
        # the common path rather than only under "rebuild".
        cmp_ok($build_at[0], '>', $rebuild_block,
            'AC3 the build is on the common path, so "continue" still builds a missing image');
    }
}

# ---------------------------------------------------------------------------
# AC4 — version mismatch is forced, not offered.
# ---------------------------------------------------------------------------
like($CODE, qr/\$FORCE_REBUILD_REASON\s*=/,
     'AC4 a version mismatch sets a forced-rebuild reason');

{
    # It must NOT be pushed into the declinable list. Scoped to the version
    # block so an unrelated push elsewhere cannot mask a regression.
    my ($vblock) = $CODE =~ /(claude-version.{0,900}?)\n\n/s;
    $vblock //= '';
    unlike($vblock, qr/push\s+\@STALE_REASONS.{0,80}version mismatch/s,
        'AC4 and does NOT route it through the declinable @STALE_REASONS')
        or diag('  prompt_stale_action defaults to continue and returns continue on EOF, '
              . 'so a headless launch would decline it silently');
}

like($CODE, qr/if\s*\(\s*defined\s+\$FORCE_REBUILD_REASON\s*\)/,
     'AC4 the forced path is taken before the prompt is even considered');
like($CODE, qr/elsif\s*\(\s*\@STALE_REASONS\s*\)/,
     'AC4 the prompt is the ELSE branch, so a forced rebuild never asks');

# ---------------------------------------------------------------------------
# AC5 — the prompt knows what exists and says so.
# ---------------------------------------------------------------------------
like($CODE, qr/prompt_stale_action\([^)]*image_exists\s*=>/s,
     'AC5 the prompt is told whether the image exists');
like($CODE, qr/prompt_stale_action\([^)]*container_exists\s*=>/s,
     'AC5 and whether the container exists');

# "rebuild nothing" must not be claimed when something has to be built.
like($CODE, qr/\@missing\s*$/m, 'AC5 the label is built from what is missing');
like($CODE, qr/Continue — keep what exists, build the/,
     'AC5 continue describes the work it will still do');
like($CODE, qr/Continue as-is — rebuild nothing/,
     'AC5 and only claims "rebuild nothing" for the case where that is true');

# ---------------------------------------------------------------------------
# AC6 — an absent record is not drift.
#
# `!defined $saved` in these conditions made a FIRST launch report that the
# Containerfile and launcher "had changed since last build", when there had
# been no last build. That is half of why the prompt read as nonsense.
# ---------------------------------------------------------------------------
for my $what (['containerfile-hash', 'CURRENT_DF_HASH'],
              ['launcher-hash',      'CURRENT_LAUNCHER_HASH']) {
    my ($file, $var) = @$what;
    # ANCHOR ON THE READ, not on the filename. Each of these names appears at a
    # _write_file site too, and matching the first occurrence picked that up
    # instead — the block was "located" and then asserted against, passing and
    # failing for reasons that had nothing to do with the drift check.
    my ($block) = $CODE =~ /_read_file\("\$LAUNCHER_DIR\/\Q$file\E"\)(.{0,300}?)\n\}/s;
    $block //= '';
    ok(length $block, "AC6 liveness: located the $file DRIFT CHECK (not its write site)")
        or next;
    like($block, qr/\$saved/, "AC6 liveness: the $file block compares a saved value")
        or next;
    like($block, qr/defined\s+\$saved\s*&&\s*length\s+\$saved\s*&&/,
         "AC6 $file: an absent record is not treated as drift");
    unlike($block, qr/!\s*defined\s+\$saved\s*\|\|/,
           "AC6 $file: the old absent-means-changed condition is gone");
}

done_testing();
