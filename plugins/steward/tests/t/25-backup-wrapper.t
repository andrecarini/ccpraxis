#!/usr/bin/env perl
# 25-backup-wrapper.t -- oracle for blueprint backup-driver, package
# 06-skill-becomes-wrapper (plugins/steward/skills/backup/SKILL.md, rewritten).
#
# Spec: .ccpraxis-local-data/blueprints/backup-driver/specs/06-skill-becomes-wrapper-spec.md
#
# Written BLIND to any rewritten implementation of SKILL.md: only the spec, the
# Decision-14 snapshot (reports/skill-before.md), the shipped four parity files
# (reports/parity/02..05-*.md), the shipped scripts/backup/Run.pm (read at
# runtime for its enum, never copied), and the sibling oracle t/24's
# require()/StewardTest/_compile_check idiom were read. This file does not read
# any phase module (Preflight/Export/Vault/Closeout.pm) and does not write or
# assume any future content of SKILL.md.
#
# UNLIKE its four siblings (t/20-24): there is no driver to spawn here, no
# fixture to stub, no encoding boundary to police. This oracle tests PROSE AND
# STRUCTURE -- it parses SKILL.md's frontmatter and body as text, reads
# @Backup::Run::DECISION_KINDS out of the shipped Run.pm at runtime, and parses
# reports/parity/*.md mechanically against the step headings extracted from
# reports/skill-before.md. No StewardTest scratch-vault/spawn helpers
# (make_machine/run_vs/init_remote/temproot/write_text) are imported because
# nothing here spawns a process or writes a scratch fixture to disk -- only
# `ok`/`is`/`like`/`unlike`/`diag`/`done_testing`/`read_text`/`path_exists` are
# used, plus a local File::Temp-backed perl -c self-check (t/24's idiom, never
# an in-memory STDERR dup, never a NUL redirect).
#
# Two hard constraints observed throughout this file's own source (not just its
# assertions):
#   1. No literal copy of @Backup::Run::DECISION_KINDS -- AC10/AC11's whole
#      point is that a 15th kind added to Run.pm must fail this test until
#      SKILL.md documents it, which a hard-coded copy would defeat. The one
#      exception is 'step_failure', named directly because AC12 specifically
#      requires checking THAT kind's row (a single named criterion, not a copy
#      of the list) -- exactly as this package's dispatch explicitly asked for.
#   2. No literal copy of the 15 step ids either -- they are extracted from
#      reports/skill-before.md's own text at runtime (Decision 14: that file is
#      the on-disk source of truth), with the single exception of the literal
#      'R' (again a single named criterion, AC16, not a copy of the list).
#   3. The name of the git subcommand that shelves uncommitted work is never
#      spelled anywhere in this file's source, including comments -- AC9 (no fenced-block line begins
#      with `git`) makes that check unnecessary to spell out, and spelling it
#      risks tripping guard-git-mutations.sh on any Bash command that later
#      greps this file's own text.
#
# AC -> test name mapping (grep "AC<n>:" for every assertion of a given
# criterion):
#   AC1  frontmatter: line 1 is '---', a later '---' closes it, name == backup,
#        description present/non-empty/single-line
#   AC2  user-invocable: true and host-only: true both present
#   AC3  allowed-tools parses to exactly {Bash, AskUserQuestion, Skill};
#        Read/Write/Edit absent
#   AC4  no line matches ^#{1,6}\s+Step\s
#   AC5  all six required headings of spec S2.5 present verbatim
#   AC6  SKILL.md is <= 250 lines
#   AC7  *.pl token set subset of {backup.pl, claude-binary-backup.pl}; every
#        claude-binary-backup.pl occurrence is after the
#        '## Snapshot/revert mode' heading
#   AC8  each of the eleven retired script names is absent
#   AC9  no line inside a fenced code block begins with `git`
#   AC10 Run.pm loaded at runtime via require(); @Backup::Run::DECISION_KINDS
#        read directly, never hard-coded (see header note above)
#   AC11 '## Presenting decisions' table's first-cell values == the enum, as a
#        SET (every enum value present, no extra rows)
#   AC12 'step_failure' specifically has a row with non-empty cells 2 and 3
#   AC13 the 4-cell (parity-shape) table parser trims whitespace, proven by
#        parsing a padded and an unpadded SYNTHETIC row to identical results
#   AC14 '## Snapshot/revert mode' exists and names list/detect/restore/verify
#   AC15 reports/parity/06-skill-becomes-wrapper.md exists, parses to >=1 row,
#        has a row (R, wrapper, plugins/steward/skills/backup/SKILL.md)
#   AC16 exactly 15 step ids extracted from reports/skill-before.md via S2.9's
#        regex, R among them
#   AC17 union of step cells across reports/parity/*.md covers all 15 ids
#   AC18 every reports/parity/*.md file yields >=1 parsed row
#   AC19 a padded row (02's real file) and an unpadded row (03/04/05's real
#        files) both parse via the SAME parser -- against real files, not only
#        synthetic input
#   AC20 every parsed parity row's phase cell is one of
#        {preflight, export, vault, closeout, wrapper}
#   AC21 every parsed parity row's module cell names a path that exists,
#        relative to the repo root
#   AC22 the 06 parity file states Step 1 was defective (a repo hook denies the
#        command as written) and that dirty_worktree is a deliberate change,
#        not preserved behaviour
#   AC23 SKILL.md documents all seven exit codes (0,1,2,3,4,10,20) and what the
#        wrapper does on each; extra checks (not separately numbered by the
#        spec, requested by the parent task) for the exit-4/consumed_seq
#        retry-legitimacy detail and exit-3 token_replayed terminality
#   AC24 '## Relaying the report' states unit_failures (not degraded) decides
#        whether the operator is told something went wrong
#   AC25 '## Follow-up actions' names all four action values and assigns each
#        the perform/relay/inform obligation of S2.4
#   AC26 this file is perl -c clean (self-check below); the "zero exit, zero
#        not ok lines" half of AC26 is a property of the FINAL implemented
#        state and is verified by running this file after the wrapper exists,
#        not by an assertion inside the file (that would be circular)
#
# ===========================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use StewardTest qw(ok is like unlike diag done_testing read_text path_exists);

