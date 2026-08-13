#!/usr/bin/env perl
# bp-usage-gate.pl — ONE host-safe usage-headroom poll for /butler:drive-solo.
#
# drive-solo runs in an interactive session that shares the user's OAuth
# token + usage. There is no deterministic orchestrator to govern it, so the
# drive-solo director (bp-drive-next.pl) governs the session ITSELF: before each
# heavy step it calls this gate (`bp-usage-gate.pl verdict`), and if the gate says
# PAUSE the session sleeps token-cheaply until the window resets, then resumes.
# This is the in-session analogue of the fleet's usage governance (Decisions
# #7-#9) — deliberately simpler, because a single CLI invocation has only ONE
# usage sample and so cannot compute a burn rate. Instead of the fleet's
# burn*drain trip projection, we pause at a fixed SOFT ceiling set BELOW the
# fleet's hard walls (5h 85% / 7d 90%). The headroom between the soft ceiling and
# the hard wall is the reserve that keeps the tiny wake-up checks themselves from
# ever hitting the wall — the whole reason to stop early.
#
# Reuses the vetted transport + parsing the orchestrator already ships:
#   bp-govern.pl  -> BpGovern::iso_to_epoch (resets_at ISO-8601 -> epoch)
#   bp-http.pl    -> BpHttp::request         (curl transport; host Schannel TLS)
# Credentials + endpoint + headers mirror bp-orchestrator.pl::fetch_usage exactly.
#
# CRITICAL (host/Windows): this perl spawns curl (a native win32 binary) with a
# URL and header values that contain ':'. Git-for-Windows MSYS2 would mangle those
# ':'-bearing args (PATH-style translation, re-joined with ';') and corrupt the
# request. Disable MSYS2 arg conversion for this whole process (per CLAUDE.md).
BEGIN { $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/; }
#
# Output (one line to stdout) + exit code — both machine-readable so the driver
# can branch on either:
#
# LEGACY TEXT PATH (no arg):
#   OK        five=<pct> seven=<pct> token_life_h=<h>                       exit 0
#   PAUSE     window=<five_hour|seven_day> resets_at_epoch=<e> \
#             resets_at_iso=<iso> estimated=<0|1> five=<pct> seven=<pct> \
#             token_life_h=<h>                                             exit 10
#             (estimated=1 => resets_at was unparseable; epoch is now+3600, a
#              conservative re-gate point, NEVER empty — see the decide block)
#   RELOGIN   token_life_h=<h>   detail=...                                 exit 40
#   UNAVAILABLE status=<n>       detail=...                                 exit 20
#   CREDS     detail=...                                                    exit 30
#
# VERDICT SUBCOMMAND (argv[0] eq 'verdict'):
#   Always exits 0; prints ONE single-line JSON object:
#   {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":...}
#
# GOVERNOR VERDICT CONSUMED (director contract — Decision #12/#13):
#   {"action":"ok","until_epoch":null,"reason":"ok"}
#   {"action":"pause-usage","until_epoch":<epoch_secs>,"reason":"usage"}
#   {"action":"pause-token","until_epoch":<epoch_secs>,"reason":"token"}
#     Not a hard-stop: until_epoch is a real wake time (expiry + grace). This
#     gate reports a TIMED condition, not a demand for human intervention --
#     the access token auto-refreshes. Its only consumer (bp-drive-next.pl)
#     does not wait on the epoch; it refreshes immediately and treats success
#     as recovery, failure as a separate, genuinely terminal `stop`.
#   {"action":"unavailable","until_epoch":null,"reason":"telemetry"|"creds"}
#
# Tunables (env):
#   BP_KGS_SOFT_5H   soft 5h ceiling  (default 80; fleet hard wall 85)
#   BP_KGS_SOFT_7D   soft 7d ceiling  (default 85; fleet hard wall 90)
#   BP_KGS_TOKEN_FLOOR_H  re-login floor in hours (default 1)
#   BP_CREDS_PATH    creds file       (default ~/.claude/.credentials.json)
#   BP_USER_AGENT    curl UA          (default claude-code/2.1.170)

package BpUsageGate;
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Absolute script dir so `require "$DIR/..."` resolves no matter how this script
# is invoked (relative CLI path, absolute, or from another dir) — a relative path
# would be searched in @INC and fail.
my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$DIR/bp-govern.pl";
require "$DIR/bp-http.pl";
require "$DIR/bp-contract.pl";

