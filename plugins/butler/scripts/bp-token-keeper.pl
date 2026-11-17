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
use Fcntl qw(:flock O_WRONLY O_CREAT O_EXCL);
use Errno qw(EBUSY EXDEV);
use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$DIR/bp-govern.pl";
require "$DIR/bp-contract.pl";
require "$DIR/bp-log.pl";
require "$DIR/bp-http.pl";

our $TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
our $DEFAULT_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
our $DEFAULT_SCOPE = 'user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload';

sub _log { my ($p,$t,$f)=@_; return unless defined $p; BpLog::event($p,$t,$f); }

# Raw bytes or undef (missing/unopenable). _read_json is re-expressed on top of
# it; observable behaviour is IDENTICAL (missing/empty/truncated/malformed ->
# undef; valid -> decoded ref) — see spec §5.8.
sub _read_raw { my $f=shift; open my $fh,'<:raw',$f or return undef; local $/; my $r=<$fh>; close $fh; return $r; }
sub _read_json { my $r = _read_raw($_[0]); return undef unless defined $r; return eval { JSON::PP->new->decode($r) }; }

# NEW private, injectable-open in-place writer (b03). Returns 1; DIES on any
# failure. $open_fn->($how,$path) -> filehandle | undef ($! set). $how is
# '+<:raw' (existing file — UPDATE, never truncate-create) or '>:raw' (absent
# file — plain create). The seam exists ONLY so AC-11 can prove the
# create-branch is not taken for an existing file (no root, no bind mount).
# INV-W4: the '>:raw' branch is taken only when -e $path is false — a failed
# '+<' open on an existing file DIES rather than falling back to a truncating
# create (fix for defect 6(i), old lines 91-93).
sub _inplace_overwrite {
    my ($path, $bytes, $mode, $open_fn) = @_;
    $open_fn //= sub { my ($how,$p)=@_; open(my $fh,$how,$p) or return undef; return $fh };
    my $ow;
    if (-e $path) { $ow = $open_fn->('+<:raw', $path) or die "in-place open $path: $!"; }
    else          { $ow = $open_fn->('>:raw',  $path) or die "in-place create $path: $!"; }
    print $ow $bytes             or die "in-place write $path: $!";
    truncate($ow, length $bytes) or die "in-place truncate $path: $!";
    close $ow                    or die "in-place close $path: $!";
    chmod $mode, $path;
    return 1;
}

