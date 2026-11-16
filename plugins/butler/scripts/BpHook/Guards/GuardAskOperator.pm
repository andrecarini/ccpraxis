# BpHook::Guards::GuardAskOperator -- an unattended (armed) session must
# not stop to ask the operator a question; AskUserQuestion is denied
# (Decision 22, package 14 of blueprint hook-continuity-remake), successor
# to guard-ask-operator.sh.
#
# Bug 20261116-132008-3692: this guard used to file the raw question text
# as an operator inbox item on every deny. Nothing classified it, so a
# technical question reached the operator verbatim, and a question already
# escalated through the ledger reached them a second time (inbox item
# 20261112-160135-43ee0000). The deny now files nothing and names the
# channel instead: a coordinator (and its workers) writes a ledger
# escalation (bp-ledger.pl set-escalation plus status: blocked), which goes
# through the escalation resolver, the only judge of whether a question is
# the operator's; an armed interactive session decides it itself, and files
# an inbox item deliberately, in product terms, only for a product decision
# the operator could answer without any technical explanation.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.4, as amended by the bug above.
# Architecture: plugins/butler/docs/hook-architecture.md
# ("guard-ask-operator" successor row). Bug 20260922-210421-0468: session
# facts come ONLY from BpHook::is_armed($sid) for THIS payload's session --
# no run-state.json, no legacy .continuity-active/ registry, no other
# session's arm file is ever consulted (Decision 3).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open), never writes a file.
# Prints only through BpHook::deny(@lines).
package BpHook::Guards::GuardAskOperator;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';
    return 0 unless BpHook::payload_ok();

    my $tool = $p->{tool_name};
    return 0 unless defined $tool && !ref($tool) && $tool eq 'AskUserQuestion';

    my $sid = BpHook::session_id($p);
    return 0 unless BpHook::is_armed($sid);

    my $ledger = $ENV{BP_LEDGER};
    my @lines;
    if (defined $ledger && length $ledger) {
        push @lines, 'BLOCKED: this is a headless coordinator session, so asking the operator would stop unattended work for an answer nobody is there to give.';
        push @lines, 'Nothing was filed. Write it as a ledger escalation: bp-ledger.pl set-escalation, then set status: blocked.';
        push @lines, "The escalation resolver, the only judge of whether a question is the operator's, decides it; most never reach them.";
    }
    else {
        push @lines, 'BLOCKED: continuity is ARMED for this session, so asking the operator would stop unattended work for an answer nobody is there to give.';
        push @lines, 'Nothing was filed. Decide it yourself and state the assumption (.ccpraxis-local-data/guidance/escalate-product-decisions-only.md).';
        push @lines, 'Only a product decision they could answer with no technical explanation is theirs: file it deliberately, in product terms, with almanac inbox file.';
    }
    push @lines, 'Carry on with the work that does not depend on the answer.';

    return BpHook::deny(map { BpHook::Guards::Common::fit($_) } @lines);
}

1;
