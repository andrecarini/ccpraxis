#!/usr/bin/env perl
# 119-gate-headless-background.t — oracle for gate-headless-background.sh
# (h01-headless-background-gate spec §2.1, done criteria 1/2/3/7).
#
# THE INCIDENT THIS PINS. A harvest judge backgrounded a Bash call and ended
# its turn reasoning "I'll just stop and wait for that notification" — three
# times in the 2026-08-11 GSA fleet run. A headless `claude -p` has no next
# turn: the process exits when the turn ends, the notification has nowhere to
# arrive, and no verdict is ever written (sources/2026-08-11-gsa-fleet-collapse.md
# Bug 1). Decisions 2/3 (blueprint.md) are binding: enforce with a HOOK, and
# make it headless-AWARE — a blanket deny would break the mirror-image defect
# (Bug 7) where an INTERACTIVE driver's legitimate backgrounded dispatch gets
# blocked by gate-drive-loop.sh for want of a recorded wake-up.
#
# THE CONTRACT UNDER TEST (spec §2.1): the verdict is a pure function of
# BP_LEDGER's PRESENCE in the process environment. BP_ROLE customises the
# DENIAL MESSAGE ONLY — never the decision. A test that lets BP_ROLE change
# the decision must fail; several assertions below exist specifically to
# catch that regression in either direction (role that should still deny;
# role that must NOT itself trigger a deny with no BP_LEDGER).
#
# Runs standalone: perl plugins/butler/tests/t/119-gate-headless-background.t
# No container, no network; every fixture lives under File::Temp.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

my $HOOKS = "$Bin/../../hooks";
my $GATE  = "$HOOKS/gate-headless-background.sh";

ok(-f $GATE, 'the gate script exists at plugins/butler/hooks/gate-headless-background.sh')
    or diag('everything below will fail-for-the-right-reason (127/No such file) until it does');