my $SKILL_MD    = "$Bin/../../skills/backup/SKILL.md";
my $RUNPM       = "$Bin/../../../../scripts/backup/Run.pm";
my $SNAPSHOT    = "$Bin/../../../../.ccpraxis-local-data/blueprints/backup-driver/reports/skill-before.md";
my $PARITY_DIR  = "$Bin/../../../../.ccpraxis-local-data/blueprints/backup-driver/reports/parity";
my $PARITY_06   = "$PARITY_DIR/06-skill-becomes-wrapper.md";
my $REPO_ROOT   = abs_path("$Bin/../../../..") // "$Bin/../../../..";

# ===========================================================================
# Self-check: this file is perl -c clean (AC26, first half).
# ===========================================================================
sub _compile_check {
    my ($file, $label) = @_;
    unless (-f $file) {
        ok(0, "AC26: perl -c is clean on $label (file not found)");
        return;
    }
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR: $!";
    my $rc = system($^X, '-c', $file);
    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;
    my $err = read_text($ename) // '';
    unlink $ename;
    ok($rc == 0, "AC26: perl -c exits 0 for $label") or diag($err);
    unlike($err, qr/syntax error|Compilation failed/, "AC26: perl -c on $label reports no syntax error / compilation failure")
        or diag($err);
}
_compile_check("$Bin/25-backup-wrapper.t", 'plugins/steward/tests/t/25-backup-wrapper.t (this file)');

# ===========================================================================
# Generic markdown-table helpers.
# ===========================================================================

# _raw_row_cells($line) -> \@cells (untrimmed, split on the ORIGINAL line) or
# undef if the line, with leading whitespace stripped, does not begin with '|'.
# This is deliberately the exact shape of spec S2.8's algorithm, generalised
# only to accept any cell count (the caller filters by count).
sub _raw_row_cells {
    my ($line) = @_;
    (my $stripped = $line) =~ s/^\s+//;
    return undef unless length($stripped) && substr($stripped, 0, 1) eq '|';
    my @cells = split /\|/, $line, -1;
    shift @cells;                                    # empty piece before first pipe
    pop @cells if @cells && $cells[-1] =~ /^\s*\z/;   # piece after final pipe
    return \@cells;
}

# parse_parity_rows($text) -> list of [old_step, phase, module, note]
#
# Exactly spec S2.8's algorithm (Decision 13 / ruling P19): 4 cells, TRIM every
# cell, skip the 'old step' header row and any dashed separator row.
sub parse_parity_rows {
    my ($text) = @_;
    my @rows;
    for my $line (split /\n/, $text) {
        my $cells = _raw_row_cells($line) or next;
        next unless @$cells == 4;
        s/^\s+|\s+\z//g for @$cells;
        next if lc($cells->[0]) eq 'old step';
        next if $cells->[0] =~ /^:?-{2,}:?\z/;
        push @rows, $cells;
    }
    return @rows;
}

# parse_decision_rows($text) -> list of [kind, what_it_is, how_to_present]
#
# Same trimming discipline as parse_parity_rows (spec B17: "the same trimming
# discipline as S2.8"), narrowed to 3 cells and a 'kind' header.
sub parse_decision_rows {
    my ($text) = @_;
    my @rows;
    for my $line (split /\n/, $text) {
        my $cells = _raw_row_cells($line) or next;
        next unless @$cells == 3;
        s/^\s+|\s+\z//g for @$cells;
        next if lc($cells->[0]) eq 'kind';
        next if $cells->[0] =~ /^:?-{2,}:?\z/;
        push @rows, $cells;
    }
    return @rows;
}

# extract_section($content, $heading_line) -> substring from just after
# $heading_line (matched as an EXACT whole line) up to (not including) the
# next '## '-level heading, or EOF. undef if the heading line is not found.
sub extract_section {
    my ($content, $heading_line) = @_;
    my @lines = split /\n/, $content, -1;
    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] eq $heading_line) { $start = $i; last; }
    }
    return undef unless defined $start;
    my $end = $#lines;
    for my $i (($start + 1) .. $#lines) {
        if ($lines[$i] =~ /^##\s+\S/) { $end = $i - 1; last; }
    }
    return $end >= $start + 1 ? join("\n", @lines[($start + 1) .. $end]) : '';
}

