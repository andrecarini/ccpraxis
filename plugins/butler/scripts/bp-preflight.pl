#!/usr/bin/env perl
# bp-preflight.pl — environment-support assertion (Decisions #29/#31).
#
# Runs BEFORE either execute verb does real work. Asserts every preflight-surface
# assumption from plugins/butler/docs/assumptions.json against the CURRENT
# environment, behind a platform-support abstraction. On any unsupported/failed
# item it HALTS with a precise, itemized report (what failed + the implement-hint)
# and a non-zero exit — never silently proceeds, never silently no-ops.
#
# Usage:
#   perl bp-preflight.pl              # gating (structural) checks
#   perl bp-preflight.pl --deep       # also run live API + hook self-test checks
#   perl bp-preflight.pl --platform=sandbox-linux   # override detection (testing)
#   perl bp-preflight.pl --quiet      # only print on failure
# Exit: 0 = supported & all gating checks pass; 2 = a gating check failed;
#       3 = unsupported platform.

use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP;

my %opt = (deep => 0, quiet => 0, platform => undef);
for (@ARGV) {
    if ($_ eq '--deep')   { $opt{deep}   = 1 }
    elsif ($_ eq '--quiet'){ $opt{quiet} = 1 }
    elsif (/^--platform=(.+)$/) { $opt{platform} = $1 }
}

