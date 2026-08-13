#!/usr/bin/env perl
# Regression oracle for the SEVENTH package status, `dropped`.
#
# THE DEFECT THIS PINS. `dropped` is written as a terminal status by
# bp-drive-next.pl (`_is_terminal`) and bp-orchestrator.pl (same sub), while
# bp-blueprint.pl -- the ONLY sanctioned writer of blueprint.md -- rejected it
# outright. "A status one script writes and another refuses" was filed twice,
# independently: from the field as 2026-08-06 batch2 item #12, and from the
# audit as Decision 14 of butler-and-dashboard-overhaul. The six-value
# vocabulary was inherited from the template and never caught up.
#
# The legend line drifted the same way and for the same reason, so it is now
# RENDERED from @STATUS_VALUES by `refresh-legend` rather than transcribed --
# these assertions exist to keep a future edit from re-forking the two.
#
# NEVER MUTATE A LIVE blueprint.md. Every mutating assertion runs on a
# File::Temp copy. :raw throughout -- the glyphs are multi-byte and an
# :encoding layer would make the byte comparisons lie.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";
my $TEMPLATE = "$PROJ/plugins/blueprint/templates/blueprint.md";

ok(-f $SCRIPT,   'sanity: bp-blueprint.pl exists') or done_testing, exit;
ok(-f $TEMPLATE, 'sanity: the blueprint template exists');

sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# The wastebasket glyph, as raw UTF-8 bytes. Written as an escape rather than a
# literal so this file stays ASCII on disk and cannot be mangled by a tool that
# guesses the encoding.
my $G_DROPPED = "\xF0\x9F\x97\x91";

# ---------------------------------------------------------------------------
# A1 -- the vocabulary itself
# ---------------------------------------------------------------------------
my $src = slurp_raw($SCRIPT);
ok(defined $src, 'A1: bp-blueprint.pl is readable');

# The source writes every glyph as a \x escape, not as raw bytes, so that the
# script itself stays ASCII on disk. Assert that form, not the decoded bytes.
like($src, qr/\$G_DROPPED\s*=\s*"\\xF0\\x9F\\x97\\x91"/i,
    'A1: $G_DROPPED is defined as the wastebasket escape');
like($src, qr/"\$G_DROPPED dropped"/,
    'A1: @STATUS_VALUES carries a glyph-prefixed `dropped` entry');
like($src, qr/dropped\s*=>\s*\$G_DROPPED/,
    'A1: %WORD2GLYPH maps the bare word `dropped` to its glyph');

# The count and the vocabulary must not be transcribed anywhere. Three call
# sites each had their own copy and all three still said "six" after the
# seventh status landed -- accepting `dropped` while denying it was a status.
unlike($src, qr/recognised statuses/ && qr/\bsix\b[^\n]*recognised statuses/,
    'A1: no message still claims there are six recognised statuses');
my @help_sites = $src =~ /status_help\(\)/g;
cmp_ok(scalar @help_sites, '>=', 3,
    'A1: every status-validation message is rendered via status_help(), not transcribed');

# ---------------------------------------------------------------------------
# A2 -- set-status ACCEPTS dropped, on a real copy
#
# This is the assertion that fails against the old code: normalize_status
# returned undef for `dropped` and set-status called arg_error.
# ---------------------------------------------------------------------------
my $dir = tempdir(CLEANUP => 1);
my $bp  = "$dir/blueprint.md";

my $tpl = slurp_raw($TEMPLATE);
ok(defined $tpl && length $tpl, 'A2: template is readable and non-empty');

# A minimal blueprint with one package row, satisfying parse_dag's contract:
# a header row naming depends_on, contiguous rows beneath it.
my $fixture = <<"BP";
---
blueprint: vocab-fixture
status: audited
---

## Package status

| package | objective | depends_on | model | status |
|---|---|---|---|---|
| p01-alpha | does a thing | - | sonnet | \xE2\xAC\x9C pending |

Status values: \xE2\xAC\x9C pending \xC2\xB7 \xF0\x9F\x94\xA7 running