my $USAGE_URL  = 'https://api.anthropic.com/api/oauth/usage';
my $USER_AGENT = $ENV{BP_USER_AGENT} // 'claude-code/2.1.170';

# Production defaults for the legacy text path (soft ceilings, frozen).
# The verdict path uses the $t tunables injected by run().
my $SOFT5   = defined $ENV{BP_KGS_SOFT_5H}       ? $ENV{BP_KGS_SOFT_5H} + 0       : 80;
my $SOFT7   = defined $ENV{BP_KGS_SOFT_7D}       ? $ENV{BP_KGS_SOFT_7D} + 0       : 85;
# Default floor: 10 MINUTES, not 1 hour. Operator decision (2026-08-12).
# A 1-hour floor parked runs for an hour of perfectly usable token life on the
# theory that nothing can refresh in-session. That theory was wrong -- the token
# refreshes, and the keeper can force it -- so the floor only needs to cover the
# refresh itself.
#
# The VALUE is BpGovern's (see BpGovern::TOKEN_FLOOR_H); this is an alias, not a
# second declaration. Three copies of this number is how the keeper silently
# kept running a 1-hour floor after the gate moved to ten minutes.
#
# A sub rather than `use constant` on purpose: `use constant` is evaluated at
# BEGIN, and bp-govern.pl is require'd at RUNTIME, so the constant form
# resolves before the value exists and dies as an undeclared bareword.
sub TOKEN_FLOOR_DEFAULT_H { BpGovern::TOKEN_FLOOR_H() }
# Seconds past token expiry before a token-pause wakes. The refresh happens at
# or before expiry; the margin absorbs clock skew between this host and the
# issuer, which is why it is not zero.
use constant TOKEN_REFRESH_GRACE_S => 90;
my $FLOOR_H = defined $ENV{BP_KGS_TOKEN_FLOOR_H} ? $ENV{BP_KGS_TOKEN_FLOOR_H} + 0 : TOKEN_FLOOR_DEFAULT_H;

# ---------------------------------------------------------------------------
# verdict_decision — PURE: no I/O, no network, no exit. Deterministic.
#
# $creds    = { ok=>0|1, expires_ms=><num|undef>, detail=><str> }
# $poll     = { status=><int>, parsed=><hashref|undef> }
# $samples5 / $samples7 = [[epoch,util],...] (empty or >=2 for burn)
# $now      = epoch seconds (injected clock)
# $t        = { ceil5, ceil7, drain, floor_h, jit_lo, jit_hi, rand }
#              $t->{rand} is a sub returning float in [0,1)
# returns   = { action=><str>, until_epoch=><num|undef>, reason=><str> }
# ---------------------------------------------------------------------------
sub verdict_decision {
    my ($creds, $poll, $samples5, $samples7, $now, $t) = @_;

    # (1) Creds problem → unavailable/creds
    unless ($creds->{ok}) {
        return { action => 'unavailable', until_epoch => undef, reason => 'creds' };
    }

    # (2) Token floor → pause-token, as a TIMED WAIT that resumes by itself.
    #
    # This used to return until_epoch => undef, which every consumer reads as a
    # hard-stop relogin park: the run halted and stayed halted until a human
    # noticed and re-authenticated. That was wrong in the common case. The
    # access token is refreshed for us (Claude Code holds a refreshToken); the
    # floor exists to avoid starting work that would die MID-FLIGHT, not to
    # demand human intervention.
    #
    # So the pause now carries a wake time — expiry plus a grace margin, by
    # which point the refresh has happened — and a consumer that waits can
    # continue without anyone being asked to do anything.
    #
    # KNOW WHAT CONSUMES THIS, because it is not what an earlier version of this
    # comment claimed. `bp-drive-next.pl` is the ONLY caller of this script; the
    # fleet orchestrator does not read this gate at all — it governs the token
    # through `bp-token-keeper.pl` instead. And drive-next no longer waits on
    # pause-token: it attempts a refresh and either continues or stops.
    #
    # So `until_epoch` currently has NO consumer that sleeps on it. It is
    # emitted because it is true and cheap, and because a future waiting
    # consumer should not have to re-derive it — not because anything waits
    # today. Do not write "the fleet resumes by itself" on the strength of this
    # field; nothing in the fleet reads it.
    if (defined $creds->{expires_ms}) {
        my $state = BpGovern::refresh_state($creds->{expires_ms}, $now * 1000,
                                             $t->{floor_h}, undef);
        if ($state eq 'pause-floor') {
            my $wake = int($creds->{expires_ms} / 1000) + TOKEN_REFRESH_GRACE_S;
            # Never hand back a wake time already in the past: expiry may have
            # passed while we were deciding, and a past wake makes a waiting
            # consumer spin. Floor it just ahead of now.
            $wake = $now + TOKEN_REFRESH_GRACE_S if $wake <= $now;
            return { action => 'pause-token', until_epoch => $wake, reason => 'token' };
        }
    }

    # (3) Poll non-200 / body-not-parsed / validate_usage fail → unavailable/telemetry
    unless ($poll->{status} == 200 && ref $poll->{parsed} eq 'HASH') {
        return { action => 'unavailable', until_epoch => undef, reason => 'telemetry' };
    }
    my ($vu_ok) = BpContract::validate_usage($poll->{parsed});
    unless ($vu_ok) {
        return { action => 'unavailable', until_epoch => undef, reason => 'telemetry' };
    }

    # (4) Burn projection → should_pause? (first of five_hour then seven_day)
    my $parsed = $poll->{parsed};
    my $u5 = $parsed->{five_hour}{utilization};
    my $u7 = $parsed->{seven_day}{utilization};
    my $b5 = BpGovern::burn_per_sec($samples5);
    my $b7 = BpGovern::burn_per_sec($samples7);
    my $p5 = BpGovern::should_pause($u5, $b5, $t->{drain}, $t->{ceil5});
    my $p7 = BpGovern::should_pause($u7, $b7, $t->{drain}, $t->{ceil7});

    if ($p5 || $p7) {
        my $w        = $p5 ? 'five_hour' : 'seven_day';
        my $resets_at = BpGovern::iso_to_epoch($parsed->{$w}{resets_at});
        # Mirror paused_payload + choose_jitter: until_epoch = resets_at + jitter
        # If resets_at undef, fall back to $now (self-corrects on next poll).
        my $base   = defined $resets_at ? $resets_at : $now;
        my $jit_lo = $t->{jit_lo} // 0;
        my $jit_hi = $t->{jit_hi} // 0;
        my $jitter = int($jit_lo + $t->{rand}->() * ($jit_hi - $jit_lo));  # choose_jitter mirror (no +1) — Decision #9/#18
        my $until  = $base + $jitter;
        return { action => 'pause-usage', until_epoch => $until + 0, reason => 'usage' };
    }

    # (5) All clear
    return { action => 'ok', until_epoch => undef, reason => 'ok' };
}

