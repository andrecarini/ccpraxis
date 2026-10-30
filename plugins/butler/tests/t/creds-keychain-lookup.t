#!/usr/bin/env perl
# platform: any
# BpCreds.pm -- one credentials lookup for every butler reader, including the
# macOS Keychain.
#
# On a Mac Claude Code keeps its OAuth grant in the login Keychain (generic
# password "Claude Code-credentials"), not in ~/.claude/.credentials.json. Every
# reader hard-coded the file, so on macOS the usage gate reported CREDS, sitrep
# and the spend panel showed "unknown", and preflight refused drive-solo.
#
# NO REAL KEYCHAIN IS EVER TOUCHED HERE. Every case that reaches the Keychain
# branch forces it with BP_CREDS_KEYCHAIN=1 and names a FAKE `security` with
# BP_CREDS_SECURITY_BIN; the real one can raise a Keychain dialog and would
# read the operator's actual secret. Cases that must NOT reach it either name a
# file or set BP_CREDS_KEYCHAIN=0, and the fake records every call so "never
# called" is asserted, not assumed.
#
# The fake used to go first on PATH, because BpCreds ran a bare `security`.
# That made PATH the thing deciding which binary answered for the Keychain;
# production now runs /usr/bin/security by absolute path, and section 11
# proves a `security` on PATH is never consulted.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Time::HiRes ();

my $SCRIPTS = "$Bin/../../scripts";
require "$SCRIPTS/BpCreds.pm";
require "$SCRIPTS/bp-usage-gate.pl";

my $ROOT = tempdir(CLEANUP => 1);
my $J    = JSON::PP->new->canonical;
my $SEP  = $^O eq 'MSWin32' ? ';' : ':';

my $SENTINEL = 'tok-SENTINEL-must-never-be-echoed';
my $NOW      = 1_800_000_000;

sub creds_json {
    my (%o) = @_;
    return $J->encode({ claudeAiOauth => {
        accessToken => $o{token} // $SENTINEL, refreshToken => 'refresh-SENTINEL',
        expiresAt   => $o{expires_ms} // (($NOW + 86_400) * 1000),
        scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'tier' } });
}

# fake_security(%o) -> ($bin_dir, $log_path). The fake writes its argv, one
# element per line, to $log_path (so list-form exec is checked element by
# element), then prints $o{stdout} and exits $o{exit}. $o{sleep} makes it hang.
my $fn = 0;
sub fake_security {
    my (%o) = @_;
    my $dir = "$ROOT/fake" . (++$fn);
    make_path($dir);
    my $log = "$dir/argv.log";
    my $payload = "$dir/payload";
    open my $p, '>:raw', $payload or die $!;
    print {$p} $o{stdout} // '';
    close $p;
    my $exit  = $o{exit}  // 0;
    my $sleep = $o{sleep} // 0;
    open my $f, '>:raw', "$dir/security" or die $!;
    print {$f} "#!/bin/sh\n"
             . ": > '$log'\n"
             . "for a in \"\$\@\"; do printf '%s\\n' \"\$a\" >> '$log'; done\n"
             . ($sleep ? "sleep $sleep\n" : '')
             . "cat '$payload'\n"
             . "exit $exit\n";
    close $f;
    chmod 0755, "$dir/security";
    return ($dir, $log);
}

sub slurp { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $x = <$f>; close $f; $x }

# with_env(\%env, $code): localises each key (undef deletes it).
sub with_env {
    my ($env, $code) = @_;
    local %ENV = %ENV;
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }
    return $code->();
}

sub fresh_home { my $h = "$ROOT/home" . (++$fn); make_path($h); return $h }

# ---- 1. no file + forced Keychain: read through `security`, list-form ------
{
    my ($bin, $log) = fake_security(stdout => creds_json() . "\n");
    my $home = fresh_home();
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    ok($r->{ok}, 'keychain: credentials are read when no file exists');
    is($r->{kind}, 'keychain', 'keychain: the source is reported as the Keychain');
    is($r->{data}{claudeAiOauth}{accessToken}, $SENTINEL, 'keychain: the JSON payload is parsed');
    is(slurp($log), "find-generic-password\n-s\nClaude Code-credentials\n-w\n",
        'keychain: `security` gets exactly find-generic-password -s <service> -w, one argv element each');
    ok(!-e "$home/.claude/.credentials.json", 'keychain: no credentials file is written');
}

# ---- 2. BP_CREDS_PATH is authoritative: a missing named file stays missing ---
{
    my ($bin, $log) = fake_security(stdout => creds_json());
    my $home = fresh_home();
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => "$home/nope.json", BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    ok(!$r->{ok}, 'BP_CREDS_PATH: a missing named file is a failure');
    is($r->{detail}, "cannot-open:$home/nope.json", 'BP_CREDS_PATH: the detail names the missing file');
    ok(!-e $log, 'BP_CREDS_PATH: the Keychain is never consulted in its place');
}

