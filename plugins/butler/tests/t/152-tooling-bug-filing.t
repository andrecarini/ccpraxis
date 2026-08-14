#!/usr/bin/env perl
# 152-tooling-bug-filing.t -- g04-tooling-bugs-get-filed
#
# Spec: .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
#       g04-tooling-bugs-get-filed-spec.md
#
# Written from the spec, blind to any prose the implementer will add to
# reporter/SKILL.md, drive-solo/SKILL.md or coordinator-protocol/SKILL.md.
# The heading names/positions asserted below are dictated verbatim by the
# spec (SS3.3, AC1-AC6), not read off a draft.
#
# THE BAR (spec, "read this before writing a single assertion"): a trigger
# that is implemented must be EXERCISED, not asserted by string presence
# alone. AC7 and AC10 below really call
# plugins/almanac/scripts/almanac-bug.pl against a File::Temp tempdir
# (never the real project), file a real report, resolve a real marker to
# it, and separately prove a forged/missing id and a malformed marker are
# REJECTED by the same check. The marker parser is written HERE, in the
# oracle itself (spec SS2: "a test-local check ... no new script"),
# mirroring the fence-scoped, section-scoped extraction
# plugins/butler/scripts/bp-judge.pl:639-674 already uses for
# MEANS-DEVIATION -- same family of marker, same integrity rule.
#
# AC11/AC12 are deliberately NOT covered here: both require
# .ccpraxis-local-data/ state (a filed backlog report; a package ledger's
# Scope section), and that tree is gitignored -- an oracle that asserted
# it would pass only on this machine, on this run. See the step-3 report.
# AC13 (full-suite baseline) is a pipeline procedure, not a single-file
# assertion. AC14/AC15 are hermeticity PROPERTIES OF THIS FILE, self-
# checked below rather than asserted against an implementation.
#
# Runs standalone: perl plugins/butler/tests/t/152-tooling-bug-filing.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);

my $REPORTER   = "$Bin/../../skills/reporter/SKILL.md";
my $DRIVESOLO  = "$Bin/../../skills/drive-solo/SKILL.md";
my $COORD      = "$Bin/../../skills/coordinator-protocol/SKILL.md";
my $ALMANAC    = "$Bin/../../../almanac/scripts/almanac-bug.pl";
my $BUGREPORT_SKILL = "$Bin/../../../almanac/skills/bug-report/SKILL.md";

