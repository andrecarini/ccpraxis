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
use File::Basename qw(basename);

my %opt = (deep => 0, quiet => 0, platform => undef, bp_dir => undef);
for (@ARGV) {
    if ($_ eq '--deep')   { $opt{deep}   = 1 }
    elsif ($_ eq '--quiet'){ $opt{quiet} = 1 }
    elsif (/^--platform=(.+)$/) { $opt{platform} = $1 }
    elsif (/^--bp-dir=(.+)$/)   { $opt{bp_dir} = $1 }
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

# ---- run_git($root, @args) -> ($rc, $squeezed_output) ---------------------
# Runs `git -C $root @args`, capturing combined stdout+stderr and collapsing
# it to a single line (report rows are one line each). $root is normalized to
# forward slashes first: native git.exe accepts forward-slash Windows paths
# directly, and this sidesteps two distinct hazards observed empirically on
# this host — (a) backslash sequences inside a double-quoted shell string
# being reinterpreted, and (b) MSYS2_ARG_CONV_EXCL=* (the usual fix for the
# colon-splitting bug with -v-style compound args) instead BREAKING a plain
# POSIX-style single path arg here, because this script is invoked by a
# POSIX/MSYS perl whose backticks already auto-translate POSIX paths for a
# native child correctly — disabling that conversion regresses it. Do NOT set
# MSYS2_ARG_CONV_EXCL here; it was tried and made things worse for this case.
sub run_git {
    my ($root, @args) = @_;
    (my $slashroot = $root) =~ s{\\}{/}g;
    my $cmd = join(' ', 'git', '-C', qq{"$slashroot"}, @args, '2>&1');
    my $out = `$cmd`;
    my $rc  = $?;
    $out //= '';
    $out =~ s/\s+/ /g;
    $out =~ s/^\s+|\s+$//g;
    return ($rc, $out);
}

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

    'repo.usable' => { run => sub {
        # Resolve the project root: BP_PROJECT_ROOT (butler env contract var,
        # and what makes this testable) -> `git rev-parse --show-toplevel`
        # from cwd -> cwd itself.
        my ($root, $source);
        if (defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT}) {
            $root   = $ENV{BP_PROJECT_ROOT};
            $source = 'BP_PROJECT_ROOT';
        } else {
            my $top = `git rev-parse --show-toplevel 2>/dev/null`;
            chomp $top;
            if (length $top) {
                $root   = $top;
                $source = "git rev-parse --show-toplevel";
            } else {
                require Cwd;
                $root   = Cwd::getcwd();
                $source = 'cwd';
            }
        }

        # `rev-parse --git-dir` alone is insufficient: the B2 shape (a `.git`
        # FILE whose `gitdir:` target does not exist) can parse the pointer
        # while every real operation fails. A second, independent read that
        # actually touches the object store is required.
        my $reason;
        my ($gd_rc, $gd_out) = run_git($root, 'rev-parse', '--git-dir');
        if ($gd_rc != 0) {
            $reason = "git -C \"$root\" rev-parse --git-dir failed: $gd_out";
        } else {
            my ($head_rc, $head_out) = run_git($root, 'rev-parse', 'HEAD');
            if ($head_rc != 0) {
                # A fresh repo with no commits yet has no HEAD — that is
                # usable, not a failure. Distinguish "no commits yet" from a
                # genuinely broken repo (e.g. the B2 shape) with a second,
                # independent read that also touches the object store.
                my ($st_rc, $st_out) = run_git($root, 'status', '--porcelain');
                if ($st_rc != 0) {
                    $reason = "git -C \"$root\" rev-parse HEAD failed ($head_out) and status --porcelain also failed: $st_out";
                }
            }
        }

        if (!defined $reason) {
            return ('ok', "repo usable at $root (root via $source)");
        }

        if (($ENV{BP_ALLOW_NO_GIT} // '') eq '1') {
            return ('ok', "WARNING: BP_ALLOW_NO_GIT=1 override — project root $root is not a usable git repo ($reason)");
        }
        return ('fail', "project root $root is not a usable git repo (root via $source): $reason");
    } },
);

