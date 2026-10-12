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

done_testing();