## Packages
BP

open my $fh, '>:raw', $bp or die "cannot write fixture: $!";
print {$fh} $fixture;
close $fh;

my $out = `perl "$SCRIPT" set-status --file "$bp" --pkg p01-alpha --status dropped 2>&1`;
my $rc  = $?;
is($rc, 0, 'A2: set-status --status dropped exits 0')
    or diag("output: $out");
unlike($out, qr/not one of the/,
    'A2: set-status does not reject `dropped` as unrecognised');

my $after = slurp_raw($bp);
like($after, qr/\Q$G_DROPPED\E dropped/,
    'A2: the package row now carries the canonical glyph-prefixed `dropped`');

# ---------------------------------------------------------------------------
# A3 -- refresh-legend RENDERS the legend from the vocabulary
#
# The fixture's legend deliberately lists only two of the seven values, so a
# verb that merely preserved the line would fail here.
# ---------------------------------------------------------------------------
my $lout = `perl "$SCRIPT" refresh-legend --file "$bp" 2>&1`;
is($?, 0, 'A3: refresh-legend exits 0') or diag("output: $lout");

my $legended = slurp_raw($bp);
my ($legend) = $legended =~ /^(Status values:.*)$/m;
ok(defined $legend, 'A3: a `Status values:` line survives the rewrite');

for my $word (qw(done pending running reviewing blocked parked dropped)) {
    like($legend, qr/\b\Q$word\E\b/, "A3: legend names `$word`");
}

# The point of rendering rather than transcribing: the legend cannot list a
# value the vocabulary does not have, nor omit one it does.
my @legend_words = $legend =~ /\b(done|pending|running|reviewing|blocked|parked|dropped)\b/g;
is(scalar @legend_words, 7, 'A3: legend lists exactly the seven statuses, no more');

# ---------------------------------------------------------------------------
# A4 -- refusal, not invention
# ---------------------------------------------------------------------------
my $noleg = "$dir/no-legend.md";
open my $nfh, '>:raw', $noleg or die $!;
print {$nfh} "---\nblueprint: x\n---\n\n## Package status\n\nnothing here\n";
close $nfh;

my $nout = `perl "$SCRIPT" refresh-legend --file "$noleg" 2>&1`;
isnt($?, 0, 'A4: refresh-legend fails when there is no legend line');
like($nout, qr/refusing to\s+invent one/,
    'A4: it refuses to invent a legend rather than appending one');

# ---------------------------------------------------------------------------
# A5 -- the shipped template no longer seeds the six-value bug
# ---------------------------------------------------------------------------
my ($tpl_legend) = $tpl =~ /^(Status values:.*)$/m;
ok(defined $tpl_legend, 'A5: the template has a legend line');
like($tpl_legend, qr/\bdropped\b/,
    'A5: the template legend names `dropped`, so new blueprints do not inherit the defect');

# ---------------------------------------------------------------------------
# A6 -- the other two scripts still agree `dropped` is terminal.
#
# The defect was a DISAGREEMENT between writers, so pinning only bp-blueprint.pl
# would let the pair drift apart again from the other side.
# ---------------------------------------------------------------------------
for my $s (qw(bp-drive-next.pl bp-orchestrator.pl)) {
    my $c = slurp_raw("$BUTLER/scripts/$s");
    ok(defined $c, "A6: $s is readable");
    like($c, qr/done\|dropped\|blocked\|parked/,
        "A6: $s still treats `dropped` as terminal");
}

