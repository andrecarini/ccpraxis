#!/usr/bin/env perl
# bp-token-keeper.pl — the orchestrator's OAuth token-keeper (Decisions #11/#12/#30).
#
# Assembles the pieces A0 proved into one deterministic, unit-tested tick:
#   refresh timing (bp-govern refresh_state) + the A0-reverse-engineered refresh
#   request + atomic write-back (flock + re-read stand-down + temp+rename +
#   JSON-validate + preserve-mode) + 429 backoff + fail-safe pause + logging.
#
# The HTTP transport is INJECTABLE (args.http_post) so the keeper logic is tested
# without touching the network or the real credential store. A3 provides a real
# transport in production.
#
# keeper_tick(\%args) -> { action => ..., detail => ... }
#   args: creds_path, now_ms, log_path(optional), http_post(optional sub),
#         client_id(optional), scope(optional)
#   action: ok | refreshed | backoff | pause-floor | pause-auth | pause-contract | pause-creds
#
# NEVER logs secret values (bp-log redacts).

package BpKeeper;
use strict;
use warnings;
use JSON::PP;
use Fcntl qw(:flock);
use Errno qw(EBUSY EXDEV);
use File::Basename qw(dirname);

my $DIR = dirname(__FILE__);
require "$DIR/bp-govern.pl";
require "$DIR/bp-contract.pl";
require "$DIR/bp-log.pl";
require "$DIR/bp-http.pl";

our $TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
our $DEFAULT_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
our $DEFAULT_SCOPE = 'user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload';

sub _log { my ($p,$t,$f)=@_; return unless defined $p; BpLog::event($p,$t,$f); }
sub _read_json { my $f=shift; open my $fh,'<:raw',$f or return undef; local $/; my $r=<$fh>; close $fh; return eval { JSON::PP->new->decode($r) }; }

