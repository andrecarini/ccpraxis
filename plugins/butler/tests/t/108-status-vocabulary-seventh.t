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

done_testing();