for my $f ($REPORTER, $DRIVESOLO, $COORD, $ALMANAC, $BUGREPORT_SKILL) {
    ok(-f $f, "fixture present: $f") or BAIL_OUT("missing input file: $f");
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or die "cannot read $p: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $reporter_txt  = slurp($REPORTER);
my $drivesolo_txt = slurp($DRIVESOLO);
my $coord_txt     = slurp($COORD);

# ---------------------------------------------------------------------------
# AC1 -- reporter/SKILL.md: "## Filing a ccpraxis tooling bug" before "## Boundaries"
# ---------------------------------------------------------------------------
{
    my $heading = '## Filing a ccpraxis tooling bug';
    my $hpos = index($reporter_txt, $heading);
    my $bpos = index($reporter_txt, '## Boundaries');
    ok($hpos >= 0, 'AC1: reporter/SKILL.md has "## Filing a ccpraxis tooling bug"');
    ok($bpos >= 0, 'AC1 precondition: reporter/SKILL.md still has "## Boundaries"');
    ok($hpos >= 0 && $bpos >= 0 && $hpos < $bpos,
       'AC1: the filing section sits BEFORE "## Boundaries" in reporter/SKILL.md');

    my $section = ($hpos >= 0)
        ? substr($reporter_txt, $hpos, ($bpos >= 0 ? $bpos - $hpos : length($reporter_txt) - $hpos))
        : '';
    like($section, qr/almanac-bug\.pl\s+file\b/, 'AC1: reporter section names "almanac-bug.pl file" verbatim');
    like($section, qr/--body\s+-/, 'AC1: reporter section carries the --body - flag verbatim');
}

# ---------------------------------------------------------------------------
# AC2 -- drive-solo/SKILL.md: same section, positioned AFTER "## Commit mechanics"
# ---------------------------------------------------------------------------
my $drivesolo_section = '';
{
    my $heading = '## Filing a ccpraxis tooling bug';
    my $hpos = index($drivesolo_txt, $heading);
    my $cpos = index($drivesolo_txt, '## Commit mechanics');
    ok($hpos >= 0, 'AC2: drive-solo/SKILL.md has "## Filing a ccpraxis tooling bug"');
    ok($cpos >= 0, 'AC2 precondition: drive-solo/SKILL.md still has "## Commit mechanics"');
    ok($hpos >= 0 && $cpos >= 0 && $hpos > $cpos,
       'AC2: the filing section sits AFTER "## Commit mechanics" in drive-solo/SKILL.md');

    if ($hpos >= 0) {
        # Section runs to the next top-level "## " heading, or EOF.
        my $rest = substr($drivesolo_txt, $hpos + length($heading));
        my $endrel = $rest =~ /^\s*##\s/m ? $-[0] : length($rest);
        $drivesolo_section = $heading . substr($rest, 0, $endrel);
    }
    like($drivesolo_section, qr/almanac-bug\.pl\s+file\b/, 'AC2: drive-solo section names "almanac-bug.pl file" verbatim');
    like($drivesolo_section, qr/--body\s+-/, 'AC2: drive-solo section carries the --body - flag verbatim');
}

# reporter's section body, bounded the same way (to next "## " heading), for AC3/AC9.
my $reporter_section = '';
{
    my $heading = '## Filing a ccpraxis tooling bug';
    my $hpos = index($reporter_txt, $heading);
    if ($hpos >= 0) {
        my $rest = substr($reporter_txt, $hpos + length($heading));
        my $endrel = $rest =~ /^\s*##\s/m ? $-[0] : length($rest);
        $reporter_section = $heading . substr($rest, 0, $endrel);
    }
}

# ---------------------------------------------------------------------------
# AC3 -- both sections: explicit "when NOT to file" + pointer to bug-report SKILL.md
# ---------------------------------------------------------------------------
for my $case ([reporter => $reporter_section], [drivesolo => $drivesolo_section]) {
    my ($name, $section) = @$case;
    like($section, qr/when\s+NOT\s+to\s+file/i,
         "AC3 ($name): section states an explicit \"when NOT to file\" line");
    like($section, qr/own\b[^.\n]{0,60}\bbug/i,
         "AC3 ($name): the own-package's-bug exclusion is named, not just a generic caveat");
    like($section, qr{plugins/almanac/skills/bug-report/SKILL\.md},
         "AC3 ($name): points at bug-report/SKILL.md by path rather than restating its checklist");
}

# ---------------------------------------------------------------------------
# AC4 -- coordinator-protocol/SKILL.md: "Prose vs. mechanism" section, between
#        "## Mandated means & deviations" and "## Pipeline"
# ---------------------------------------------------------------------------
my $prose_vs_mech_section = '';
{
    my $mpos = index($coord_txt, '## Mandated means & deviations');
    my $ppos = index($coord_txt, '## Pipeline');
    ok($mpos >= 0, 'AC4 precondition: coordinator-protocol still has "## Mandated means & deviations"');
    ok($ppos >= 0, 'AC4 precondition: coordinator-protocol still has "## Pipeline"');

    my $between = ($mpos >= 0 && $ppos >= 0 && $ppos > $mpos)
        ? substr($coord_txt, $mpos, $ppos - $mpos) : '';
    my $found = ($between =~ /^#{2,6}\s*prose\s+vs\.?\s*mechanism\b/im);
    ok($found, 'AC4: a "Prose vs. mechanism" heading exists strictly between those two sections');

    if ($found) {
        # Bound the subsection to the next heading of the same or higher level.
        my $hstart = $-[0];
        my $rest = substr($between, $hstart);
        my $endrel = $rest =~ /\n#{2,6}\s/ ? $+[0] - 1 : length($rest);
        $prose_vs_mech_section = substr($rest, 0, $endrel);
    }
}
like($prose_vs_mech_section, qr/CONSTRAINT CONFLICT/, 'AC4a: names CONSTRAINT CONFLICT explicitly');
like($prose_vs_mech_section, qr/ORACLE EDIT/, 'AC4a: names ORACLE EDIT explicitly');
like($prose_vs_mech_section, qr/CONSTRAINT CONFLICT[^.]{0,400}?\b(not|never)\b[^.]{0,120}?(gate|gated|marker)/is,
     'AC4a: states CONSTRAINT CONFLICT is not gated (within the same passage)');
like($prose_vs_mech_section, qr/TOOLING-BUG-FILED/, 'AC4b: mentions the TOOLING-BUG-FILED marker');
like($prose_vs_mech_section, qr/mechanical/i, 'AC4b: calls the marker\'s integrity "mechanical"');
like($prose_vs_mech_section, qr/judg[e]?ment/i, 'AC4b: names the underlying call a "judgement"');

# ---------------------------------------------------------------------------
# AC5 -- TOOLING-BUG-FILED grammar documented near MEANS-DEVIATION, scoped to
#        "## Decisions & attempt log", never inside a fenced block
# ---------------------------------------------------------------------------
{
    like($coord_txt, qr/TOOLING-BUG-FILED:\s*id=/,
         'AC5: coordinator-protocol documents the TOOLING-BUG-FILED: id=... grammar');
    like($coord_txt, qr/why=/, 'AC5 precondition: why= appears somewhere (MEANS-DEVIATION already uses it)');

    my $mdpos = index($coord_txt, 'MEANS-DEVIATION');
    my $tbfpos = index($coord_txt, 'TOOLING-BUG-FILED');
    my $near = ($mdpos >= 0 && $tbfpos >= 0 && abs($tbfpos - $mdpos) < 4000);
    ok($near, 'AC5: TOOLING-BUG-FILED is documented textually near MEANS-DEVIATION (within 4000 chars)');

    if ($tbfpos >= 0) {
        my $window = substr($coord_txt, $tbfpos > 1000 ? $tbfpos - 1000 : 0, 3000);
        like($window, qr/Decisions\s*&\s*attempt\s+log/i,
             'AC5: the grammar doc states it counts only inside "## Decisions & attempt log"');
        like($window, qr/fenced\s+code\s+block/i,
             'AC5: the grammar doc states it never counts inside a fenced code block');
    } else {
        fail('AC5: cannot check section-scoping prose -- TOOLING-BUG-FILED not documented at all');
        fail('AC5: cannot check fence-scoping prose -- TOOLING-BUG-FILED not documented at all');
    }
}

# ---------------------------------------------------------------------------
# AC6 -- step-7 fix-batch consolidation extended to filing
# ---------------------------------------------------------------------------
{
    my $fbpos = index($coord_txt, '**Fix-batch.**');
    my $uipos = index($coord_txt, '**UI pass**');
    ok($fbpos >= 0, 'AC6 precondition: the "**Fix-batch.**" step-7 paragraph still exists');
    my $fb_region = ($fbpos >= 0)
        ? substr($coord_txt, $fbpos, ($uipos > $fbpos ? $uipos - $fbpos : 1500))
        : '';
    like($fb_region, qr/same\s+tooling\s+defect/i,
         'AC6: the fix-batch step names the same-tooling-defect-from-multiple-sources case');
    like($fb_region, qr/\b(one|once|single)\b[^.\n]{0,60}\b(filing|filed|marker|report)\b/i,
         'AC6: the fix-batch step states it becomes ONE filing/marker, not one per source');
}

# ---------------------------------------------------------------------------
# AC8 -- report-quality-bar prose + one worked example from this run
# ---------------------------------------------------------------------------
{
    my $bugreport_txt = slurp($BUGREPORT_SKILL);
    like($bugreport_txt, qr/What makes a report worth reading/,
         'AC8 precondition: bug-report/SKILL.md still has its quality-bar section');

    my $has_pointer =
        ($coord_txt =~ qr{plugins/almanac/skills/bug-report/SKILL\.md}) ||
        ($reporter_section =~ qr{plugins/almanac/skills/bug-report/SKILL\.md}) ||
        ($drivesolo_section =~ qr{plugins/almanac/skills/bug-report/SKILL\.md});
    ok($has_pointer, 'AC8: something points at bug-report/SKILL.md\'s quality-bar section');

    # The worked example: spec SS7 item 4, the registry-path $PWD finding --
    # present almost verbatim (file:line + the $PWD hazard) somewhere in
    # coordinator-protocol, reporter, or drive-solo.
    my $has_worked_example =
        ($coord_txt =~ /gate-drive-loop\.sh/ && $coord_txt =~ /\$PWD/) ||
        ($reporter_section =~ /gate-drive-loop\.sh/ && $reporter_section =~ /\$PWD/) ||
        ($drivesolo_section =~ /gate-drive-loop\.sh/ && $drivesolo_section =~ /\$PWD/) ||
        ($coord_txt =~ /registry-path/i && $coord_txt =~ /\$PWD/) ||
        ($reporter_section =~ /registry-path/i && $reporter_section =~ /\$PWD/) ||
        ($drivesolo_section =~ /registry-path/i && $drivesolo_section =~ /\$PWD/);
    ok($has_worked_example,
       'AC8: one worked example from SS7 (the registry-path $PWD finding) is transcribed, file:line and all');
}

# ---------------------------------------------------------------------------
# AC9 -- no-double-filing: both surfaces point at "Before you file" rather than
#        re-deriving the check-list-first rule
# ---------------------------------------------------------------------------
{
    my $bugreport_txt = slurp($BUGREPORT_SKILL);
    like($bugreport_txt, qr/Before you file/, 'AC9 precondition: bug-report/SKILL.md still has "Before you file"');

    # Whole-file, not just the new section: the pointer only needs to exist
    # SOMEWHERE in each surface (AC3 already pins one copy inside the new
    # section specifically; this is the broader "did not re-derive" check).
    like($reporter_txt, qr{plugins/almanac/skills/bug-report/SKILL\.md},
         'AC9 (reporter): points at bug-report/SKILL.md rather than re-deriving the check-first rule');
    like($drivesolo_txt, qr{plugins/almanac/skills/bug-report/SKILL\.md},
         'AC9 (drive-solo): points at bug-report/SKILL.md rather than re-deriving the check-first rule');
}

# ---------------------------------------------------------------------------
# AC16 -- MEANS-DEVIATION untouched: same count as measured at spec time (3),
#         plus EXACTLY one new textual cross-reference from AC4/AC5 (=> 4).
#         Baseline measured directly from disk, 2026-08-14, before this
#         package's diff (grep -c MEANS-DEVIATION coordinator-protocol/SKILL.md == 3).
# ---------------------------------------------------------------------------
{
    my $count = () = $coord_txt =~ /MEANS-DEVIATION/g;
    is($count, 4, 'AC16: MEANS-DEVIATION appears exactly once more than the pre-package baseline (3 -> 4)');
}

# ===========================================================================
# AC7 / AC10 -- EXERCISED: real filing, real marker resolution, real forgery
# rejection, against a File::Temp tempdir project. Never touches the real
# C:/Development/ccpraxis/.ccpraxis-local-data/bug-reports/ (AC14). Never
# invokes `collect` (AC15) -- only `file`/`list`.
# ===========================================================================

sub run_almanac {
    my (@args) = @_;
    my $pid = open(my $fh, '-|', $^X, $ALMANAC, @args);
    unless ($pid) { return (-1, "open failed: $!"); }
    local $/;
    my $out = <$fh> // '';
    close $fh;
    my $code = ($? == -1) ? -1 : ($? >> 8);
    return ($code, $out);
}

sub write_body_file {
    my ($text) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    binmode $fh, ':raw';
    print {$fh} $text;
    close $fh;
    return $path;
}

# --- test-local TOOLING-BUG-FILED parser -----------------------------------
# Mirrors plugins/butler/scripts/bp-judge.pl:639-674 (parse_means_deviations):
# scoped to "## Decisions & attempt log", fence-aware, same family of marker.
# Deliberately re-implemented here rather than imported -- spec SS2 rules this
# package ships no new script, and the check must be exercised INSIDE the
# oracle, not delegated to production code that does not exist yet.
sub parse_tooling_bug_filed {
    my ($txt) = @_;
    my @out;
    return @out unless defined $txt && length $txt;
    my ($sec) = $txt =~ /^##\s+Decisions\s*&\s*attempt\s+log\s*$(.*?)(?=^##\s|\z)/ms;
    return @out unless defined $sec;
    my $fenced = 0;
    for my $ln (split /\r?\n/, $sec) {
        $ln =~ s/\r$//;
        if ($ln =~ /^\s*(?:```|~~~)/) { $fenced = !$fenced; next }
        next if $fenced;
        next unless $ln =~ /TOOLING-BUG-FILED:\s*(.*)$/;
        my $rest = $1;
        my $STOP = qr/(?=\s+id=|\s+why=|$)/;
        my ($id)  = $rest =~ /\bid=(.*?)$STOP/;
        my ($why) = $rest =~ /\bwhy=(.*?)$STOP/;
        next unless defined $id && $id =~ /\S/;   # malformed: no id= at all -- not a marker
        for ($id, $why) { next unless defined $_; s/^\s+//; s/\s+$// }
        push @out, { id => $id, why => (defined $why ? $why : '') };
    }
    return @out;
}

sub marker_resolves {
    my ($marker, $project_root) = @_;
    return 0 unless defined $marker->{id} && length $marker->{id};
    return 0 unless defined $marker->{why} && length $marker->{why};   # why= must be non-empty
    my $path = "$project_root/.ccpraxis-local-data/bug-reports/$marker->{id}.md";
    return -f $path ? 1 : 0;
}

# --- snapshot the REAL project's bug-reports dir, to prove AC14 afterwards --
my $REAL_PROJECT = "$Bin/../../../..";
my $real_bugreports_dir = "$REAL_PROJECT/.ccpraxis-local-data/bug-reports";
my %real_before;
if (opendir(my $dh, $real_bugreports_dir)) {
    %real_before = map { $_ => 1 } grep { /\.md\z/ } readdir($dh);
    closedir $dh;
}

my $TMPPROJECT = tempdir(CLEANUP => 1);

# --- file ONE real report into the scratch project --------------------------
my $body_path = write_body_file("Oracle-filed probe report for AC7/AC10.\nNever real ccpraxis backlog.\n");
my ($file_code, $file_out) = run_almanac(
    'file', '--title', 'AC7/AC10 oracle probe report -- scratch project only',
    '--severity', 'low', '--area', 'butler',
    '--project', $TMPPROJECT, '--body-file', $body_path,
);
is($file_code, 0, 'AC7/AC10 setup: almanac-bug.pl file exits 0 against the scratch project')
    or diag("file output: $file_out");
my ($real_report_path) = $file_out =~ /(\S+\.md)\s*$/;
ok(defined $real_report_path && -f $real_report_path,
   'AC7/AC10 setup: almanac-bug.pl file actually wrote a report file');
my ($real_id) = defined($real_report_path) ? ($real_report_path =~ m{([^/\\]+)\.md$}) : (undef);
ok(defined $real_id && length $real_id, 'AC7/AC10 setup: a real report id was extracted from the printed path');

SKIP: {
    skip 'no real filed report to build a marker against', 8 unless defined $real_id;

    # ---- AC7, branch 1: a marker citing the REAL id resolves --------------
    my $ledger_real = <<"LEDGER";
---
package: scratch
---
# scratch ledger

## Decisions & attempt log

- 2026-08-14T00:00:00Z -- driver -- TOOLING-BUG-FILED: id=$real_id why=exercised by oracle t/152, real filing
LEDGER
    my @markers_real = parse_tooling_bug_filed($ledger_real);
    is(scalar(@markers_real), 1, 'AC7: exactly one marker parsed from the real-id fixture');
    ok(marker_resolves($markers_real[0], $TMPPROJECT),
       'AC7 (true branch): a TOOLING-BUG-FILED marker citing a REAL id resolves to the filed report');

    # ---- AC7, branch 2: a marker citing a FORGED/missing id is rejected ---
    my $ledger_forged = <<"LEDGER";
---
package: scratch
---
# scratch ledger

## Decisions & attempt log

- 2026-08-14T00:00:01Z -- driver -- TOOLING-BUG-FILED: id=99999999-999999-dead why=forged, never actually filed
LEDGER
    my @markers_forged = parse_tooling_bug_filed($ledger_forged);
    is(scalar(@markers_forged), 1, 'AC7: exactly one marker parsed from the forged-id fixture');
    ok(!marker_resolves($markers_forged[0], $TMPPROJECT),
       'AC7 (false branch): a TOOLING-BUG-FILED marker citing a FORGED id is REJECTED, not resolved');

    # Both branches must produce genuinely distinct outcomes -- a checker that
    # always returns the same answer regardless of input would pass either
    # assertion alone but fail this one.
    isnt(marker_resolves($markers_real[0], $TMPPROJECT), marker_resolves($markers_forged[0], $TMPPROJECT),
         'AC7: the real-id and forged-id branches produce DISTINCT outcomes');

    # ---- grammar edge cases (THE BAR: malformed / missing why= / two markers
    #      in one ledger / marker in the wrong section) ---------------------

    # malformed: no "id=" token at all -- must not be picked up as a marker.
    my $ledger_malformed = <<"LEDGER";
## Decisions & attempt log

- 2026-08-14T00:00:02Z -- driver -- TOOLING-BUG-FILED: this is not the grammar at all
LEDGER
    my @markers_malformed = parse_tooling_bug_filed($ledger_malformed);
    is(scalar(@markers_malformed), 0, 'AC7 grammar: a malformed marker (no id=) is not parsed as one');

    # missing why=: real id, but no why= field -- must NOT resolve, even
    # though the id itself is genuine (why= non-empty is part of integrity).
    my $ledger_no_why = <<"LEDGER";
## Decisions & attempt log

- 2026-08-14T00:00:03Z -- driver -- TOOLING-BUG-FILED: id=$real_id
LEDGER
    my @markers_no_why = parse_tooling_bug_filed($ledger_no_why);
    is(scalar(@markers_no_why), 1, 'AC7 grammar: a marker missing why= is still parsed as a marker...');
    ok(!marker_resolves($markers_no_why[0], $TMPPROJECT),
       '...but does NOT resolve, because why= must be non-empty (same rule as MEANS-DEVIATION)');

    # two markers in one ledger: one real, one forged, in the SAME log --
    # both must be found, independently, in order.
    my $ledger_two = <<"LEDGER";
## Decisions & attempt log

- 2026-08-14T00:00:04Z -- driver -- TOOLING-BUG-FILED: id=$real_id why=first, real
- 2026-08-14T00:00:05Z -- driver -- TOOLING-BUG-FILED: id=zzz-forged-zzz why=second, forged
LEDGER
    my @markers_two = parse_tooling_bug_filed($ledger_two);
    is(scalar(@markers_two), 2, 'AC7 grammar: two markers in one ledger are both parsed');
    ok(marker_resolves($markers_two[0], $TMPPROJECT) && !marker_resolves($markers_two[1], $TMPPROJECT),
       'AC7 grammar: of the two, only the real one resolves -- order and independence both hold');

    # marker in the WRONG section (e.g. "## Scope") -- must not be counted at
    # all, even though it is grammatically perfect.
    my $ledger_wrong_section = <<"LEDGER";
## Scope

Some narrative. TOOLING-BUG-FILED: id=$real_id why=perfectly formed, wrong section entirely

## Decisions & attempt log

- 2026-08-14T00:00:06Z -- driver -- nothing relevant here
LEDGER
    my @markers_wrong_section = parse_tooling_bug_filed($ledger_wrong_section);
    is(scalar(@markers_wrong_section), 0,
       'AC7 grammar: a well-formed marker OUTSIDE "## Decisions & attempt log" is not counted');

    # marker inside a fenced code block, even within the right section --
    # must not be counted either (same rule as MEANS-DEVIATION).
    my $ledger_fenced = <<'LEDGER';
## Decisions & attempt log

```
TOOLING-BUG-FILED: id=REALID why=quoted inside a fence, must not count
```
LEDGER
    $ledger_fenced =~ s/REALID/$real_id/;
    my @markers_fenced = parse_tooling_bug_filed($ledger_fenced);
    is(scalar(@markers_fenced), 0,
       'AC7 grammar: a marker inside a fenced code block is never counted, even with a real id');
}

# ---- AC10: `list --project <tmp>` shows the freshly filed title -----------
{
    my ($list_code, $list_out) = run_almanac('list', '--project', $TMPPROJECT);
    is($list_code, 0, 'AC10: almanac-bug.pl list exits 0 against the scratch project');
    like($list_out, qr/AC7\/AC10 oracle probe report/,
         'AC10: the freshly filed title appears in `list` output from the SAME scratch project');
}

# ---- AC14 (self-check): the real project's bug-reports dir gained NOTHING --
{
    my %real_after;
    if (opendir(my $dh, $real_bugreports_dir)) {
        %real_after = map { $_ => 1 } grep { /\.md\z/ } readdir($dh);
        closedir $dh;
    }
    my @new_real_files = grep { !$real_before{$_} } keys %real_after;
    is(scalar(@new_real_files), 0,
       'AC14: this oracle filed nothing into the REAL project bug-reports dir')
        or diag("leaked into real store: @new_real_files");
}

# ---- AC15 (self-check): this oracle file never invokes the `collect` verb --
{
    open my $selffh, '<:raw', $0 or die "cannot re-read self ($0): $!";
    local $/;
    my $self_src = <$selffh>;
    close $selffh;
    # Strip this very sentence and the surrounding comment block so the
    # documentation ABOUT not calling collect doesn't trip its own check.
    my @collect_calls = ($self_src =~ /run_almanac\(\s*'collect'/g);
    is(scalar(@collect_calls), 0, 'AC15: this oracle never calls run_almanac(\'collect\', ...)');
}

done_testing();