# ---- 3. the default file wins over the Keychain ------------------------------
{
    my ($bin, $log) = fake_security(stdout => creds_json(token => 'from-keychain'));
    my $home = fresh_home();
    make_path("$home/.claude");
    open my $f, '>:raw', "$home/.claude/.credentials.json" or die $!;
    print {$f} creds_json(token => 'from-file');
    close $f;
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    is($r->{kind}, 'file', 'default file: an existing ~/.claude/.credentials.json is used');
    is($r->{data}{claudeAiOauth}{accessToken}, 'from-file', 'default file: its content is what is read');
    ok(!-e $log, 'default file: the Keychain is not consulted');
}

# ---- 4. BP_CREDS_KEYCHAIN=0 opts out ----------------------------------------
{
    my ($bin, $log) = fake_security(stdout => creds_json());
    my $home = fresh_home();
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 0 },
                     sub { BpCreds::load() });
    is($r->{kind}, 'none', 'opt-out: BP_CREDS_KEYCHAIN=0 leaves no source');
    is($r->{detail}, "cannot-open:$home/.claude/.credentials.json",
        'opt-out: the detail names the file that was looked for');
    ok(!-e $log, 'opt-out: `security` is never run');
}

# ---- 5. the automatic rule: macOS only, and only for the account's own HOME --
{
    my $home = fresh_home();
    my $auto = with_env({ HOME => $home, USERPROFILE => $home, BP_CREDS_KEYCHAIN => undef },
                        sub { BpCreds::keychain_enabled() });
    is($auto, 0, 'auto: a redirected HOME (a test sandbox, a throwaway config) never reaches the Keychain');
    if ($^O ne 'darwin') {
        my $real = with_env({ BP_CREDS_KEYCHAIN => undef }, sub { BpCreds::keychain_enabled() });
        is($real, 0, "auto: off on $^O, whatever HOME is");
    }
}

# ---- 6. failures never echo the payload --------------------------------------
{
    my ($bin) = fake_security(stdout => "$SENTINEL garbage", exit => 44);
    my $home = fresh_home();
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    ok(!$r->{ok}, 'security failure: not ok');
    is($r->{detail}, 'keychain:security-exit-44', 'security failure: the exit code is the detail');
    unlike($J->encode({ %$r, data => undef }), qr/SENTINEL/, 'security failure: nothing it printed is kept');
}
{
    my ($bin) = fake_security(stdout => "not json $SENTINEL\n");
    my $home = fresh_home();
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    is($r->{detail}, 'invalid-json:keychain', 'unparseable item: detail says so without quoting it');
    unlike($J->encode({ %$r, data => undef }), qr/SENTINEL/, 'unparseable item: the payload is not echoed');
}

# ---- 7. a hex-printed item is decoded ----------------------------------------
{
    my ($bin) = fake_security(stdout => unpack('H*', creds_json(token => 'hex-token')) . "\n");
    my $home = fresh_home();
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    is($r->{data}{claudeAiOauth}{accessToken}, 'hex-token',
        'hex: `security -w` hex output that decodes to a JSON object is accepted');
}

# ---- 8. a hung `security` (a Keychain dialog nobody answers) is bounded -------
{
    my ($bin) = fake_security(stdout => creds_json(), sleep => 30);
    my $home = fresh_home();
    local $BpCreds::KEYCHAIN_TIMEOUT_SECONDS = 1;
    my $t0 = Time::HiRes::time();
    my $r = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                       BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    my $dt = Time::HiRes::time() - $t0;
    is($r->{detail}, 'keychain:timeout', 'timeout: a hung read is reported as a timeout');
    cmp_ok($dt, '<', 15, "timeout: the caller is released promptly (${dt}s)");
}

# ---- 9. the usage gate reads the Keychain end to end -------------------------
{
    my ($bin) = fake_security(stdout => creds_json());
    my $home = fresh_home();
    my @auth;
    my $cap = "$ROOT/gate-out.txt";
    my $rc = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                        BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 }, sub {
        open(my $saved, '>&', \*STDOUT) or die "dup: $!";
        open(STDOUT, '>', $cap) or die "redirect: $!";
        my $rc = BpUsageGate::run(['verdict'], {
            now      => sub { $NOW },
            http_get => sub {
                my ($url, $h) = @_;
                push @auth, $h->{Authorization};
                return { status => 200, content => $J->encode({
                    five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00Z' },
                    seven_day => { utilization => 5,  resets_at => '2099-01-02T00:00:00Z' } }) };
            },
        });
        open(STDOUT, '>&', $saved) or die "restore: $!";
        $rc;
    });
    my $v = eval { JSON::PP->new->decode(slurp($cap)) } || {};
    is($v->{action}, 'ok', 'gate: verdict is ok with Keychain credentials (was unavailable/creds)');
    is_deeply(\@auth, ["Bearer $SENTINEL"], 'gate: the Keychain token is the one sent');
    unlike(slurp($cap), qr/SENTINEL/, 'gate: the token never reaches stdout');
    ok(!-e "$home/.claude/.credentials.json", 'gate: no credentials file is created');
}

