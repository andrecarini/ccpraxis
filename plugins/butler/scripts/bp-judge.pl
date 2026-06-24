#!/usr/bin/env perl
# bp-judge.pl — the DETERMINISTIC decision core for A5 (the judges). The judges
# themselves are scoped, throwaway `claude -p` calls the orchestrator fires (the
# only Claude in the whole run besides the coordinators); THIS file holds none of
# that — it is the pure, unit-tested logic that decides *whether* to fire a judge,
# *what* to do with its verdict, and *how* a harvest knob reshapes the DAG. The
# orchestrator (bp-orchestrator.pl) is the thin shell that spawns the judges and
# feeds their on-disk verdicts back through these functions.
#
# Two judges (Decisions #13/#15), both fresh-context, both verdict-on-disk:
#   • harvest-judge — verifies a FINISHED package's declared outputs against its
#     done-criteria from disk → pass | fail. Default runs as an async spot-audit
#     (#15); configurably as a per-launch gate.
#   • resolve-judge — a deeper, broad-context attempt to fix a STUCK package
#     (re-scope, corrected relaunch, drop an *optional* criterion) → relaunch | park.
#
# DESIGN: every decision here is a PURE function — no I/O, no globals, no clock —
# so t/10-judges.t can exhaust the matrix without a real `claude`. Verdict parsing
# is fail-CLOSED (an unrecognized judge verdict never reads as "all good": a bad
# harvest verdict escalates, a bad resolve verdict parks — Decision #29's spirit
# applied to the judges' own output).
#
# require: require "<path>/bp-judge.pl"; BpJudge::escalation_verdict(...)

package BpJudge;
use strict;
use warnings;

# ===========================================================================
# HARVEST KNOB (Decision #15)
# ===========================================================================

# harvest_mode($v) -> 'audit' | 'gate'
# The configured harvest mode. Default = 'audit' (#15: trust the coordinator's own
# tests/review/red-team, launch dependents immediately, verify async). Any
# unrecognized value falls back to the documented default rather than erroring —
# the knob can never wedge a run by being mistyped.
sub harvest_mode {
    my ($v) = @_;
    return 'gate' if defined $v && lc("$v") eq 'gate';
    return 'audit';
}

