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
# A1-A5 -- RETARGETED for s03-drop-table-status-column (spec §2.6).
#
# A1-A5 tested bp-blueprint.pl's glyph/legend/set-status TABLE vocabulary,
# which s03 deletes outright (Decision 11: the table carries no status at
# all, so it needs no vocabulary to validate against). That deletion is
# CORRECT and not a regression of the defect this file exists to pin --
# `dropped` remains a valid LEDGER status with live guards (A6-A8, UNTOUCHED
# below: bp-drive-next.pl, bp-orchestrator.pl, ledger-guard.sh, gate-stop.sh,
# bp-ledger.pl); it simply stops being a TABLE concept.
#
# This block replaces A1-A5 with the deletion verification the spec asks
# for: every symbol A1-A5 used to test is actually gone from
# bp-blueprint.pl's source, the retired verbs fail with the new ledger-
# pointer message (not a generic error, not a silent success), and the
# shipped template no longer carries a "Status values:" line to seed any
# vocabulary bug in the first place.
# ---------------------------------------------------------------------------
my $src = slurp_raw($SCRIPT);
ok(defined $src, 'A1-A5(retargeted): bp-blueprint.pl is readable');

unlike($src, qr/\$G_DROPPED\b/,        'A1-A5(retargeted): $G_DROPPED is gone');
unlike($src, qr/\@STATUS_VALUES\b/,    'A1-A5(retargeted): @STATUS_VALUES is gone');
unlike($src, qr/%WORD2GLYPH\b|\bWORD2GLYPH\b/, 'A1-A5(retargeted): %WORD2GLYPH is gone');
unlike($src, qr/\bstatus_help\b/,      'A1-A5(retargeted): status_help is gone');
unlike($src, qr/\bnormalize_status\b/, 'A1-A5(retargeted): normalize_status is gone');
unlike($src, qr/\bop_refresh_legend\b/, 'A1-A5(retargeted): op_refresh_legend is gone');
unlike($src, qr/'refresh-legend'/,     'A1-A5(retargeted): the refresh-legend dispatch entry is gone');

my $dir = tempdir(CLEANUP => 1);
my $bp  = "$dir/blueprint.md";

my $tpl = slurp_raw($TEMPLATE);
ok(defined $tpl && length $tpl, 'A1-A5(retargeted): template is readable and non-empty');

# A minimal blueprint with one package row, satisfying parse_dag's contract:
# a header row naming depends_on, contiguous rows beneath it. New shape (no
# status column), matching the edited template.
my $fixture = <<"BP";
---
blueprint: vocab-fixture
status: audited
---

## Package status

| package | objective | depends_on | model |
|---|---|---|---|
| p01-alpha | does a thing | - | sonnet |

## Packages
BP

open my $fh, '>:raw', $bp or die "cannot write fixture: $!";
print {$fh} $fixture;
close $fh;
my $before_digest = slurp_raw($bp);

my $out = `perl "$SCRIPT" set-status --file "$bp" --pkg p01-alpha --status dropped 2>&1`;
my $rc  = $?;
isnt($rc, 0, 'A1-A5(retargeted): set-status --status dropped is refused (retirement is unconditional -- not even a real vocabulary word survives)');
like($out, qr/Decision 11/, 'A1-A5(retargeted): set-status refusal cites Decision 11');
like($out, qr/bp-ledger\.pl\s+set-status/, 'A1-A5(retargeted): set-status refusal points at bp-ledger.pl set-status');
is(slurp_raw($bp), $before_digest, 'A1-A5(retargeted): set-status refusal leaves the file byte-identical');

my $out2 = `perl "$SCRIPT" set-field --file "$bp" --pkg p01-alpha --field status --value dropped 2>&1`;
my $rc2  = $?;
isnt($rc2, 0, 'A1-A5(retargeted): set-field --field status is refused identically');
like($out2, qr/Decision 11/, 'A1-A5(retargeted): set-field --field status refusal cites Decision 11');
is(slurp_raw($bp), $before_digest, 'A1-A5(retargeted): set-field --field status refusal leaves the file byte-identical');

# The shipped template no longer carries a "Status values:" legend line at all.
unlike($tpl, qr/^\s*Status values:/m,
    'A1-A5(retargeted): the template has no "Status values:" legend line');

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
