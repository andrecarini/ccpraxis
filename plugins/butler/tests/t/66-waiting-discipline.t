#!/usr/bin/env perl
# b14-waiting-discipline oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b14-waiting-discipline-spec.md
# section 3 (C1..C6) and its vacuity gate.
#
# WRITTEN BLIND TO THE GUIDANCE THIS PACKAGE WILL ADD. As of authoring, coordinator-protocol/
# SKILL.md, plugins/butler/templates/dispatch-prompt.md, judge-harvest.md and judge-resolve.md
# carry NONE of the positive waiting pattern this spec mandates (spec Sec.0: 0 case-sensitive hits
# for the awaiting vocabulary in the protocol; the templates carry none of the pattern language
# either). Every assertion below is expected to fail on MISSING GUIDANCE -- a substring not found,
# or a vocabulary count of 0 where > 0 is required -- never on a Perl exception or a bad path. This
# is a doc-conformance test, not a behavioural one: there is no subprocess, no hook invocation, no
# fixture synthesis -- just Test::More assertions over the literal text of four files read from
# disk.
#
# THIS FILE DOES NOT ASSERT THE EXACT WORDING of the guidance-to-be-written (spec 2 gives content
# to convey, not verbatim sentences to match) -- except where the spec itself gives a concrete,
# load-bearing number (the "160s / one turn" vs "96 turns of a 100-turn budget" arithmetic in
# Sec.2.2, and the C6 vocabulary list, which IS the mandated regex from Sec.0/Sec.3 C6, copied
# verbatim). Everything else is asserted as content-bearing substrings/patterns naming the specific
# instruction (per the vacuity gate: SUBSTANCE, not a heading), never a bare "some string exists
# somewhere".
#
# VACUITY GATE (spec Sec.3, restated here because it is why this file is shaped the way it is):
#   * C1 and C4 assert on the SUBSTANCE of the instruction (background->end turn->resume; the
#     named prohibited shapes; "check once, never in a loop"), not merely that a "## Waiting"
#     heading exists.
#   * C3 is PER-FILE: three separate assertion groups, one per file (dispatch-prompt.md,
#     judge-harvest.md, judge-resolve.md). An aggregate "the pattern appears somewhere in
#     templates/" would pass with two of the three files untouched; this file names each file it
#     reads and fails independently per file.
#   * C6 counts the awaiting vocabulary ONLY in coordinator-protocol/SKILL.md, using the EXACT
#     case-sensitive alternation from spec Sec.0/Sec.3
#     (background|run_in_background|TaskOutput|poll|wait|Monitor|sleep). A repo-wide count would
#     be satisfied today by b15's ALREADY-SHIPPED wait-shape-guard.sh (which itself contains most
#     of this vocabulary) without coordinator-protocol/SKILL.md changing at all -- that would make
#     the oracle worthless. This file greps ONLY the one path named in BP_SKILL below.
#
# HARNESS NOTES:
#   * done_testing(), not a hardcoded plan (project convention; a hardcoded plan that drifts from
#     the assertion count fails with ZERO not-ok lines, which is its own landmine -- see the
#     project CLAUDE.md and t/67's header for the precedent this file follows).
#   * Every assertion NAMES THE FILE it read, in the test description, so a reviewer can see what
#     was actually checked without re-deriving it.
#   * Read-only: this file never writes to any of the four subject files, never touches git.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

# $Bin is .../plugins/butler/tests/t -- walk up to the repo root (four levels).
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;

my $BP_SKILL     = "$REPO/plugins/butler/skills/coordinator-protocol/SKILL.md";
my $BP_DISPATCH  = "$REPO/plugins/butler/templates/dispatch-prompt.md";
my $BP_HARVEST   = "$REPO/plugins/butler/templates/judge-harvest.md";
my $BP_RESOLVE   = "$REPO/plugins/butler/templates/judge-resolve.md";

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    binmode $fh;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $skill    = slurp($BP_SKILL);
my $dispatch = slurp($BP_DISPATCH);
my $harvest  = slurp($BP_HARVEST);
my $resolve  = slurp($BP_RESOLVE);

ok(defined $skill && length $skill,       "subject exists and is non-empty: $BP_SKILL");
ok(defined $dispatch && length $dispatch, "subject exists and is non-empty: $BP_DISPATCH");
ok(defined $harvest && length $harvest,   "subject exists and is non-empty: $BP_HARVEST");
ok(defined $resolve && length $resolve,   "subject exists and is non-empty: $BP_RESOLVE");

$skill    //= '';
$dispatch //= '';
$harvest  //= '';
$resolve  //= '';

# =====================================================================================
# C1 -- coordinator-protocol/SKILL.md has a dedicated waiting section stating the
# POSITIVE pattern (launch with run_in_background, END THE TURN, resume on the
# completion notification) AND naming the prohibited shapes.
#
# VACUITY GATE: these assert on the SUBSTANCE of the instruction, not on the mere
# presence of a heading. Each of the three positive-pattern clauses and each of the
# five named prohibited shapes gets its own assertion against $BP_SKILL specifically.
# =====================================================================================

