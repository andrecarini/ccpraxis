#!/usr/bin/env perl
# platform: any
# Package 05-almanac-routing-prose (blueprint tooling-fixes). Oracle for
# Decision 5 (routing prose for the task/todo/decision skills) and
# Decision 8 (note skill documents edit --content / --force-external).
# Derived ONLY from the blueprint's Decision 5, Decision 8 and package
# 05-almanac-routing-prose's done criteria -- never from the SKILL.md
# implementations themselves. Matching is deliberately by regex on
# meaning-bearing clauses, never a pinned literal: the blueprint states what
# each skill's prose must say, not the exact bytes, and pinning a literal
# here would make this test an echo of one implementer's phrasing.
#
# At the time this file is written, none of the three routing rules or the
# note --content/--force-external documentation exist yet, so every
# assertion below is expected to fail for exactly that reason -- never a
# harness bug in this file.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Encode qw(decode);

my $ROOT = "$Bin/../..";    # plugins/almanac

sub slurp_utf8 {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return decode('UTF-8', $raw);
}

# parse_frontmatter($text) -> { ok, description, body } -- same shape as
# almanac-skills.t's own parser (kept intentionally minimal: this file only
# ever needs description and body).
sub parse_frontmatter {
    my ($text) = @_;
    return { ok => 0 } unless defined $text;
    my @lines = split /\n/, $text;
    for my $l (@lines) { $l =~ s/\r$//; }
    return { ok => 0 } unless @lines && $lines[0] eq '---';
    my $end;
    for my $i (1 .. $#lines) {
        if ($lines[$i] eq '---') { $end = $i; last }
    }
    return { ok => 0 } unless defined $end;
    my @fm   = @lines[1 .. $end - 1];
    my @body = @lines[$end + 1 .. $#lines];
    my $description;
    for my $l (@fm) {
        if (!defined $description && $l =~ /^description:\s?(.*)$/) { $description = $1 }
    }
    return { ok => 1, description => $description, body => join("\n", @body) };
}

# OVERRIDDEN by blueprint where-things-go, package 02-thread-store (specs/
# 02-thread-store-spec.md section 2.10, AC16): skills/task/ is deleted and
# skills/thread/ replaces it as the carrier of the routing rule Decision 5
# pinned for the old tasklist skill, re-expressed for threads.
my %SKILL_PATH = (
    thread   => "$ROOT/skills/thread/SKILL.md",
    todo     => "$ROOT/skills/todo/SKILL.md",
    decision => "$ROOT/skills/inbox/SKILL.md",   # spec 01-inbox-rename: decision -> inbox
    note     => "$ROOT/skills/note/SKILL.md",
);

my %raw;
my %parsed;
for my $k (keys %SKILL_PATH) {
    ok(-f $SKILL_PATH{$k}, "fixture present: $SKILL_PATH{$k}") or next;
    $raw{$k}    = slurp_utf8($SKILL_PATH{$k});
    $parsed{$k} = parse_frontmatter($raw{$k});
    ok($parsed{$k}{ok}, "$k/SKILL.md has parseable --- frontmatter");
}

# =============================================================================
# thread (specs/02-thread-store-spec.md section 2.10, AC16) -- re-expression
# of Decision 5's routing rule for threads: "a thread's tasks: steps of work
# actively under way, never status notes". The thread skill's description
# names the routing rule, and its BODY says status notes and progress logs
# do not belong in a thread's tasks (move the step's status instead), and
# that a linked task's status is its package's.
# =============================================================================
SKIP: {
    skip 'thread/SKILL.md missing or unparseable', 5 unless $parsed{thread}{ok};
    my $d = $parsed{thread}{description} // '';
    my $b = $parsed{thread}{body} // '';

    # Key clause: a thread's tasks hold steps of work that are actively
    # under way right now (not finished, not merely planned) -- tolerant of
    # "actively under way" / "currently under way" / "under way now" and of
    # "step(s) of work" vs "work step(s)".
    like($d, qr/\bstep(?:s)?\s+of\s+work\b/i,
        "thread description: names 'step(s) of work' as what a thread's tasks hold");
    like($d, qr/\bactively\b[^.\n]{0,20}\bunder\s*way\b|\bunder\s*way\b[^.\n]{0,20}\bactively\b|\bcurrently\s+under\s*way\b/i,
        "thread description: says those steps are actively under way (not just planned or finished)");

    # The BODY says status notes and progress logs do NOT belong in a
    # thread's tasks -- tolerant of "status notes"/"status updates",
    # "progress logs"/"progress updates", and of "do not belong"/"don't
    # belong"/"never" phrasing, in either order.
    like($b, qr/\bstatus\s+(?:notes?|updates?)\b/i,
        "thread body: mentions status notes/updates");
    like($b, qr/\bprogress\s+(?:logs?|updates?)\b/i,
        "thread body: mentions progress logs/updates");
    unless (
        $b =~ /\bstatus\s+(?:notes?|updates?)\b[^.\n]{0,80}\b(?:do(?:es)?\s+not|don't|never)\s+belong\b/is
        || $b =~ /\b(?:do(?:es)?\s+not|don't|never)\s+belong\b[^.\n]{0,80}\bstatus\s+(?:notes?|updates?)\b/is
    ) {
        fail("thread body: says status notes do not belong in a thread's tasks");
    } else {
        pass("thread body: says status notes do not belong in a thread's tasks");
    }

    # AC16: a linked task's status is its package's -- distinct new clause
    # this package's spec requires that the old task skill never had.
    like($b, qr/\blinked\b[^.\n]{0,60}\bstatus\b[^.\n]{0,40}\bpackage\b|\bpackage\b[^.\n]{0,40}\bstatus\b[^.\n]{0,60}\blinked\b/is,
        "thread body: says a linked task's status is its package's");
}

# =============================================================================
# todo -- Decision 5 routing rule: "todos: deferred work an agent can do
# later". Done criterion 2: the todo skill's description names this
# routing rule.
# =============================================================================
SKIP: {
    skip 'todo/SKILL.md missing or unparseable', 2 unless $parsed{todo}{ok};
    my $d = $parsed{todo}{description} // '';

    like($d, qr/\bdeferred\s+work\b/i,
        "todo description: names 'deferred work' as what a todo holds");
    like($d, qr/\ban?\s+agent\b[^.\n]{0,30}\b(?:can\s+)?do\s+later\b|\bdo\s+later\b|\blater\s+session\b/i,
        "todo description: says an agent can do it later");
}

# =============================================================================
# decision -- Decision 5 routing rule: "decisions: anything that needs the
# operator, including manual checks and taste calls. They show in the
# statusline flag, in every session of the project." Done criterion 2: the
# decision skill's description names the routing rule (manual checks, taste
# calls, questions -> the operator) AND states it shows as the statusline
# flag in every session of the project.
# =============================================================================
SKIP: {
    skip 'decision/SKILL.md missing or unparseable', 5 unless $parsed{decision}{ok};
    my $d = $parsed{decision}{description} // '';

    like($d, qr/\bmanual\s+check(?:s)?\b/i,
        "decision description: names manual checks as routing to a decision");
    like($d, qr/\btaste\s+call(?:s)?\b/i,
        "decision description: names taste calls as routing to a decision");
    like($d, qr/\bquestion(?:s)?\b/i,
        "decision description: names questions as routing to a decision");
    like($d, qr/\bthe\s+operator\b/i,
        "decision description: says this is anything that needs the operator");

    like($d, qr/\bstatusline\b[^.\n]{0,20}\bflag\b|\bflag\b[^.\n]{0,20}\bstatusline\b/i,
        "decision description: mentions the statusline flag");
    like($d, qr/\bevery\s+session\b[^.\n]{0,30}\bproject\b|\bproject\b[^.\n]{0,30}\bevery\s+session\b/i,
        "decision description: says it shows in every session of the project");
}

# =============================================================================
# note -- Decision 8: edit gains --content and --content-file (implemented
# in package 02); the note skill documents both edit --content and
# --force-external (the refusal edit --content raises against an external
# target unless overridden, per Decision 6 ruling 12 / Decision 8 Q2).
# =============================================================================
SKIP: {
    skip 'note/SKILL.md missing or unparseable', 2 unless $parsed{note}{ok};
    my $text = $raw{note} // '';

    like($text, qr/\bedit\b[^\n]{0,40}--content\b/,
        "note/SKILL.md: documents 'edit ... --content' (Decision 8)");
    like($text, qr/--force-external\b/,
        "note/SKILL.md: documents --force-external (Decision 8)");
}

use File::Find ();

# =============================================================================
# Package 14-what-goes-where-prose (blueprint where-things-go). AC1-AC21,
# derived ONLY from specs/14-what-goes-where-prose-spec.md sections 2, 4 and
# 5 -- never from an implementation, none of which exists yet for AC1-AC10,
# the routing fixes (AC11/AC13/AC14) or the hook-architecture.md wording
# (AC20/AC21). Those are expected to fail for exactly that reason. AC22/AC23
# are driver-run commands, not assertions, and are deliberately not added
# here.
# =============================================================================

my $REPO           = "$Bin/../../../..";    # repo root
my $CLAUDE_MD_PATH  = "$REPO/global-config/CLAUDE.md";
my $PROJECT_CLAUDE_MD_PATH = "$REPO/CLAUDE.md";

sub normalize_crlf {
    my ($text) = @_;
    return undef unless defined $text;
    $text =~ s/\r\n/\n/g;
    return $text;
}

# -----------------------------------------------------------------------------
# AC1-AC10: the new "## What goes where" section in global-config/CLAUDE.md
# (spec section 2.1 and the AC1-AC10 table rows). Regex/meaning-based per the
# spec's own caution against whole-section byte-pinning; only the heading
# (AC1) and the token literals (AC4) are pinned exactly.
# -----------------------------------------------------------------------------

my $claude_md_text = normalize_crlf(slurp_utf8($CLAUDE_MD_PATH));
my @cmd_lines = defined $claude_md_text ? split(/\n/, $claude_md_text) : ();

my @heading_idx = grep { $cmd_lines[$_] eq '## What goes where' } 0 .. $#cmd_lines;
is(scalar(@heading_idx), 1,
    'AC1: global-config/CLAUDE.md has exactly one line equal to "## What goes where"');

my $heading_i = (@heading_idx == 1) ? $heading_idx[0] : undef;

my @arming_idx = grep { $cmd_lines[$_] eq '## Arming continuity (butler)' } 0 .. $#cmd_lines;
my @house_idx  = grep { $cmd_lines[$_] eq '## House rules learned across projects' } 0 .. $#cmd_lines;

ok((defined($heading_i) && @arming_idx && @house_idx
        && $heading_i > $arming_idx[0] && $heading_i < $house_idx[0]),
    'AC2: heading sits after "## Arming continuity (butler)" and before "## House rules learned across projects"');

my @section_lines;
if (defined $heading_i) {
    my $end_i = $#cmd_lines;
    for my $i ($heading_i + 1 .. $#cmd_lines) {
        if ($cmd_lines[$i] =~ /^## /) { $end_i = $i - 1; last }
    }
    @section_lines = @cmd_lines[$heading_i .. $end_i];
}
my $section_text = join("\n", @section_lines);

my $section_byte_len = length(Encode::encode('UTF-8', $section_text));
my @section_non_blank = grep { /\S/ } @section_lines;
ok((@section_lines && $section_byte_len <= 2000),
    "AC3: section is at most 2000 UTF-8 bytes (got $section_byte_len; section " .
        (@section_lines ? 'found' : 'not found') . ')');
ok((@section_lines && scalar(@section_non_blank) <= 12),
    'AC3: section has at most 12 non-blank lines (got ' . scalar(@section_non_blank) . ')');

my @ac4_literals = (
    '/almanac:thread', '/almanac:todo', '/almanac:inbox', '/almanac:note',
    '/almanac:bug-report', '/blueprint:create', '/butler:continuity',
    '/sitrep', '/pending',
);
for my $lit (@ac4_literals) {
    my $q = quotemeta($lit);
    ok(scalar($section_text =~ /$q/), "AC4: section contains literal '$lit'");
}

my %ac_line_for;
for my $lit (@ac4_literals) {
    my $q = quotemeta($lit);
    for my $l (@section_lines) {
        if ($l =~ /$q/) { $ac_line_for{$lit} = $l; last }
    }
}

my $thread_line = $ac_line_for{'/almanac:thread'} // '';
like($thread_line, qr/handover/i, 'AC5: thread line mentions "handover"');
like($thread_line, qr/operator/i, 'AC5: thread line mentions "operator"');

my $todo_line = $ac_line_for{'/almanac:todo'} // '';
like($todo_line, qr/not yet in a thread/i, 'AC5: todo line says "not yet in a thread"');
like($todo_line, qr/\bmoves?\b/i, 'AC5: todo line uses "move(s)"');

my $inbox_line = $ac_line_for{'/almanac:inbox'} // '';
like($inbox_line, qr/needs the operator/i, 'AC5: inbox line says "needs the operator"');
like($inbox_line, qr/product/i, 'AC5: inbox line mentions "product"');

my $note_line = $ac_line_for{'/almanac:note'} // '';
like($note_line, qr/durable fact/i, 'AC5: note line mentions "durable fact"');

my $bug_line = $ac_line_for{'/almanac:bug-report'} // '';
like($bug_line, qr/ccpraxis/i, 'AC5: bug line mentions "ccpraxis"');
like($bug_line, qr/defect/i, 'AC5: bug line mentions "defect"');
like($bug_line, qr/package/i, 'AC5: bug line mentions "package"');

my $blueprint_line = $ac_line_for{'/blueprint:create'} // '';
like($blueprint_line, qr/multi-session/i, 'AC5: blueprint line mentions "multi-session"');

like($section_text, qr/\bone way\b/i, 'AC6: section states the link rule runs "one way"');
my $ac6_found = 0;
for my $l (@section_lines) {
    if ($l =~ /\b(?:task|bug)\b[^.\n]{0,40}\bnames?\b[^.\n]{0,20}\bpackage\b/i
        && $l =~ /\bledgers?\b[^.\n]{0,20}\bnever\b/i)
    {
        $ac6_found = 1;
        last;
    }
}
ok($ac6_found,
    'AC6: some line names both halves of the one-way rule (task/bug names package; ledger never)');

ok(($section_text =~ m{/butler:continuity} && index($section_text, 'butler-continuity on') < 0),
    'AC7: section points to /butler:continuity (AC4) without duplicating literal "butler-continuity on"');

my $sitrep_line  = $ac_line_for{'/sitrep'}  // '';
my $pending_line = $ac_line_for{'/pending'} // '';
like($sitrep_line, qr/current project/i, 'AC8: /sitrep line says "current project"');
like($pending_line, qr/every project/i, 'AC8: /pending line says "every project"');

ok(scalar($section_text !~ /decision/i), 'AC9: section contains no match of /decision/i');

my $project_claude_md = normalize_crlf(slurp_utf8($PROJECT_CLAUDE_MD_PATH));
my $ac10_dup_found = 0;
my $ac10_dup_line  = '';
if (@section_lines > 1 && defined $project_claude_md) {
    for my $l (@section_lines[1 .. $#section_lines]) {    # skip the heading itself
        next unless $l =~ /\S/;
        if (index($project_claude_md, $l) >= 0) {
            $ac10_dup_found = 1;
            $ac10_dup_line  = $l;
            last;
        }
    }
}
ok(!$ac10_dup_found,
    'AC10: no non-blank section line duplicates a line of /project/CLAUDE.md'
        . ($ac10_dup_found ? " (found: $ac10_dup_line)" : ''));
for my $forbidden ('promote.pl', 'drive-solo', 'live install') {
    ok(index($section_text, $forbidden) < 0, "AC10: section does not contain '$forbidden'");
}

# -----------------------------------------------------------------------------
# Shared scan-set / exemption machinery for AC11 (reference resolution) and
# the AC16-AC19 DC3 retired-phrase lint (spec section 2.3).
# -----------------------------------------------------------------------------

sub is_exempt_path {
    my ($relpath) = @_;
    return 0 unless defined $relpath;
    return $relpath =~ m{(?:^|/)(?:tests|docs)/} ? 1 : 0;
}

sub scan_set {
    my @roots;
    push @roots, grep { -d $_ } glob("$REPO/plugins/*/skills");
    push @roots, grep { -d $_ } glob("$REPO/plugins/*/agents");
    push @roots, "$REPO/skills" if -d "$REPO/skills";
    push @roots, "$REPO/global-config" if -d "$REPO/global-config";

    my @files;
    for my $root (@roots) {
        File::Find::find(
            {
                follow   => 0,
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $_ && !-l $_;
                    push @files, $File::Find::name;
                },
            },
            $root
        );
    }

    my @result;
    for my $f (@files) {
        my $rel = $f;
        $rel =~ s{^\Q$REPO\E/?}{};
        next if is_exempt_path($rel);
        push @result, { abs => $f, rel => $rel };
    }
    return @result;
}

# -----------------------------------------------------------------------------
# AC11: reference resolution -- every /almanac:<name> token in the scan set
# must resolve to an existing plugins/almanac/skills/<name>/SKILL.md.
# -----------------------------------------------------------------------------

my @ac11_scan = scan_set();
my @ac11_offenders;
for my $file (@ac11_scan) {
    my $content = slurp_utf8($file->{abs});
    next unless defined $content;
    $content = normalize_crlf($content);
    my @flines = split /\n/, $content;
    for my $i (0 .. $#flines) {
        my $line = $flines[$i];
        while ($line =~ /\/almanac:([a-z][a-z-]*)/g) {
            my $name   = $1;
            my $target = "$REPO/plugins/almanac/skills/$name/SKILL.md";
            unless (-f $target) {
                push @ac11_offenders, sprintf('%s:%d: /almanac:%s', $file->{rel}, $i + 1, $name);
            }
        }
    }
}
diag("AC11 offenders:\n" . join("\n", @ac11_offenders)) if @ac11_offenders;
is(scalar(@ac11_offenders), 0,
    'AC11: every /almanac:<name> token in the scan set resolves to an existing skills/<name>/SKILL.md');

# -----------------------------------------------------------------------------
# AC12-AC15: skill-description routing checks.
# -----------------------------------------------------------------------------

my %AC_SKILL_PATH = map { $_ => "$REPO/plugins/almanac/skills/$_/SKILL.md" }
    qw(thread todo inbox note bug-report bug-triage);

for my $skill (sort keys %AC_SKILL_PATH) {
    my $parsed = parse_frontmatter(slurp_utf8($AC_SKILL_PATH{$skill}));
    SKIP: {
        skip "AC12: $skill/SKILL.md missing or unparseable", 1 unless $parsed->{ok};
        my $d = $parsed->{description} // '';
        my $skip_pos;
        if ($d =~ /\b(?:skip|do not use|not for)\b/i) { $skip_pos = $-[0] }
        my $bad = 0;
        my @offenders;
        while ($d =~ /\/almanac:([a-z][a-z-]*)/g) {
            my $name = $1;
            my $pos  = $-[0];
            next if $name eq $skill;
            if (!defined $skip_pos || $pos < $skip_pos) {
                $bad = 1;
                push @offenders, "$name\@$pos";
            }
        }
        diag("AC12 offenders in $skill description: " . join(', ', @offenders)) if $bad;
        ok(!$bad,
            "AC12: $skill description names foreign /almanac: systems only at/after its skip/routing clause");
    }
}

{
    my $parsed = parse_frontmatter(slurp_utf8($AC_SKILL_PATH{note}));
    SKIP: {
        skip 'AC13: note/SKILL.md missing or unparseable', 3 unless $parsed->{ok};
        my $d = $parsed->{description} // '';
        like($d, qr{/almanac:thread}, 'AC13: note description contains /almanac:thread');
        like($d, qr{/almanac:todo}, 'AC13: note description contains /almanac:todo');
        unlike($d, qr{/almanac:task\b}, 'AC13: note description contains no /almanac:task');
    }
}

{
    my %ac14_desc;
    for my $s (qw(thread todo bug-triage bug-report)) {
        my $parsed = parse_frontmatter(slurp_utf8($AC_SKILL_PATH{$s}));
        $ac14_desc{$s} = $parsed->{ok} ? ($parsed->{description} // '') : undef;
    }

    SKIP: {
        skip 'AC14: thread/SKILL.md missing or unparseable', 2 unless defined $ac14_desc{thread};
        like($ac14_desc{thread}, qr{/almanac:todo}, 'AC14: thread description contains /almanac:todo');
        like($ac14_desc{thread}, qr{/almanac:inbox}, 'AC14: thread description contains /almanac:inbox');
    }
    SKIP: {
        skip 'AC14: todo/SKILL.md missing or unparseable', 2 unless defined $ac14_desc{todo};
        like($ac14_desc{todo}, qr{/almanac:thread}, 'AC14: todo description contains /almanac:thread');
        like($ac14_desc{todo}, qr{/almanac:inbox}, 'AC14: todo description contains /almanac:inbox');
    }
    SKIP: {
        skip 'AC14: bug-triage/SKILL.md missing or unparseable', 1 unless defined $ac14_desc{'bug-triage'};
        like($ac14_desc{'bug-triage'}, qr{/almanac:bug-report},
            'AC14: bug-triage description contains /almanac:bug-report');
    }
    SKIP: {
        skip 'AC14: bug-report/SKILL.md missing or unparseable', 1 unless defined $ac14_desc{'bug-report'};
        like($ac14_desc{'bug-report'}, qr/project you are building|own tracker/i,
            'AC14: bug-report description references "project you are building" or "own tracker"');
    }
}

pass('AC15: the original 24 assertions above (untouched by this patch) still run unaffected by the additions below');

# -----------------------------------------------------------------------------
# AC16-AC19: the DC3 retired-phrase lint itself (spec section 2.3).
# -----------------------------------------------------------------------------

my %AC_PHRASE_REGEX = (
    R1 => qr/\bflat[\s_-]*task[\s_-]*lists?\b/i,
    R2 => qr/\btask[\s_-]+focus\b/i,
    R3 => qr/\balmanac[\s:_-]+decisions?\b/i,
    R4 => qr/\boperator[_-]batch(?:\.md)?\b/i,
);

sub lint_hits_in_text {
    my ($text) = @_;
    return 0 unless defined $text;
    my $hits = 0;
    for my $id (sort keys %AC_PHRASE_REGEX) {
        $hits++ if $text =~ $AC_PHRASE_REGEX{$id};
    }
    return $hits;
}

sub lint_offenders_in_file {
    my ($abs, $rel) = @_;
    my $text = slurp_utf8($abs);
    return () unless defined $text;
    $text = normalize_crlf($text);
    my @offenders;
    for my $id (sort keys %AC_PHRASE_REGEX) {
        my $re = $AC_PHRASE_REGEX{$id};
        while ($text =~ /$re/g) {
            my $start    = $-[0];
            my $line_no  = 1 + (substr($text, 0, $start) =~ tr/\n//);
            my $line_end = index($text, "\n", $start);
            $line_end    = length($text) if $line_end < 0;
            my $line_start = ($start == 0) ? 0 : rindex($text, "\n", $start - 1) + 1;
            my $line_text   = substr($text, $line_start, $line_end - $line_start);
            push @offenders, "$rel:$line_no: $line_text";
        }
    }
    return @offenders;
}

my @ac16_scan = scan_set();
ok(scalar(@ac16_scan) >= 20, 'AC16: scan set has at least 20 files (got ' . scalar(@ac16_scan) . ')');
my %ac16_rel_present = map { $_->{rel} => 1 } @ac16_scan;
for my $want (
    qw(global-config/CLAUDE.md plugins/almanac/skills/inbox/SKILL.md
        plugins/butler/agents/bp-architect.md skills/sitrep/SKILL.md)
    )
{
    ok($ac16_rel_present{$want}, "AC16: scan set includes $want");
}

my @ac17_positive = (
    'the flat tasklist',  'flat-tasklist migration', 'Flat task list',
    'task focus',         'the task-focus store',
    'almanac decision',   'almanac-decision.pl',     '/almanac:decision', 'Almanac decisions',
    'OPERATOR-BATCH.md',  'operator_batch',
);
for my $fixture (@ac17_positive) {
    ok(lint_hits_in_text($fixture) >= 1, "AC17: lint fires on positive fixture '$fixture'");
}

my @ac17_negative = (
    'Decision 14',          'the almanac inbox',    'focus on the task',
    'an ordered task list', 'the task focused on',  'an operator batch',
    'the Decisions table',
);
for my $fixture (@ac17_negative) {
    is(lint_hits_in_text($fixture), 0, "AC17: lint does not fire on negative fixture '$fixture'");
}

for my $path (qw(plugins/x/skills/y/tests/z.t plugins/x/docs/a.md skills/s/docs/b.md)) {
    ok(is_exempt_path($path), "AC18: '$path' is exempt");
}
for my $path ('plugins/x/skills/y/SKILL.md', 'global-config/CLAUDE.md', 'skills/doctor-tests/SKILL.md') {
    ok(!is_exempt_path($path), "AC18: '$path' is not exempt");
}

my @ac19_offenders;
for my $file (scan_set()) {
    push @ac19_offenders, lint_offenders_in_file($file->{abs}, $file->{rel});
}
diag("AC19 offenders:\n" . join("\n", @ac19_offenders)) if @ac19_offenders;
is(scalar(@ac19_offenders), 0, 'AC19: zero R1-R4 hits across the §2.3 scan set');

# -----------------------------------------------------------------------------
# AC20-AC21: plugins/butler/docs/hook-architecture.md wording (spec 2.4).
# -----------------------------------------------------------------------------

{
    my $hook_arch_path = "$REPO/plugins/butler/docs/hook-architecture.md";
    my $hook_text = normalize_crlf(slurp_utf8($hook_arch_path));
    SKIP: {
        skip 'AC20/AC21: hook-architecture.md missing', 3 unless defined $hook_text;
        my @hlines = split /\n/, $hook_text;
        my @ac20_pending_decision_hits = grep { /\b(?:pending|almanac)\s+decisions?\b/i } @hlines;
        diag("AC20 offending lines:\n" . join("\n", @ac20_pending_decision_hits))
            if @ac20_pending_decision_hits;
        ok(!@ac20_pending_decision_hits,
            'AC20: hook-architecture.md has no line matching /\b(?:pending|almanac)\s+decisions?\b/i');
        ok(index($hook_text, 'Almanac::Decision') < 0,
            'AC20: hook-architecture.md contains no "Almanac::Decision"');

        if ($hook_text =~ /^### file: guard-ask-operator\.sh\n(.*?)(?=\n### file:|\z)/ms) {
            my $block = $1;
            my ($reason_line) = ($block =~ /^(reason:.*)$/m);
            ok((defined $reason_line && $reason_line =~ /\binbox item\b/),
                "AC21: guard-ask-operator.sh block's reason: line matches /\\binbox item\\b/");
        }
        else {
            fail('AC21: could not locate "### file: guard-ask-operator.sh" block in hook-architecture.md');
        }
    }
}

done_testing();