# ---------------------------------------------------------------------------
# _read_creds($path) — I/O half: read + parse creds file.
# Returns { ok, expires_ms, detail, tok } (tok is INTERNAL only — never emitted).
# ---------------------------------------------------------------------------
sub _read_creds {
    my ($path) = @_;
    my $raw = do {
        local $/;
        open my $fh, '<', $path or return { ok => 0, expires_ms => undef, detail => "cannot-open:$path", tok => undef };
        <$fh>;
    };
    my $data = eval { JSON::PP->new->decode($raw) };
    return { ok => 0, expires_ms => undef, detail => "invalid-json:$path", tok => undef }
        unless ref $data eq 'HASH';
    my $oauth = $data->{claudeAiOauth};
    return { ok => 0, expires_ms => undef, detail => 'no-claudeAiOauth', tok => undef }
        unless ref $oauth eq 'HASH';
    my $tok = $oauth->{accessToken};
    return { ok => 0, expires_ms => undef, detail => 'no-accessToken', tok => undef }
        unless defined $tok && length $tok;
    my $exp_ms = (defined $oauth->{expiresAt} && $oauth->{expiresAt} =~ /^\d+$/)
               ? $oauth->{expiresAt} + 0
               : undef;
    return { ok => 1, expires_ms => $exp_ms, detail => '', tok => $tok };
}

