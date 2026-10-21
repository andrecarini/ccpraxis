#!/usr/bin/env perl
# platform: any
# NEW oracle for blueprint butler-gate-ergonomics package 03-retire-runstate,
# spec §3 (the executable-reference detector, exact specification) and §4
# B15/B16, AC-2/AC-3.
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/03-retire-runstate-spec.md
# section 3 -- NOT from bp-runstate.pl's own implementation (which this
# package deletes) and not from any of the files this detector scans.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. bp-runstate.pl still exists on disk as
# this file is written, and it is referenced from bp-watch.pl,
# guard-ask-operator.sh, bp-continuity.pl, three SKILL.md files, and several
# .t files (per spec §2.9's own table). D1/D2 below are therefore EXPECTED
# to report many hits until the implementer migrates every one of those
# callers off and deletes the file. That is the correct, non-vacuous,
# blind-oracle failure: this file asserts a PROPERTY of the tree (zero
# executable references), not a specific migration mechanism.
#
# ===========================================================================
# A NOTED SPEC INCONSISTENCY (recorded here AND in this package's test-writer
# report, per this task's own instruction to report rather than invent):
# spec §3.3's counter-fixture table claims D2 (§3.2's pattern,
# `m{scripts/bp-runstate\.pl} || m{BpRunState::}`, literally as given) fires
# ("1 hit") on the fixture `require "$DIR/bp-runstate.pl";`. Run literally,
# it does not -- that fixture string contains neither the substring
# "scripts/bp-runstate.pl" (no "scripts/" segment precedes "bp-runstate.pl"
# in "$DIR/bp-runstate.pl") nor "BpRunState::". This file implements the
# REGEX exactly as given in the spec's own code block (§3.2), because that
# code block is unambiguous and its "scripts/" qualifier is load-bearing
# elsewhere in the very same section: it is what distinguishes a resolved-
# path CALLER from a bare-name absence assertion like
# `unlike($code, qr/bp-runstate\.pl/, ...)`, which §3.2's prose explicitly
# and repeatedly says must NOT be flagged. Broadening the pattern to bare
# "bp-runstate\.pl" (which WOULD satisfy the table's row-1 claim) would
# flag every such `unlike(...)` assertion across the suite instead --
# directly contradicting that explicit, emphasized rule. So the counter-
# fixture assertions below follow the LITERAL regex, not the table's row-1
# count, and say so at that specific assertion.
# ===========================================================================
use strict;
use warnings;

# A test must never actuate a real wake-lock (test-wakelock-hygiene.t).
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Find ();

(my $PLUGIN = "$Bin/../..") =~ s{\\}{/}g;
my $SCRIPTS_DIR = "$PLUGIN/scripts";
my $HOOKS_DIR   = "$PLUGIN/hooks";
my $SKILLS_DIR  = "$PLUGIN/skills";
my $TESTS_DIR   = $Bin;

# The one named exemption (spec §3.1): guard-run-finish.sh's *bp-runstate*
# case pattern and runstate_re regex are an AUTHORISATION GUARD over a
# command string a human might still type, not a caller. Removing them would
# silently un-gate a run-ending spelling that run-finish-guard.t,
# run-finish-reads-invocations.t and finish-guard-counts-live-runs.t depend
# on (spec §2.9's "must NOT be changed" list; spec §7's out-of-scope note).
(my $EXEMPT_D1 = "$HOOKS_DIR/guard-run-finish.sh") =~ s{\\}{/}g;

# ===========================================================================
# Detector D1 (spec §3.1) -- verbatim.
# ===========================================================================
sub _executable_runstate_hits {
    my ($src) = @_;
    my @hits;
    for my $line (split /\n/, $src) {
        (my $code = $line) =~ s/#.*$//;
        push @hits, $line if $code =~ /bp-runstate|BpRunState/;
    }
    return @hits;
}

