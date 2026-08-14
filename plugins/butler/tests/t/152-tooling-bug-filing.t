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

# heading_pos($text, '## Foo') -> byte offset of that ATX heading as a real
# heading (start of line, nothing after it but whitespace), or -1.
#
# ADDED 2026-08-14 by driver adjudication. Every scan below originally used a
# bare index($text, '## Foo'), which matches the string ANYWHERE -- including
# inside ordinary backticked prose that merely NAMES a heading. That is not a
# hypothetical: coordinator-protocol/SKILL.md legitimately mentions `## Pipeline`
# twice in running text, once inside a list enumerating literal section names.
# index() found the prose mention first, the scan failed, and the implementer
# reasonably reworded the DOCUMENTATION to get the test green -- leaving one
# item in a list of headings formatted unlike its siblings, i.e. the prose got
# worse to suit the oracle.
#
# That is defect shape #5 in this run's catalogue: a malformed oracle shaping
# production code. It already put grep-based workarounds into a live hook once
# (t/142 -> mark-wakeup.sh). The fix belongs in the scan, not in the prose: a
# heading is a line, so match it as one.
# FIX-BATCH (step 7, F5): the version above (driver, 64105de) anchored a
# heading to its own physical line but had two remaining gaps, both found by
# red-team M2/L3 and both currently non-triggering in committed content
# (confirmed by grep before this fix), which is luck rather than design:
#   - no fence-awareness: a line that LOOKS like a heading inside a fenced
#     example block still counted as a real one.
#   - CRLF/BOM fragility: a trailing \r before the line-end anchor, or a BOM
#     as the literal first three bytes of the file, made a real heading on
#     that line invisible.
# Fixed by scanning line-by-line via byte offsets (never split(), which loses
# separator length and would desync the returned offset), toggling a fence
# flag exactly like parse_tooling_bug_filed's marker scan below, stripping a
# trailing \r before matching, and skipping a leading UTF-8 BOM for matching
# purposes only -- the returned offset always indexes the ORIGINAL $text.
sub heading_pos {
    my ($text, $heading) = @_;
    return -1 unless defined $text && defined $heading;
    my $len = length($text);
    my $off = (substr($text, 0, 3) eq "\xEF\xBB\xBF") ? 3 : 0;
    my $fenced = 0;
    while ($off <= $len) {
        my $nl = index($text, "\n", $off);
        my $line_end = ($nl == -1) ? $len : $nl;
        my $line = substr($text, $off, $line_end - $off);
        $line =~ s/\r\z//;
        if ($line =~ /^\s*(?:```|~~~)/) {
            $fenced = !$fenced;
        } elsif (!$fenced && $line =~ /^\Q$heading\E[ \t]*\z/) {
            return $off;
        }
        last if $nl == -1;
        $off = $nl + 1;
    }
    return -1;
}

# ---------------------------------------------------------------------------
# AC1 -- reporter/SKILL.md: "## Filing a ccpraxis tooling bug" before "## Boundaries"
# ---------------------------------------------------------------------------
{
    my $heading = '## Filing a ccpraxis tooling bug';
    my $hpos = heading_pos($reporter_txt, $heading);
    my $bpos = heading_pos($reporter_txt, '## Boundaries');
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
    my $hpos = heading_pos($drivesolo_txt, $heading);
    my $cpos = heading_pos($drivesolo_txt, '## Commit mechanics');
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
    my $hpos = heading_pos($reporter_txt, $heading);
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
    my $mpos = heading_pos($coord_txt, '## Mandated means & deviations');
    my $ppos = heading_pos($coord_txt, '## Pipeline');
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
# FIX-BATCH (step 7, F7 first item, reviewer S1): the CONSTRAINT CONFLICT
# "not gated" assertion above had no ORACLE EDIT mirror -- only a bare
# presence check (qr/ORACLE EDIT/), so the "ORACLE EDIT ... likewise never
# gated" clause could be deleted entirely and this oracle would stay green
# as long as the bare string "ORACLE EDIT" remained anywhere in the section.
# Both halves of AC4 now hold the same shape.
like($prose_vs_mech_section, qr/ORACLE EDIT[^.]{0,400}?\b(not|never)\b[^.]{0,120}?(gate|gated|marker)/is,
     'AC4a: states ORACLE EDIT is not gated (within the same passage)');
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
    # FIX-BATCH (step 7, F7 second item, reviewer S2): the original precondition
    # (qr/why=/, whole-file) was satisfiable by MEANS-DEVIATION's PRE-EXISTING
    # why= alone, so it passed regardless of whether TOOLING-BUG-FILED's OWN
    # grammar line carried why= at all -- it tested nothing about the marker
    # this AC names. Tightened to require id= and why= on the SAME grammar
    # line, which only TOOLING-BUG-FILED's own documented grammar can satisfy.
    like($coord_txt, qr/TOOLING-BUG-FILED:\s*id=[^\n]*\bwhy=/,
         'AC5: the TOOLING-BUG-FILED grammar line itself carries both id= and why=');

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
#
# FIX-BATCH (step 7, F1) note: M1's honesty fix (the "Prose vs. mechanism"
# subsection) deliberately avoids the literal `MEANS-DEVIATION:` token —
# "the deviation marker documented in 'Mandated means & deviations' above" /
# "that deviation marker" / "that other marker" throughout — specifically so
# this pre-existing, unmodified assertion keeps holding without being
# touched. The ORIGINAL MEANS-DEVIATION section remains byte-for-byte
# unedited (confirmed by diff during this fix-batch).
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
# FIX-BATCH (step 7, F4, F6):
#
# F4 -- red-team M1: the original single-match (non-/g) section regex
# captured only the FIRST "## Decisions & attempt log" occurrence, so a
# duplicated heading (a plausible merge/edit artifact -- this run filed a
# real report about exactly this class of accidental duplication,
# 20260814-093030-2d3f, for test file numbers) silently hid every marker
# after the first occurrence: a false negative directly threatening Done
# Criterion 5 ("nothing double-files"), since a worker whose genuine marker
# silently fails to register has every incentive to re-file. DECIDED: union
# ALL occurrences rather than reject the ledger outright -- a marker in ANY
# occurrence of the structurally-mandated heading is a real filing, and
# rejecting the whole ledger would make the failure mode WORSE (every marker
# lost, not just the ones after the first) for a defect this test's own
# authors cannot prevent occurring in a live ledger.
#
# F6 -- red-team M3: a marker inside a single-backtick inline code span (an
# illustrative "e.g. `TOOLING-BUG-FILED: ...`" mention while documenting the
# grammar for a future reader -- verified as a REAL pattern: this run's own
# ledger entries write exactly this kind of illustrative aside) or inside a
# 4-space-indented Markdown code block was counted as a genuine filing.
# THE SINGLE RULE APPLIED: a marker counts only in plain running/list text --
# never inside a fenced code block (unchanged from the original design),
# never inside an inline single-backtick code span (detected by an ODD count
# of backticks preceding the marker on its own line -- standard inline-code-
# span parsing: odd means still inside an unclosed span at that point), and
# never on a line that opens with 4+ spaces of indentation (a Markdown
# indented code block, distinct from a normal ledger bullet which starts at
# column 0). Same family of rule as the fence check two lines above it --
# "is this text or is this an example of text" -- applied consistently to
# every place that question can arise on one line.
sub parse_tooling_bug_filed {
    my ($txt) = @_;
    my @out;
    return @out unless defined $txt && length $txt;
    my @sections = $txt =~ /^##\s+Decisions\s*&\s*attempt\s+log\s*$(.*?)(?=^##\s|\z)/msg;
    return @out unless @sections;
    my $sec = join("\n", @sections);
    my $fenced = 0;
    for my $ln (split /\r?\n/, $sec) {
        $ln =~ s/\r$//;
        if ($ln =~ /^\s*(?:```|~~~)/) { $fenced = !$fenced; next }
        next if $fenced;
        next if $ln =~ /^\s{4,}\S/;   # indented code block -- illustrative, not a marker
        next unless $ln =~ /TOOLING-BUG-FILED:/;
        my $mpos = index($ln, 'TOOLING-BUG-FILED:');
        my $before = substr($ln, 0, $mpos);
        my $backtick_count = () = $before =~ /`/g;
        next if $backtick_count % 2 == 1;   # inside an inline code span -- illustrative mention
        $ln =~ /TOOLING-BUG-FILED:\s*(.*)$/;
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

# FIX-BATCH (step 7, F2, F3): red-team H1/H2 defeated the original version of
# this reference checker with its own reference implementation:
#
# F3 -- H2: `id=` had NO character restriction, so a relative-traversal id
# (`../../evil-planted/forged`) walked straight out of bug-reports/ via naive
# string concatenation (absolute-looking ids already failed safe -- Perl
# concatenation doesn't treat a leading `/` as a path reset -- but relative
# traversal was a live vector). FIXED by constraining `id=` to the exact
# shape `almanac-bug.pl`'s own `AlmanacBug::new_id()` generates
# (`plugins/almanac/scripts/almanac-bug.pl:195-200`:
# `\d{8}-\d{6}-[0-9a-f]{4}`) -- no `/`, `\`, or `.` can ever pass, so
# traversal is rejected by construction, not by path-normalization logic
# that could itself have a bug.
#
# F2 -- H1: a plain `.md` file with NO almanac frontmatter, dropped into
# bug-reports/ by any means other than `almanac-bug.pl file` -- which
# `almanac-bug.pl`'s own `list`/`verify` correctly recognize as "not a
# report" -- was accepted by a bare `-f` as a fully resolved filing, even
# though `almanac-bug.pl list` for the same project shows ZERO reports.
# FIXED by requiring the target to actually BE a report: frontmatter must
# parse, its own `id:` field must match the marker's `id=` (closing the loop
# H1 identified as the single missing check), and it must carry a non-empty
# `status:` -- not merely that some file exists at the naively-derived path.
sub marker_resolves {
    my ($marker, $project_root) = @_;
    return 0 unless defined $marker->{id} && length $marker->{id};
    return 0 unless defined $marker->{why} && length $marker->{why};   # why= must be non-empty
    return 0 unless $marker->{id} =~ /^\d{8}-\d{6}-[0-9a-f]{4}$/;      # F3: reject traversal by construction
    my $path = "$project_root/.ccpraxis-local-data/bug-reports/$marker->{id}.md";
    return 0 unless -f $path;
    open my $fh, '<:raw', $path or return 0;
    local $/;
    my $content = <$fh>;
    close $fh;
    return 0 unless defined $content && $content =~ /\A---\r?\n(.*?)\r?\n---\r?\n/s;
    my $fm = $1;
    my %f;
    for my $line (split /\r?\n/, $fm) {
        next unless $line =~ /^([A-Za-z0-9_]+):\s*(.*)$/;
        $f{$1} = $2;
    }
    return 0 unless defined $f{id} && $f{id} eq $marker->{id};        # F2: frontmatter id must match
    return 0 unless defined $f{status} && length $f{status};          # F2: must actually be a report
    return 1;
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
    skip 'no real filed report to build a marker against', 26 unless defined $real_id;

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

    # =========================================================================
    # FIX-BATCH (step 7) -- F2, F3, F4, F5, F6: exercised, adversarial coverage
    # added against the reviewer/red-team findings. Each block below FAILS if
    # the corresponding fix in marker_resolves()/parse_tooling_bug_filed()/
    # heading_pos() is reverted -- confirmed during this fix-batch.
    # =========================================================================

    # ---- F2 (H1): a plain .md with NO almanac frontmatter is REJECTED, even
    #      though a bare -f would have accepted it and almanac-bug.pl list
    #      agrees nothing was ever filed for that id. ------------------------
    my $junk_id = '20990101-000000-dead';   # valid id= GRAMMAR, never actually filed
    my $bugreports_dir = "$TMPPROJECT/.ccpraxis-local-data/bug-reports";
    ok(-d $bugreports_dir || mkdir($bugreports_dir), 'F2 setup: bug-reports dir exists in scratch project')
        or diag("mkdir failed: $!");
    open(my $junk_fh, '>:raw', "$bugreports_dir/$junk_id.md") or die "cannot write junk fixture: $!";
    print {$junk_fh} "not a real almanac report -- no frontmatter, never filed via almanac-bug.pl\n";
    close $junk_fh;
    my ($junk_code, $junk_list_out) = run_almanac('list', '--project', $TMPPROJECT);
    is($junk_code, 0, 'F2 setup: almanac-bug.pl list still exits 0 with the junk file present');
    unlike($junk_list_out, qr/\Q$junk_id\E/,
           'F2 setup precondition: almanac-bug.pl itself does NOT count the junk file as a report');
    my $marker_junk = { id => $junk_id, why => 'planted junk file, never filed' };
    ok(!marker_resolves($marker_junk, $TMPPROJECT),
       'F2: marker_resolves REJECTS a plain .md with no almanac frontmatter, unlike a bare -f check');

    # ---- F3 (H2): a relative-traversal id= is REJECTED outright, by grammar,
    #      before any filesystem check even runs. ---------------------------
    mkdir "$TMPPROJECT/evil-planted";
    open(my $evil_fh, '>:raw', "$TMPPROJECT/evil-planted/forged.md") or die "cannot write evil fixture: $!";
    print {$evil_fh} "this is not a real almanac report, never filed, no frontmatter\n";
    close $evil_fh;
    my $marker_traversal = { id => '../../evil-planted/forged', why => 'path traversal attempt' };
    ok(!marker_resolves($marker_traversal, $TMPPROJECT),
       'F3: marker_resolves REJECTS a relative-traversal id= outright');
    # A well-formed real id continues to resolve after the grammar check was
    # added -- the fix narrows what's ACCEPTED, it doesn't break the true case.
    ok(marker_resolves({ id => $real_id, why => 'still resolves after F3' }, $TMPPROJECT),
       'F3 regression guard: a genuinely well-formed id still resolves after the grammar constraint');

    # ---- F4: a duplicated "## Decisions & attempt log" heading no longer
    #      hides a marker that lives only in the SECOND occurrence. ---------
    my $ledger_dup_heading = <<"LEDGER";
## Decisions & attempt log

- 2026-08-14T00:00:07Z -- driver -- first copy, no marker here

## Something else

## Decisions & attempt log

- 2026-08-14T00:00:08Z -- driver -- TOOLING-BUG-FILED: id=$real_id why=marker only in the SECOND occurrence
LEDGER
    my @markers_dup_heading = parse_tooling_bug_filed($ledger_dup_heading);
    is(scalar(@markers_dup_heading), 1,
       'F4: a marker inside the SECOND occurrence of a duplicated heading is still found');
    ok(@markers_dup_heading && marker_resolves($markers_dup_heading[0], $TMPPROJECT),
       'F4: and it resolves, because it cites the real id');

    # ---- F6: an illustrative, backtick-quoted mention of the marker (while
    #      documenting the grammar for a future reader) is NOT counted, even
    #      though it sits on a real ledger bullet line in the right section.
    my $ledger_illustrative = <<"LEDGER";
## Decisions & attempt log

- 2026-08-14T00:00:09Z -- driver -- documented the grammar for later use, e.g. \`TOOLING-BUG-FILED: id=$real_id why=illustrative example only, never actually meant as a real filing\`
LEDGER
    my @markers_illustrative = parse_tooling_bug_filed($ledger_illustrative);
    is(scalar(@markers_illustrative), 0,
       'F6: an inline-backtick-quoted illustrative mention of the marker is not counted as a real filing');

    # ---- F6: a 4-space-indented Markdown code block quoting the marker is
    #      also not counted. -------------------------------------------------
    my $ledger_indented = <<"LEDGER";
## Decisions & attempt log

Example ledger line:

    TOOLING-BUG-FILED: id=$real_id why=indented example, not a real bullet
LEDGER
    my @markers_indented = parse_tooling_bug_filed($ledger_indented);
    is(scalar(@markers_indented), 0,
       'F6: a 4-space-indented illustrative code block is not counted as a real filing');

    # ---- F5: heading_pos() is fence-aware -- a line that LOOKS like a
    #      heading inside a fenced example block is not a real heading. -----
    my $fenced_heading_doc = "# Title\n\n```\nExample doc structure:\n## Boundaries\n```\n\nSome real content.\n## Boundaries\nReal section body.\n";
    my $fence_aware_pos = heading_pos($fenced_heading_doc, '## Boundaries');
    ok($fence_aware_pos >= 0, 'F5: heading_pos still finds the REAL heading after the fenced example');
    my $real_heading_offset = index($fenced_heading_doc, "## Boundaries\nReal section body");
    is($fence_aware_pos, $real_heading_offset,
       'F5: heading_pos skips the fenced false positive and returns the REAL heading\'s offset');

    # ---- F5: heading_pos() tolerates CRLF line endings on the heading line.
    my $crlf_doc = "# Title\r\n\r\n## Boundaries\r\nReal content.\r\n";
    ok(heading_pos($crlf_doc, '## Boundaries') >= 0,
       'F5: heading_pos matches a heading whose line ends in CRLF, not just LF');

    # ---- F5: heading_pos() tolerates a UTF-8 BOM as the literal first bytes.
    my $bom_doc = "\xEF\xBB\xBF## Boundaries\nReal content.\n";
    ok(heading_pos($bom_doc, '## Boundaries') >= 0,
       'F5: heading_pos matches a heading immediately preceded by a UTF-8 BOM as the file\'s first bytes');
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