# ---- 10. the gate CLI, as sitrep and bp-spend run it -------------------------
# An expired token answers RELOGIN before any request is made, so this proves
# the credentials were read from the Keychain without touching the network.
{
    my ($bin) = fake_security(stdout => creds_json(expires_ms => 1000));
    my $home = fresh_home();
    my $out = with_env({ BP_CREDS_SECURITY_BIN => "$bin/security", HOME => $home, USERPROFILE => $home,
                         BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                       sub { scalar `"$^X" "$SCRIPTS/bp-usage-gate.pl" 2>&1` });
    my $rc = $? >> 8;
    is($rc, 40, 'gate CLI: an expired Keychain token is RELOGIN (40), not CREDS (30)')
        or diag($out);
    unlike($out, qr/SENTINEL/, 'gate CLI: the secret is never printed');
}

# ---- 11. the binary is named by absolute path; PATH is never consulted --------
{
    my $saved = delete local $ENV{BP_CREDS_SECURITY_BIN};
    is(BpCreds::security_bin(), '/usr/bin/security',
        'security_bin: production runs /usr/bin/security, the copy macOS ships');
    local $ENV{BP_CREDS_SECURITY_BIN} = '';
    is(BpCreds::security_bin(), '/usr/bin/security', 'security_bin: an empty override is no override');
}
{
    # A `security` first on PATH must not answer, with or without the override.
    my ($on_path, $path_log) = fake_security(stdout => creds_json(token => 'from-PATH'));
    my ($named,   $named_log) = fake_security(stdout => creds_json(token => 'from-override'));
    my $home = fresh_home();
    my $r = with_env({ PATH => "$on_path$SEP$ENV{PATH}", BP_CREDS_SECURITY_BIN => "$named/security",
                       HOME => $home, USERPROFILE => $home, BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                     sub { BpCreds::load() });
    is($r->{data}{claudeAiOauth}{accessToken}, 'from-override',
        'override: BP_CREDS_SECURITY_BIN is the binary that is run');
    ok(-e $named_log, 'override: ...and it was called');
    ok(!-e $path_log, 'override: the `security` first on PATH was never run');

    my $missing = "$ROOT/no-such-dir/security";
    my $r2 = with_env({ PATH => "$on_path$SEP$ENV{PATH}", BP_CREDS_SECURITY_BIN => $missing,
                        HOME => $home, USERPROFILE => $home, BP_CREDS_PATH => undef, BP_CREDS_KEYCHAIN => 1 },
                      sub { BpCreds::load() });
    ok(!$r2->{ok}, 'missing binary: not ok');
    like($r2->{detail}, qr/\Akeychain:(?:security-not-runnable|security-exit-\d+)\z/,
        'missing binary: reported as a Keychain failure') or diag($r2->{detail});
    ok(!-e $path_log, 'missing binary: PATH is NOT searched for a stand-in');
}

# ---- 12. tests cannot reach the real Keychain by default ---------------------
# A standalone `perl x.t` keeps the operator's HOME, which is exactly the case
# keychain_enabled() reads the real Keychain in. The runner pins
# BP_CREDS_KEYCHAIN=0 for every file it runs (runner-test-sandbox.t M3), and
# every shared harness lib pins it at load so a direct run of a file that uses
# one is covered too. TestPlatform.pm is not a harness: it is the pure marker
# parser the runner itself loads, and it must not touch %ENV.
{
    my @libs = grep { !m{/TestPlatform\.pm\z} } sort glob("$Bin/../../../*/tests/lib/*.pm");
    ok(scalar @libs >= 4, 'found the shared test harness libs (' . scalar(@libs) . ')');
    for my $lib (@libs) {
        my $src = slurp($lib) // '';
        (my $name = $lib) =~ s{.*/plugins/}{plugins/};
        like($src, qr/^BEGIN\s*\{\s*\$ENV\{BP_CREDS_KEYCHAIN\}\s*=\s*'0'\s*\}/m,
            "$name pins BP_CREDS_KEYCHAIN=0 at load");
    }
}

done_testing();