# ===========================================================================
# AC13: the parity-shape (4-cell) parser trims whitespace -- proven on
# SYNTHETIC padded vs. unpadded rows describing the same conceptual data.
# ===========================================================================
{
    my $padded   = "| 9 | wrapper | some/module.pm | a note |\n";
    my $unpadded = "|9|wrapper|some/module.pm|a note|\n";
    my @p_rows = parse_parity_rows($padded);
    my @u_rows = parse_parity_rows($unpadded);
    is(scalar(@p_rows), 1, 'AC13: synthetic padded row yields exactly 1 parsed row'); # shape-lint: intentional -- fixture the test built (N=1), not a shared artifact
    is(scalar(@u_rows), 1, 'AC13: synthetic unpadded row yields exactly 1 parsed row'); # shape-lint: intentional -- fixture the test built (N=1), not a shared artifact
    if (@p_rows && @u_rows) {
        is(join("\x1f", @{$p_rows[0]}), join("\x1f", @{$u_rows[0]}),
            'AC13: padded and unpadded synthetic rows parse to IDENTICAL cell values');
    } else {
        ok(0, 'AC13: padded and unpadded synthetic rows parse to IDENTICAL cell values (a variant produced zero rows)');
    }
}

# ===========================================================================
# AC16: exactly 15 step ids extracted from reports/skill-before.md via
# STEP_RE = /^##\s+Step\s+([^:\s]+)\s*:/ (spec S2.9), R among them.
# ===========================================================================
my @SNAPSHOT_STEPS;
{
    my $snap = read_text($SNAPSHOT);
    ok(defined($snap) && length($snap), 'AC16: reports/skill-before.md is readable and non-empty (Decision 14 snapshot)');
    if (defined $snap) {
        for my $line (split /\n/, $snap) {
            if ($line =~ /^##\s+Step\s+([^:\s]+)\s*:/) {
                push @SNAPSHOT_STEPS, $1;
            }
        }
    }
    is(scalar(@SNAPSHOT_STEPS), 15, 'AC16: skill-before.md yields exactly 15 step ids via S2.9\'s regex'); # shape-lint: intentional -- Decision 14 snapshot is a deliberately frozen artifact; AC16 exists to make tampering fail loudly (spec S6, out of scope: "Editing reports/skill-before.md")
    my %snap_has = map { $_ => 1 } @SNAPSHOT_STEPS;
    ok($snap_has{R}, 'AC16: \'R\' is among the 15 extracted step ids');
}

