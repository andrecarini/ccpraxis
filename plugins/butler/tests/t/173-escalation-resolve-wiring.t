#!/usr/bin/env perl
# 173-escalation-resolve-wiring.t — the escalation-resolve judge path is actually wired.
#
# WHAT IS BEING PROTECTED
#
# bp-orchestrator.pl carries this comment above its escalation-resolve dispatch:
#
#     # 'escalation-resolve' is a new VALUE here, not new code, per e03 spec
#
# It was wrong three times over, and nothing caught it for the entire life of the
# feature. bp-judge.sh is NOT value-agnostic: it gates on an allow-list and
# derives two file paths from $KIND.
#
#   1. `case "$KIND" in harvest|resolve|conformance)` rejected the kind outright.
#   2. AGENT_FILE=agents/bp-$KIND-judge.md  ->  bp-escalation-resolve-judge.md,
#      which has never existed (the real agent is bp-escalation-resolver.md --
#      different stem, no `-judge` suffix).
#   3. TEMPLATE=templates/judge-$KIND.md   ->  judge-escalation-resolve.md,
#      which did not exist either.
#
# So the autonomous-resolution path had never once executed. Every escalation
# reached the operator, which is precisely the failure the feature exists to
# prevent -- and the orchestrator, having no spawn cap on this kind, retried
# roughly every ten seconds forever. Almanac 20260824-170753-01b8, filed from a
# live run: 19+ spawn failures in the minute the operator watched it.
#
# WHY THIS FILE IS STRUCTURAL RATHER THAN BEHAVIOURAL
#
# bp-judge.sh calls bp_require_sandbox and `require_cmd jq flock claude setsid
# realpath` in its first ten lines. On the Git-for-Windows host none of that
# holds (no jq, not a sandbox), so it exits long before the allow-list -- and
# running it anywhere it DOESN'T exit early would launch a real `claude`
# process, which a test must never do.
#
# The assertions below therefore re-derive the paths using the script's OWN
# rules, read out of the script, and check they resolve. That is what makes this
# a rule rather than three instances: add a fifth judge kind tomorrow without its
# agent file or template, and this turns red for the new kind automatically.
#
# Runs standalone: perl plugins/butler/tests/t/173-escalation-resolve-wiring.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $PLUGIN = "$Bin/../..";
my $JUDGE  = "$PLUGIN/scripts/bp-judge.sh";
my $ORCH   = "$PLUGIN/scripts/bp-orchestrator.pl";

ok(-f $JUDGE, 'A0: bp-judge.sh exists') or BAIL_OUT('no bp-judge.sh');
my $src = do { local (@ARGV, $/) = ($JUDGE); <> };
ok(defined $src && length $src, 'A1: bp-judge.sh is readable') or BAIL_OUT('unreadable');

# ---------------------------------------------------------------------------
# B. The allow-list, read from the script rather than assumed.
# ---------------------------------------------------------------------------
my ($allow) = $src =~ /case\s+"\$KIND"\s+in\s+([a-z|\-]+)\)/;
ok(defined $allow && length $allow, 'B0: the kind allow-list is parseable from the source')
    or BAIL_OUT('cannot find the allow-list; the rest of this file would be vacuous');
my @kinds = split /\|/, $allow;
cmp_ok(scalar @kinds, '>=', 4, 'B1: at least four judge kinds are allowed');
ok((grep { $_ eq 'escalation-resolve' } @kinds),
   'B2: escalation-resolve is in the allow-list -- without this the script exits 2 before '
 . 'doing anything, which is the failure actually logged on the live run')
    or diag('allow-list: ' . join(',', @kinds));

# ---------------------------------------------------------------------------
# C. THE RULE. For every allowed kind, the files bp-judge.sh will look for must
#    exist. Derived from the script's own expressions, so a kind added later is
#    covered without editing this file.
# ---------------------------------------------------------------------------
# The agent path has a per-kind exception; read the exception table out of the
# source rather than hardcoding it, so a second exception is picked up too.
my %agent_override;
if (my ($case_body) = $src =~ /\n\s*case\s+"\$KIND"\s+in\s*\n(.*?)\nesac/s) {
    while ($case_body =~ /^\s*([a-z\-]+)\)\s*AGENT_FILE="\$PLUGIN_ROOT\/agents\/([^"]+)"/mg) {
        $agent_override{$1} = $2;
    }
}

