#!/usr/bin/env perl
# A3 token-keeper (bp-token-keeper.pl, Decisions #11/#12/#30): every survivability
# branch, with an INJECTED http transport — no live network, no real creds.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-token-keeper.pl";

plan tests => 21;

my $J   = JSON::PP->new;
my $dir = tempdir(CLEANUP => 1);
my $NOW = 1_782_000_000_000;          # fixed "now" in ms
my $H   = 3_600_000;

sub make_creds {
    my ($path, $exp) = @_;
    open my $f, '>:raw', $path or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb',
        expiresAt => $exp, scopes => ['user:inference','user:profile'],
        subscriptionType => 'max', rateLimitTier => 'x' } });
    close $f;
}
sub read_creds { local $/; open my $f,'<:raw',shift or die; my $d=$J->decode(<$f>); $d->{claudeAiOauth} }
sub mock { my ($resp,$calls)=@_; return sub { push @$calls, {@_ ? (body=>$_[2]) : ()}; return $resp } }

# 1. life ok (5h) -> no refresh, no http call
{
    my $c = "$dir/ok.json"; make_creds($c, $NOW + 5*$H);
    my @calls; my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW, http_post=>mock({},\@calls) });
    is($r->{action}, 'ok', 'ok: 5h life -> action ok');
    is(scalar @calls, 0,   'ok: no refresh attempted');
}

# 2. pause-floor (0.5h) -> no http call, logs token_floor
{
    my $c = "$dir/floor.json"; make_creds($c, $NOW + 0.5*$H); my $log = "$dir/floor.log";
    my @calls; my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW, log_path=>$log, http_post=>mock({},\@calls) });
    is($r->{action}, 'pause-floor', 'floor: 0.5h life -> pause-floor');
    is(scalar @calls, 0,            'floor: no refresh attempted past the floor');
    my $logtxt = do { local $/; open my $f,'<',$log or die; <$f> };
    like($logtxt, qr/token_floor/,  'floor: logs token_floor event');
}

# 3. refresh band (1.5h) + 200 -> refreshed, creds rotated, logged, no secret leak
{
    my $c = "$dir/ref.json"; make_creds($c, $NOW + 1.5*$H); my $log = "$dir/ref.log";
    my $resp = { status=>200, content=>$J->encode({
        access_token=>'sk-ant-NEW-cccccccccccccccccccc', refresh_token=>'sk-ant-NEWREF-dddddddddddddddddddd',
        expires_in=>28800, scope=>'user:inference user:profile' }) };
    my @calls; my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW, log_path=>$log, http_post=>mock($resp,\@calls) });
    is($r->{action}, 'refreshed', 'refresh: 200 -> refreshed');
    is(scalar @calls, 1,          'refresh: exactly one http call');
    my $o = read_creds($c);
    is($o->{accessToken}, 'sk-ant-NEW-cccccccccccccccccccc', 'refresh: accessToken rotated on disk');
    is($o->{expiresAt}, $NOW + 28800*1000,                   'refresh: expiresAt = now + expires_in*1000');
    my $logtxt = do { local $/; open my $f,'<',$log or die; <$f> };
    like($logtxt, qr/"result":200/, 'refresh: logs result 200');
    unlike($logtxt, qr/sk-ant-NEW|cccccc|dddddd/, 'refresh: NO secret token in the log');
}

# 4. refresh band + 429 -> backoff, creds UNCHANGED
{
    my $c = "$dir/r429.json"; make_creds($c, $NOW + 1.5*$H); my $log = "$dir/r429.log";
    my @calls; my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW, log_path=>$log,
        http_post=>mock({status=>429, content=>'{"error":{"type":"rate_limit_error"}}'},\@calls) });
    is($r->{action}, 'backoff', '429: -> backoff');
    is(read_creds($c)->{accessToken}, 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa', '429: creds untouched');
    my $logtxt = do { local $/; open my $f,'<',$log or die; <$f> };
    like($logtxt, qr/"result":429/, '429: logged');
}

# 5. refresh band + 401 -> pause-auth (needs /login), creds UNCHANGED
{
    my $c = "$dir/r401.json"; make_creds($c, $NOW + 1.5*$H);
    my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW,
        http_post=>mock({status=>401, content=>'{"error":"invalid_grant"}'},[]) });
    is($r->{action}, 'pause-auth', '401: -> pause-auth');
    is(read_creds($c)->{accessToken}, 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa', '401: creds untouched');
}

# 6. refresh band + 200 with drifted body -> pause-contract, creds UNCHANGED
{
    my $c = "$dir/rdrift.json"; make_creds($c, $NOW + 1.5*$H);
    my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW,
        http_post=>mock({status=>200, content=>'{"expires_in":28800}'},[]) });   # missing access_token
    is($r->{action}, 'pause-contract', 'drifted refresh body -> pause-contract');
    is(read_creds($c)->{accessToken}, 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa', 'drift: creds untouched');
}

# 7. invalid creds shape -> pause-contract
{
    my $c = "$dir/bad.json"; open my $f,'>:raw',$c or die; print $f '{"claudeAiOauth":{"accessToken":"x"}}'; close $f;
    my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW, http_post=>mock({},[]) });
    is($r->{action}, 'pause-contract', 'bad creds shape -> pause-contract');
}

# 8. atomic_writeback stand-down (refreshToken changed underneath) -> no overwrite
{
    my $c = "$dir/sd.json"; make_creds($c, $NOW + 1.5*$H);
    my $wb = BpKeeper::atomic_writeback($c, {access_token=>'sk-x',expires_in=>1}, 'WRONG-OLD-REFRESH', $NOW);
    is($wb, 'stand-down', 'stand-down when refreshToken changed underneath');
    is(read_creds($c)->{accessToken}, 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa', 'stand-down: creds untouched');
}