# ---------------------------------------------------------------------------
# run(\@argv, \%opts) — subcommand dispatch + seam injection.
# Returns exit code; prints to STDOUT.
# opts: now, http_get, creds_path, samples5, samples7, rand
# ---------------------------------------------------------------------------
sub run {
    my ($argv, $opts) = @_;
    $opts //= {};

    my $sub = ($argv && @$argv) ? $argv->[0] : '';

    # --- --help / -h: self-documenting CLI contract (Decision #13); no creds/poll ---
    if ($sub eq '--help' || $sub eq '-h') {
        print <<'END_HELP';
bp-usage-gate.pl — Claude usage-headroom gate + governor verdict.

USAGE
  bp-usage-gate.pl            legacy text path (soft-ceiling single-poll gate)
  bp-usage-gate.pl verdict    machine verdict for the drive-solo director (JSON)
  bp-usage-gate.pl --help

LEGACY TEXT PATH (no arg) — one line + exit code:
  OK          five=<pct> seven=<pct> token_life_h=<h>                              exit 0
  PAUSE       window=<five_hour|seven_day> resets_at_epoch=<e> resets_at_iso=<iso>
              estimated=<0|1> five=<pct> seven=<pct> token_life_h=<h>              exit 10
  RELOGIN     token_life_h=<h> detail=...                                          exit 40
  UNAVAILABLE status=<n> detail=...                                                exit 20
  CREDS       detail=...                                                           exit 30

VERDICT SUBCOMMAND (bp-usage-gate.pl verdict) — always exit 0, ONE single-line JSON:
  {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":"..."}
    ok           until_epoch=null            reason="ok"
    pause-usage  until_epoch=<epoch secs>    reason="usage"   (timed auto-resume)
    pause-token  until_epoch=<epoch secs>    reason="token"   (timed condition, not a hard-stop --
                                                                 the only consumer refreshes immediately
                                                                 rather than waiting on the epoch;
                                                                 success=recovery, failure=a separate
                                                                 stop/token-refresh-failed)
    unavailable  until_epoch=null            reason="telemetry"|"creds"  (degrade-and-proceed)
END_HELP
        return 0;
    }

    # --- seam injection ---
    my $now_fn    = $opts->{now}      // sub { time };
    my $http_get  = $opts->{http_get} // sub {
        my ($url, $hdrs) = @_;
        return BpHttp::request('GET', $url, $hdrs);
    };
    my $home       = $ENV{HOME} // $ENV{USERPROFILE} // '';
    my $creds_path = $opts->{creds_path}
                  // $ENV{BP_CREDS_PATH}
                  // "$home/.claude/.credentials.json";
    my $rand_fn   = $opts->{rand} // sub { rand() };
    my $samples5  = $opts->{samples5} // [];
    my $samples7  = $opts->{samples7} // [];

    # --- 'verdict' subcommand (JSON path) ---
    if ($sub eq 'verdict') {
        my $now = $now_fn->();

        # Production $t uses soft ceilings (env-tunable); tests inject their own.
        my $t = {
            ceil5   => defined $ENV{BP_KGS_SOFT_5H}       ? $ENV{BP_KGS_SOFT_5H} + 0       : 80,
            ceil7   => defined $ENV{BP_KGS_SOFT_7D}       ? $ENV{BP_KGS_SOFT_7D} + 0       : 85,
            drain   => 600,
            floor_h => defined $ENV{BP_KGS_TOKEN_FLOOR_H} ? $ENV{BP_KGS_TOKEN_FLOOR_H} + 0 : TOKEN_FLOOR_DEFAULT_H,
            jit_lo  => 0,
            jit_hi  => 0,
            rand    => $rand_fn,
        };

        # I/O: read creds
        my $cr = _read_creds($creds_path);
        my $creds = { ok => $cr->{ok}, expires_ms => $cr->{expires_ms}, detail => $cr->{detail} };

        # I/O: poll usage (only when creds ok AND token not at floor). NOTE: this
        # floor short-circuit is an efficiency optimization only — verdict_decision
        # enforces the SAME token floor independently (both call BpGovern::refresh_state,
        # idempotent), so the two sites cannot disagree.
        my $poll = { status => 0, parsed => undef };
        if ($cr->{ok}) {
            # Check token floor before polling
            if (defined $cr->{expires_ms}) {
                my $state = BpGovern::refresh_state($cr->{expires_ms}, $now * 1000,
                                                     $t->{floor_h}, undef);
                if ($state ne 'pause-floor') {
                    # Token is fine — poll
                    my $res = $http_get->($USAGE_URL, {
                        'Authorization'  => "Bearer $cr->{tok}",
                        'anthropic-beta' => 'oauth-2025-04-20',
                        'User-Agent'     => $USER_AGENT,
                        'Accept'         => 'application/json',
                    });
                    my $status = $res->{status} // 0;
                    my $parsed = ($status == 200)
                               ? eval { JSON::PP->new->decode($res->{content} // '') }
                               : undef;
                    $poll = { status => $status, parsed => (ref $parsed eq 'HASH' ? $parsed : undef) };
                }
                # If pause-floor, leave poll status=0 — verdict_decision will catch it
                # at step (2) before looking at poll.
            } else {
                # No expiresAt — can still poll; no token floor check possible
                my $res = $http_get->($USAGE_URL, {
                    'Authorization'  => "Bearer $cr->{tok}",
                    'anthropic-beta' => 'oauth-2025-04-20',
                    'User-Agent'     => $USER_AGENT,
                    'Accept'         => 'application/json',
                });
                my $status = $res->{status} // 0;
                my $parsed = ($status == 200)
                           ? eval { JSON::PP->new->decode($res->{content} // '') }
                           : undef;
                $poll = { status => $status, parsed => (ref $parsed eq 'HASH' ? $parsed : undef) };
            }
        }

        my $v = verdict_decision($creds, $poll, $samples5, $samples7, $now, $t);

        # Emit exactly one canonical single-line JSON; until_epoch must be a JSON number or null.
        my $out = {
            action      => $v->{action},
            reason      => $v->{reason},
            until_epoch => (defined $v->{until_epoch} ? $v->{until_epoch} + 0 : undef),
        };
        print JSON::PP->new->canonical->encode($out), "\n";
        return 0;
    }

    # --- legacy text path (no arg) ---
    # Preserved byte-for-byte: fixed soft ceiling, single sample, original exits.
    {
        my $now = $now_fn->();

        # read creds
        my $cr = _read_creds($creds_path);
        unless ($cr->{ok}) {
            print "CREDS detail=$cr->{detail}\n";
            return 30;
        }
        my $tok = $cr->{tok};

        # token life (informational + hard re-login floor)
        my $token_life_h = 'na';
        if (defined $cr->{expires_ms}) {
            my $now_ms = $now * 1000;
            $token_life_h = sprintf '%.2f', ($cr->{expires_ms} - $now_ms) / 3_600_000;
            if ($token_life_h + 0 <= $FLOOR_H) {
                print "RELOGIN token_life_h=$token_life_h detail=oauth-token-under-floor-cannot-refresh-in-session\n";
                return 40;
            }
        }

        # poll usage
        my $res = $http_get->($USAGE_URL, {
            'Authorization'  => "Bearer $tok",
            'anthropic-beta' => 'oauth-2025-04-20',
            'User-Agent'     => $USER_AGENT,
            'Accept'         => 'application/json',
        });
        my $status = $res->{status} // 0;
        unless ($status == 200) {
            print "UNAVAILABLE status=$status detail=telemetry-unreachable\n";
            return 20;
        }

        my $u = eval { JSON::PP->new->decode($res->{content} // '') };
        unless (ref $u eq 'HASH') {
            print "UNAVAILABLE status=200 detail=response-not-json\n";
            return 20;
        }

        my $u5 = $u->{five_hour}{utilization};
        my $u7 = $u->{seven_day}{utilization};
        unless (defined $u5 && defined $u7) {
            print "UNAVAILABLE status=200 detail=missing-utilization-fields\n";
            return 20;
        }

        # decide: pause on whichever window is over its soft ceiling
        my $over5 = $u5 >= $SOFT5;
        my $over7 = $u7 >= $SOFT7;
        if ($over5 || $over7) {
            my $w   = $over5 ? 'five_hour' : 'seven_day';
            my $iso = $u->{$w}{resets_at} // '';
            # Sanitize the server-controlled value before it enters the single-line,
            # space-delimited text output: strip control chars + spaces (a newline would
            # forge a second line; a space would inject a bogus key=value field). Valid
            # ISO-8601 has neither, so happy-path bytes are unchanged. (redteam HIGH-1)
            $iso =~ tr/\x00-\x20\x7f//d;
            my $ep  = BpGovern::iso_to_epoch($iso);
            my $estimated = 0;
            if (!defined $ep || $ep eq '') {
                $ep = $now + 3600;
                $estimated = 1;
            }
            print "PAUSE window=$w resets_at_epoch=$ep resets_at_iso=$iso estimated=$estimated five=$u5 seven=$u7 token_life_h=$token_life_h\n";
            return 10;
        }

        print "OK five=$u5 seven=$u7 token_life_h=$token_life_h\n";
        return 0;
    }
}

# ---------------------------------------------------------------------------
# CLI entry point — safe to `require` (caller is set; block is skipped).
# ---------------------------------------------------------------------------
package main;
unless (caller) {
    my $rc = BpUsageGate::run(\@ARGV);
    exit $rc;
}

1;
