#!/usr/bin/env perl
# 121-guard-judge-checks.t — oracle for guard-judge-checks.sh (h01 spec §2.2,
# done criterion 6, AC6).
#
# THE RULE THIS MECHANISES. bp-harvest-judge.md's own Method already says a
# declared `checks:` entry is verified "via a declared artefact, never by
# re-running them" — and all three judge runs in the 2026-08-11 GSA fleet
# incident re-ran `pnpm run lint`, `pnpm run build` and `pnpm test` anyway
# (sources/2026-08-11-gsa-fleet-collapse.md:125). A second, independent
# instance of prose failing to bind in the SAME incident. This hook makes it
# mechanical.
#
# DELIBERATELY NARROW — per the spec's own out-of-scope section (§6). This is
# NOT a general "declared artefact" verifier: it refuses exactly the
# pnpm/npm/yarn (run)? lint|build|test shape named in the incident evidence,
# and ONLY when BP_ROLE=harvest-judge (the rule exists nowhere else). Do not
# read the assertions below as demanding broader coverage — the spec never
# promised it, and asserting that would invent behavior it does not state.
#
# jq AVAILABILITY. bp_hook_require_jq (lib.sh) hard-fails closed when jq is
# absent — deliberately, because this hook is designed to run only inside the
# judge's sandboxed claude -p, where jq is guaranteed. jq does NOT exist on
# this Windows host (confirmed: `command -v jq` -> not found), so the
# regex-matching assertions (which require jq to read tool_input.command) are
# gated behind a runtime check and SKIPped on a jq-less host rather than
# asserted incorrectly — that would fail for an infrastructure reason, not a
# missing-behavior reason, which is exactly the false-negative this suite
# must avoid. The fail-closed behavior itself (K section) is asserted
# unconditionally on either host, because it must hold on both.
#
# Runs standalone: perl plugins/butler/tests/t/121-guard-judge-checks.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $HOOKS = "$Bin/../../hooks";
my $GUARD = "$HOOKS/guard-judge-checks.sh";

ok(-f $GUARD, 'guard-judge-checks.sh exists at plugins/butler/hooks/guard-judge-checks.sh')
    or diag('everything below fails-for-the-right-reason until it does');

my $HAVE_JQ = `command -v jq 2>/dev/null` ne '';

