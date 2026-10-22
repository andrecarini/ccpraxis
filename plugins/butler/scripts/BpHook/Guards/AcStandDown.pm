# BpHook::Guards::AcStandDown -- the AC-loss stand-down signal a running
# local dispatch actually sees (package 11 of blueprint tooling-backlog).
#
# Contract: .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 11-ac-loss-clean-suspend-cycle-spec.md sec 2.9/3.6.
#
# Denies every subagent tool call while BpAcWatch::guard_active() is true
# (an active stand-down marker AND a phase of expired|standing-down|
# monitoring). A main-session call (no agent_id) always passes. Fails
# CLOSED under an active marker when the payload is unparseable or carries
# no tool_name from a subagent (GateShutdown's own pattern). Never calls
# exit, never dies on purpose, never spawns a process.
package BpHook::Guards::AcStandDown;
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
require "$SELF_DIR/../../BpAcWatch.pm"
    unless grep { m{(?:^|/)BpAcWatch\.pm$} } keys %INC;

my $L1 = 'STAND-DOWN: AC power lost; this host is on battery and may sleep. Tool calls are refused until AC returns.';
my $L2 = "Do not retry. Reply now with your report: what you changed, each file's state, and what was in progress.";
# H3 (fix-batch, redteam-1): a concrete recovery hint for the window before
# BpAcWatch::guard_active()'s own staleness self-heal fires -- if AC is
# actually present, the operator (not a denied subagent) can clear the
# stand-down by hand rather than wait it out.
my $L3 = "Operator: if AC is present, run bp-ac-watch.pl clear --reason '<2+ words>' to lift this.";

sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';

    my $data_dir = BpHook::data_dir($p);
    return 0 unless defined $data_dir && length $data_dir;
    return 0 unless BpAcWatch::guard_active($data_dir);

    my $agent_id = BpHook::agent_id($p);
    my $tool = $p->{tool_name};

    # L4 (todo 20261003-004707-628d0000, redteam-1): a payload that parsed
    # and carries no agent_id is a genuine main-session call, and spec 2.9
    # scopes fail-closed to subagents -- the main session must stay able to
    # run `bp-ac-watch.pl clear` and `butler-continuity on` while stood
    # down, even if its own tool_name is somehow missing.
    return 0 if BpHook::payload_ok() && !defined $agent_id;

    # GateShutdown's own rule otherwise: an unparseable payload (which has
    # no reliable agent_id either) or a subagent call with no usable
    # tool_name fails CLOSED under an active signal (spec 2.9's fail-closed
    # bullet).
    if (!BpHook::payload_ok() || !defined $tool || ref($tool) || !length $tool) {
        my $aid_for_log = defined $agent_id ? $agent_id : '?';
        BpAcWatch::log_event($data_dir, 'guard', 'STANDDOWN-DENIED', { agent => $aid_for_log, tool => '-' },
            'denied: no identifiable tool_name while stood down (fail-closed)');
        return BpHook::deny(BpHook::Guards::Common::fit($L1), BpHook::Guards::Common::fit($L2),
            BpHook::Guards::Common::fit($L3));
    }

    # H2 (fix-batch, reviewer-1/redteam-1): exempt the report/communication
    # tools -- same exact pair, same reason, as
    # @BpHook::DenialBreaker::CLASSIFIER_EXEMPT_TOOLS (lines 48-56 of that
    # file). $L2 above tells a denied worker to "Reply now with your
    # report"; in this harness that reply can only be delivered through
    # SubagentHandback (or SendMessage to the driver), so denying those two
    # as well defeats the stand-down's own promise of a clean report before
    # sleep.
    return 0 if $tool eq 'SendMessage' || $tool eq 'SubagentHandback';

    BpAcWatch::log_event($data_dir, 'guard', 'STANDDOWN-DENIED', { agent => $agent_id, tool => $tool },
        'denied: AC-loss stand-down is active');
    return BpHook::deny(BpHook::Guards::Common::fit($L1), BpHook::Guards::Common::fit($L2),
        BpHook::Guards::Common::fit($L3));
}

1;