# ---- blueprint DAG integrity (b08) ----------------------------------------
# NOT a %CHECK entry: the manifest loop below only invokes ids present in
# docs/assumptions.json (that file is outside this package's write set), and
# DAG integrity is a property of the INPUT being dispatched, not the
# platform, so it must not inherit assumptions.json's per-OS skip semantics.
# See spec-b08 sec4.2 for the full rationale.

# main::dag_project_root() -> ($root, $source). Duplicates repo.usable's
# three-rung ladder (:197-248) rather than refactoring it -- repo.usable must
# stay byte-identical (t/27-preflight-repo-check.t asserts on its wording).
sub dag_project_root {
    if (defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT}) {
        return ($ENV{BP_PROJECT_ROOT}, 'BP_PROJECT_ROOT');
    }
    my $top = `git rev-parse --show-toplevel 2>/dev/null`;
    chomp $top;
    if (length $top) {
        return ($top, 'git rev-parse --show-toplevel');
    }
    require Cwd;
    return (Cwd::getcwd(), 'cwd');
}

# main::dag_data_dir() -> ($data, $source). $CCPRAXIS_DATA_DIR wins outright;
# otherwise "<project_root>/.ccpraxis-local-data".
sub dag_data_dir {
    if (defined $ENV{CCPRAXIS_DATA_DIR} && length $ENV{CCPRAXIS_DATA_DIR}) {
        return ($ENV{CCPRAXIS_DATA_DIR}, 'CCPRAXIS_DATA_DIR');
    }
    my ($root, $rsrc) = dag_project_root();
    return ("$root/.ccpraxis-local-data", "project root ($rsrc)");
}

# A rung's candidate path is only accepted if it actually names a blueprint
# dir. A wrong explicit path is an operator error and must be visible, not
# silently skipped in favor of the next rung.
sub _dag_check_bpdir {
    my ($path, $source) = @_;
    return (undef, "$source names $path, which has no blueprint.md")
        unless -f "$path/blueprint.md";
    return ($path, $source);
}

# main::dag_bpdir() -> ($bpdir, $source) on success; (undef, $why) on
# failure. Ladder: --bp-dir -> BP_BLUEPRINT_DIR -> BP_BLUEPRINT -> discovery
# (exactly one unfinished blueprint under <data>/blueprints). See spec-b08
# sec4.2 for the full ladder and its "does not fall through" rule.
sub dag_bpdir {
    if (defined $opt{bp_dir} && length $opt{bp_dir}) {
        return _dag_check_bpdir($opt{bp_dir}, '--bp-dir');
    }
    if (defined $ENV{BP_BLUEPRINT_DIR} && length $ENV{BP_BLUEPRINT_DIR}) {
        return _dag_check_bpdir($ENV{BP_BLUEPRINT_DIR}, 'BP_BLUEPRINT_DIR');
    }
    if (defined $ENV{BP_BLUEPRINT} && length $ENV{BP_BLUEPRINT}) {
        my ($data) = dag_data_dir();
        return _dag_check_bpdir("$data/blueprints/$ENV{BP_BLUEPRINT}", 'BP_BLUEPRINT');
    }
    my ($data) = dag_data_dir();
    my @cands;
    for my $md (glob("$data/blueprints/*/blueprint.md")) {
        (my $dir = $md) =~ s{/blueprint\.md$}{};
        require "$Bin/bp-validate-dag.pl";
        push @cands, $dir if BpValidateDag::has_unfinished($dir);
    }
    return (undef, "no blueprint with unfinished packages under $data/blueprints")
        if @cands == 0;
    if (@cands > 1) {
        my @names = sort map { basename($_) } @cands;
        return (undef, scalar(@cands) . ' candidate blueprints ('
                      . join(', ', @names) . ') — cannot tell which is being dispatched');
    }
    return ($cands[0], 'discovery');
}