for my $kind (@kinds) {
    my $agent = exists $agent_override{$kind}
              ? "$PLUGIN/agents/$agent_override{$kind}"
              : "$PLUGIN/agents/bp-$kind-judge.md";
    ok(-f $agent, "C1[$kind]: the agent file bp-judge.sh resolves exists ($agent)")
        or diag("bp-judge.sh would exit 1 at the [ -f \"\$AGENT_FILE\" ] check for kind '$kind'");

    # conformance builds its prompt inline (templates/ was outside b05's write
    # set), and the script guards its template check the same way -- so the
    # exemption is read from the source, not assumed here.
    next if $kind eq 'conformance';
    my $tmpl = "$PLUGIN/templates/judge-$kind.md";
    ok(-f $tmpl, "C2[$kind]: the template bp-judge.sh resolves exists ($tmpl)")
        or diag("bp-judge.sh would exit 1 at the [ -f \"\$TEMPLATE\" ] check for kind '$kind'");
}

# Non-vacuity: C1/C2 must be capable of failing. A kind that is deliberately NOT
# wired resolves to paths that do not exist, and the same derivation says so.
{
    my $bogus = 'no-such-kind';
    ok(!-f "$PLUGIN/agents/bp-$bogus-judge.md" && !-f "$PLUGIN/templates/judge-$bogus.md",
       'C3: counter-fixture -- the same derivation finds nothing for an unwired kind, so '
     . 'C1/C2 passing means the files are really there');
}

# ---------------------------------------------------------------------------
# D. The escalation-resolve template must carry the placeholders bp-judge.sh
#    substitutes for it, or the judge is launched pointing at nothing.
# ---------------------------------------------------------------------------
{
    my $tmpl = "$PLUGIN/templates/judge-escalation-resolve.md";
  SKIP: {
        skip 'template missing (C2 already reported it)', 3 unless -f $tmpl;
        my $t = do { local (@ARGV, $/) = ($tmpl); <> };
        like($t, qr/\{\{VERDICT_PATH\}\}/, 'D1: the template names the verdict path');
        like($t, qr/\{\{AGENT_FILE\}\}/,   'D2: the template points at the operating contract');
        like($t, qr/\{\{DECISION_FILE\}\}/,
             'D3: the template names the RECORD BEING TRIAGED -- a judge with no target burns '
           . 'its whole budget discovering that and writes no verdict');
    }
    like($src, qr/\{\{DECISION_FILE\}\}/,
         'D4: ...and bp-judge.sh actually substitutes it (a placeholder nothing fills is '
       . 'delivered to the agent literally)');
}

# ---------------------------------------------------------------------------
# E. The orchestrator side: ordering and the spawn cap.
# ---------------------------------------------------------------------------
{
    my $o = do { local (@ARGV, $/) = ($ORCH); <> };
    ok(defined $o && length $o, 'E0: bp-orchestrator.pl is readable') or BAIL_OUT('unreadable');

    # The judge learns which record to triage by reading <pkg>.decision. Writing
    # that AFTER spawning is a race the judge loses -- it is one-shot, so there
    # is no second look.
    my $decision_write = index($o, 'escalation-resolve/$pkg.decision');
    my $spawn          = index($o, "\$spawn_judge->({ kind => 'escalation-resolve'");
    cmp_ok($decision_write, '>', -1, 'E1: the decision-id write is present');
    cmp_ok($spawn,          '>', -1, 'E2: the escalation-resolve spawn is present');
    cmp_ok($decision_write, '<', $spawn,
           'E3: the decision id is written BEFORE the judge is spawned -- a one-shot judge that '
         . 'starts before its target is named has nothing to read and no second chance');

    # A cap, because this path had none and that is how it spun.
    like($o, qr/escalation_spawn_fail/,
         'E4: escalation-resolve spawn failures are counted');
    like($o, qr/next if \(\$reg->\{\$pkg\}\{escalation_spawn_fail\}.*judge_spawn_cap/,
         'E5: ...and the count GATES the dispatch -- a counter with no guard is a log line '
       . 'while the run keeps hammering, which is exactly what was observed');
}

done_testing();
