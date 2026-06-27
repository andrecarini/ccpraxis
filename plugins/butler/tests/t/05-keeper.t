#!/usr/bin/env perl
# A3 token-keeper (bp-token-keeper.pl, Decisions #11/#12/#30): every survivability
# branch, with an INJECTED http transport — no live network, no real creds.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use Errno qw(EBUSY EXDEV EACCES);

require "$Bin/../../scripts/bp-token-keeper.pl";

plan tests => 36;

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

# 9. atomic_writeback IN-PLACE FALLBACK (Fix 1 defense-in-depth): rename fails
#    with EBUSY — the single-file-bind-mountpoint case. The refreshed token must
#    still land on disk (in-place truncate+rewrite under the held flock) and the
#    call returns 'ok'. (We inject a rename that fails with EBUSY rather than
#    build a real bind mount, which would need root + Linux.)
{
    my $c = "$dir/inplace.json"; make_creds($c, $NOW + 1.5*$H);
    my $busy = sub { $! = EBUSY; return 0 };
    my $wb = BpKeeper::atomic_writeback($c,
        { access_token=>'sk-ant-INPLACE-eeeeeeeeeeeeeeeeeeee',
          refresh_token=>'sk-ant-NEWREF-ffffffffffffffffffff', expires_in=>28800 },
        'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW, $busy);
    is($wb, 'ok', 'in-place fallback (EBUSY): writeback returns ok');
    my $o = read_creds($c);
    is($o->{accessToken},  'sk-ant-INPLACE-eeeeeeeeeeeeeeeeeeee', 'in-place fallback: accessToken rotated on disk');
    is($o->{refreshToken}, 'sk-ant-NEWREF-ffffffffffffffffffff', 'in-place fallback: refreshToken rotated on disk');
    is($o->{expiresAt},    $NOW + 28800*1000,                    'in-place fallback: expiresAt updated on disk');
}

# 10. in-place fallback also triggers on EXDEV (cross-device rename).
{
    my $c = "$dir/inplace2.json"; make_creds($c, $NOW + 1.5*$H);
    my $xdev = sub { $! = EXDEV; return 0 };
    my $wb = BpKeeper::atomic_writeback($c,
        { access_token=>'sk-ant-XDEV-gggggggggggggggggggg', expires_in=>10 },
        'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW, $xdev);
    is($wb, 'ok', 'in-place fallback (EXDEV): writeback returns ok');
    is(read_creds($c)->{accessToken}, 'sk-ant-XDEV-gggggggggggggggggggg', 'EXDEV fallback: accessToken rotated');
}

# 11. a NON-EBUSY/EXDEV rename failure (e.g. EACCES) is NOT swallowed: the
#     fallback is scoped to the single-file-bind errnos only. Dies, creds untouched.
{
    my $c = "$dir/eacces.json"; make_creds($c, $NOW + 1.5*$H);
    my $perm = sub { $! = EACCES; return 0 };
    my $ok = eval { BpKeeper::atomic_writeback($c,
        { access_token=>'sk-x', expires_in=>1 },
        'sk-ant-OLDREF-bbbbbbbbbbbbbbbbbbbb', $NOW, $perm); 1 };
    ok(!$ok, 'non-EBUSY/EXDEV rename failure (EACCES) is NOT swallowed -> dies');
    is(read_creds($c)->{accessToken}, 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa',
       'EACCES: creds untouched (no in-place write)');
}

# 12. LOUD divergence alert on 4xx (hard requirement): the sandbox's OWN refresh
#     was rejected. keeper_tick must surface alert=1 + status + a divergence
#     detail, and log a DISTINCT token_unauthorized event — never a quiet pause.
{
    my $c = "$dir/alert.json"; make_creds($c, $NOW + 1.5*$H); my $log = "$dir/alert.log";
    my $r = BpKeeper::keeper_tick({ creds_path=>$c, now_ms=>$NOW, log_path=>$log,
        http_post=>mock({status=>403, content=>'{"error":"invalid_grant"}'},[]) });
    is($r->{action}, 'pause-auth', '4xx: still pauses gracefully (action pause-auth)');
    is($r->{alert},  1,            '4xx: alert flag set on the return');
    is($r->{status}, 403,          '4xx: HTTP status surfaced to the orchestrator');
    like($r->{detail}, qr/DIVERGED|REJECTED/, '4xx: detail names the divergence (not a routine expiry)');
    my $logtxt = do { local $/; open my $f,'<',$log or die; <$f> };
    like($logtxt, qr/token_unauthorized/, '4xx: logs the DISTINCT token_unauthorized event');
    like($logtxt, qr/"alert"\s*:\s*1/,    '4xx: log carries the alert flag');
    is(read_creds($c)->{accessToken}, 'sk-ant-OLD-aaaaaaaaaaaaaaaaaaaaaaaa', '4xx: creds untouched');
}