# ===========================================================================
# Load Run.pm at runtime and read the enum directly (AC10).
# ===========================================================================
my $RUNPM_OK = eval { require $RUNPM; 1 };
ok($RUNPM_OK, 'AC10: scripts/backup/Run.pm loads via require() at runtime') or diag($@ // 'unknown error');
my @KINDS;
{
    no warnings 'once'; # @Backup::Run::DECISION_KINDS is read exactly once, deliberately, at runtime
    @KINDS = $RUNPM_OK ? @Backup::Run::DECISION_KINDS : ();
}
ok(scalar(@KINDS) > 0, 'AC10: @Backup::Run::DECISION_KINDS is non-empty after require (read directly, never copied in this file\'s source)');

# ===========================================================================
# Read SKILL.md (once) and split into lines for the rest of this file.
# ===========================================================================
my $SKILL_CONTENT = read_text($SKILL_MD);
ok(defined($SKILL_CONTENT) && length($SKILL_CONTENT), 'sanity: plugins/steward/skills/backup/SKILL.md is readable and non-empty')
    or diag("could not read $SKILL_MD");
$SKILL_CONTENT //= '';
my @SKILL_LINES = split /\n/, $SKILL_CONTENT, -1;

# ===========================================================================
# AC1: frontmatter opens on line 1 with '---', closes with a later '---',
# name == backup, description present/non-empty/single-line.
# ===========================================================================
my ($FRONTMATTER, $FM_CLOSE_IDX);
{
    my $opens = @SKILL_LINES && $SKILL_LINES[0] eq '---';
    ok($opens, 'AC1: SKILL.md frontmatter opens on line 1 with \'---\'');

    my $close_idx;
    if ($opens) {
        for my $i (1 .. $#SKILL_LINES) {
            if ($SKILL_LINES[$i] eq '---') { $close_idx = $i; last; }
        }
    }
    ok(defined($close_idx) && $close_idx > 0, 'AC1: SKILL.md frontmatter closes with a later \'---\'');
    $FM_CLOSE_IDX = $close_idx;

    my %fm;
    if ($opens && defined $close_idx) {
        for my $i (1 .. $close_idx - 1) {
            if ($SKILL_LINES[$i] =~ /^([A-Za-z][A-Za-z0-9_-]*):\s?(.*)\z/) {
                my ($k, $v) = ($1, $2);
                $fm{$k} = $v unless exists $fm{$k}; # first occurrence wins
            }
        }
    }
    $FRONTMATTER = \%fm;

    is($fm{name}, 'backup', 'AC1: frontmatter name == backup');
    my $desc = $fm{description};
    ok(defined($desc) && length($desc) > 0, 'AC1: frontmatter description is present and non-empty');
    ok(defined($desc) && $desc !~ /^[|>]/, 'AC1: frontmatter description is a single-line scalar (not a YAML block scalar)');
}

# ===========================================================================
# AC2: user-invocable: true and host-only: true are both still present.
# ===========================================================================
{
    is($FRONTMATTER->{'user-invocable'}, 'true', 'AC2: frontmatter user-invocable == true');
    is($FRONTMATTER->{'host-only'}, 'true', 'AC2: frontmatter host-only == true (driver targets the live host install)');
}

# ===========================================================================
# AC3: allowed-tools parses to exactly {Bash, AskUserQuestion, Skill};
# Read/Write/Edit are absent.
# ===========================================================================
{
    my $raw = $FRONTMATTER->{'allowed-tools'};
    ok(defined($raw) && length($raw), 'AC3: frontmatter allowed-tools is present');
    my @got = defined($raw) ? map { s/^\s+|\s+\z//gr } split(/,/, $raw) : ();
    my %got = map { $_ => 1 } @got;
    my @want = qw(Bash AskUserQuestion Skill);
    for my $w (@want) {
        ok($got{$w}, "AC3: allowed-tools contains '$w'");
    }
    my %want_set = map { $_ => 1 } @want;
    my @extra = grep { !$want_set{$_} } @got;
    is(scalar(@extra), 0, 'AC3: allowed-tools contains no tool outside {Bash, AskUserQuestion, Skill}') # shape-lint: intentional -- a closed interface contract given verbatim by spec S2.5, not an extensible enum
        or diag('extra tools: ' . join(', ', @extra));
    for my $forbidden (qw(Read Write Edit)) {
        ok(!$got{$forbidden}, "AC3: allowed-tools does not contain '$forbidden'");
    }
}

# ===========================================================================
# AC4: no line of SKILL.md matches ^#{1,6}\s+Step\s
# ===========================================================================
{
    my @offenders = grep { $SKILL_LINES[$_] =~ /^#{1,6}\s+Step\s/ } (0 .. $#SKILL_LINES);
    is(scalar(@offenders), 0, 'AC4: no line of SKILL.md matches ^#{1,6}\\s+Step\\s (the numbered protocol is gone)')
        or diag('offending lines: ' . join(', ', map { $_ + 1 } @offenders));
}

# ===========================================================================
# AC5: all six required headings of spec S2.5 are present verbatim.
# ===========================================================================
my @REQUIRED_HEADINGS = (
    '## Modes',
    '## Running the driver',
    '## Presenting decisions',
    '## Relaying the report',
    '## Follow-up actions',
    '## Snapshot/revert mode',
);
{
    my %present = map { $_ => 1 } @SKILL_LINES;
    for my $h (@REQUIRED_HEADINGS) {
        ok($present{$h}, "AC5: required heading '$h' is present verbatim as its own line");
    }
}

# ===========================================================================
# AC6: SKILL.md is <= 250 lines (coarse regression guard against a protocol
# reworded rather than deleted -- the snapshot is 575 lines).
# ===========================================================================
{
    my $n = scalar(@SKILL_LINES);
    ok($n <= 250, "AC6: SKILL.md is <= 250 lines (has $n)");
}

# ===========================================================================
# AC7 / AC8: script-invocation surface.
# ===========================================================================
{
    # AC7a: every *.pl token found anywhere in SKILL.md is one of the two
    # scripts the wrapper is allowed to invoke directly.
    my %ALLOWED_PL = map { $_ => 1 } ('backup.pl', 'claude-binary-backup.pl');
    my %seen_pl;
    while ($SKILL_CONTENT =~ /\b([A-Za-z0-9._-]+\.pl)\b/g) {
        $seen_pl{$1}++;
    }
    for my $tok (sort keys %seen_pl) {
        ok($ALLOWED_PL{$tok}, "AC7: *.pl token '$tok' found in SKILL.md is one of {backup.pl, claude-binary-backup.pl}");
    }

    # AC7b: every claude-binary-backup.pl occurrence is after the
    # '## Snapshot/revert mode' heading.
    my $heading = '## Snapshot/revert mode';
    my $heading_off = index($SKILL_CONTENT, $heading);
    ok($heading_off >= 0, "AC7: '$heading' heading text is findable (needed to order claude-binary-backup.pl occurrences)");
    if ($heading_off >= 0) {
        my $pos = -1;
        my $any = 0;
        while (1) {
            $pos = index($SKILL_CONTENT, 'claude-binary-backup.pl', $pos + 1);
            last if $pos < 0;
            $any = 1;
            ok($pos > $heading_off, "AC7: claude-binary-backup.pl occurrence at offset $pos is after the '$heading' heading (offset $heading_off)");
        }
        ok($any, 'AC7: claude-binary-backup.pl is invoked at least once, in the revert mode');
    } else {
        ok(0, "AC7: every claude-binary-backup.pl occurrence is after '$heading' (heading not found)");
    }

    # AC8: each of the eleven retired script names is absent.
    my @RETIRED = (
        'sync-export.pl', 'sensitive-check.pl', 'ccpraxis-helpers.pl',
        'json-diff.pl', 'filter-diff.pl', 'save-preference.pl',
        'lint-readme-paths.pl', 'gen-readme-tree.pl', 'vault-sync.pl',
        'todo-sync.pl', 'check-plugins.pl',
    );
    for my $script (@RETIRED) {
        unlike($SKILL_CONTENT, qr/\Q$script\E/, "AC8: retired script '$script' is absent from SKILL.md");
    }
}

# ===========================================================================
# AC9: no line inside a fenced code block begins with `git` (the driver owns
# every git operation; this is what stops the snapshot's unrunnable Step 1
# language from being carried forward).
# ===========================================================================
{
    my $in_fence = 0;
    my @offenders;
    for my $i (0 .. $#SKILL_LINES) {
        my $line = $SKILL_LINES[$i];
        (my $stripped = $line) =~ s/^\s+//;
        if ($stripped =~ /^```/) {
            $in_fence = !$in_fence;
            next;
        }
        next unless $in_fence;
        push @offenders, $i + 1 if $stripped =~ /^git(?:\s|\z)/;
    }
    is(scalar(@offenders), 0, 'AC9: no line inside a fenced code block begins with \'git\'')
        or diag('offending SKILL.md lines: ' . join(', ', @offenders));
}

# ===========================================================================
# AC11 / AC12: the '## Presenting decisions' table.
# ===========================================================================
{
    my $section = extract_section($SKILL_CONTENT, '## Presenting decisions');
    ok(defined($section), "AC11: '## Presenting decisions' section is findable");
    my @rows = defined($section) ? parse_decision_rows($section) : ();
    ok(scalar(@rows) > 0, 'AC11: the presentation table under \'## Presenting decisions\' yields at least one parsed row');

    my %row_by_kind;
    for my $r (@rows) {
        $row_by_kind{ $r->[0] } = $r;
    }

    # Set equality: every enum value present (AC11a) ...
    for my $kind (@KINDS) {
        ok(exists $row_by_kind{$kind}, "AC11: enum kind '$kind' has a row in the presentation table");
    }
    # ... and no row names a kind outside the enum (AC11b, catches a rename).
    my %kind_set = map { $_ => 1 } @KINDS;
    for my $r (@rows) {
        ok($kind_set{ $r->[0] }, "AC11: presentation table row '$r->[0]' names a value that is actually in the enum");
    }

    # Every row has non-empty second and third cells.
    for my $r (@rows) {
        ok(defined($r->[1]) && length($r->[1]), "AC11: presentation table row '$r->[0]' has a non-empty 'what it is' cell");
        ok(defined($r->[2]) && length($r->[2]), "AC11: presentation table row '$r->[0]' has a non-empty 'how to present it' cell");
    }

    # AC12: step_failure specifically. (Named directly per this package's
    # dispatch instructions -- a single criterion-named literal, not a copy of
    # the enum: it is declared in Run.pm and emitted by no phase, the
    # documented pressure-relief valve from package 01's ruling.)
    my $sf = $row_by_kind{step_failure};
    ok(defined($sf), "AC12: 'step_failure' specifically has a row in the presentation table");
    if (defined $sf) {
        ok(length($sf->[1]) > 0, "AC12: 'step_failure' row has a non-empty 'what it is' cell");
        ok(length($sf->[2]) > 0, "AC12: 'step_failure' row has a non-empty 'how to present it' cell");
    } else {
        ok(0, "AC12: 'step_failure' row has a non-empty 'what it is' cell (no row)");
        ok(0, "AC12: 'step_failure' row has a non-empty 'how to present it' cell (no row)");
    }
}

# ===========================================================================
# AC14: '## Snapshot/revert mode' exists and names list/detect/restore/verify.
# ===========================================================================
{
    my $section = extract_section($SKILL_CONTENT, '## Snapshot/revert mode');
    ok(defined($section), "AC14: '## Snapshot/revert mode' heading exists (with a body)");
    $section //= '';
    like($section, qr/\blist\b/, "AC14: '## Snapshot/revert mode' names 'list'");
    like($section, qr/\bdetect\b/, "AC14: '## Snapshot/revert mode' names 'detect'");
    like($section, qr/\brestore\b/, "AC14: '## Snapshot/revert mode' names 'restore'");
    like($section, qr/\bverify\b/, "AC14: '## Snapshot/revert mode' names 'verify'");
}

# ===========================================================================
# Parse ALL reports/parity/*.md files once (shared by AC15/17/18/19/20/21/22).
# ===========================================================================
my @PARITY_FILES = sort glob("$PARITY_DIR/*.md");
ok(scalar(@PARITY_FILES) > 0, 'sanity: at least one reports/parity/*.md file is found by the glob');

my %rows_by_file;      # basename -> arrayref of [step, phase, module, note]
my %union_steps;       # step-cell (trimmed) -> 1, across ALL parity files
my @ALL_PARITY_ROWS;   # flat list of [file_basename, step, phase, module, note]

for my $f (@PARITY_FILES) {
    my $base = $f;
    $base =~ s{.*[\\/]}{};
    my $text = read_text($f);
    my @rows = defined($text) ? parse_parity_rows($text) : ();
    $rows_by_file{$base} = \@rows;
    for my $r (@rows) {
        $union_steps{ $r->[0] } = 1;
        push @ALL_PARITY_ROWS, [$base, @$r];
    }
}

# ===========================================================================
# AC18: every reports/parity/*.md file yields >= 1 parsed row (a mis-shaped
# file must fail, not silently contribute nothing).
# ===========================================================================
for my $base (sort keys %rows_by_file) {
    ok(scalar(@{ $rows_by_file{$base} }) >= 1, "AC18: reports/parity/$base parses to at least 1 row");
}

# ===========================================================================
# AC19: a padded row (02's REAL file) and an unpadded row (03/04/05's REAL
# files) both parse via the SAME parser -- proven against the real files, not
# only synthetic input (AC13 already covers synthetic; this covers real).
# ===========================================================================
{
    my ($padded_file) = grep { /^02-/ } sort keys %rows_by_file;
    my @unpadded_candidates = grep { /^0[345]-/ } sort keys %rows_by_file;

    ok(defined($padded_file), 'AC19: a package-02 parity file (the padded-cell producer) is found on disk');
    ok(scalar(@unpadded_candidates) > 0, 'AC19: at least one package-03/04/05 parity file (an unpadded-cell producer) is found on disk');

    if (defined $padded_file) {
        ok(scalar(@{ $rows_by_file{$padded_file} }) >= 1,
            "AC19: the real padded-cell file ($padded_file) parses to >= 1 row via parse_parity_rows");
    } else {
        ok(0, 'AC19: the real padded-cell file (02-*.md) parses to >= 1 row via parse_parity_rows (file not found)');
    }
    for my $u (@unpadded_candidates) {
        ok(scalar(@{ $rows_by_file{$u} }) >= 1,
            "AC19: the real unpadded-cell file ($u) parses to >= 1 row via the SAME parse_parity_rows");
    }
}

# ===========================================================================
# AC15: reports/parity/06-skill-becomes-wrapper.md exists, parses to >= 1 row,
# and contains a row (R, wrapper, plugins/steward/skills/backup/SKILL.md).
# ===========================================================================
{
    ok(path_exists($PARITY_06), 'AC15: reports/parity/06-skill-becomes-wrapper.md exists');
    my $text = read_text($PARITY_06);
    my @rows = defined($text) ? parse_parity_rows($text) : ();
    ok(scalar(@rows) >= 1, 'AC15: reports/parity/06-skill-becomes-wrapper.md parses to at least 1 row');
    my ($r_row) = grep { $_->[0] eq 'R' && $_->[1] eq 'wrapper' } @rows;
    ok(defined($r_row), 'AC15: a row exists with step cell \'R\' and phase cell \'wrapper\'');
    if (defined $r_row) {
        is($r_row->[2], 'plugins/steward/skills/backup/SKILL.md',
            'AC15: the R/wrapper row\'s module cell is plugins/steward/skills/backup/SKILL.md');
    } else {
        ok(0, 'AC15: the R/wrapper row\'s module cell is plugins/steward/skills/backup/SKILL.md (no such row)');
    }
}

# ===========================================================================
# AC17: the union of step cells across ALL reports/parity/*.md files covers
# all 15 step ids extracted from reports/skill-before.md (AC16, above).
# Rows whose step cell is not among the 15 (e.g. '5.5.a') are permitted as
# refinements and are simply ignored here -- only coverage of the 15 matters.
# ===========================================================================
for my $step (@SNAPSHOT_STEPS) {
    ok(exists $union_steps{$step}, "AC17: step '$step' is covered by some reports/parity/*.md file");
}

# ===========================================================================
# AC20: every parsed parity row's phase cell is one of
# {preflight, export, vault, closeout, wrapper} -- a closed set fixed by
# spec S2.10 ("wrapper is a legal value... alongside the four driver phases").
# ===========================================================================
{
    my %ALLOWED_PHASE = map { $_ => 1 } qw(preflight export vault closeout wrapper);
    for my $row (@ALL_PARITY_ROWS) {
        my ($base, $step, $phase, $module, $note) = @$row;
        ok($ALLOWED_PHASE{$phase}, "AC20: $base row (step '$step') has phase cell '$phase' in the closed set");
    }
}

# ===========================================================================
# AC21: every parsed parity row's module cell names a path that exists,
# relative to the repo root.
# ===========================================================================
for my $row (@ALL_PARITY_ROWS) {
    my ($base, $step, $phase, $module, $note) = @$row;
    my $abs = "$REPO_ROOT/$module";
    ok(-e $abs, "AC21: $base row (step '$step') module cell '$module' exists relative to the repo root");
}

# ===========================================================================
# AC22: the 06 parity file states plainly that Step 1 was defective (a repo
# hook denies the command as written) and that its replacement by the
# dirty_worktree decision is a DELIBERATE change, not preserved behaviour.
# ===========================================================================
{
    my $text = read_text($PARITY_06) // '';
    like($text, qr/\bdirty_worktree\b/, 'AC22: reports/parity/06 mentions the dirty_worktree decision by name');
    like($text, qr/\b(?:den(?:y|ies|ied)|reject(?:s|ed)?|block(?:s|ed)?|refus(?:es|ed))\b/i,
        'AC22: reports/parity/06 says the original Step 1 command was denied/rejected/blocked by something (the repo hook)');
    like($text, qr/\bhook\b/i, 'AC22: reports/parity/06 names the mechanism as a hook');
    like($text, qr/\bdeliberate\b/i,
        'AC22: reports/parity/06 characterises the dirty_worktree replacement as a deliberate change');
    unlike($text, qr/preserved\s+(?:as\s+)?behaviou?r|achieves?\s+parity|parity\s+(?:is\s+)?(?:achieved|preserved)/i,
        'AC22: reports/parity/06 does not claim Step 1\'s original behaviour was preserved as parity');
}

# ===========================================================================
# AC23: SKILL.md documents all seven exit codes (0,1,2,3,4,10,20) and what the
# wrapper does on each.
# ===========================================================================
{
    my $section = extract_section($SKILL_CONTENT, '## Running the driver');
    ok(defined($section), "AC23: '## Running the driver' section is findable");
    $section //= '';

    # Collect the leading cell of every markdown-table row in the section
    # that looks like it names an exit code (>= 2 cells, first cell numeric).
    my %code_row;
    for my $line (split /\n/, $section) {
        my $cells = _raw_row_cells($line) or next;
        next unless @$cells >= 2;
        s/^\s+|\s+\z//g for @$cells;
        next if $cells->[0] =~ /^:?-{2,}:?\z/;
        next unless $cells->[0] =~ /^\d+\z/;
        $code_row{ $cells->[0] } = $cells;
    }

    my @EXIT_CODES = qw(0 1 2 3 4 10 20); # closed contract, spec S2.1's interface table -- not the decision-kind enum
    for my $code (@EXIT_CODES) {
        ok(exists $code_row{$code}, "AC23: exit code $code is documented in '## Running the driver'");
        if (exists $code_row{$code}) {
            my $rest = join(' ', @{ $code_row{$code} }[1 .. $#{ $code_row{$code} }]);
            ok(length($rest) > 0, "AC23: exit code ${code}'s table row has a non-empty description of what the wrapper does");
        }
    }

    # Extra, requested by the parent task (not a separately-numbered spec AC):
    # the exit-4/consumed_seq retry-legitimacy detail, and exit-3
    # token_replayed's terminality.
    like($SKILL_CONTENT, qr/consumed_seq/,
        'AC23-extra: SKILL.md documents the consumed_seq detail (exit 4 leaves the resume token valid for one corrected retry)');
    like($SKILL_CONTENT, qr/token_replayed/,
        'AC23-extra: SKILL.md documents token_replayed (an exit-3 code that is terminal, unlike exit 4)');
}

# ===========================================================================
# AC24: '## Relaying the report' states that unit_failures -- not degraded --
# decides whether the operator is told something went wrong.
# ===========================================================================
{
    my $section = extract_section($SKILL_CONTENT, '## Relaying the report');
    ok(defined($section), "AC24: '## Relaying the report' section is findable");
    $section //= '';
    like($section, qr/unit_failures/, "AC24: '## Relaying the report' mentions unit_failures");
    like($section, qr/degraded/, "AC24: '## Relaying the report' mentions degraded");
    like($section,
        qr/unit_failures[^.\n]{0,220}?(?:not|regardless\s+of|rather\s+than|never)[^.\n]{0,220}?degraded
          |degraded[^.\n]{0,220}?(?:not|only|never)[^.\n]{0,220}?unit_failures
          |not[^.\n]{0,120}?degraded[^.\n]{0,220}?unit_failures/xis,
        "AC24: '## Relaying the report' states unit_failures (not degraded alone) is what decides \"something went wrong\"");
}

# ===========================================================================
# AC25: '## Follow-up actions' names all four action values and assigns each
# the perform/relay/inform obligation of spec S2.4.
# ===========================================================================
{
    my $section = extract_section($SKILL_CONTENT, '## Follow-up actions');
    ok(defined($section), "AC25: '## Follow-up actions' section is findable");
    $section //= '';

    for my $action (qw(invoke_setup_project create_skip_marker install_plugin add_marketplace)) {
        like($section, qr/\Q$action\E/, "AC25: '## Follow-up actions' names '$action'");
    }

    for my $action (qw(invoke_setup_project create_skip_marker)) {
        if ($section =~ /\Q$action\E(.{0,300})/s) {
            like($1, qr/perform|invoke|creat|execut/i,
                "AC25: '$action' is described near a perform/invoke/create/execute obligation");
        } else {
            ok(0, "AC25: '$action' is described near a perform/invoke/create/execute obligation (action not found)");
        }
    }

    if ($section =~ /install_plugin(.{0,300})/s) {
        like($1, qr/relay/i, "AC25: 'install_plugin' is described as RELAYED (not performed -- an agent cannot run /plugin install)");
    } else {
        ok(0, "AC25: 'install_plugin' is described as RELAYED (action not found)");
    }

    if ($section =~ /add_marketplace(.{0,300})/s) {
        like($1, qr/inform/i, "AC25: 'add_marketplace' is described as INFORM-ONLY (it is emitted with zero decisions gating it)");
        unlike($1, qr/\bperform(?:s|ed)?\b|\bexecut(?:e|es|ed)\b/i,
            "AC25: 'add_marketplace' is not described as something the wrapper performs/executes");
    } else {
        ok(0, "AC25: 'add_marketplace' is described as INFORM-ONLY (action not found)");
    }
}


# ===========================================================================
# RED-TEAM HARDENING -- coordinator dispatch, post-review/red-team pass on the
# now-rewritten SKILL.md. Four items below, RT1-RT4, each describing a LIVE
# defect the review/red-team pass found in the CURRENT SKILL.md. Every new
# assertion in this section is expected to FAIL until the implementer fixes
# the corresponding defect -- these are oracle checks, not scaffolding for a
# future pass. t/24 was explicitly NOT touched (another agent is editing it
# concurrently for the matching report-side half of RT3).
# ===========================================================================

# ---------------------------------------------------------------------------
# RT1: AC10/AC11 prove every enum kind is DOCUMENTED, never that the
# documentation is TRUE. A row can name three invented choices for a decision
# that only ever offers two. Derive the REAL choice ids MECHANICALLY from the
# phase modules' own source -- the same class of extraction already used for
# the kind enum (Run.pm) and the 15 steps (skill-before.md) -- and assert
# every real choice id is at least NAMED (underscore or hyphen form, matching
# the convention already used correctly elsewhere in this same table, e.g.
# 'use-live' for use_live) in that kind's presentation-table row. No literal
# choice-id list appears in this file's source; only kinds whose choices are
# a LITERAL array immediately after their 'kind => ...' call are statically
# enumerable this way -- kinds built by a helper sub or a ternary
# (settings_key, marketplace_key, container_settings_key, push_confirmation,
# vault_conflict) are not covered by this technique and are silently absent
# from @KINDS_WITH_LITERAL_CHOICES rather than falsely claimed as checked.
# ---------------------------------------------------------------------------
{
    my @PHASE_MODULES = (
        "$Bin/../../../../scripts/backup/Preflight.pm",
        "$Bin/../../../../scripts/backup/Export.pm",
        "$Bin/../../../../scripts/backup/Vault.pm",
        "$Bin/../../../../scripts/backup/Closeout.pm",
    );

    my %real_ids; # kind => { id => 1, ... } -- literal choices[] only
    for my $file (@PHASE_MODULES) {
        my $src = read_text($file);
        next unless defined $src;
        while ($src =~ /\bkind\s*=>\s*'([a-z0-9_]+)'/g) {
            my $kind = $1;
            my $window = substr($src, pos($src), 2000);
            next unless $window =~ /\bchoices\s*=>\s*\[(.*?)\]/s;
            my @ids = ($1 =~ /\bid\s*=>\s*'([a-z0-9_]+)'/g);
            next unless @ids;
            $real_ids{$kind} ||= {};
            $real_ids{$kind}{$_} = 1 for @ids;
        }
    }

    ok(scalar(keys %real_ids) > 0,
        'RT1: at least one kind\'s literal choices[] block was extracted from the phase modules at runtime');

    # Re-parse the presentation table independently and locally -- does not
    # reuse or mutate the %row_by_kind built for AC11/AC12 above.
    my $rt1_section = extract_section($SKILL_CONTENT, '## Presenting decisions');
    my %rt1_row_by_kind;
    if (defined $rt1_section) {
        for my $r (parse_decision_rows($rt1_section)) {
            $rt1_row_by_kind{ $r->[0] } = $r;
        }
    }

    for my $kind (sort keys %real_ids) {
        my $row = $rt1_row_by_kind{$kind};
        my $row_text = defined($row) ? join(' ', @{$row}[1, 2]) : '';
        for my $id (sort keys %{ $real_ids{$kind} }) {
            my @parts = split /_/, $id;
            my $pattern = join('[_-]', map { quotemeta($_) } @parts);
            like($row_text, qr/$pattern/i,
                "RT1: kind '$kind' presentation-table row names its real choice '$id' (from the phase module's own literal choices[], not invented)");
        }
    }
}

# ---------------------------------------------------------------------------
# RT2: nothing forbids the AGENT from answering a decision itself.
# `decisions[]` carries the CHOICES OFFERED, never the operator's
# SELECTIONS -- an instruction to re-derive answers from decisions[] tells
# the agent to synthesise consent it never received, defeating Run.pm's
# consumed_seq consent-replay guard. Two assertions: an explicit prohibition
# must exist somewhere, and the exit-4 guidance specifically must not
# instruct deriving answers from decisions[].
# ---------------------------------------------------------------------------
{
    like($SKILL_CONTENT,
        qr/\bnever\b[^.\n]{0,150}\b(?:answer|choose|select|invent|fabricate|synthesi[sz]e)[^.\n]{0,150}\b(?:operator|human|user)\b
          |\b(?:operator|human|user)\b[^.\n]{0,150}\bnever\b[^.\n]{0,150}\b(?:answer|choose|select|invent|fabricate|synthesi[sz]e)/xis,
        'RT2: SKILL.md states an explicit prohibition on the wrapper answering a decision without the operator');

    unlike($SKILL_CONTENT,
        qr/(?:re-?derive|reconstruct|regenerate)[^.\n]{0,80}\banswers?\b[^.\n]{0,80}\bdecisions(?:\[\])?\b/is,
        'RT2: the exit-4 guidance does not instruct deriving/re-deriving answers from the decisions[] payload (decisions[] carries choices OFFERED, never the operator\'s selections)');
}

# ---------------------------------------------------------------------------
# RT3: Preflight.pm emits skills_synced and claude_md_status; the wrapper
# never surfaces either, so global CLAUDE.md drift is detected every run and
# told to nobody. (The matching report-carries-them assertion is being added
# to t/24 by a sibling agent concurrently -- this checks the wrapper-side
# relay only, per the coordinator's instruction not to touch t/24.)
# ---------------------------------------------------------------------------
{
    my $section = extract_section($SKILL_CONTENT, '## Relaying the report');
    $section //= '';
    like($section, qr/skills[_-]?synced|skills\s+mirror/i,
        "RT3: '## Relaying the report' surfaces the skills-mirror sync result (skills_synced)");
    like($section, qr/claude[_-]?md[_-]?status|CLAUDE\.md\b[^.\n]{0,40}\bstatus/i,
        "RT3: '## Relaying the report' surfaces the CLAUDE.md link/status check (claude_md_status)");
}

# ---------------------------------------------------------------------------
# RT4: create_skip_marker dropped its mkdir -p. The marker's parent directory
# ($cwd/.claude/) can be missing (a bare root CLAUDE.md alone triggers the
# offer), so a bare touch fails and a CONSENTED write silently does not
# happen -- the operator is told it was recorded and is asked again next run.
# ---------------------------------------------------------------------------
{
    my $section = extract_section($SKILL_CONTENT, '## Follow-up actions');
    $section //= '';
    if ($section =~ /create_skip_marker(.{0,400})/s) {
        like($1, qr/mkdir(?:\s+-p)?\b|parent\s+director(?:y|ies)/i,
            "RT4: 'create_skip_marker' instructions create the marker's parent directory (mkdir -p) before touching the file");
    } else {
        ok(0, "RT4: 'create_skip_marker' instructions create the marker's parent directory (mkdir -p) before touching the file (action not found)");
    }
}

done_testing();
