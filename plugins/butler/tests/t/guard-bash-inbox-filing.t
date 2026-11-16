#!/usr/bin/env perl
# platform: any
# Bug 20261116-132008-3692, path 1 of 3: a butler coordinator (or one of
# its workers) filed an operator inbox item directly with the almanac CLI,
# bypassing the escalation resolver, and a technical question (a mode-only
# exec-bit change on a "protected" path) held a fleet for 62 hours. The
# operator: "I have absolutely no idea what any of this means so it's
# obviously not a product question and should have never blocked the fleet."
#
# Pinned here (GuardBash rule GB-i):
#   I1 -- with BP_LEDGER set, every spelling of "file an inbox item" is
#         denied: almanac.pl inbox file (quoted path, plugin-root variable),
#         the bare almanac shim, almanac-inbox.pl file, quoted verbs, a
#         bash -c script, a $(...) carrier, a perl -e calling
#         Almanac::Inbox::file. The deny names the ledger channel
#         (set-escalation plus status: blocked) and the resolver, and keeps
#         the guard-bash budget (2 lines, 160 chars).
#   I2 -- the same deny reaches a worker (agent_id present) and a judge
#         (BP_ROLE set): BP_LEDGER is the run, whoever holds it.
#   I3 -- prose that merely names the command is not denied: a grep pattern,
#         echo, a quoted commit message, a data heredoc, a comment; nor are
#         the read verbs (inbox list/show).
#   I4 -- a subagent of an armed drive-solo driver is denied too, told to put
#         the question in its result; the driver's own main thread, and an
#         unarmed interactive session, are allowed.
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

sub payload {
    my (%o) = @_;
    my $p = { tool_name => 'Bash', tool_input => { command => $o{cmd} } };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{agent_id}   = $o{agent_id}   if exists $o{agent_id};
    return $p;
}

sub gb {
    my ($p, %env) = @_;
    return GuardHarness::run_module('Guards::GuardBash', $p, env => \%env);
}

sub lines_of {
    my ($res) = @_;
    my @l = split /\n/, ($res->{err} // '');
    pop @l while @l && $l[-1] eq '';
    return @l;
}

my %COORD = (BP_LEDGER => '/x/blueprints/bp/packages/14-x.md');

my @FILING = (
    q{perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox file --title "Approve the chmod?"},
    q{almanac inbox file --title "Approve the chmod?" --body "why"},
    q{perl /c/Users/x/.claude/ccpraxis/plugins/almanac/scripts/almanac-inbox.pl file --title q},
    q{perl 'C:/Users/Andr\xc3\xa9/.claude/ccpraxis/plugins/almanac/scripts/almanac.pl' inbox file --title q},
    q{cd /work && almanac 'inbox' "file" --title q},
    q{bash -c "almanac inbox file --title q"},
    q{ID=$(almanac inbox file --title q); echo $ID},
    q{echo "$(perl almanac.pl inbox file --title q)"},
    q{perl -e 'require "almanac-inbox.pl"; Almanac::Inbox::file(title => "q")'},
    q{ALMANAC=1 env almanac.pl inbox file --title q 2>&1 | tail -1},
);

# I1 -- coordinator.
for my $cmd (@FILING) {
    my $res = gb(payload(cmd => $cmd), %COORD);
    is($res->{rc}, 2, "I1: coordinator denied: $cmd") or diag("err: $res->{err}");
    my @l = lines_of($res);
    like($l[0] // '', qr/^BLOCKED: .*inbox item/, "I1: line 1 says what is refused: $cmd");
    like($res->{err}, qr/bp-ledger\.pl set-escalation plus status: blocked/, "I1: names the ledger channel: $cmd");
    like($res->{err}, qr/escalation resolver, the only judge of whether a question is the operator's/,
         "I1: names the resolver as the only judge: $cmd");
    cmp_ok(scalar(@l), '<=', 2, "I1: guard-bash budget of 2 lines: $cmd");
    cmp_ok(length($_), '<=', 160, "I1: line <= 160 chars: $cmd") for @l;
    is($res->{out}, '', "I1: stdout empty: $cmd");
}

# I2 -- a worker and a judge under the same ledger.
{
    my $res = gb(payload(cmd => $FILING[0], session_id => 'coord-1', agent_id => 'a1b2c3'), %COORD);
    is($res->{rc}, 2, 'I2: a coordinator\'s worker (agent_id present) is denied');
    my $res_j = gb(payload(cmd => $FILING[1]), %COORD, BP_ROLE => 'escalation-resolve');
    is($res_j->{rc}, 2, 'I2: a judge (BP_ROLE set, BP_LEDGER set) is denied');
}

# I3 -- prose, data and read verbs pass under BP_LEDGER.
{
    my @ALLOWED = (
        q{grep -rn "almanac inbox file" plugins/almanac/skills},
        q{echo almanac inbox file},
        q{printf '%s\n' "run: almanac inbox file --title x"},
        q{perl plugins/butler/scripts/bp-ledger.pl set-escalation --ledger L --text "do not use almanac inbox file"},
        qq{cat > notes.md <<'EOF'\nalmanac inbox file --title q\nEOF},
        q{ls # almanac inbox file},
        q{almanac inbox list},
        q{perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox show 20261113-150442-8ba20000},
        q{perl almanac-inbox.pl list},
    );
    for my $cmd (@ALLOWED) {
        (my $name = $cmd) =~ s{\n}{ \\n }g;
        my $res = gb(payload(cmd => $cmd), %COORD);
        is($res->{rc}, 0, "I3: allowed under BP_LEDGER: $name") or diag("err: $res->{err}");
    }
}

# I4 -- drive-solo: the driver's subagent is denied, the driver and an
# unarmed session are not.
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    ok(GuardHarness::arm('drv-1', 'driver'), 'I4 setup: a driver session armed');
    my $res_w = GuardHarness::run_module('Guards::GuardBash',
        payload(cmd => $FILING[1], session_id => 'drv-1', agent_id => 'w0rk3r'), env => {});
    is($res_w->{rc}, 2, 'I4: a subagent of an armed driver is denied') or diag("err: $res_w->{err}");
    like($res_w->{err}, qr/Put the question in your result; the driver reads it/,
         'I4: the worker is told its channel is its result');
    my @l = lines_of($res_w);
    cmp_ok(scalar(@l), '<=', 2, 'I4: guard-bash budget of 2 lines');

    my $res_d = GuardHarness::run_module('Guards::GuardBash',
        payload(cmd => $FILING[1], session_id => 'drv-1'), env => {});
    is($res_d->{rc}, 0, 'I4: the driver\'s own main thread may still file') or diag("err: $res_d->{err}");

    my $res_m = GuardHarness::run_module('Guards::GuardBash',
        payload(cmd => $FILING[1], session_id => 'manual-1'), env => {});
    is($res_m->{rc}, 0, 'I4: an unarmed interactive session may file');
}

done_testing();