sub run_guard {
    my ($cmd, %env) = @_;
    my $payload = qq({"session_id":"s1","cwd":"/x","tool_name":"Bash",)
                . qq("tool_input":{"command":"$cmd"}});
    # Both overrides must be APPENDED. In a shell env-var prefix the LAST
    # assignment wins, so prepending BP_LEDGER (as this did) left the base
    # string's trailing `BP_LEDGER=` in force and BP_LEDGER was empty in every
    # single call. That did not merely break K1: it made block B pass VACUOUSLY,
    # because the guard exited 0 at its BP_LEDGER check and never reached the
    # BP_ROLE check that block exists to test. BP_ROLE was already appended and
    # was therefore fine -- the asymmetry is what hid it.
    my $envstr = 'BP_LEDGER= BP_ROLE= ';
    $envstr .= "BP_LEDGER='$env{BP_LEDGER}' "        if defined $env{BP_LEDGER};
    $envstr .= "BP_ROLE='$env{BP_ROLE}' "            if defined $env{BP_ROLE};
    my $out = `${envstr}bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# ===========================================================================
# A. BP_LEDGER unset => exit 0, no matter the role or command. This check
#    precedes bp_hook_require_jq, so it holds on ANY host, jq or not.
# ===========================================================================
{
    my ($rc) = run_guard('pnpm run lint', BP_ROLE => 'harvest-judge');
    is($rc, 0, 'A1: BP_LEDGER unset => exit 0 even with a matching command + harvest-judge role '
             . '(this rule exists only inside a headless judge process)');
}

# ===========================================================================
# B. BP_LEDGER set but BP_ROLE != harvest-judge => exit 0 regardless of
#    command. Also precedes bp_hook_require_jq — holds on any host.
#    Behavior 9 (§4 AC6): resolve-judge, conformance-judge, coordinator.
# ===========================================================================
for my $role (qw(resolve-judge conformance-judge coordinator)) {
    my ($rc) = run_guard('pnpm run lint', BP_LEDGER => '/fake/ledger.md', BP_ROLE => $role);
    is($rc, 0, "B: BP_ROLE=$role with a matching command => exit 0 "
             . "(the rule is scoped to harvest-judge only, per bp-harvest-judge.md's own Method)");
}
{
    # BP_ROLE entirely unset defaults to "coordinator" elsewhere in this repo
    # (gate-stop.sh, track-dispatch.sh both use ${BP_ROLE:-coordinator}) —
    # must also be exempt.
    my ($rc) = run_guard('pnpm run lint', BP_LEDGER => '/fake/ledger.md');
    is($rc, 0, 'B4: BP_ROLE unset (defaults to coordinator) with a matching command => exit 0');
}

# ===========================================================================
# K. FAIL-CLOSED ON MISSING jq — asserted UNCONDITIONALLY, must hold whether
#    or not this host has jq (on this host it demonstrably does not).
# ===========================================================================
SKIP: {
    skip 'this assertion is only meaningful without jq; jq is present on this host', 1 if $HAVE_JQ;
    my ($rc, $out) = run_guard('pnpm run lint', BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'harvest-judge');
    is($rc, 2, 'K1: with jq absent, the harvest-judge+BP_LEDGER path fails CLOSED (exit 2) '
             . 'rather than silently allowing an unenforced operation');
}

# ===========================================================================
# C/D/E. THE ACTUAL DENYLIST — only meaningful with jq present (this hook is
# designed to run only inside the sandboxed container, where jq is
# guaranteed). SKIP the whole block on this jq-less host rather than let it
# fail for an environmental reason.
# ===========================================================================
SKIP: {
    skip 'jq is not installed on this host; guard-judge-checks.sh hard-requires it by design '
       . '(this hook only ever runs inside the judge\'s sandboxed claude -p)', 20
        unless $HAVE_JQ;

    # C. Behavior 8: the exact shape is denied, for several equivalent forms.
    for my $cmd ('pnpm run lint', 'pnpm run build', 'pnpm run test',
                 'npm run lint', 'npm run build', 'npm run test',
                 'yarn run lint', 'yarn lint', 'pnpm build', 'npm test') {
        my ($rc, $out) = run_guard($cmd, BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'harvest-judge');
        is($rc, 2, "C: '$cmd' as a harvest-judge => exit 2 (re-running a declared check)");
        like($out, qr/declared|evidence|contracted slice/i,
             "C: '$cmd' denial message points at recorded evidence, not merely refusing");
        like($out, qr/\Q$cmd\E/,
             "C: '$cmd' denial message echoes the actual command");
    }

    # D. Behavior 10: commands NOT matching the shape are allowed, even as
    #    harvest-judge. Non-vacuity: these must NOT be denied, or the guard
    #    is broader than the spec's deliberately narrow scope.
    for my $cmd ('pnpm run typecheck', 'pnpm install', 'pytest', 'make test',
                 'go test ./...') {
        my ($rc) = run_guard($cmd, BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'harvest-judge');
        is($rc, 0, "D: '$cmd' as a harvest-judge => exit 0 (outside the deliberately narrow shape)");
    }

    # D2. 'pnpm run lint:fix' DOES match the denylist shape (\b matches at the
    # word boundary before ':', so "lint" is found inside "lint:fix") — and
    # per fix-batch step 7's driver ruling, that is correct, not a false
    # positive: lint:fix is a MUTATING re-run, not verification, and a
    # harvest judge has no business running it either. The rule being
    # enforced is "verify a declared check via its recorded evidence, never
    # by re-running it" — lint:fix is a re-run regardless of what it mutates.
    {
        my ($rc) = run_guard('pnpm run lint:fix', BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'harvest-judge');
        is($rc, 2, "D2: 'pnpm run lint:fix' as a harvest-judge => exit 2 (a mutating re-run is still a re-run)");
    }

    # D3. 'echo pnpm run lint' also matches the denylist shape today: the
    # regex has no notion of "echo" as a no-op prefix, so it fires on the
    # literal substring inside the echoed text too. This is a genuine false
    # positive (echoing a string is not running it) — but it fails CLOSED,
    # costs one refused command with a self-explanatory message, and
    # complicating the regex to parse shell semantics (recognising `echo`,
    # or any other command that merely mentions the shape in its arguments)
    # is far more likely to open a bypass than to prevent a nuisance. Per
    # fix-batch step 7's driver ruling, this is accepted deliberately, not an
    # oversight left unfixed.
    {
        my ($rc) = run_guard('echo pnpm run lint', BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'harvest-judge');
        is($rc, 2, "D3: 'echo pnpm run lint' as a harvest-judge => exit 2 (accepted fail-closed false positive; see comment)");
    }

    # E. Behavior 9, re-confirmed with jq actually parsing the command (the
    #    unconditional B block above never reached the regex at all).
    my ($rc) = run_guard('pnpm run lint', BP_LEDGER => '/fake/ledger.md', BP_ROLE => 'resolve-judge');
    is($rc, 0, 'E1: resolve-judge + matching command, with jq present => still exit 0');
}

done_testing();