# D1's .md branch (spec §3.1): NO comment stripping at all -- a '#' in
# markdown is a heading, and a heading naming a dead verb is exactly what
# must not survive. Whole-file, zero-occurrence rule.
sub _md_runstate_hits {
    my ($src) = @_;
    my @hits;
    for my $line (split /\n/, $src) {
        push @hits, $line if $line =~ /bp-runstate|BpRunState/;
    }
    return @hits;
}

# ===========================================================================
# Detector D2 (spec §3.2) -- verbatim.
# ===========================================================================
sub _test_tree_runstate_hits {
    my ($src) = @_;
    my @hits;
    for my $line (split /\n/, $src) {
        (my $code = $line) =~ s/#.*$//;
        push @hits, $line if $code =~ m{scripts/bp-runstate\.pl} || $code =~ m{BpRunState::};
    }
    return @hits;
}

sub _slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or die "read $p: $!";
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s // '';
}

sub _find_files {
    my ($dir, $ext_re) = @_;
    my @out;
    return @out unless -d $dir;
    File::Find::find({
        wanted => sub {
            return unless -f $_;
            push @out, $File::Find::name if $File::Find::name =~ $ext_re;
        },
        no_chdir => 1,
    }, $dir);
    return sort @out;
}

# ===========================================================================
# §3.3 NON-VACUITY -- the six counter-fixtures, proved FIRST and
# independently of the real tree's current state (these are pure-function
# assertions over fabricated strings; they must pass regardless of
# bp-runstate.pl's implementation status, today or after migration).
# ===========================================================================

# Row 1: require "$DIR/bp-runstate.pl";  -- D1: 1 hit.
{
    my $line = qq{require "\$DIR/bp-runstate.pl";\n};
    my @d1 = _executable_runstate_hits($line);
    is(scalar(@d1), 1, 'CF1 (D1): require "$DIR/bp-runstate.pl"; -> exactly 1 hit');

    # D2, per the LITERAL regex (see header note above): this fixture string
    # contains no "scripts/" segment immediately before "bp-runstate.pl" and
    # no "BpRunState::", so the literal pattern gives 0, not the spec
    # table's stated 1. Asserted as what the code actually does, not as an
    # invented behavior -- flagged in the test-writer report as a spec
    # inconsistency rather than silently "fixed" here.
    my @d2 = _test_tree_runstate_hits($line);
    is(scalar(@d2), 0,
       'CF1 (D2), DEVIATES FROM SPEC TABLE (documented above and in the test-writer report): '
     . 'the literal pattern m{scripts/bp-runstate\.pl}||m{BpRunState::} does not match this '
     . 'exact fixture (no "scripts/" segment present) -- the spec\'s own §3.3 table claims 1 '
     . 'hit here, which this file does not reproduce because doing so would require widening '
     . 'the pattern in a way that breaks the explicitly-required non-flagging of absence '
     . 'assertions (CF6 below)');

    # A representative REAL caller form (matches spec §3.2's own first prose
    # example, "$Bin/../../scripts/bp-runstate.pl") DOES trip D2, proving D2
    # is not vacuously zero for every string -- this is the non-vacuity half
    # the spec table's row 1 was trying to establish.
    my $real_form = qq{my \$SCRIPT = "\$Bin/../../scripts/bp-runstate.pl";\n};
    my @d2b = _test_tree_runstate_hits($real_form);
    is(scalar(@d2b), 1,
       'CF1b (D2 non-vacuity, real caller shape): a resolved path built with the literal '
     . '"scripts/" segment DOES trip D2 -- proving D2 is a real predicate, not always 0');
}

# Row 2: my ($ok, $msg) = BpRunState::pause($root, %o);  -- D1: 1, D2: 1.
{
    my $line = qq{my (\$ok, \$msg) = BpRunState::pause(\$root, \%o);\n};
    is(scalar(_executable_runstate_hits($line)), 1,
       'CF2 (D1): a bare BpRunState::pause(...) call -> exactly 1 hit');
    is(scalar(_test_tree_runstate_hits($line)), 1,
       'CF2 (D2): the same line -> exactly 1 hit (BpRunState:: is caught directly, no '
     . '"scripts/" qualifier needed for this branch of the pattern)');
}