# Atomic write-back (the A0-proven implementation). Returns 'ok' or 'stand-down'.
sub atomic_writeback {
    my ($path, $resp, $expected_old_refresh, $now_ms, $rename_fn, $inplace_fn) = @_;
    $now_ms //= time * 1000;
    # The rename step is an INJECTABLE seam (like http_post) so the in-place
    # fallback below is unit-testable without a real single-file bind mount
    # (which needs root + Linux). Production passes nothing -> real rename.
    $rename_fn //= sub { rename($_[0], $_[1]) };
    # b03: injectable in-place writer, matching $rename_fn's seam style. Default
    # = the real overwrite. Production passes nothing -> real in-place write.
    $inplace_fn //= \&_inplace_overwrite;
    open my $lock, '>', "$path.lock" or die "lock: $!";
    flock($lock, LOCK_EX) or die "flock: $!";
    # b03: read the ORIGINAL raw bytes once, under the held flock, and retain
    # them for the duration of the call — they are the rollback source if the
    # in-place fallback below fails partway through (INV-W2).
    my $orig_raw = _read_raw($path);
    my $data = (defined $orig_raw ? eval { JSON::PP->new->decode($orig_raw) } : undef)
        or die "creds unparseable at write-back";
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
    # b03 R1 (redteam MAJOR-1): the temp is created with restrictive perms
    # (0600) via O_EXCL BEFORE a single token byte is written. The old code
    # opened '>:raw' (0666 & ~umask -- world-readable at a default umask) and
    # only chmod'd to $mode AFTER a successful close, so (a) there was a real
    # world-readable window on the happy path, and (b) a print/close failure
    # on THIS initial write died before reaching either the chmod or an
    # unlink, orphaning a 0644 file holding the new access+refresh tokens in
    # plaintext forever. Both are fixed here: the mode is restrictive from
    # creation, and every failure below unlinks the temp before dying
    # (O_EXCL also refuses a stale/pre-planted/symlinked temp at this path).
    sysopen(my $w, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600) or die "tmp: $!";
    binmode $w, ':raw';
    unless (print $w $out) {
        my $e = $!; close $w; unlink($tmp) or warn "tmp cleanup $tmp: $!";
        die "tmp write $path: $e";
    }
    unless (close $w) {
        my $e = $!; unlink($tmp) or warn "tmp cleanup $tmp: $!";
        die "tmp close $path: $e";
    }
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
            # In-place rewrite WITHOUT a zero-length window: open for UPDATE
            # (no O_TRUNC), overwrite from the start with the already-validated
            # bytes, then truncate to the new length. A kill mid-write then
            # leaves a new-prefix+old-suffix file (corrupt but NON-EMPTY) rather
            # than a zero-byte one. Either way the next launcher run
            # re-materializes creds from the host, so this fallback is
            # self-healing. (Only runs on a legacy pre-Fix-1 single-file-bind
            # sandbox; Fix-1 dir-bind creds take the atomic rename path above.)
            my $ok = eval { $inplace_fn->($path, $out, $mode); 1 };
            my $ierr = $@ || 'unknown in-place failure';
            if ($ok) {
                unlink($tmp) or warn "tmp cleanup $tmp: $!";
            } else {
                # b03 R3 (redteam MAJOR-3): the restore below reuses the SAME
                # real opener the primary attempt just used, so an open-step
                # failure (EROFS/EACCES/EMFILE -- nothing ever written) would
                # hit it identically and produce a false "creds may be
                # damaged" for a byte-for-byte untouched file. Distinguish
                # "nothing was written" from "write failed midway" by
                # comparing the file's CURRENT bytes to the retained
                # $orig_raw before attempting any restore at all.
                my $cur_bytes = _read_raw($path);
                my $untouched = (defined $cur_bytes && defined $orig_raw && $cur_bytes eq $orig_raw) ? 1 : 0;
                if ($untouched) {
                    unlink($tmp) or warn "tmp cleanup $tmp: $!";
                    die "in-place write $path failed: $ierr ($path was never modified -- nothing to restore)";
                }
                # A genuine mid-write failure: attempt the restore.
                # Restore ALWAYS uses the real _inplace_overwrite, never $inplace_fn:
                # the injected failing writer must not be able to sabotage the rollback.
                my $rok = eval { _inplace_overwrite($path, $orig_raw, $mode); 1 };
                my $rerr = $@;
                unlink($tmp) or warn "tmp cleanup $tmp: $!";
                # b03 R2 (redteam MAJOR-2): by the time we get here the auth
                # server has ALREADY rotated the refresh token server-side (the
                # POST that produced $resp ran before atomic_writeback was ever
                # called) -- so the just-restored $orig_raw is a KNOWN-STALE
                # credential even though the restore "succeeded". Say so
                # explicitly so a later 401 reads as a consequence of THIS
                # failure, not as a host/sandbox grant-divergence alert.
                die "in-place write $path failed: $ierr (original creds restored; WARNING: the "
                  . "just-restored refresh token may already be stale -- the auth server likely "
                  . "rotated it server-side before this restore ran)" if $rok;
                die "in-place write $path failed: $ierr (RESTORE FAILED: $rerr - creds may be damaged)";
            }
        } else {
            unlink($tmp) or warn "tmp cleanup $tmp: $!";
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

# _creds_changed_since PATH, MTIME_AT_READ -> 0 | 1
#   Did the credentials file change on disk since we read it? This is the only
#   fact available in-process that OBSERVES divergence rather than guessing at
#   it: if another holder rotated the grant, it rewrote this file, and the
#   refresh token we just presented is stale.
#
#   Conservative in the safe direction. An unknown (no mtime recorded, or the
#   file has since vanished) answers 0 -- "not observed" -- because a false 1
#   would assert an architectural fault on no evidence, which is the exact
#   failure this whole change exists to stop.
sub _creds_changed_since {
    my ($path, $mtime_at_read) = @_;
    return 0 unless defined $mtime_at_read && $mtime_at_read =~ /\A\d+(?:\.\d+)?\z/;
    my @st = stat($path);
    return 0 unless @st;
    return ($st[9] != $mtime_at_read) ? 1 : 0;
}

sub keeper_tick {
    my ($args) = @_;
    my $path = $args->{creds_path} or die "keeper_tick: creds_path required";
    # Stamp the file's mtime BEFORE reading it, so a rewrite that lands during
    # our own refresh round is detectable afterwards. Tests may inject it.
    unless (exists $args->{creds_mtime_at_read}) {
        my @st0 = stat($path);
        $args->{creds_mtime_at_read} = @st0 ? $st0[9] : undef;
    }
    my $now  = $args->{now_ms}     // (time * 1000);
    my $log  = $args->{log_path};
    my $post = $args->{http_post}  || \&_real_http_post;
    my $quiet_creds = $args->{quiet_creds_error} // 0;

    # 1. creds present + parseable + shape valid
    my $data = _read_json($path);
    unless ($data) {
        _log($log,'creds_error',{detail=>'unreadable or invalid JSON'}) unless $quiet_creds;
        return {action=>'pause-creds'};
    }
    my ($cok,$cprob) = BpContract::validate_creds($data);
    unless ($cok) { _log($log,'creds_drift',{problems=>$cprob}); return {action=>'pause-contract',detail=>$cprob}; }
    my $o = $data->{claudeAiOauth};

    # 2. timing decision
    #
    # FLOOR = 10 MINUTES, and crossing it is no longer an instant surrender.
    # Operator decision 2026-08-12.
    #
    # This used to return pause-floor here, WITHOUT EVER ATTEMPTING A REFRESH:
    # once the token dropped under the (then 1-hour) floor the keeper gave up
    # and queued a re-login for a human, never once trying the refresh token it
    # was holding. That is backwards. The refresh is cheap, it is the only thing
    # that can actually rescue the run, and an unattended fleet has nobody to
    # answer the re-login it raises instead.
    #
    # So the floor no longer decides whether to TRY; it decides what a FAILURE
    # means. Above the floor a transient failure is worth backing off into the
    # remaining runway. Below it there is no runway left, so the same failure is
    # terminal and the fleet stops for a human — which is what the floor was
    # always really for.
    # The floor is BpGovern's, not ours — see BpGovern::TOKEN_FLOOR_H. Passing
    # it explicitly only so the log and the tests can name the value in force.
    my $floor_h = $args->{floor_h} // BpGovern::TOKEN_FLOOR_H();
    my $state = BpGovern::refresh_state($o->{expiresAt}, $now, $floor_h);
    if ($state eq 'ok') { return {action=>'ok'}; }

    # Below the floor: still attempt the refresh, but a failure is terminal.
    my $below_floor = ($state eq 'pause-floor');
    _log($log,'token_floor',{detail=>'under the refresh floor — attempting refresh anyway',
                             floor_h=>$floor_h, expiresAt=>$o->{expiresAt}}) if $below_floor;

    # 3. attempt the refresh
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
        # Backing off is only meaningful if there is runway left to back off
        # INTO. Under the floor there is not, so the same 429 is terminal.
        if ($below_floor) {
            _log($log,'token_floor',{result=>429, action=>'pause-floor',
                                     detail=>'rate-limited under the floor; no runway left to retry within'});
            return {action=>'pause-floor', detail=>'refresh rate-limited (429) with no runway left'};
        }
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
        # orchestrator so the queued escalations decision can name it unmistakably.
        #
        # REPORT 20260917-110321-ff63: the alert named two causes and carried
        # NOTHING to tell them apart, and the pause is manual=1 so it never
        # self-clears — a human is fetched, and the message they are fetched with
        # is a question rather than a finding.
        #
        # It was also WRONG the one time it fired. On 2026-09-17 the host had
        # been in Modern Standby for over three hours; the keeper woke four
        # seconds later, refreshed under the floor, got 400, and reported a
        # possible architectural fault. One second afterwards an authenticated
        # usage poll returned 200. The credentials were fine.
        #
        # So the alert now carries the three facts that actually discriminate,
        # and stops asserting divergence when a wake explains it:
        #
        #   creds_rewritten  — did .credentials.json change on disk between our
        #                      read and this failure? If so ANOTHER party rotated
        #                      the grant while we held a now-stale refresh token.
        #                      That is what divergence IS, observed rather than
        #                      guessed.
        #   expired_by_s     — was the token already past its own expiry when we
        #                      called? An expired grant being refused is ordinary,
        #                      not architectural.
        #   suspend_gap_s    — did this machine just come back from a suspend?
        #                      (runs/.last-suspend.json, written by the
        #                      orchestrator — report 20260917-155603-b83e.)
        my $diag = {
            http_status   => $status,
            below_floor   => ($below_floor ? 1 : 0),
            expires_at    => $o->{expiresAt},
            expired_by_s  => (defined $o->{expiresAt} && $o->{expiresAt} =~ /\A\d+\z/)
                             ? int(($now - $o->{expiresAt}) / 1000) : undef,
            creds_rewritten => _creds_changed_since($path, $args->{creds_mtime_at_read}),
            suspend_gap_s   => (ref $args->{recent_suspend} eq 'HASH')
                             ? $args->{recent_suspend}{gap_secs} : undef,
            suspend_age_s   => (ref $args->{recent_suspend} eq 'HASH'
                                && defined $args->{recent_suspend}{at_epoch})
                             ? int($now / 1000) - $args->{recent_suspend}{at_epoch} : undef,
        };

        # A wake within this window explains a rejected refresh without any
        # architectural fault. Wide on purpose: being wrong here costs one extra
        # sentence, while being wrong the other way sends a human to redesign the
        # token architecture over a machine that was asleep.
        my $WAKE_WINDOW_S = 900;
        my $just_woke = (defined $diag->{suspend_age_s}
                         && $diag->{suspend_age_s} >= 0
                         && $diag->{suspend_age_s} <= $WAKE_WINDOW_S) ? 1 : 0;

        my $alert;
        if ($just_woke && !$diag->{creds_rewritten}) {
            $alert = "The sandbox's OAuth refresh was REJECTED (HTTP $status) "
                   . "$diag->{suspend_age_s}s after this host resumed from a "
                   . "$diag->{suspend_gap_s}s suspend, and the credentials file was NOT "
                   . "rewritten by anyone else meanwhile. The likeliest cause is the sleep, "
                   . "not the copy-token architecture: a grant that expires while the machine "
                   . "is suspended is refused on the first call after the wake. Try "
                   . "re-authenticating with /login before concluding anything about "
                   . "divergence.";
        }
        elsif ($diag->{creds_rewritten}) {
            $alert = "ALERT: the sandbox's OWN OAuth refresh was REJECTED (HTTP $status), and "
                   . ".credentials.json WAS REWRITTEN by another party between our read and "
                   . "this call. That is the divergence case observed rather than guessed: two "
                   . "holders are refreshing the same grant and ours is now stale. Revisit the "
                   . "copy-token architecture before resuming.";
        }
        else {
            $alert = "ALERT: the sandbox's OWN OAuth refresh was REJECTED (HTTP $status). "
                   . "The credentials file was not rewritten underneath us and no recent host "
                   . "suspend explains it, so the copied token is invalid on its own terms -- "
                   . "this is NOT a routine /login expiry. Revisit the copy-token architecture "
                   . "before resuming.";
        }

        _log($log,'token_unauthorized',
             {result=>$status, action=>'pause-auth', alert=>1, detail=>$alert, diag=>$diag});
        return {action=>'pause-auth', alert=>1, status=>$status, detail=>$alert, diag=>$diag};
    }
    # 5xx / network / 0 -> transient, back off and retry within the runway.
    # Same reasoning as the 429 arm: under the floor there is no runway, so a
    # transient failure has nowhere left to retry into and stops the fleet
    # rather than spinning until the token dies on its own.
    if ($below_floor) {
        _log($log,'token_floor',{result=>$status, action=>'pause-floor',
                                 detail=>'transient refresh failure under the floor; no runway left'});
        return {action=>'pause-floor', detail=>"refresh failed (status $status) with no runway left"};
    }
    _log($log,'token_refresh',{result=>$status, action=>'backoff', detail=>'transient error; retry'});
    return {action=>'backoff', detail=>"status $status"};
}

package main;
1;
