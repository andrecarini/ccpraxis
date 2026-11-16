#!/usr/bin/env perl
# platform: any
# Bug 20261116-132008-3692, path 2 of 3: GuardAskOperator filed the raw
# AskUserQuestion text as an operator inbox item on every deny, with no
# classification at all, so technical questions reached the operator
# verbatim and an already-escalated one reached them twice
# (20261112-160135-43ee0000). The deny stays; the filing goes.
#
# Pinned here:
#   N1 -- an armed interactive session is denied, NOTHING is filed (no
#         almanac store is even created), and the deny tells it to decide
#         itself and to file deliberately, in product terms, with
#         `almanac inbox file`, only a product decision the operator could
#         answer with no technical explanation.
#   N2 -- a coordinator (BP_LEDGER set) is denied, nothing is filed, and the
#         deny names the ledger channel (bp-ledger.pl set-escalation, then
#         status: blocked) and the resolver as the judge.
#   N3 -- the module no longer reaches the inbox store at all.
#   N4 -- deny budget unchanged: at most 4 lines, each <= 160 chars.
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

my $MODULE = dirname(__FILE__) . '/../../scripts/BpHook/Guards/GuardAskOperator.pm';

sub mk_root {
    my $t = tempdir(CLEANUP => 1);
    (my $root = $t) =~ s{\\}{/}g;
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub ask {
    my ($root, $sid, %env) = @_;
    my $p = { tool_name => 'AskUserQuestion', session_id => $sid, cwd => $root,
              tool_input => { questions => [ { question => 'Approve the mode-only chmod on container/run.sh?' } ] } };
    return GuardHarness::run_module('Guards::GuardAskOperator', $p,
        env => { CLAUDE_PROJECT_DIR => $root, %env });
}

sub lines_of {
    my ($res) = @_;
    my @l = split /\n/, ($res->{err} // '');
    pop @l while @l && $l[-1] eq '';
    return @l;
}

# N1 -- armed interactive session.
{
    local %ENV = %ENV;
    my $root = mk_root();
    GuardHarness::fresh_state();
    ok(GuardHarness::arm('n1-armed', 'manual'), 'N1 setup: session armed');
    my $res = ask($root, 'n1-armed');
    is($res->{rc}, 2, 'N1: an armed session is still denied');
    ok(!-d "$root/.ccpraxis-local-data/almanac", 'N1: nothing was filed -- no almanac store was created');
    unlike($res->{err}, qr/filed as inbox item/, 'N1: the deny no longer claims an inbox item was filed');
    like($res->{err}, qr/Nothing was filed\./, 'N1: the deny says nothing was filed');
    like($res->{err}, qr/Decide it yourself/, 'N1: the deny says to decide it yourself');
    like($res->{err}, qr/product decision they could answer with no technical explanation/,
         'N1: the deny states the plain-language bar for the operator');
    like($res->{err}, qr/in product terms, with almanac inbox file\./,
         'N1: the deny names the deliberate route, in product terms');
    unlike($res->{err}, qr/set-escalation/, 'N1: an interactive session is not sent to a ledger it does not have');
    my @l = lines_of($res);
    cmp_ok(scalar(@l), '<=', 4, 'N4: at most 4 lines (armed)');
    cmp_ok(length($_), '<=', 160, 'N4: line <= 160 chars (armed)') for @l;
}

# N2 -- coordinator.
{
    local %ENV = %ENV;
    my $root = mk_root();
    GuardHarness::fresh_state();
    my $res = ask($root, 'n2-coord', BP_LEDGER => '/x/packages/14-x.md');
    is($res->{rc}, 2, 'N2: a coordinator is denied');
    ok(!-d "$root/.ccpraxis-local-data/almanac", 'N2: nothing was filed for the coordinator either');
    like($res->{err}, qr/Nothing was filed\./, 'N2: the deny says nothing was filed');
    like($res->{err}, qr/bp-ledger\.pl set-escalation, then set status: blocked/,
         'N2: the deny names the ledger escalation channel');
    like($res->{err}, qr/escalation resolver, the only judge of whether a question is the operator's/,
         'N2: the deny names the resolver as the judge');
    my @l = lines_of($res);
    cmp_ok(scalar(@l), '<=', 4, 'N4: at most 4 lines (coordinator)');
    cmp_ok(length($_), '<=', 160, 'N4: line <= 160 chars (coordinator)') for @l;
}

# N3 -- the module never reaches the inbox store.
{
    open(my $fh, '<:raw', $MODULE) or die "cannot read $MODULE: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    (my $code = $src) =~ s/^\s*#.*$//mg;
    unlike($code, qr/Almanac::Inbox::|almanac-inbox\.pl/, 'N3: GuardAskOperator.pm code never calls the inbox store');
}

done_testing();