# Row 3: a whole-line historical-precedent comment naming bp-runstate.pl --
# D1: 0, D2: 0 (comment-stripped to nothing).
{
    my $line = qq{# bp-runstate.pl was retired by package 03; see BpResumption.pm\n};
    is(scalar(_executable_runstate_hits($line)), 0,
       'CF3 (D1): a whole-line comment naming bp-runstate.pl -> 0 hits (comment-stripped)');
    is(scalar(_test_tree_runstate_hits($line)), 0,
       'CF3 (D2): the same comment -> 0 hits');
}

# Row 4: a whole-line comment naming BpRunState:: -- D1: 0, D2: 0.
{
    my $line = qq{# BpRunState::pause used to hold the lease here\n};
    is(scalar(_executable_runstate_hits($line)), 0,
       'CF4 (D1): a whole-line comment naming BpRunState:: -> 0 hits');
    is(scalar(_test_tree_runstate_hits($line)), 0,
       'CF4 (D2): the same comment -> 0 hits');
}

# Row 5: ordinary English/identifier verb words ($rec->{status}, finish_count(),
# pause_for($x)) -- D1: 0 (PINS §3.1's deliberate verb-exclusion decision).
{
    my $line = qq{my \$st = \$rec->{status}; my \$n = finish_count(); pause_for(\$x);\n};
    is(scalar(_executable_runstate_hits($line)), 0,
       'CF5 (D1) CANONICAL -- pins §3.1\'s own verb-exclusion decision: "status", "finish" '
     . 'and "pause" as ordinary identifiers/English never trip D1 -- only "bp-runstate" or '
     . '"BpRunState" do, deliberately, because a pattern including the four verbs would flag '
     . 'dozens of unrelated lines across this tree (package ledgers\' "status: running", '
     . '$rec->{status}, drive-solo/SKILL.md\'s "pause" action word, guard-run-finish.sh itself)');
    is(scalar(_test_tree_runstate_hits($line)), 0,
       'CF5 (D2): the same line -> 0 hits (D2 is narrower than D1 but agrees on this line)');
}

# Row 6: an assertion OF ABSENCE, exactly the shape used across the suite --
# D2: 0 (out of D1's scope entirely per the table; not asserted for D1 here).
{
    my $line = qq{unlike(\$code, qr/bp-runstate\\.pl/, 'the hook never names it');\n};
    is(scalar(_test_tree_runstate_hits($line)), 0,
       'CF6 (D2) CANONICAL -- pins §3.2\'s own stated purpose: an assertion OF ABSENCE '
     . '(unlike($code, qr/bp-runstate\.pl/, ...)) is NOT flagged by D2 -- flagging it would '
     . 'push a package under pressure to delete the very assertions that make the deletion '
     . 'verifiable (audit-05\'s stated failure mode one level down), and this exact shape is '
     . 'used live today by subagent-stall-guard.t\'s AC6/AC27, drive-loop-gate.t\'s AC23 and '
     . 'reporter-stop-gate.t\'s AC23, all of which must keep passing D2 unchanged');
}

# ===========================================================================
# AC-2/B15 -- D1 over the real tree: scripts/, hooks/, skills/ (recursive),
# minus the one named exemption. EXPECTED TO FAIL (many hits) until every
# caller in spec §2.1/§2.2/§2.5-§2.7's write set is migrated and the file is
# deleted.
# ===========================================================================
{
    # Fix-batch HIGH-2: this was qr/\.(?:pl|pm)\z/, silently omitting the nine
    # .sh files under scripts/ (bp-lib.sh among them, sourced by every butler
    # hook) despite the assertion below claiming .pl/.pm/.sh coverage. scripts/
    # gets the same three-extension pattern hooks/ and skills/ already use.
    my @files = (
        _find_files($SCRIPTS_DIR, qr/\.(?:pl|pm|sh)\z/),
        _find_files($HOOKS_DIR,   qr/\.sh\z/),
        _find_files($SKILLS_DIR,  qr/\.(?:pl|pm|sh)\z/),
    );
    my @all_hits;
    my @exempt_hits;
    for my $f (@files) {
        (my $fn = $f) =~ s{\\}{/}g;
        if ($fn eq $EXEMPT_D1) {
            push @exempt_hits, _executable_runstate_hits(_slurp($f));
            next;
        }
        my @hits = _executable_runstate_hits(_slurp($f));
        push @all_hits, map { "$fn: $_" } @hits;
    }
    is(scalar(@all_hits), 0,
       'AC-2/D1: zero executable bp-runstate/BpRunState references across scripts/, hooks/ '
     . '(both .pl/.pm/.sh), and skills/*.pl|*.pm|*.sh, minus the guard-run-finish.sh exemption')
        or diag("executable D1 hit(s):\n  " . join("\n  ", @all_hits));

    # Fix-batch MEDIUM-6: the exemption used to `next` past guard-run-finish.sh
    # entirely, so a future genuine reference added anywhere in that file
    # would be invisible to D1 forever. Scan it too and pin the hit COUNT to
    # its two known, legitimate, non-executable references (the *bp-runstate*
    # case pattern and the runstate_re regex) -- a new/different reference
    # changes the count and fails, which is the point.
    # guard-run-finish.sh itself is on package 16's deletion list (batch B);
    # its runstate exemption goes with it (spec 16 sec 4 batch B note) -- the
    # file is simply absent from @files now, so the exemption branch never
    # fires and @exempt_hits is always empty (DEL: subject file deleted).
    is(scalar(@exempt_hits), 0,
       'AC-2/D1 exemption is now VACUOUS, not bounded: guard-run-finish.sh no longer exists '
     . '(package 16 batch B deletion), so its exemption branch never fires')
        or diag("guard-run-finish.sh D1 hit(s):\n  " . join("\n  ", @exempt_hits));
}

# D1's .md branch: every skills/**/*.md file, zero occurrences anywhere
# (no comment-stripping -- spec §3.1/§6's "an implementer who unifies the
# two branches will silently stop checking the skills" warning).
{
    my @md = _find_files($SKILLS_DIR, qr/\.md\z/);
    my @all_hits;
    for my $f (@md) {
        (my $fn = $f) =~ s{\\}{/}g;
        my @hits = _md_runstate_hits(_slurp($f));
        push @all_hits, map { "$fn: $_" } @hits;
    }
    is(scalar(@all_hits), 0,
       'AC-2/D1 (.md branch) / B16: zero occurrences of bp-runstate/BpRunState anywhere in '
     . 'any skills/**/*.md file -- no skill instructs anyone to call a verb that no longer '
     . 'exists')
        or diag("markdown D1 hit(s):\n  " . join("\n  ", @all_hits));
}

# The three specific skills the spec names must each independently show zero
# (B16, spelled out per-file so a failure names exactly which skill still
# teaches the dead verb, not just "some skill somewhere").
for my $skill (qw(drive-solo reporter coordinator-protocol)) {
    my $path = "$SKILLS_DIR/$skill/SKILL.md";
  SKIP: {
        skip "no $skill/SKILL.md on disk", 1 unless -f $path;
        my @hits = _md_runstate_hits(_slurp($path));
        is(scalar(@hits), 0,
           "B16: $skill/SKILL.md contains zero bp-runstate/BpRunState occurrences")
            or diag("hit(s):\n  " . join("\n  ", @hits));
    }
}

# ===========================================================================
# AC-2/B15 -- D2 over the real test tree: plugins/butler/tests/t/*.t.
# EXPECTED TO FAIL (hits from the files this package's own migration plan
# has not yet reached, and from the 4 doomed runstate-*.t files this
# package's IMPLEMENTER deletes, not this test-writer) until the
# implementation lands.
# ===========================================================================
{
    # SELF-EXEMPTION, added by this test-writer, not stated in the spec: this
    # very file's own fixture strings (CF1b, CF2, CF4, the diagnostic-message
    # literals) necessarily CONTAIN the literal patterns D2 looks for -- that
    # is the whole non-vacuity proof above. Scanning this file against its
    # own detector would make AC-2/D2 permanently unsatisfiable regardless of
    # migration progress, which cannot be the intent (D1 already carries one
    # explicit, named, reasoned exemption for the identical structural
    # reason -- a detector cannot be made to flag the fixture text that
    # proves it works). Recorded in the test-writer report as an addition
    # beyond the spec's literal text.
    (my $SELF = "$Bin/runstate-references-retired.t") =~ s{\\}{/}g;

    # DRIVER RULING (package 03, 2026-09-23): a second named D2 exemption,
    # for the identical structural reason D1 already exempts
    # guard-run-finish.sh (line ~60 above). run-finish-guard.t's fixture
    # strings (e.g. 'perl plugins/butler/scripts/bp-runstate.pl finish
    # --reason "x"') feed run_guard() to prove guard-run-finish.sh BLOCKS a
    # human from typing that spelling -- they are proof text for an
    # authorization guard, not an executable caller of the retired script.
    # run-finish-guard.t is explicitly protected and out of this package's
    # write set (spec SS2.9/SS7); its ~26 assertions must not be touched to
    # chase this detector green. Test-writer flagged this as an open
    # question rather than resolving it unilaterally -- resolved here.
    (my $EXEMPT_D2 = "$Bin/run-finish-guard.t") =~ s{\\}{/}g;

    my @t_files = _find_files($TESTS_DIR, qr/\.t\z/);
    my @all_hits;
    my @exempt_hits2;
    for my $f (@t_files) {
        (my $fn = $f) =~ s{\\}{/}g;
        next if $fn eq $SELF;
        if ($fn eq $EXEMPT_D2) {
            push @exempt_hits2, _test_tree_runstate_hits(_slurp($f));
            next;
        }
        my @hits = _test_tree_runstate_hits(_slurp($f));
        push @all_hits, map { "$fn: $_" } @hits;
    }
    is(scalar(@all_hits), 0,
       'AC-2/D2: zero D2-pattern references (a resolved scripts/bp-runstate.pl path, or '
     . 'BpRunState::) across plugins/butler/tests/t/*.t, excluding this detector file itself '
     . 'and run-finish-guard.t (a named exemption, same reason as D1\'s guard-run-finish.sh: '
     . 'proof text for an authorization guard, not a caller)')
        or diag("test-tree D2 hit(s):\n  " . join("\n  ", @all_hits));

    # Fix-batch MEDIUM-6: same bounding for the D2 exemption -- scan
    # run-finish-guard.t too and pin its hit count to the 11 fixture strings
    # it currently carries (all `run_guard(command => 'perl .../bp-runstate.pl
    # finish ...')` proof text for the authorization guard), rather than
    # skipping the file unconditionally.
    # run-finish-guard.t is itself on package 16's deletion list (batch B,
    # its subject guard-run-finish.sh is gone); the exemption branch never
    # fires now that the file is absent from plugins/butler/tests/t/*.t
    # (DEL: subject test file deleted).
    is(scalar(@exempt_hits2), 0,
       'AC-2/D2 exemption is now VACUOUS, not bounded: run-finish-guard.t no longer exists '
     . '(package 16 batch B deletion), so its exemption branch never fires')
        or diag("run-finish-guard.t D2 hit(s):\n  " . join("\n  ", @exempt_hits2));
}

# ===========================================================================
# AC-1 -- bp-runstate.pl is absent from disk. Independent of D1/D2 (a direct
# existence check), and the one assertion in this whole file that is a
# simple negative -f rather than a source scan.
# ===========================================================================
{
    my $path = "$SCRIPTS_DIR/bp-runstate.pl";
    ok(!-f $path, 'AC-1: plugins/butler/scripts/bp-runstate.pl does not exist on disk');
}

done_testing();