# ---------------------------------------------------------------------------
# A7 -- the HOOKS that gate writing a status must accept `dropped` too.
#
# Found by the s01 scout AFTER the first pass of this fix shipped: bp-blueprint.pl
# had been corrected while two hooks kept their own hardcoded vocabularies, so a
# coordinator writing `status: dropped` to its ledger was still denied by the
# write guard and still refused permission to stop. A settled status that the
# only guarded write path rejects is not settled in any useful sense.
#
# NOTE the deliberate asymmetry: the LEDGER vocabulary carries `converging` and
# bp-blueprint.pl's does not, because the package ledger has a mid-flight value
# the blueprint.md summary table has no use for. These are two vocabularies on
# purpose; asserting them separately is the point, not an oversight.
# ---------------------------------------------------------------------------
my $lg = slurp_raw("$PROJ/plugins/butler/hooks/ledger-guard.sh");
ok(defined $lg, 'A7: ledger-guard.sh is readable');
like($lg, qr/\@STATUSES\s*=\s*qw\([^)]*\bdropped\b[^)]*\)/,
    'A7: ledger-guard.sh accepts `dropped` as a ledger frontmatter status');
like($lg, qr/\@STATUSES\s*=\s*qw\([^)]*\bconverging\b[^)]*\)/,
    'A7: ledger-guard.sh still accepts `converging` (ledger-only, by design)');

my $gs = slurp_raw("$PROJ/plugins/butler/hooks/gate-stop.sh");
ok(defined $gs, 'A7: gate-stop.sh is readable');

# Both terminal-status case arms must list dropped. Counting them separately
# matters: the first pass of this very fix corrected one site of three.
my @gs_terminal = $gs =~ /^\s*(?:parked\|done\|blocked|done\|blocked\|parked)\|dropped\)/mg;
cmp_ok(scalar @gs_terminal, '>=', 2,
    'A7: BOTH of gate-stop.sh terminal-status arms list `dropped`');
unlike($gs, qr/^\s*done\|blocked\|parked\)\s*:/m,
    'A7: no gate-stop.sh terminal arm omits `dropped`');

# ---------------------------------------------------------------------------
# A8 -- bp-ledger.pl, the sanctioned WRITER of package ledgers.
#
# The third home of this same defect, found by the s01 architect after two
# previous passes each believed the fix complete. Without `dropped` here, a
# coordinator that legitimately dropped its package could not record it through
# the typed API at all -- while bp-drive-next.pl and bp-orchestrator.pl read that
# very field and call `dropped` terminal.
#
# Asserted END TO END rather than by grepping the source, because a source-shape
# assertion is what let the earlier passes look complete: @STATUSES feeds two
# separate call sites (validate and set-status) and only a real invocation proves
# both accept it.
# ---------------------------------------------------------------------------
my $LEDGER_PL = "$BUTLER/scripts/bp-ledger.pl";
ok(-f $LEDGER_PL, 'A8: bp-ledger.pl exists');

my $ldir = tempdir(CLEANUP => 1);
my $led  = "$ldir/p01-probe.md";
open my $lfh, '>:raw', $led or die "cannot write ledger fixture: $!";
# bp-ledger.pl validates STRUCTURE before it validates the status, so a fixture
# missing any required heading fails for the wrong reason and would make this
# assertion vacuous. The first draft of this fixture did exactly that -- it went
# red for `converging`, a value that was already accepted, which is what exposed
# the mistake.
print {$lfh} <<'LED';
---
package: p01-probe
blueprint: vocab-fixture
status: pending
write_set: plugins/nowhere/
last_updated: 2026-08-13T00:00:00Z
---

# Package p01-probe

## Pipeline

- [ ] 1. Nothing

## Decisions & attempt log

- none

## Next action

Nothing.

## Outputs

none

## Escalation (when status: blocked)

none
LED
close $lfh;

for my $word (qw(dropped converging done parked)) {
    my $o = `perl "$LEDGER_PL" set-status --ledger "$led" --status $word 2>&1`;
    my $r = $?;
    is($r, 0, "A8: bp-ledger.pl set-status accepts `$word`")
        or diag("output: $o");
}

my $bogus = `perl "$LEDGER_PL" set-status --ledger "$led" --status nonsense 2>&1`;
isnt($?, 0, 'A8: bp-ledger.pl still refuses an unrecognised status');
like($bogus, qr/\bdropped\b/,
    'A8: and its refusal message lists `dropped` among the allowed values');

done_testing();
