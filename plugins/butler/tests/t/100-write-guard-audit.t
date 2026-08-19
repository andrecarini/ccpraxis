#!/usr/bin/env perl
# t/100-write-guard-audit.t — the two report artifacts a01-write-integrity-
# reread-under-lock must leave on disk (spec §4 AC15, AC18).
#
# AC15 ("record it before changing it", criterion 3): the pre-change DROP-vs-
# FORCE verdict per site, resolved and corrected by the driver from the
# scout's uniform "SILENTLY FORCES" verdict (spec §1.1). The spec does not
# pin a filename for this report -- only that it lives in the package report
# directory -- so this oracle scans every .md file there rather than assuming
# one name, and requires it to actually DISTINGUISH the two behaviours
# (_set_ledger_status = drop+force, update_registry_pkg = force-only), not
# merely mention both subs.
#
# AC18: reports/a01-write-integrity-reread-under-lock/rmw-audit.md, a fixed
# path named explicitly by the spec. Floor assertions only (a listed site with
# file:line, converted yes/no, and — for every "no" — a non-empty reason);
# never an exact row count (spec §6 "no whole-shape oracle").
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

# A blueprint's package/report content lives under blueprints/<name>/ while the
# blueprint is active, and is relocated to blueprints/_archive/<name>/ once the
# blueprint is finished. This oracle must find its subject either way -- resolve
# by checking both locations rather than hardcoding one, and fail loudly (never
# silently skip) if the subject is in neither.
my $BP_ROOT = "$Bin/../../../../.ccpraxis-local-data/blueprints";
my $BP_NAME = 'butler-and-dashboard-overhaul';
my $BP_REL  = 'reports/a01-write-integrity-reread-under-lock';
my @BP_CANDIDATES = ("$BP_ROOT/$BP_NAME/$BP_REL", "$BP_ROOT/_archive/$BP_NAME/$BP_REL");
my ($REPORT_DIR) = grep { -d $_ } @BP_CANDIDATES;

unless (defined $REPORT_DIR) {
    plan tests => 1;
    fail("AC15/AC18: package report dir for '$BP_NAME' not found in either location -- looked at: "
       . join(' | ', @BP_CANDIDATES));
    done_testing();
    exit 1;
}

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }

# ═════════════════════════════════════════════════════════════════════════
# AC15 — the pre-change DROP-vs-FORCE record (criterion 3)
# ═════════════════════════════════════════════════════════════════════════
{
    ok(-d $REPORT_DIR, "AC15: the package report directory exists ($REPORT_DIR)")
        or diag("if this fails, the report dir itself moved -- check BP_REPORT_DIR");

    my @candidates;
    if (opendir my $dh, $REPORT_DIR) {
        @candidates = sort grep { /\.md$/ } readdir $dh;
        closedir $dh;
    }
    ok(scalar(@candidates) > 0, 'AC15: at least one report file exists in the package report directory')
        or diag('no .md files found under the report directory at all');

    my $winner;
    for my $f (@candidates) {
        my $txt = slurp("$REPORT_DIR/$f") // '';
        next unless $txt =~ /_set_ledger_status/ && $txt =~ /update_registry_pkg/;
        # Must actually distinguish the two, not just name-drop both subs: a DROP
        # verdict near _set_ledger_status, a FORCE-only (no-drop) verdict near
        # update_registry_pkg, and a file:line for each (bp-orchestrator.pl:NNNN).
        my $drop_near_s1  = ($txt =~ /_set_ledger_status[^\n]{0,400}\bDROP/is)
                          || ($txt =~ /\bDROP[^\n]{0,400}_set_ledger_status/is);
        my $force_near_1b = ($txt =~ /update_registry_pkg[^\n]{0,400}FORCE/is)
                          || ($txt =~ /FORCE[^\n]{0,400}update_registry_pkg/is);
        my $has_lines     = $txt =~ /bp-orchestrator\.pl[:#]?\s*3883/ && $txt =~ /bp-orchestrator\.pl[:#]?\s*1345/;
        if ($drop_near_s1 && $force_near_1b && $has_lines) { $winner = $f; last; }
    }
    ok(defined $winner,
        'AC15/criterion3: a report file distinguishes a DROP site (_set_ledger_status, bp-orchestrator.pl:3883) '
      . 'from a FORCE-only site (update_registry_pkg, bp-orchestrator.pl:1345), each with its file:line')
        or diag('scanned: ' . join(', ', @candidates));
}

# ═════════════════════════════════════════════════════════════════════════
# AC18 — the read-modify-write audit (criterion 5), a fixed path per spec
# ═════════════════════════════════════════════════════════════════════════
{
    my $rmw = "$REPORT_DIR/rmw-audit.md";
    ok(-f $rmw, "AC18: $rmw exists") or diag('rmw-audit.md has not been written yet');

    my $doc = slurp($rmw) // '';

    # Floor: every site §4/AC18 explicitly names must appear, each with a file:line.
    my %required = (
        '_set_ledger_status'    => qr/_set_ledger_status[^\n]*bp-orchestrator\.pl[:#]?\s*\d+/is,
        'update_registry_pkg'   => qr/update_registry_pkg[^\n]*bp-orchestrator\.pl[:#]?\s*\d+/is,
        'queue_needs_you'       => qr/queue_needs_you[^\n]*bp-orchestrator\.pl[:#]?\s*\d+/is,
        'run_op'                => qr/run_op[^\n]*bp-ledger\.pl[:#]?\s*\d+/is,
        '_apply_harvest_findings' => qr/_apply_harvest_findings[^\n]*bp-orchestrator\.pl[:#]?\s*\d+/is,
        'write_paused'          => qr/write_paused[^\n]*bp-orchestrator\.pl[:#]?\s*\d+/is,
        'mark_judge_inflight'   => qr/mark_judge_inflight[^\n]*bp-orchestrator\.pl[:#]?\s*\d+/is,
        'registry_merge'        => qr/registry_merge[^\n]*bp-lib\.sh[:#]?\s*\d+/is,
    );
    for my $name (sort keys %required) {
        like($doc, $required{$name}, "AC18: rmw-audit.md lists $name with a file:line");
    }

    # Floor: converted yes/no is stated for the four canonical converted sites.
    for my $name (qw(_set_ledger_status update_registry_pkg queue_needs_you)) {
        my ($near) = ($doc =~ /(\Q$name\E.{0,200})/is);
        $near //= '';
        like($near, qr/\b(yes|no)\b/i, "AC18: the $name row states converted yes/no");
    }

    # Floor: every "no" row carries a non-empty reason (never a bare "no").
    # Heuristic, line-oriented: find lines whose converted marker is "no", then
    # require more than the bare word on that line (a reason column/clause).
    my @no_lines = grep { /\bconverted\b[^\n]{0,20}\bno\b/i || /\|\s*no\s*\|/i || /\bno\b\s*[-\x{2014}:]/i }
                   split /\n/, $doc;
    ok(scalar(@no_lines) >= 1, 'AC18: at least one row is marked not-converted (criterion 5 is a list of ALL rmw sites)')
        or diag('no "no" rows found -- either every site converted (unlikely, spec lists several as out of scope) or the table format was not recognised');
    for my $line (@no_lines) {
        (my $tail = $line) =~ s/.*?\bno\b//i;
        $tail =~ s/^[\s|:\x{2014}-]+//;
        ok(length($tail) >= 3, 'AC18: unconverted row carries a non-empty reason (' . substr($line, 0, 80) . ')');
    }
}

done_testing();
