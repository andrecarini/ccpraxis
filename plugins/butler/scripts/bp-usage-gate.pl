#!/usr/bin/env perl
# bp-usage-gate.pl — ONE host-safe usage-headroom poll for /butler:keep-going-solo.
#
# keep-going-solo runs in an interactive session that shares the user's OAuth
# token + usage. There is no deterministic orchestrator to govern it, so the
# driver must govern ITSELF: before each heavy step it calls this gate, and if the
# gate says PAUSE it sleeps token-cheaply until the window resets, then resumes.
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
# Tunables (env):
#   BP_KGS_SOFT_5H   soft 5h ceiling  (default 80; fleet hard wall 85)
#   BP_KGS_SOFT_7D   soft 7d ceiling  (default 85; fleet hard wall 90)
#   BP_KGS_TOKEN_FLOOR_H  re-login floor in hours (default 1)
#   BP_CREDS_PATH    creds file       (default ~/.claude/.credentials.json)
#   BP_USER_AGENT    curl UA          (default claude-code/2.1.170)

use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Absolute script dir so `require "$DIR/..."` resolves no matter how this script
# is invoked (relative CLI path, absolute, or from another dir) — a relative path
# would be searched in @INC and fail.
my $DIR = dirname(abs_path(__FILE__));
require "$DIR/bp-govern.pl";
require "$DIR/bp-http.pl";

my $USAGE_URL  = 'https://api.anthropic.com/api/oauth/usage';
my $USER_AGENT = $ENV{BP_USER_AGENT} // 'claude-code/2.1.170';
my $SOFT5      = defined $ENV{BP_KGS_SOFT_5H} ? $ENV{BP_KGS_SOFT_5H} + 0 : 80;
my $SOFT7      = defined $ENV{BP_KGS_SOFT_7D} ? $ENV{BP_KGS_SOFT_7D} + 0 : 85;
my $FLOOR_H    = defined $ENV{BP_KGS_TOKEN_FLOOR_H} ? $ENV{BP_KGS_TOKEN_FLOOR_H} + 0 : 1;

my $home  = $ENV{HOME} // $ENV{USERPROFILE} // '';
my $creds = $ENV{BP_CREDS_PATH} // "$home/.claude/.credentials.json";

sub emit { print "$_[0]\n"; exit $_[1]; }

# --- read credentials -------------------------------------------------------
my $raw = do {
    local $/;
    open my $fh, '<', $creds or emit("CREDS detail=cannot-open:$creds", 30);
    <$fh>;
};
my $data = eval { JSON::PP->new->decode($raw) };
emit("CREDS detail=invalid-json:$creds", 30) unless ref $data eq 'HASH';
my $oauth = $data->{claudeAiOauth};
emit("CREDS detail=no-claudeAiOauth", 30) unless ref $oauth eq 'HASH';
my $tok = $oauth->{accessToken};
emit("CREDS detail=no-accessToken", 30) unless defined $tok && length $tok;

# token life (informational + hard re-login floor). expiresAt is epoch ms.
my $token_life_h = 'na';
if (defined $oauth->{expiresAt} && $oauth->{expiresAt} =~ /^\d+$/) {
    my $now_ms = time * 1000;
    $token_life_h = sprintf '%.2f', ($oauth->{expiresAt} - $now_ms) / 3_600_000;
    if ($token_life_h + 0 <= $FLOOR_H) {
        emit("RELOGIN token_life_h=$token_life_h detail=oauth-token-under-floor-cannot-refresh-in-session", 40);
    }
}

# --- poll usage -------------------------------------------------------------
my $res = BpHttp::request('GET', $USAGE_URL, {
    'Authorization'  => "Bearer $tok",
    'anthropic-beta' => 'oauth-2025-04-20',
    'User-Agent'     => $USER_AGENT,
    'Accept'         => 'application/json',
});
my $status = $res->{status} // 0;
emit("UNAVAILABLE status=$status detail=telemetry-unreachable", 20) unless $status == 200;

my $u = eval { JSON::PP->new->decode($res->{content} // '') };
emit("UNAVAILABLE status=200 detail=response-not-json", 20) unless ref $u eq 'HASH';

my $u5 = $u->{five_hour}{utilization};
my $u7 = $u->{seven_day}{utilization};
emit("UNAVAILABLE status=200 detail=missing-utilization-fields", 20)
    unless defined $u5 && defined $u7;

# --- decide -----------------------------------------------------------------
# Pause on whichever window is over its soft ceiling; report that window's reset.
my $over5 = $u5 >= $SOFT5;
my $over7 = $u7 >= $SOFT7;
if ($over5 || $over7) {
    my $w   = $over5 ? 'five_hour' : 'seven_day';
    my $iso = $u->{$w}{resets_at} // '';
    my $ep  = BpGovern::iso_to_epoch($iso);
    my $estimated = 0;
    if (!defined $ep || $ep eq '') {
        # We ARE over the soft ceiling and MUST pause — but the reset time is
        # missing/unparseable. Two wrong moves to avoid: (1) degrading to
        # "keep working" would push toward the hard wall precisely when we're
        # closest to it; (2) emitting an empty/zero epoch makes the driver wake
        # immediately and busy-poll. Instead synthesize a conservative estimate
        # one hour out and flag it: the driver sleeps ~1h then RE-gates, so an
        # over- or under-estimate self-corrects on the next poll and never
        # bypasses the ceiling.
        $ep = time + 3600;
        $estimated = 1;
    }
    emit("PAUSE window=$w resets_at_epoch=$ep resets_at_iso=$iso estimated=$estimated five=$u5 seven=$u7 token_life_h=$token_life_h", 10);
}

emit("OK five=$u5 seven=$u7 token_life_h=$token_life_h", 0);
