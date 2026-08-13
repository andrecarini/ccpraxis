#!/usr/bin/env perl
# 140-hooks-reach-non-ccpraxis-project.t — the oracle package g02 exists to
# force into being (done criteria 2 and 5; spec §3 behaviors 1/2/7, AC2, AC5).
#
# THE FAILURE THIS FILE IS WRITTEN AGAINST. Two pre-existing suites --
# plugins/sandbox/tests/t/61-settings-scope-split.t and
# plugins/butler/tests/t/112-subagent-stall-guard.t -- assert only that a
# command STRING appears inside .claude/settings.json's JSON structure. Both
# stayed green while gate-headless-background.sh and guard-judge-checks.sh
# were registered on a route ($CLAUDE_PROJECT_DIR-relative, in ccpraxis's own
# tracked settings.json) that cannot reach any other project on this machine
# -- the exact incident (2026-08-11 GSA fleet collapse) that motivated
# guard-judge-checks.sh happened in a project this registration never
# touched. "A path string appears in a file" is not evidence a hook runs
# anywhere. This file never asserts that. Every block below either (a) runs
# the hook script itself from a directory that is demonstrably not ccpraxis,
# with environment values that simulate a foreign project being driven, or
# (b) proves the OLD dead route is still dead, so the fix cannot be "add a
# second redundant live path" dressed up as a repair.
#
# WHAT THIS FILE DOES NOT PROVE (state it plainly, per the driver's
# instruction, rather than imply more than is shown). It does NOT launch a
# real `claude -p` session against a foreign project and observe Claude
# Code's own hook dispatch pick up hooks.json's entries -- no such harness
# exists in this repo (spec §6, explicitly out of scope: "testing Claude
# Code's own hook dispatch, not this package's code"). What it DOES prove is
# the necessary condition the fix depends on and the scout already proved at
# the mechanism level: gate-headless-background.sh and guard-judge-checks.sh,
# invoked by absolute path, are cwd-independent and
# $CLAUDE_PROJECT_DIR-independent -- their verdict is a pure function of the
# process environment (BP_LEDGER/BP_ROLE), never of where they are called
# from or what project is nominally "current". That independence is exactly
# what makes routing them through ${CLAUDE_PLUGIN_ROOT} (hooks.json, resolved
# machine-wide via the live install regardless of driven project -- proven at
# the mechanism level in scout-step1.md item 1) sufficient to reach a foreign
# project: whatever invokes the script correctly, the script itself will not
# refuse to act just because the cwd or CLAUDE_PROJECT_DIR is foreign. If a
# future change made either script SILENTLY EXIT 0 on unrecognised cwd or
# unset CLAUDE_PROJECT_DIR, this file goes red; today, before g02's edit, it
# is already green (the scripts have always been environment-pure) -- so this
# file's contribution is not "goes red before the fix, green after" but
# "pins the necessary condition and makes any future regression of it
# visible", complementing 141 (which pins the registration-route half that IS
# red before the fix).
#
# Runs standalone: perl plugins/butler/tests/t/140-hooks-reach-non-ccpraxis-project.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $HOOKS = "$Bin/../../hooks";
my $GATE  = "$HOOKS/gate-headless-background.sh";
my $GUARD = "$HOOKS/guard-judge-checks.sh";

ok(-f $GATE,  'gate-headless-background.sh exists at its documented path')
    or diag('everything below fails-for-the-right-reason (missing file) until it does');
ok(-f $GUARD, 'guard-judge-checks.sh exists at its documented path')
    or diag('everything below fails-for-the-right-reason (missing file) until it does');

my $HAVE_JQ = `command -v jq 2>/dev/null` ne '';

# A directory that is demonstrably NOT an ancestor of this repo, and whose
# tree (like every real non-ccpraxis project verified by the scout: DAME,
# GSA) has no plugins/butler/hooks/ at all.
my $FOREIGN = tempdir(CLEANUP => 1);
$FOREIGN = abs_path($FOREIGN);

ok(!-d "$FOREIGN/plugins/butler/hooks",
   'sanity: the foreign root has no plugins/butler/hooks/, matching every real '
 . 'non-ccpraxis project the scout verified (DAME, GSA)');

