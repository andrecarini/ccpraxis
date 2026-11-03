#!/usr/bin/env perl
# platform: any
# Bug a2da: when the usage gate gives no figures (the host token is under its
# floor while the operator is away), the dashboard's spend snapshot falls back
# to the newest usage_poll a fleet orchestrator in the same project logged.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Test::More;
use JSON::PP;

my $PERL     = $^X;
my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
require $SPEND_PL;

# --- pure: the data root is derived from the launcher's global dir ----------
is(BpSpend::data_root_from_global_dir('/c/p/.ccpraxis-local-data/claude-home/.launcher'),
   '/c/p/.ccpraxis-local-data', 'the data root is two levels above claude-home/.launcher');
is(BpSpend::data_root_from_global_dir('C:\\p\\.ccpraxis-local-data\\claude-home\\.launcher\\'),
   'C:/p/.ccpraxis-local-data', 'backslashes and a trailing separator are tolerated');
is(BpSpend::data_root_from_global_dir('/tmp/somewhere'), undef, 'any other dir maps to nothing');

# --- pure: the newest fresh reading wins --------------------------------------
my $now = 1_787_000_000;
my $r = BpSpend::claude_from_orchestrator_polls([
    { epoch => $now - 900, five => 1,  seven => 2 },
    { epoch => $now - 120, five => 30, seven => 15 },
    { epoch => $now - 60,  five => 31, seven => 16 },
], $now);
is($r->{status}, 'ok', 'a fresh poll is a reading');
is($r->{five_hour}{utilization}, 31, 'the newest poll supplies five_hour');
is($r->{seven_day}{utilization}, 16, 'and seven_day');
like($r->{diagnostic}, qr/^via fleet orchestrator, 1m old$/, 'its source and age are stated');
is(BpSpend::claude_from_orchestrator_polls([{ epoch => $now - 601, five => 1, seven => 2 }], $now),
   undef, 'a poll older than ten minutes is not used');
is(BpSpend::claude_from_orchestrator_polls([], $now), undef, 'no polls, no reading');

# --- end to end: snapshot with a RELOGIN gate and an orchestrator log --------
sub iso { my @t = gmtime($_[0]); sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0] }

my $proj = tempdir(CLEANUP => 1);
my $data = "$proj/.ccpraxis-local-data";
my $g    = "$data/claude-home/.launcher";
my $runs = "$data/blueprints/bp1/runs";
make_path($g, $runs);
open(my $lf, '>', "$runs/orchestrator.log") or die $!;
print {$lf} qq({"five":12,"result":200,"seven":9,"ts":") . iso($now - 200) . qq(","type":"usage_poll"}\n);
print {$lf} qq({"age_s":10,"path":"/tmp/.butler-busy","ts":") . iso($now - 70) . qq(","type":"busy_lease_tick"}\n);
print {$lf} qq({"five":0,"result":401,"seven":0,"ts":") . iso($now - 30) . qq(","type":"usage_poll"}\n);
print {$lf} qq({"five":13,"result":200,"seven":9,"ts":") . iso($now - 90) . qq(","type":"usage_poll"}\n);
close $lf;

my $fake = "$proj/gate.pl";
open(my $gf, '>', $fake) or die $!;
print {$gf} qq{print "RELOGIN token_life_h=0.50 detail=oauth-token-under-floor-cannot-refresh-in-session\\n"; exit 40;\n};
close $gf;

sub snap {
    my ($global) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, 'snapshot', '--global-dir', $global,
                                          '--now', $now, '--gate-cmd', "$PERL $fake"));
    my $out = `$cmd 2>&1`;
    open(my $fh, '<:raw', "$global/spend.json") or return (undef, $out);
    my $j = eval { JSON::PP->new->decode(do { local $/; <$fh> }) };
    my ($c) = grep { ($_->{provider} // '') eq 'claude' } @{ $j->{results} || [] };
    return ($c, $out);
}

my ($c, $out) = snap($g);
is($c->{status}, 'ok', 'a RELOGIN gate with a fresh orchestrator poll yields a reading')
    or diag($out);
is($c->{five_hour}{utilization}, 13, 'from the newest successful poll (a 401 poll is skipped)');
is($c->{seven_day}{utilization}, 9, 'seven_day too');
like($c->{diagnostic} // '', qr/via fleet orchestrator/, 'and it says where the figures came from');

# Without an orchestrator log, the gate's own failure stands.
my $proj2 = tempdir(CLEANUP => 1);
my $g2 = "$proj2/.ccpraxis-local-data/claude-home/.launcher";
make_path($g2);
my ($c2) = snap($g2);
is($c2->{status}, 'unknown', 'no orchestrator poll: still unknown');
like($c2->{diagnostic} // '', qr/oauth-token-under-floor/, 'with the gate\'s own diagnostic');

done_testing();