# main::dag_integrity_gate() -> ($status, $detail) where $status is
# 'ok'|'fail'|'skip'. Loads the validator as a LIBRARY (require), not a
# subprocess -- precedent: creds.shape's require of bp-contract.pl above.
sub dag_integrity_gate {
    require "$Bin/bp-validate-dag.pl";
    my ($bpdir, $src) = dag_bpdir();
    return ('skip', "DAG integrity NOT validated: $src"
                  . " — pass --bp-dir=<blueprint-dir> or set BP_BLUEPRINT_DIR to gate it")
        unless defined $bpdir;
    my $r = eval { BpValidateDag::validate($bpdir) };
    return ('fail', "blueprint DAG could not be validated at $bpdir: " . ($@ || 'unknown error'))
        unless ref $r eq 'HASH';
    return ('fail', BpValidateDag::fail_detail($r)) unless $r->{ok};
    my $n = scalar @{ $r->{normalized} };
    return ('ok', "DAG ok at $bpdir (via $src)"
                . ($n ? "; $n dep token(s) auto-normalized (short->full / self-dep)" : ''));
}

# ---- version-pin drift audit (b46). NOT a platform assumption and NOT a
# %CHECK entry, for the same reason dag.integrity above isn't one: it's a
# property of what's pinned right now, not of the platform, so it must not
# inherit assumptions.json's per-OS skip semantics.
#
# REPORTS, NEVER BLOCKS (spec b46 sec1/sec2): a drifted pin must never fail
# preflight and wedge an unattended fleet over a routine upstream release --
# so this row is pushed to @rows only, NEVER to @fail, regardless of drift.
#
# Env overrides exist so this is testable exactly like repo.usable's
# BP_PROJECT_ROOT / BP_ALLOW_NO_GIT ladder, without a new CLI flag:
#   BP_PIN_MANIFEST  - path to a Containerfile-shaped fixture (default: the real one)
#   BP_PIN_FETCHER   - path to a JSON fixture keyed by package name, each value an
#                      npm-packument doc ({"time": {...}}) -- see bp-pin.pl's own contract
#   BP_PIN_NOW       - ISO-8601 or epoch clock override
# Each pin becomes its OWN `pin.<package>` row (glyph 'ok' for 'current', 'warn'
# otherwise); a locate/require failure instead falls back to a single `pin.audit` row.
# Cached live audit. TTL default 24h; BP_PIN_CACHE_TTL=0 forces a live check.
sub _pin_cache_path {
    return $ENV{BP_PIN_CACHE} if defined $ENV{BP_PIN_CACHE} && length $ENV{BP_PIN_CACHE};
    my $tmp = $ENV{TMPDIR} || '/tmp';
    $tmp =~ s{/+$}{};
    return "$tmp/.bp-pin-audit-cache.json";
}