# ---------------------------------------------------------------------------
# Helper: run a hook BY ABSOLUTE PATH, with cwd set to $FOREIGN and
# CLAUDE_PROJECT_DIR set to $FOREIGN (simulating bp-launch.sh's `cd
# "$PROJECT_ROOT"` into a project that is not ccpraxis, then a headless
# `claude -p` with no --settings override -- exactly the shape spec §1
# describes). Never asserts on stderr alone (a hook that exits early prints
# nothing and would pass an unlike() trivially) -- always pairs rc with
# content when content is asserted.
# ---------------------------------------------------------------------------
sub run_from_foreign {
    my ($script, $payload, %env) = @_;
    my $envstr = 'BP_LEDGER= BP_ROLE= BP_DIR= BP_PROJECT_ROOT= CLAUDE_PROJECT_DIR= ';
    for my $k (qw(BP_LEDGER BP_ROLE BP_DIR BP_PROJECT_ROOT CLAUDE_PROJECT_DIR)) {
        next unless exists $env{$k};
        my $v = $env{$k};
        $v =~ s/'/'\\''/g;
        $envstr .= "$k='$v' ";
    }
    my $abs = abs_path($script);
    my $out = `cd "$FOREIGN" && ${envstr}bash "$abs" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub bg_payload {
    return qq({"session_id":"s1","cwd":"$FOREIGN","tool_name":"Bash",)
         . qq("tool_input":{"command":"pnpm run build","run_in_background":true}});
}

sub judge_payload {
    my ($cmd) = @_;
    return qq({"session_id":"s1","cwd":"$FOREIGN","tool_name":"Bash",)
         . qq("tool_input":{"command":"$cmd"}});
}

# ===========================================================================
# A. gate-headless-background.sh, invoked from a foreign cwd with
#    CLAUDE_PROJECT_DIR pointed at that same foreign root (behavior 1, AC2).
#    Would fail if the script silently allowed (rc != 2) merely because it
#    was invoked from outside ccpraxis -- which is exactly the failure mode
#    the old registration route produced (never invoked at all, functionally
#    indistinguishable from "always allows").
# ===========================================================================
{
    my ($rc, $out) = run_from_foreign($GATE, bg_payload(),
        BP_LEDGER => '/fake/ledger.md', CLAUDE_PROJECT_DIR => $FOREIGN);
    is($rc, 2, 'A1: from a foreign cwd, with CLAUDE_PROJECT_DIR set to that same foreign root, '
             . 'headless (BP_LEDGER set) + run_in_background:true is STILL denied (exit 2)');
    like($out, qr/run_in_background/i, 'A2: ...and still carries the standard denial content');
}

# ===========================================================================
# B. Same, with CLAUDE_PROJECT_DIR entirely UNSET (the other half of "cwd or
#    CLAUDE_PROJECT_DIR", per behavior 1's own wording).
# ===========================================================================
{
    my ($rc, $out) = run_from_foreign($GATE, bg_payload(), BP_LEDGER => '/fake/ledger.md');
    is($rc, 2, 'B1: from a foreign cwd with CLAUDE_PROJECT_DIR entirely UNSET, still denied (exit 2)');
    like($out, qr/run_in_background/i, 'B2: ...and still carries the standard denial content');
}

# ===========================================================================
# C. The interactive-allow half, ALSO proven from the foreign root -- a fix
#    that only proved the DENY path reaches elsewhere, and left the ALLOW
#    path untested from a foreign cwd, would be an asymmetric proof.
# ===========================================================================
{
    my ($rc) = run_from_foreign($GATE, bg_payload(), CLAUDE_PROJECT_DIR => $FOREIGN);
    is($rc, 0, 'C1: from a foreign cwd, BP_LEDGER unset => exit 0 (allow), same as from ccpraxis');
}

# ===========================================================================
# D. guard-judge-checks.sh, same independence claim (behavior 2, AC2).
#    SKIP the jq-dependent assertion on a jq-less host (this host confirmed
#    jq-less), per the established 121-guard-judge-checks.t pattern -- a
#    false negative for an infrastructure reason is exactly what must be
#    avoided.
# ===========================================================================
SKIP: {
    skip 'jq is not installed on this host; guard-judge-checks.sh hard-requires it by design', 2
        unless $HAVE_JQ;
    my ($rc, $out) = run_from_foreign($GUARD, judge_payload('pnpm run lint'),
        BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'harvest-judge', CLAUDE_PROJECT_DIR => $FOREIGN);
    is($rc, 2, 'D1: from a foreign cwd/CLAUDE_PROJECT_DIR, a harvest-judge re-running a declared '
             . 'check is STILL denied (exit 2) -- identical to invoking from ccpraxis'."'".' own tree');
    like($out, qr/declared|evidence|contracted slice/i, 'D2: ...with the standard denial content');
}
{
    # The BP_LEDGER-unset precondition holds on ANY host, jq or not (matches
    # 121's block A) -- runs unconditionally so this file is not entirely
    # jq-gated.
    my ($rc) = run_from_foreign($GUARD, judge_payload('pnpm run lint'), CLAUDE_PROJECT_DIR => $FOREIGN);
    is($rc, 0, 'D3: from a foreign cwd, BP_LEDGER unset => exit 0, same as from ccpraxis '
             . '(this rule exists only inside a headless judge process, regardless of cwd)');
}

# ===========================================================================
# E. THE OLD ROUTE IS STILL DEAD (behavior 7). A literal simulation of what
#    .claude/settings.json's $CLAUDE_PROJECT_DIR-relative command would
#    resolve to for a coordinator/judge driving $FOREIGN: the shell itself
#    must fail to find the file (rc != 0, "No such file or directory"), NOT
#    the hook script producing rc 2 for some other reason. This distinguishes
#    "the fix removed the dead route" from "the fix added a second live route
#    alongside a dead one that still looks superficially present".
# ===========================================================================
{
    my $dead_path = "$FOREIGN/plugins/butler/hooks/gate-headless-background.sh";
    ok(!-f $dead_path, 'E1: sanity -- the old $CLAUDE_PROJECT_DIR-relative path does not exist '
                      . 'under the foreign root (matches DAME/GSA, verified absent by the scout)');
    my $out = `bash "$dead_path" 2>&1`;
    my $rc  = $? >> 8;
    isnt($rc, 0, 'E2: attempting to invoke the old dead route fails (non-zero exit)');
    like($out, qr/No such file or directory/i,
         'E3: ...and fails with a shell-level "No such file or directory", not a hook-level denial -- '
       . 'proving the failure is "route does not exist" and not "route exists but happens to deny"');
}
{
    my $dead_path = "$FOREIGN/plugins/butler/hooks/guard-judge-checks.sh";
    my $out = `bash "$dead_path" 2>&1`;
    my $rc  = $? >> 8;
    isnt($rc, 0, 'E4: same for guard-judge-checks.sh'."'".' old dead route');
    like($out, qr/No such file or directory/i, 'E5: ...same shell-level failure');
}

# ===========================================================================
# F. Bonus, non-blocking corroboration against a REAL second project on this
#    machine, per AC2's explicit "additionally, non-fatally, against
#    /c/Development/DAME if that path exists". SKIP entirely (never FAIL) if
#    absent, so this suite stays portable off this one machine.
# ===========================================================================
SKIP: {
    my $dame = '/c/Development/DAME';
    skip 'DAME is not present on this host; the required, always-run proof is the tempdir case above', 3
        unless -d $dame;

    ok(!-d "$dame/plugins/butler/hooks",
       'F1: corroboration -- DAME, a REAL second project on this machine, has no '
     . 'plugins/butler/hooks/ either (matches the scout'."'".'s verified absence)');

    my ($rc, $out) = run_from_foreign($GATE, bg_payload(),
        BP_LEDGER => '/fake/ledger.md', CLAUDE_PROJECT_DIR => $dame);
    # run_from_foreign always cd's into $FOREIGN, not $dame -- for this block
    # specifically we want cwd=$dame too, so re-invoke directly here rather
    # than reuse the helper's fixed cd target.
    my $envstr = "BP_LEDGER='/fake/ledger.md' BP_ROLE= BP_DIR= BP_PROJECT_ROOT= CLAUDE_PROJECT_DIR='$dame' ";
    my $abs = abs_path($GATE);
    my $payload = qq({"session_id":"s1","cwd":"$dame","tool_name":"Bash",)
                . qq("tool_input":{"command":"pnpm run build","run_in_background":true}});
    $out = `cd "$dame" && ${envstr}bash "$abs" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    $rc = $? >> 8;
    is($rc, 2, 'F2: from DAME'."'".'s real cwd, with CLAUDE_PROJECT_DIR=DAME, headless denial still fires');
    like($out, qr/run_in_background/i, 'F3: ...with the standard denial content');
}

done_testing();