# ---------------------------------------------------------------------------
# Helper: run the hook with a chosen environment and payload, capture both
# the exit code and stderr separately — never assert on stderr alone, since a
# hook that exits early on an unrelated path prints nothing and would pass an
# unlike() trivially.
# ---------------------------------------------------------------------------
sub run_gate {
    my ($payload, %env) = @_;
    my $envstr = '';
    for my $k (qw(BP_LEDGER BP_ROLE BP_DIR BP_PROJECT_ROOT)) {
        if (exists $env{$k}) {
            my $v = $env{$k};
            $v =~ s/'/'\\''/g;
            $envstr .= "$k='$v' ";
        } else {
            $envstr .= "$k= ";   # explicitly UNSET for this call
        }
    }
    my $out = `${envstr}bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub bg_payload {
    my (%opt) = @_;
    my $extra = $opt{extra} // '';
    my $bg    = exists $opt{bg} ? $opt{bg} : 'true';
    return qq({"session_id":"s1","cwd":"/x","tool_name":"Bash",)
         . qq("tool_input":{"command":"pnpm run build","run_in_background":$bg$extra}});
}

# ===========================================================================
# A. HEADLESS DENIAL (done criterion 1 / AC1 / behavior 1)
# ===========================================================================
{
    my ($rc, $out) = run_gate(bg_payload(), BP_LEDGER => '/fake/ledger.md');
    is($rc, 2, 'A1: headless (BP_LEDGER set) + run_in_background:true => exit 2 (BLOCK)');
    like($out, qr/run_in_background/i,
         'A2: denial message names the literal field run_in_background');
    like($out, qr/foreground/i,
         'A3: denial message names the alternative: foreground');
    like($out, qr/notification|never arrive|no later turn|no next turn/i,
         'A4: denial message names the reason (session ends when the turn ends)');
    like($out, qr/coordinator/i,
         'A5: with BP_ROLE unset (default coordinator), message refers to a coordinator');
}

# ===========================================================================
# B. HEADLESS DENIAL WITH BP_ROLE=harvest-judge (behavior 2 / AC1)
#    Decision (identical to A) but WORDING differs — this is the exact
#    incident (a headless harvest judge, not a coordinator).
# ===========================================================================
{
    my ($rc, $out) = run_gate(bg_payload(), BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'harvest-judge');
    is($rc, 2, 'B1: headless + BP_ROLE=harvest-judge => STILL exit 2 (decision unchanged by role)');
    like($out, qr/run_in_background/i, 'B2: message still names run_in_background');
    like($out, qr/foreground/i,        'B3: message still names foreground');
    like($out, qr/harvest-judge/i,
         'B4: message additionally NAMES the role — this is the wording-only customisation');
}

# ===========================================================================
# C. BP_ROLE CANNOT FLIP THE DECISION IN EITHER DIRECTION
#    This is the package's central pin: "BP_ROLE customises WORDING ONLY,
#    never behaviour."
# ===========================================================================
{
    # C1: a role that is neither "coordinator" nor a recognised judge name
    # must not somehow escape the deny while BP_LEDGER is set.
    my ($rc1) = run_gate(bg_payload(), BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'totally-invented-role');
    is($rc1, 2, 'C1: an unrecognised BP_ROLE does not weaken headless denial');

    # C2: the mirror case — BP_ROLE alone, with BP_LEDGER UNSET, must NOT
    # trigger a deny. If an implementation accidentally branches on BP_ROLE
    # instead of (or in addition to) BP_LEDGER, this is the assertion that
    # catches it: a judge role name present with no ledger is exactly what an
    # interactive session dispatching-by-hand while impersonating a role
    # would look like, and it must still be ALLOWED.
    my ($rc2) = run_gate(bg_payload(), BP_ROLE => 'harvest-judge');
    is($rc2, 0, 'C2: BP_ROLE=harvest-judge with BP_LEDGER UNSET is still ALLOWED — '
              . 'the decision keys on BP_LEDGER alone, never on BP_ROLE');
}

# ===========================================================================
# D. INTERACTIVE PERMISSION (done criterion 2 / AC2 / behavior 3)
#    The gate allows; mark-wakeup.sh (unmodified for the Bash path) records
#    the SAME call as a legitimate wake-up. Both halves are asserted jointly
#    so a fix that only allows (without leaving mark-wakeup.sh able to record)
#    cannot pass by half-measure.
# ===========================================================================
{
    my ($rc, $out) = run_gate(bg_payload());   # BP_LEDGER explicitly unset
    is($rc, 0, 'D1: interactive (BP_LEDGER unset) + run_in_background:true => exit 0 (allow)');

    my $MARK = "$HOOKS/mark-wakeup.sh";
    ok(-f $MARK, 'D2: mark-wakeup.sh exists (pre-existing, unchanged for the Bash path)');

    my $root = tempdir(CLEANUP => 1);
    require File::Path;
    File::Path::make_path("$root/.ccpraxis-local-data/.drive-solo");
    my $payload = qq({"session_id":"s1","cwd":"$root","tool_name":"Bash",)
                . qq("tool_input":{"command":"pnpm run build","run_in_background":true}});
    my $mout = `bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $mrc = $? >> 8;
    is($mrc, 0, 'D3: mark-wakeup.sh never blocks');
    ok(-f "$root/.ccpraxis-local-data/.drive-solo/.wakeup-pending",
       'D4: ...and records the SAME interactive backgrounded call as a wake-up '
     . '(gate-headless-background.sh allows; mark-wakeup.sh independently records — '
     . 'this is the full AC2 contract, not merely "does not block")');
}

# ===========================================================================
# E. NOT ITS BUSINESS: no run_in_background field, or explicitly false
#    (done criterion — behavior 4). Regardless of BP_LEDGER.
# ===========================================================================
{
    my ($rc1) = run_gate(bg_payload(bg => 'false'), BP_LEDGER => '/fake/ledger.md');
    is($rc1, 0, 'E1: run_in_background:false + headless => exit 0 (not this call'."'".'s business)');

    my $absent = qq({"session_id":"s1","cwd":"/x","tool_name":"Bash","tool_input":{"command":"pnpm run build"}});
    my ($rc2) = run_gate($absent, BP_LEDGER => '/fake/ledger.md');
    is($rc2, 0, 'E2: run_in_background absent entirely + headless => exit 0');

    my ($rc3) = run_gate($absent);
    is($rc3, 0, 'E3: run_in_background absent + interactive => exit 0');
}