# C1a: the positive pattern's three concrete steps, each independently present.
like($skill, qr/run_in_background/,
     "C1 [$BP_SKILL]: names run_in_background as the launch mechanism for long work");
like($skill, qr/\bend\b.{0,20}\bturn\b/i,
     "C1 [$BP_SKILL]: instructs ending the turn after launching background work (substance, not a heading)");
like($skill, qr/(completion notification|notified when it completes|resume(?:s|d)? (?:on|via) (?:the )?(?:completion )?notification)/i,
     "C1 [$BP_SKILL]: instructs resuming on the completion notification, not by re-polling");
like($skill, qr/never re-invoke|never (?:call|check|poll)|do not (?:poll|re-invoke|check)/i,
     "C1 [$BP_SKILL]: explicitly forbids re-invoking a tool to check on a background task");

# C1b: the five prohibited shapes named CONCRETELY (spec 2.3), each its own assertion.
like($skill, qr/while\s*\[\s*!\s*-s/,
     "C1 [$BP_SKILL]: names the prohibited shape `while [ ! -s ... ]`");
like($skill, qr/until\s+grep\s+-q/,
     "C1 [$BP_SKILL]: names the prohibited shape `until grep -q ...`");
like($skill, qr/echo\s+["']?waiting/i,
     "C1 [$BP_SKILL]: names the prohibited shape `echo waiting`");
like($skill, qr/sleep.{0,20}spin|spin.{0,20}sleep/i,
     "C1 [$BP_SKILL]: names the prohibited `sleep` spin shape");
like($skill, qr/(repeated\s+(?:`?cat`?|`?TaskOutput`?)|(?:cat|TaskOutput).{0,40}(?:output|sentinel)\s*file)/i,
     "C1 [$BP_SKILL]: names repeated cat/TaskOutput against an output or sentinel file as prohibited");

# =====================================================================================
# C2 -- foreground-is-default for validation, WITH the turn arithmetic: a 160s
# foreground suite costs ONE turn; the same suite awaited by polling cost one
# coordinator 96 turns of a 100-turn budget. Both concrete numbers are load-bearing
# (spec 2.2 gives them as the persuasive arithmetic, not decoration) so both are
# asserted literally against $BP_SKILL.
# =====================================================================================

like($skill, qr/foreground/i,
     "C2 [$BP_SKILL]: states foreground execution as the documented default for validation");
like($skill, qr/160\s*s(?:ec(?:onds?)?)?\b/i,
     "C2 [$BP_SKILL]: states the concrete 160s foreground-suite figure");
like($skill, qr/\bone\s+turn\b|\b1\s+turn\b/i,
     "C2 [$BP_SKILL]: states that the 160s foreground suite costs ONE turn");
like($skill, qr/96\s+turns/i,
     "C2 [$BP_SKILL]: states the concrete 96-turns figure a polling coordinator actually burned");
like($skill, qr/100[\s-]turn\s+budget|100-turn/i,
     "C2 [$BP_SKILL]: states the 96 turns were of a 100-turn budget (the arithmetic that makes the point persuasive)");

# =====================================================================================
# C3 -- the dispatch prompt AND BOTH judge templates carry the same pattern.
# ASSERT PER FILE: three files, three independent assertion groups. An aggregate check
# over the templates directory would pass if only one of the three had been touched;
# each group below reads and asserts against exactly one named file.
# =====================================================================================

# --- dispatch-prompt.md ---
like($dispatch, qr/run_in_background/,
     "C3 [$BP_DISPATCH]: dispatch prompt carries run_in_background as the launch mechanism");
like($dispatch, qr/(completion notification|resume(?:s|d)? (?:on|via) (?:the )?(?:completion )?notification)/i,
     "C3 [$BP_DISPATCH]: dispatch prompt instructs resuming on the completion notification");
like($dispatch, qr/\bend\b.{0,20}\bturn\b/i,
     "C3 [$BP_DISPATCH]: dispatch prompt instructs ending the turn after launching background work");

# --- judge-harvest.md ---
like($harvest, qr/run_in_background/,
     "C3 [$BP_HARVEST]: harvest-judge template carries run_in_background as the launch mechanism");
like($harvest, qr/(completion notification|resume(?:s|d)? (?:on|via) (?:the )?(?:completion )?notification)/i,
     "C3 [$BP_HARVEST]: harvest-judge template instructs resuming on the completion notification");
like($harvest, qr/\bend\b.{0,20}\bturn\b/i,
     "C3 [$BP_HARVEST]: harvest-judge template instructs ending the turn after launching background work");

# --- judge-resolve.md ---
like($resolve, qr/run_in_background/,
     "C3 [$BP_RESOLVE]: resolve-judge template carries run_in_background as the launch mechanism");
like($resolve, qr/(completion notification|resume(?:s|d)? (?:on|via) (?:the )?(?:completion )?notification)/i,
     "C3 [$BP_RESOLVE]: resolve-judge template instructs resuming on the completion notification");
like($resolve, qr/\bend\b.{0,20}\bturn\b/i,
     "C3 [$BP_RESOLVE]: resolve-judge template instructs ending the turn after launching background work");

# C3 corollary (spec 2.5): judges inherit this on a thinner budget (max_turns 20, 1800s
# timeout) and time out without ever writing a verdict -- at least one of the two judge
# templates should carry this framing so a judge understands WHY the discipline binds
# it too. Asserted as an OR across the two judge files (either carrying it satisfies the
# spec's "judges inherit this" framing), still per-file-readable since each variable
# names its own file.
ok(($harvest =~ qr/max_turns.{0,10}20|20.{0,10}turns/i && $harvest =~ qr/1800\s*s(?:ec(?:onds?)?)?\b/i)
   || ($resolve =~ qr/max_turns.{0,10}20|20.{0,10}turns/i && $resolve =~ qr/1800\s*s(?:ec(?:onds?)?)?\b/i),
   "C3/2.5 [$BP_HARVEST or $BP_RESOLVE]: at least one judge template states the thinner max_turns:20 / 1800s budget judges inherit this discipline under");

# =====================================================================================
# C4 -- the guidance says to check a result ONCE, never in a loop. Every field instance
# was waiting on something ALREADY COMPLETE (spec 2.4).
#
# VACUITY GATE: asserted on SUBSTANCE -- the specific "once, not in a loop" instruction
# -- not on a heading.
# =====================================================================================


# NB: bare `\bonce\b` and bare `BLOCKED` each ALREADY appear in coordinator-protocol/
# SKILL.md today, unrelated to waiting -- "redispatch once with a sharpened prompt"
# (worker dispatch contract) and the "A `BLOCKED:` message is protocol feedback"
# environment-contract line. Asserting either bare would vacuously pass with NO waiting
# guidance written at all, so both are asserted in PROXIMITY to the waiting-specific
# vocabulary that only the new section would introduce -- never as a bare word.
like($skill, qr/\bonce\b.{0,120}(sentinel|already\s+complete|result|artifact)|(sentinel|already\s+complete|result|artifact).{0,120}\bonce\b/is,
     "C4 [$BP_SKILL]: instructs checking a result/sentinel ONCE (in proximity, not the unrelated pre-existing 'redispatch once' worker-contract line)");
like($skill, qr/never\s+in\s+a\s+loop|not\s+in\s+a\s+loop|never\s+loop/i,
     "C4 [$BP_SKILL]: explicitly forbids checking in a loop (the substance, not a heading)");

# =====================================================================================
# C5 -- it points at b15's enforcement, so a coordinator learns the boundary from the
# document rather than from a BLOCKED: message mid-run.
# =====================================================================================

like($skill, qr/b15|wait-shape-guard/i,
     "C5 [$BP_SKILL]: points at b15's wait-shape-guard.sh enforcement");
like($skill, qr/(?:b15|wait-shape-guard).{0,200}BLOCKED|BLOCKED.{0,200}(?:b15|wait-shape-guard)/is,
     "C5 [$BP_SKILL]: names the BLOCKED: message NEAR the b15/wait-shape-guard pointer (in proximity, not the unrelated pre-existing environment-contract BLOCKED: line)");

# =====================================================================================
# C6 -- the ledger's own grep no longer returns zero: the CASE-SENSITIVE count for the
# awaiting vocabulary in coordinator-protocol/SKILL.md is now > 0.
#
# VACUITY GATE: this MUST count coordinator-protocol/SKILL.md SPECIFICALLY (not the repo,
# not the templates, not the hook) -- a repo-wide count is already satisfied today by
# b15's shipped wait-shape-guard.sh, which itself is dense with this vocabulary, without
# coordinator-protocol/SKILL.md changing one byte. The regex is the exact case-sensitive
# alternation given in spec Sec.0/Sec.3.
# =====================================================================================

{
    # NB: a qr// built with NO modifiers bakes in an explicit "(?^:...)" reset that an
    # outer /i at the match site cannot override (a documented perlre gotcha) -- so the
    # case-sensitive and case-insensitive matchers below are each compiled with their own
    # modifiers up front, never shared via one qr// plus a trailing /i.
    my $vocab_re_cs = qr/background|run_in_background|TaskOutput|poll|wait|Monitor|sleep/;
    my $vocab_re_ci = qr/background|run_in_background|TaskOutput|poll|wait|Monitor|sleep/i;
    my $count = () = $skill =~ /$vocab_re_cs/g;
    ok($count > 0,
       "C6 [$BP_SKILL]: case-sensitive count of the awaiting vocabulary "
       . '(background|run_in_background|TaskOutput|poll|wait|Monitor|sleep) is > 0 (got '
       . $count . '); today it is exactly 0');

    # Sanity companion (not a spec criterion, but guards against this file being fooled by
    # the SAME false positive the spec names at Sec.0 -- "thrashing burns the budget that
    # monitoring is protecting" -- lower-case "monitor" inside a longer word, which is the
    # one case-insensitive hit that exists today and must NOT be mistaken for C6 evidence).
    my $ci_count = () = $skill =~ /$vocab_re_ci/g;
    ok($ci_count >= $count,
       "C6 [$BP_SKILL]: case-insensitive count ($ci_count) is >= case-sensitive count ($count), as expected");
}

done_testing();