sub pin_audit_rows {
    my ($deep) = @_;
    my @rows;
    my $have_fetcher_override = defined $ENV{BP_PIN_FETCHER} && length $ENV{BP_PIN_FETCHER};

    # A live lookup is 3 HTTP round trips (~14s), which starves any caller that
    # spawns preflight repeatedly (t/27 runs one subprocess per assertion). The
    # first fix for that was to gate the live check behind --deep -- but NOTHING
    # IN PRODUCTION PASSES --deep: bp-orchestrate.sh runs `--quiet` and
    # drive-solo runs it bare. So every real dispatch reported 'drift-unknown'
    # and a stale pin could never be noticed, which is exactly the "an unwired
    # audit is the comment again" failure this package exists to prevent. The
    # operator's requirement is to not have to REMEMBER; a check that never runs
    # does not meet it.
    #
    # So the live check runs BY DEFAULT and is made cheap by a TTL cache: the
    # first run per TTL pays the round trips, every run after it is a file read.
    # The cache is keyed to nothing and deliberately outside the project tree --
    # it is a pure optimisation, safe to delete, and shared across the repeated
    # spawns that made this expensive in the first place.
    my $ttl = defined $ENV{BP_PIN_CACHE_TTL} && $ENV{BP_PIN_CACHE_TTL} =~ /^\d+$/
        ? $ENV{BP_PIN_CACHE_TTL} : 86_400;
    my $cache = _pin_cache_path();
    my $use_cache = !$have_fetcher_override && !$ENV{BP_PIN_MANIFEST} && !$ENV{BP_PIN_NOW};

    if ($use_cache && $ttl > 0 && -f $cache && (time - (stat($cache))[9]) < $ttl) {
        my $cached = eval { read_json($cache) };
        if (ref $cached eq 'HASH' && ref $cached->{rows} eq 'ARRAY') {
            for my $row (@{ $cached->{rows} }) {
                next unless ref $row eq 'HASH' && defined $row->{package};
                my $status = (defined $row->{status} && $row->{status} eq 'current') ? 'ok' : 'warn';
                push @rows, [$status, "pin.$row->{package}", ($row->{detail} // '') . ' [cached]'];
            }
            return @rows if @rows;
        }
        # Unreadable or empty cache is not an error -- fall through and re-check.
    }

    my ($report, $rc) = eval {
        require "$Bin/bp-pin.pl";
        my %opts;
        $opts{manifest} = $ENV{BP_PIN_MANIFEST} if defined $ENV{BP_PIN_MANIFEST} && length $ENV{BP_PIN_MANIFEST};
        $opts{now}      = $ENV{BP_PIN_NOW}      if defined $ENV{BP_PIN_NOW}      && length $ENV{BP_PIN_NOW};
        $opts{fetcher_path} = $ENV{BP_PIN_FETCHER} if $have_fetcher_override;
        BpPin::audit(\%opts);
    };

    # Persist a good live report so the next spawn is free. Best-effort: a
    # cache that cannot be written must never affect the verdict.
    if ($use_cache && ref $report eq 'HASH' && !defined $report->{error} && ref $report->{rows} eq 'ARRAY') {
        eval {
            open my $cfh, '>:raw', "$cache.tmp.$$" or die;
            print $cfh JSON::PP->new->canonical->encode({ rows => $report->{rows} });
            close $cfh;
            rename "$cache.tmp.$$", $cache;
            1;
        } or do { unlink "$cache.tmp.$$" };
    }
    if ($@ || ref $report ne 'HASH') {
        my $err = $@ || 'bp-pin.pl audit returned no report';
        $err =~ s/\s+$//;
        push @rows, ['warn', 'pin.audit', "version-pin audit unavailable: $err"];
        return @rows;
    }
    if (defined $report->{error}) {
        push @rows, ['warn', 'pin.audit', "version-pin audit: $report->{error} (drift-unknown; not blocking)"];
        return @rows;
    }
    for my $row (@{ $report->{rows} || [] }) {
        my $status = $row->{status} eq 'current' ? 'ok' : 'warn';
        push @rows, [$status, "pin.$row->{package}", $row->{detail}];
    }
    return @rows;
}

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

# ---- blueprint DAG integrity (b08). NOT a platform assumption -- see spec 4.2. ----
{
    my ($st, $detail) = dag_integrity_gate();
    push @rows, [$st, 'dag.integrity', $detail];
    push @fail, ['dag.integrity', $detail] if $st eq 'fail';
}

# ---- version-pin drift audit (b46). Rows only -- NEVER pushed to @fail, so
# preflight's exit code is unchanged by drift (spec b46 sec1/sec2).
push @rows, eval { pin_audit_rows($opt{deep}) };

unless ($opt{quiet} && !@fail) {
    print "\n=== butler preflight (platform: $plat) ===\n";
    for my $r (@rows) {
        my %glyph = (ok=>'  ok  ', fail=>' FAIL ', skip=>' skip ', warn=>' warn ');
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