# ===========================================================================
# F. THE VERDICT IS A PURE FUNCTION OF THE ENVIRONMENT — done criterion 3 /
#    AC3 / behavior 5 / done criterion 7's "claimed interactivity" fixture.
#    A payload that fabricates interactivity-looking fields must not move the
#    verdict; only BP_LEDGER's presence in the real process environment may.
# ===========================================================================
{
    my $lying = bg_payload(extra => q(,"session_type":"interactive","interactive":true));
    my ($rc, $out) = run_gate($lying, BP_LEDGER => '/fake/ledger.md');
    is($rc, 2, 'F1: a payload CLAIMING interactivity while BP_LEDGER is set is still DENIED — '
             . 'the agent controls the payload, never the verdict');
    like($out, qr/run_in_background/i, 'F2: ...and still carries the standard denial content');
}

# ===========================================================================
# G. BP_LEDGER set to the EMPTY STRING is treated as unset (matches every
#    other hook's `[ -n "${BP_LEDGER:-}" ]` treatment of the same variable).
# ===========================================================================
{
    my ($rc) = run_gate(bg_payload(), BP_LEDGER => '');
    is($rc, 0, 'G1: BP_LEDGER="" (empty, not unset) is treated as interactive => exit 0');
}

# ===========================================================================
# H. THE GATE READS BP_LEDGER ONLY — NOT bp_hook_gate's three-variable AND.
#    guard-writes.sh's bp_hook_gate requires BP_LEDGER AND BP_DIR AND
#    BP_PROJECT_ROOT all set before it does anything; copying that pattern
#    verbatim (rather than reading BP_LEDGER directly, as §2.1 mandates) would
#    make this gate SILENTLY ALLOW a headless call whenever BP_DIR or
#    BP_PROJECT_ROOT happened to be unset even though BP_LEDGER was set —
#    which never happens for a real bp-launch.sh/bp-judge.sh process, but a
#    test fixture that only sets BP_LEDGER must still see a DENY, or a
#    bp_hook_gate-style rewrite has quietly slipped in.
# ===========================================================================
{
    my ($rc) = run_gate(bg_payload(), BP_LEDGER => '/fake/ledger.md');
    is($rc, 2, 'H1: BP_LEDGER alone (BP_DIR/BP_PROJECT_ROOT unset) is sufficient to deny — '
             . 'the gate must not require the bp_hook_gate three-variable contract');
}

# ===========================================================================
# I. SOURCE-LEVEL INVARIANT: no bp_hook_gate call. bp_hook_gate can only make
#    a hook SKIP (exit 0) when BP_LEDGER is absent — it cannot make one branch
#    both ways, which is exactly why this hook must not call it (spec §2.1's
#    own commentary). Blank full-line comments first (t/94's G8 technique),
#    so a comment EXPLAINING why the call is absent does not itself match.
# ===========================================================================
SKIP: {
    skip 'gate script does not exist yet', 1 unless -f $GATE;
    open my $fh, '<', $GATE or skip "cannot read $GATE: $!", 1;
    my $src = do { local $/; <$fh> };
    close $fh;
    my $code = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;
    unlike($code, qr/\bbp_hook_gate\b\s*\(?\s*\)?\s*;?\s*$/m,
         'I1: bp_hook_gate is not INVOKED as a statement — it would suppress the interactive '
       . 'branch this hook must still execute (permit-and-record), not merely skip');
}

# ===========================================================================
# J. Exit code discipline: never anything other than 0 or 2.
# ===========================================================================
{
    my ($rc) = run_gate(bg_payload(), BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'resolve-judge');
    ok($rc == 0 || $rc == 2, "J1: exit code is 0 or 2, never anything else (got $rc)");
    is($rc, 2, 'J2: resolve-judge is still headless and still denied (role only changes wording)');
}

done_testing();