# ---- platform-support abstraction ----------------------------------------
# The ONE place that maps a raw OS to a supported environment id. Adding a new
# platform (e.g. nixos) is a localized edit here + the per-check $CHECKS entries.
sub detect_platform {
    return $opt{platform} if defined $opt{platform};       # test override (raw, still validated below)
    return 'win32'        if $^O =~ /^(MSWin32|cygwin|msys)$/;
    if ($^O eq 'linux') {
        # 'sandbox-linux' means INSIDE OUR sandbox, not "any linux". The Containerfile
        # sets IS_SANDBOX=1 (the same marker bp_require_sandbox keys off). A bare linux
        # host (e.g. NixOS) is a DISTINCT, currently-unsupported platform — do NOT assume
        # linux == our sandbox (Decision #31).
        return 'sandbox-linux' if ($ENV{IS_SANDBOX} // '') eq '1';
        return 'linux-host';                               # known OS, unsupported platform
    }
    return undef;                                          # truly unknown OS
}

# ---- tiny check helpers --------------------------------------------------
sub have_cmd { my $c = shift; my $r = `command -v $c 2>/dev/null`; chomp $r; return length($r) ? $r : undef; }
sub mod_ok   { my $m = shift; return eval "require $m; 1" ? 1 : 0; }
sub read_json { my $f = shift; open my $fh,'<:raw',$f or return undef; local $/; my $r=<$fh>; close $fh;
                return eval { JSON::PP->new->decode($r) }; }
sub home { $ENV{USERPROFILE} // $ENV{HOME} // '' }

# ---- oauth_usable($d, $now_ms) — pure predicate (testable without running main) ---
# Returns ($ok, $reason). $now_ms defaults to time()*1000 (epoch ms).
sub oauth_usable {
    my ($d, $now_ms) = @_;
    $now_ms //= time() * 1000;
    return (0, 'creds missing/unparseable')  unless ref $d eq 'HASH';
    my $oa = $d->{claudeAiOauth};
    return (0, 'claudeAiOauth absent')       unless ref $oa eq 'HASH' && %$oa;
    if (length($oa->{refreshToken} // '')) {
        return (1, 'renewable (refreshToken)');
    }
    if (length($oa->{accessToken} // '') &&
        defined $oa->{expiresAt}          &&
        $oa->{expiresAt} =~ /^\d+$/       &&
        $oa->{expiresAt} > $now_ms) {
        return (1, 'accessToken unexpired');
    }
    return (0, 'expired with no refreshToken');
}

# ---- per-assumption checks (id => sub returning ('ok'|'fail'|'skip', detail)) ----
# 'deep' marks checks that need network or a live claude (only run with --deep).
my %CHECK = (
    'os' => { run => sub { ('ok', "platform=".(detect_platform()//'?')) } },

    'bin.curl' => { run => sub {
        my $p = have_cmd('curl') or return ('fail', 'curl not found on PATH');
        my $plat = detect_platform();
        if ($plat eq 'win32') {
            my $v = `curl --version 2>/dev/null`;
            return ('fail', "curl present ($p) but not a Schannel build (system trust store needed on Windows)")
                unless $v =~ /Schannel/i;
            return ('ok', "curl Schannel at $p");
        }
        return ('ok', "curl at $p");
    } },

    'bin.perl' => { run => sub {
        # HTTPS is curl's job (bin.curl) — the sandbox perl has no
        # IO::Socket::SSL/Net::SSLeay, and the transport deliberately uses curl.
        # So perl only needs JSON::PP (core) for the scripts; do NOT require the
        # SSL modules here or the supported sandbox would falsely fail.
        my @miss = grep { !mod_ok($_) } qw(JSON::PP);
        return @miss ? ('fail', "missing perl modules: ".join(', ',@miss)) : ('ok', 'JSON::PP present (HTTPS handled by curl)');
    } },

    'bin.jq' => { run => sub {
        my $p = have_cmd('jq') or return ('fail', 'jq not found (butler hooks fail-closed without it)');
        ('ok', "jq at $p");
    } },

    'tls.ca' => { run => sub {
        my @cand = qw(/usr/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
                      /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem);
        for my $c (@cand) { return ('ok', "CA bundle: $c") if -f $c; }
        ('fail', 'no CA bundle found (perl IO::Socket::SSL needs one; or use a Schannel curl transport)');
    } },

    'creds.path' => { run => sub {
        my $c = home()."/.claude/.credentials.json";
        return ('fail', "creds file not found at $c") unless -f $c;
        return ('fail', "creds file not parseable JSON: $c") unless read_json($c);
        ('ok', "creds present + parseable");
    } },

    'creds.shape' => { run => sub {
        my $c = home()."/.claude/.credentials.json";
        my $d = read_json($c) or return ('fail', "creds unreadable for shape check");
        require "$Bin/bp-contract.pl";
        my ($ok,$probs) = BpContract::validate_creds($d);
        $ok ? ('ok','creds shape valid') : ('fail', "creds shape drift: ".join('; ',@$probs));
    } },

    'oauth.client_id' => { run => sub {
        my $id = $ENV{CLAUDE_CODE_OAUTH_CLIENT_ID} // '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
        ('ok', "client_id resolved (".substr($id,0,8)."…)");
    } },

    'runtime.container' => { run => sub {
        my $p = have_cmd('podman') // have_cmd('docker');
        $p ? ('ok', "container runtime: $p") : ('fail', 'neither podman nor docker found (dispatch-fleet needs the sandbox)');
    } },

    'api.refresh' => { run => sub {
        ('skip', 'not probed in preflight (premature refresh is rate-limited → 429); A8 actively verifies one in-band refresh at runtime');
    } },

    'api.usage' => { deep => 1, run => sub {
        # live single probe — only with --deep. curl transport (bp-http.pl),
        # reusing the contract validator.
        my $c = home()."/.claude/.credentials.json";
        my $d = read_json($c) or return ('fail','no creds for usage probe');
        my $tok = $d->{claudeAiOauth}{accessToken} or return ('fail','no accessToken');
        require "$Bin/bp-http.pl";
        my $res = BpHttp::request('GET', 'https://api.anthropic.com/api/oauth/usage', {
            'Authorization'=>"Bearer $tok",'anthropic-beta'=>'oauth-2025-04-20',
            'User-Agent'=>'claude-code/preflight','Accept'=>'application/json'});
        return ('fail', "usage GET $res->{status} (expected 200)") unless $res->{status}==200;
        my $parsed = eval { JSON::PP->new->decode($res->{content}) };
        require "$Bin/bp-contract.pl";
        my ($ok,$probs) = BpContract::validate_usage($parsed//{});
        $ok ? ('ok','usage 200 + contract valid') : ('fail',"usage contract drift: ".join('; ',@$probs));
    } },

    'hooks.subagent' => { deep => 1, run => sub {
        ('skip', 'self-test requires a live claude session; A8 runs the deny-out-of-scope-edit self-test at launch');
    } },

    'harness.wake' => { run => sub {
        ('skip', 'harness property (proven in A0); bounded long-poll + re-arm is the robust fallback');
    } },

    'oauth.sandbox_login' => { run => sub {
        my $d = read_json(home()."/.claude/.credentials.json");
        my ($ok, $reason) = oauth_usable($d);
        return ('fail', "$reason — run \`claude-sandbox\` and \`/login\` first, then re-run dispatch-fleet") unless $ok;
        ('ok', "sandbox login usable: $reason");
    } },
);

# ---- run ------------------------------------------------------------------
unless (caller) {
my $plat = detect_platform();
my $manifest = read_json("$Bin/../docs/assumptions.json")
    or die "bp-preflight: cannot read assumptions.json (the registry must exist)\n";
my %hint = map { $_->{id} => $_->{implement_hint} } @{$manifest->{assumptions}};
my %supported_for = map { $_->{id} => { map {$_=>1} @{$_->{supported_envs}} } } @{$manifest->{assumptions}};

# Unsupported platform → halt loud with the full implement checklist.
my $is_supported = defined $plat && grep { $_ eq $plat } @{$manifest->{supported_envs}};
unless ($is_supported) {
    my $name = defined $plat ? "platform '$plat' (OS '$^O')" : "unknown OS '$^O'";
    print "\n*** PREFLIGHT FAILED — UNSUPPORTED PLATFORM ***\n";
    print "  $name is not a supported environment: ", join(', ', @{$manifest->{supported_envs}}), "\n";
    print "  To add support, implement these platform-specific assumptions:\n";
    for my $a (@{$manifest->{assumptions}}) {
        print "    - [$a->{id}] $a->{what}\n        hint: $a->{implement_hint}\n";
    }
    print "  Refusing to run — fix or extend the platform-support abstraction first (Decision #31).\n\n";
    exit 3;
}

my (@fail, @rows);
for my $a (@{$manifest->{assumptions}}) {
    my $id = $a->{id};
    my $chk = $CHECK{$id};
    # Skip assumptions that don't apply to this platform.
    unless ($supported_for{$id}{$plat}) { push @rows, ['skip', $id, "n/a on $plat"]; next; }
    unless ($chk) { push @rows, ['skip', $id, 'no check implemented']; next; }
    if ($chk->{deep} && !$opt{deep}) { push @rows, ['skip', $id, 'deep check (use --deep)']; next; }
    my ($status, $detail) = eval { $chk->{run}->() };
    if ($@) { $status='fail'; ($detail=$@)=~s/\s+$//; }
    push @rows, [$status, $id, $detail];
    push @fail, [$id, $detail] if $status eq 'fail';
}

unless ($opt{quiet} && !@fail) {
    print "\n=== butler preflight (platform: $plat) ===\n";
    for my $r (@rows) {
        my %glyph = (ok=>'  ok  ', fail=>' FAIL ', skip=>' skip ');
        printf "[%s] %-20s %s\n", $glyph{$r->[0]}, $r->[1], $r->[2]//'';
    }
}

if (@fail) {
    print "\n*** PREFLIGHT FAILED — environment not supported as-is ***\n";
    for my $f (@fail) {
        print "  - [$f->[0]] $f->[1]\n";
        print "      implement: $hint{$f->[0]}\n" if $hint{$f->[0]};
    }
    print "  Refusing to run — fix the above or extend platform support (Decision #31).\n\n";
    exit 2;
}
print "\nPREFLIGHT OK — environment supported.\n" unless $opt{quiet};
exit 0;
} # end unless (caller)
1;