# gate_admits($mode,$status,$harvest) -> 0|1
# May dependents treat this package as satisfied? In audit mode, status 'done' is
# enough (verification is async, off the critical path). In gate mode, a finished
# package is admitted only once its harvest verdict is 'pass'.
sub gate_admits {
    my ($mode, $status, $harvest) = @_;
    return 0 unless defined $status && $status eq 'done';
    return 1 unless ($mode // 'audit') eq 'gate';
    return (defined $harvest && $harvest eq 'pass') ? 1 : 0;
}

# effective_status($mode,\%status,\%harvest) -> \%eff
# The status map the DAG should actually see. In GATE mode, a 'done' package whose
# harvest verdict isn't yet 'pass' is demoted to 'harvesting' so deps_met /
# ready_packages (which only ever honor 'done') hold its dependents back until the
# gate passes — without touching those functions. In AUDIT mode this is an exact
# identity passthrough, so A3's launch behavior is byte-for-byte unchanged.
sub effective_status {
    my ($mode, $status, $harvest) = @_;
    my %eff = %{ $status || {} };
    return \%eff unless ($mode // 'audit') eq 'gate';
    for my $pkg (keys %eff) {
        next unless defined $eff{$pkg} && $eff{$pkg} eq 'done';
        $eff{$pkg} = 'harvesting'
            unless gate_admits('gate', $eff{$pkg}, ($harvest ? $harvest->{$pkg} : undef));
    }
    return \%eff;
}

# ===========================================================================
# ESCALATION LADDER (Decision #13: park-the-branch, never global-halt)
# ===========================================================================

# escalation_verdict($c) -> 'resolve' | 'park'
# Consulted only AFTER the coordinator's own retry loops are exhausted (the
# watchdog has returned 'block' — the package is genuinely stuck). Spend a
# resolve-judge call if the per-package resolve budget remains; otherwise park the
# branch and queue the decision. The resolve-judge is deliberately rare (#13),
# hence a small cap (default 1).
#   $c = { resolve_attempts => N, resolve_cap => M (default 1) }
sub escalation_verdict {
    my ($c) = @_;
    my $cap = defined $c->{resolve_cap} ? $c->{resolve_cap} : 1;
    my $att = $c->{resolve_attempts} // 0;
    return ($att < $cap) ? 'resolve' : 'park';
}

# normalize_resolve($parsed) -> { action => 'relaunch'|'park', reason => ..., ... }
# Interpret the resolve-judge's on-disk verdict object. The judge itself (Claude,
# scoped, with Edit/Write inside a declared write-set) does the intent-laden fix —
# re-scopes the spec, drops an *optional* criterion, corrects the ledger — and
# records `action: relaunch` when it applied a fix the coordinator should retry, or
# `action: park` when it could not determine intent. THIS function does only the
# deterministic mapping the orchestrator acts on. Fail-CLOSED: a missing, crashed,
# or unrecognized verdict parks (never a silent relaunch loop — #13 "parks without
# guessing"). On park it surfaces `needs_you` (the question for the human) verbatim.
sub normalize_resolve {
    my ($p) = @_;
    return { action => 'park', reason => 'resolve verdict missing or not an object' }
        unless ref $p eq 'HASH';
    my $a = lc($p->{action} // '');
    if ($a eq 'relaunch') {
        return {
            action        => 'relaunch',
            reason        => ($p->{reason} // ''),
            mutated_files => (ref $p->{mutated_files} eq 'ARRAY' ? $p->{mutated_files} : []),
        };
    }
    # Coerce needs_you to a hashref (or undef) so a malformed verdict (needs_you as a
    # bare string, etc.) can't blow up the orchestrator's `needs_you->{question}` deref.
    my $ny = $p->{needs_you};
    $ny = (ref $ny eq 'HASH') ? $ny
        : (defined $ny ? { question => "$ny" } : undef);
    return {
        action    => 'park',
        reason    => ($p->{reason} // ($a eq 'park'
                        ? 'resolve-judge could not determine intent'
                        : "unrecognized resolve action '" . ($p->{action} // '') . "'")),
        needs_you => $ny,
    };
}

# ===========================================================================
# HARVEST VERDICT + FAILED-AUDIT HANDLING (Q2)
# ===========================================================================

# normalize_harvest($parsed) -> 'pass' | 'fail' | 'error'
# The harvest-judge writes { verdict: 'pass'|'fail', ... } after reading only the
# package's done-criteria + declared outputs from disk. Anything else (missing,
# malformed, crashed judge) is 'error' — NOT silently 'pass'. Upstream, both 'fail'
# and 'error' are non-pass and trigger the same conservative escalation, so a judge
# we can't trust never green-lights a package (#29's never-proceed-on-unrecognized).
sub normalize_harvest {
    my ($p) = @_;
    return 'error' unless ref $p eq 'HASH';
    my $v = lc($p->{verdict} // $p->{result} // '');
    return 'pass' if $v eq 'pass';
    return 'fail' if $v eq 'fail';
    return 'error';
}

# audit_outcome($c) -> 'accept' | 'reopen' | 'park'
# What the orchestrator does with a completed harvest verdict (audit mode — the
# package's dependents may already be running off the trusted output):
#   pass                             -> accept   (record harvest-verified, done)
#   non-pass, under corrective cap    -> reopen   (relaunch the package NON-terminal
#                                                  with the audit's specific failures
#                                                  as corrective context; one cycle)
#   non-pass, corrective cap exhausted-> park     (queue a needs-you alarm)
# Park-don't-halt (#13) + demote-don't-panic (#12): a failed audit never auto-kills
# live dependents — the orchestrator flags them for re-verification, the loop keeps
# independent work running. corrective_cap default 1 (a single corrective cycle).
sub audit_outcome {
    my ($c) = @_;
    return 'accept' if defined $c->{verdict} && $c->{verdict} eq 'pass';
    my $cap = defined $c->{corrective_cap} ? $c->{corrective_cap} : 1;
    my $att = $c->{corrective_attempts} // 0;
    return ($att < $cap) ? 'reopen' : 'park';
}

# ===========================================================================
# JUDGE FIRING POLICY (which packages need which judge this tick) — pure
# ===========================================================================

# want_harvest_audit($c) -> 0|1
# In AUDIT mode, fire a harvest spot-audit exactly once per finished package:
# status is 'done', no verdict recorded yet, and none already in flight. (In GATE
# mode the gate fires through the same seam but is sequenced by effective_status,
# so this audit-mode predicate returns 0.)
sub want_harvest_audit {
    my ($c) = @_;
    return 0 unless ($c->{mode} // 'audit') eq 'audit';
    return 0 unless defined $c->{status} && $c->{status} eq 'done';
    return 0 if $c->{inflight};
    return 0 if defined $c->{harvest} && length $c->{harvest};   # already verdicted
    return 1;
}

# want_harvest_gate($c) -> 0|1
# In GATE mode, fire the harvest gate for a finished-but-unadmitted package: status
# 'done', no 'pass' verdict yet, none in flight. (Mirror of want_harvest_audit for
# the gate knob; effective_status holds the dependents while this runs.)
sub want_harvest_gate {
    my ($c) = @_;
    return 0 unless ($c->{mode} // 'audit') eq 'gate';
    return 0 unless defined $c->{status} && $c->{status} eq 'done';
    return 0 if $c->{inflight};
    return 0 if defined $c->{harvest} && $c->{harvest} eq 'pass';
    return 1;
}

package main;
use strict;
use warnings;
1;
