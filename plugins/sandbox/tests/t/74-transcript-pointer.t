#!/usr/bin/env perl
# Oracle for b02-backpack-owns-path — DC5 (AC14, AC15) + a supplementary
# assertion tying DC2's flagged migration consequence to something
# machine-checkable (item_hash / is_approved, BackpackApproval.pm).
#
# NEVER executes launcher.pl. Every assertion about launcher.pl below is a
# STATIC regex over its source text, read as a plain file. `perl -c` is used
# only as a compile-sanity check, never a run.
#
# AC14: launcher.pl source contains the last-transcript.txt write shown in
#       spec section 2.5, anchored immediately after the $TRANSCRIPT =
#       _open_transcript(...) line.
# AC15: plugins/sandbox/docs/working-on-ccpraxis.md mentions
#       last-transcript.txt.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use Cwd qw(abs_path);

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $LAUNCHER = "$REPO_ROOT/plugins/sandbox/scripts/launcher.pl";
ok(-f $LAUNCHER, 'launcher.pl exists') or BAIL_OUT('script missing');

# Compile-check only -- this does NOT run the script (`perl -c` never
# executes top-level code that would build an image or start a container).
{
    my $out = `"$^X" -c "$LAUNCHER" 2>&1`;
    like($out, qr/syntax OK/, 'launcher.pl compiles clean (perl -c, not executed)') or diag($out);
}

open my $fh, '<:raw', $LAUNCHER or BAIL_OUT("cannot open $LAUNCHER: $!");
local $/;
my $src = <$fh>;
close $fh;

# ===========================================================================
# AC14 -- the last-transcript.txt pointer write, anchored to the real
# $TRANSCRIPT assignment line so this isn't satisfied by an unrelated
# last-transcript.txt string appearing anywhere in the file.
# ===========================================================================
{
    ok($src =~ /\$TRANSCRIPT\s*=\s*_open_transcript\(/,
        'AC14 precondition: the $TRANSCRIPT = _open_transcript(...) anchor line exists')
        or BAIL_OUT('anchor missing -- spec citation (launcher.pl:1792) is stale');

    # Grab a window of source starting at the anchor, so the pointer write
    # must appear NEAR it (spec: "insert immediately after :1792"), not
    # merely exist somewhere else in a 5000+ line file.
    my ($window) = $src =~ /(\$TRANSCRIPT\s*=\s*_open_transcript\(.{0,2000})/s;
    ok(defined $window, 'AC14: could isolate a window after the $TRANSCRIPT anchor')
        or BAIL_OUT('regex bug in the oracle, not a subject-under-test failure');

    like($window, qr/last-transcript\.txt/,
        'AC14: "last-transcript.txt" appears near the $TRANSCRIPT assignment') or diag($window);
    like($window, qr/\$LAUNCHER_DIR/,
        'AC14: the pointer is written under $LAUNCHER_DIR (.launcher/), per spec 2.5')
        or diag($window);
    like($window, qr{/root/\.claude/sandbox-logs/launch-\$LAUNCH_ID\.transcript\.log},
        'AC14: the pointer\'s CONTENT is the in-container sandbox-logs path (matches BPK-07\'s '
        . 'quoted path exactly) -- the whole point is redirecting an agent from the RO-overlaid '
        . '.launcher/ to the real, writable log location')
        or diag($window);
    # Best-effort, per spec: no die() gating this cosmetic write.
    unlike($window, qr/or\s+die\b.{0,40}last-transcript/is,
        'AC14: the pointer write is best-effort (does not die() on failure)') or diag($window);
}

# ===========================================================================
# AC15 -- plugins/sandbox/docs/working-on-ccpraxis.md mentions
# last-transcript.txt.
# ===========================================================================
{
    my $doc = "$REPO_ROOT/plugins/sandbox/docs/working-on-ccpraxis.md";
    ok(-f $doc, 'working-on-ccpraxis.md exists') or BAIL_OUT('fixture broken');
    open my $dfh, '<:raw', $doc or BAIL_OUT("cannot open $doc: $!");
    local $/;
    my $dsrc = <$dfh>;
    close $dfh;

    like($dsrc, qr/last-transcript\.txt/,
        'AC15: working-on-ccpraxis.md mentions last-transcript.txt') or diag('not found');
}

# ===========================================================================
# Supplementary -- DC2's flagged consequence made concrete: migrating an
# entry off its hand-rolled `export PATH=...` preamble EDITS `install`,
# which changes item_hash (md5 over install\0verify), which flips
# is_approved from 1 to 0. This is the exact mechanism the spec names as
# "the surviving candidate for the original vanishing-items incident" and
# says must not surprise anyone. BackpackApproval.pm is a pure module (no
# console I/O, no spawning) -- safe to require directly, unlike launcher.pl.
#
# This is NOT one of AC1-16; it is the spec's own instruction ("If that is
# observable at the backpack.pl level, assert it") applied at the one level
# where it actually IS observable (BackpackApproval.pm), since backpack.pl
# itself has no approval concept -- that lives entirely in launcher.pl's
# supporting modules.
# ===========================================================================
{
    my $lib = "$REPO_ROOT/plugins/sandbox/scripts";
    unshift @INC, $lib;
    require BackpackApproval;

    # The gh-auth item's REAL pre-migration shape (spec 2, Context): install
    # literally begins with a hand-rolled PATH preamble.
    my $before_migration = {
        category => 'project-setup',
        name     => 'gh-auth',
        install  => 'export PATH="/opt/tools/bin:$PATH" && gh auth status || gh auth login',
        verify   => 'export PATH="/opt/tools/bin:$PATH" && gh auth status',
    };
    my $store = {};
    BackpackApproval::approve($before_migration, $store);
    ok(BackpackApproval::is_approved($before_migration, $store),
        'supplementary: the pre-migration entry, once approved, reads as approved');

    # DC2's migration: strip the preamble (bin_dirs now covers it).
    my $after_migration = {
        category => 'project-setup',
        name     => 'gh-auth',
        install  => 'gh auth status || gh auth login',
        verify   => 'gh auth status',
    };
    ok(!BackpackApproval::is_approved($after_migration, $store),
        'supplementary: migrating the SAME entry (stripping the PATH preamble) changes '
        . 'item_hash and flips is_approved to 0 -- a migrated entry reads as un-approved on '
        . 'the very next launch, exactly as the spec flags. Not a bug to "fix" here (it is '
        . 'out of scope for b02), but it must be true, not merely asserted in prose')
        or diag('is_approved stayed true across an install-text edit -- item_hash is not '
              . 'actually keyed on install/verify content, contradicting BackpackApproval.pm\'s '
              . 'own documented contract');
}

done_testing();
