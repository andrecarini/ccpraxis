#!/usr/bin/env perl
# A8 contract-validators (bp-contract.pl): good shapes pass, drifted shapes are
# caught with precise, itemized problems (Decision #29 — detect Anthropic-side
# drift, never proceed on unrecognized data).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

require "$Bin/../../scripts/bp-contract.pl";

plan tests => 18;

# ---- usage ----------------------------------------------------------------
{
    my $good = { five_hour => { utilization => 58, resets_at => '2026-06-22T05:59:59.7+00:00' },
                 seven_day => { utilization => 7,  resets_at => '2026-06-22T17:59:59+00:00' } };
    my ($ok, $p) = BpContract::validate_usage($good);
    is($ok, 1, 'usage: good shape passes');
    is(scalar @$p, 0, 'usage: good shape has no problems');
}
{
    my ($ok, $p) = BpContract::validate_usage({ five_hour => { resets_at => '2026-06-22T05:59:59+00:00' },
                                                seven_day => { utilization => 7 } });
    is($ok, 0, 'usage: missing utilization + missing resets_at fails');
    ok((grep { /five_hour\.utilization/ } @$p), 'usage: names the missing five_hour.utilization');
    ok((grep { /seven_day\.resets_at/ }   @$p), 'usage: names the missing seven_day.resets_at');
}
{
    my ($ok, $p) = BpContract::validate_usage({ five_hour => { utilization => 150, resets_at => '2026-06-22T00:00:00Z' },
                                                seven_day => { utilization => 7,  resets_at => '2026-06-22T00:00:00Z' } });
    is($ok, 0, 'usage: out-of-range utilization fails');
    ok((grep { /out of 0\.\.100/ } @$p), 'usage: flags the out-of-range value');
}
{
    my ($ok, $p) = BpContract::validate_usage("not a hash");
    is($ok, 0, 'usage: non-object fails');
}

# ---- refresh --------------------------------------------------------------
{
    my ($ok) = BpContract::validate_refresh({ access_token => 'sk-x', expires_in => 28800 });
    is($ok, 1, 'refresh: good shape passes (refresh_token optional)');
}
{
    my ($ok, $p) = BpContract::validate_refresh({ expires_in => -5 });
    is($ok, 0, 'refresh: missing access_token + bad expires_in fails');
    ok((grep { /access_token/ } @$p), 'refresh: names missing access_token');
    ok((grep { /expires_in/ }   @$p), 'refresh: names bad expires_in');
}

# ---- creds ----------------------------------------------------------------
{
    my $good = { claudeAiOauth => { accessToken => 'sk-a', refreshToken => 'sk-r',
                 expiresAt => 1782286577985, scopes => ['user:inference'] } };
    my ($ok) = BpContract::validate_creds($good);
    is($ok, 1, 'creds: good shape passes');
}
{
    my ($ok, $p) = BpContract::validate_creds({ claudeAiOauth => {
                 accessToken => 'sk-a', refreshToken => 'sk-r', expiresAt => 999, scopes => 'nope' } });
    is($ok, 0, 'creds: epoch-seconds + non-array scopes fails');
    ok((grep { /expiresAt/ } @$p), 'creds: flags non-epoch-ms expiresAt');
    ok((grep { /scopes/ }    @$p), 'creds: flags non-array scopes');
}
{
    my ($ok, $p) = BpContract::validate_creds({});
    is($ok, 0, 'creds: missing claudeAiOauth fails');
    ok((grep { /claudeAiOauth/ } @$p), 'creds: names the missing object');
}