# Atomic write-back (the A0-proven implementation). Returns 'ok' or 'stand-down'.
sub atomic_writeback {
    my ($path, $resp, $expected_old_refresh, $now_ms, $rename_fn) = @_;
    $now_ms //= time * 1000;
    # The rename step is an INJECTABLE seam (like http_post) so the in-place
    # fallback below is unit-testable without a real single-file bind mount
    # (which needs root + Linux). Production passes nothing -> real rename.
    $rename_fn //= sub { rename($_[0], $_[1]) };
    open my $lock, '>', "$path.lock" or die "lock: $!";
    flock($lock, LOCK_EX) or die "flock: $!";
    my $data = _read_json($path) or die "creds unparseable at write-back";
    my $o = $data->{claudeAiOauth} or die "no claudeAiOauth";
    if (defined $expected_old_refresh && ($o->{refreshToken}//'') ne $expected_old_refresh) {
        close $lock; return 'stand-down';
    }
    $o->{accessToken}  = $resp->{access_token};
    $o->{refreshToken} = $resp->{refresh_token} // $o->{refreshToken};
    $o->{expiresAt}    = int($now_ms) + int($resp->{expires_in}) * 1000;
    $o->{scopes}       = [ split / /, $resp->{scope} ] if defined $resp->{scope} && length $resp->{scope};
    my $out = JSON::PP->new->utf8->canonical->pretty->encode($data);
    eval { JSON::PP->new->decode($out); 1 } or die "serialized creds invalid";
    defined $o->{$_} or die "missing $_ post-update" for qw(accessToken refreshToken expiresAt);
    my @st = stat($path); my $mode = @st ? ($st[2] & 07777) : 0600;
    my $tmp = "$path.tmp.$$";
    open my $w, '>:raw', $tmp or die "tmp: $!"; print $w $out or die; close $w or die;
    chmod $mode, $tmp;
    unless ($rename_fn->($tmp, $path)) {
        # Read errno IMMEDIATELY (any later syscall clobbers $!).
        my $en = $! + 0;
        my $es = "$!";
        # A single-file bind mountpoint (e.g. the legacy pre-Fix-1 sandbox
        # creds overlay at /root/.claude/.credentials.json) rejects a
        # rename OVER it with EBUSY (Linux bind) / EXDEV (cross-device).
        # We still hold the flock here, so fall back to an in-place
        # truncate+rewrite of the existing file — same fully-formed,
        # already-validated bytes, no rename. This keeps the keeper able to
        # persist a refresh even on a single-file-bind target. (On Fix-1
        # sandboxes the creds are a real file in a dir bind and the rename
        # path is taken; this is the defense-in-depth branch.)
        if ($en == EBUSY || $en == EXDEV) {
            unlink $tmp;
            open my $ow, '>:raw', $path
                or die "in-place open $path (after rename $es): $!";
            print $ow $out or die "in-place write $path: $!";
            close $ow      or die "in-place close $path: $!";
            chmod $mode, $path;
        } else {
            unlink $tmp;
            die "rename: $es";
        }
    }
    close $lock;
    return 'ok';
}

# Default real transport (production), via curl (bp-http.pl). Tests inject their
# own. curl is used because the sandbox perl has no IO::Socket::SSL/Net::SSLeay,
# so HTTP::Tiny cannot do HTTPS there; curl trusts the system cert store.
sub _real_http_post {
    my ($url, $headers, $body) = @_;
    return BpHttp::request('POST', $url, $headers, $body);
}

sub keeper_tick {
    my ($args) = @_;
    my $path = $args->{creds_path} or die "keeper_tick: creds_path required";
    my $now  = $args->{now_ms}     // (time * 1000);
    my $log  = $args->{log_path};
    my $post = $args->{http_post}  || \&_real_http_post;

    # 1. creds present + parseable + shape valid
    my $data = _read_json($path);
    unless ($data) { _log($log,'creds_error',{detail=>'unreadable or invalid JSON'}); return {action=>'pause-creds'}; }
    my ($cok,$cprob) = BpContract::validate_creds($data);
    unless ($cok) { _log($log,'creds_drift',{problems=>$cprob}); return {action=>'pause-contract',detail=>$cprob}; }
    my $o = $data->{claudeAiOauth};

    # 2. timing decision
    my $state = BpGovern::refresh_state($o->{expiresAt}, $now);
    if ($state eq 'ok')          { return {action=>'ok'}; }
    if ($state eq 'pause-floor') {
        _log($log,'token_floor',{detail=>'crossed 1h floor unrefreshed', expiresAt=>$o->{expiresAt}});
        return {action=>'pause-floor'};
    }

    # 3. state eq 'refresh' -> attempt the refresh
    my $body = JSON::PP->new->encode({
        grant_type    => 'refresh_token',
        refresh_token => $o->{refreshToken},
        client_id     => $args->{client_id} // $ENV{CLAUDE_CODE_OAUTH_CLIENT_ID} // $DEFAULT_CLIENT_ID,
        scope         => $args->{scope} // join(' ', @{$o->{scopes}||[]}) || $DEFAULT_SCOPE,
    });
    my $res = $post->($TOKEN_URL, { 'Content-Type'=>'application/json', 'Accept'=>'application/json',
                                    'User-Agent'=>'claude-code/keeper' }, $body);
    my $status = $res->{status} // 0;

    if ($status == 200) {
        my $resp = eval { JSON::PP->new->decode($res->{content} // '') };
        my ($rok,$rprob) = $resp ? BpContract::validate_refresh($resp) : (0,['refresh response not JSON']);
        unless ($rok) { _log($log,'refresh_drift',{problems=>$rprob}); return {action=>'pause-contract',detail=>$rprob}; }
        my $wb = atomic_writeback($path, $resp, $o->{refreshToken}, $now);
        my $new_exp = int($now) + int($resp->{expires_in})*1000;
        _log($log,'token_refresh',{result=>200, writeback=>$wb, expiresAt=>$new_exp, expires_in=>$resp->{expires_in}});
        return {action=>'refreshed', detail=>{writeback=>$wb, expiresAt=>$new_exp}};
    }
    if ($status == 429) {
        _log($log,'token_refresh',{result=>429, action=>'backoff', detail=>'rate-limited; retry within runway'});
        return {action=>'backoff'};
    }
    if ($status == 400 || $status == 401 || $status == 403) {
        # LOUD DIVERGENCE ALERT (hard requirement). A 4xx on the sandbox's
        # OWN refresh is NOT a routine expiry — it means the copied token was
        # rejected: the sandbox's copy may be invalid, or the host and sandbox
        # token grants have diverged (both refreshing the same grant). This is
        # the signal to revisit the copy-token architecture. Emit a DISTINCT,
        # high-visibility event (token_unauthorized + alert=1) — never let this
        # blend into a quiet pause — and return the detail up to the
        # orchestrator so the queued needs-you decision can name it unmistakably.
        my $alert = "ALERT: the sandbox's OWN OAuth refresh was REJECTED (HTTP $status). "
                  . "The copied token may be invalid OR the host/sandbox token grants have "
                  . "DIVERGED -- this is NOT a routine /login expiry. Revisit the copy-token "
                  . "architecture before resuming.";
        _log($log,'token_unauthorized',{result=>$status, action=>'pause-auth', alert=>1, detail=>$alert});
        return {action=>'pause-auth', alert=>1, status=>$status, detail=>$alert};
    }
    # 5xx / network / 0 -> transient, back off and retry within the runway
    _log($log,'token_refresh',{result=>$status, action=>'backoff', detail=>'transient error; retry'});
    return {action=>'backoff', detail=>"status $status"};
}

package main;
1;
