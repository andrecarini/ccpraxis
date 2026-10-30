#!/usr/bin/env perl
# platform: any
# A8 preflight (bp-preflight.pl): asserts environment support from the manifest
# and HALTS LOUD on an unsupported platform (Decisions #29/#31). A bare linux
# host must NOT be mistaken for our sandbox.
#
# macOS is a supported HOST (drive-solo runs there): darwin maps to 'macos',
# and its credentials come from the login Keychain via BpCreds. The Keychain
# case below names a FAKE `security` (BP_CREDS_SECURITY_BIN); nothing here may reach the
# real one (it can raise a Keychain dialog and reads the operator's secret),
# hence BP_CREDS_KEYCHAIN=0 for every other spawn.
BEGIN { $ENV{BP_CREDS_KEYCHAIN} = '0' }
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

my $script   = "$Bin/../../scripts/bp-preflight.pl";
my $manifest = "$Bin/../../docs/assumptions.json";

plan tests => 23;

ok(-f $script,   'bp-preflight.pl exists');
ok(-f $manifest, 'assumptions.json exists');

# ---- manifest structure ---------------------------------------------------
my $m = do { open my $fh,'<:raw',$manifest or die; local $/; JSON::PP->new->decode(<$fh>) };
is_deeply([sort @{$m->{supported_envs}}], ['macos','sandbox-linux','win32'], 'supported_envs = {win32, macos, sandbox-linux}');
my %ids = map { $_->{id} => 1 } @{$m->{assumptions}};
ok($ids{$_}, "manifest has assumption '$_'")
    for qw(os api.usage api.refresh creds.shape hooks.subagent);

# ---- unsupported platforms HALT (exit 3) ----------------------------------
for my $plat (qw(nixos linux-host)) {
    my $out = `"$^X" "$script" --platform=$plat 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 3, "unsupported platform '$plat' halts with exit 3")
        or diag($out);
}

# ---- real run produces a clean verdict (0 ok / 2 gating-fail), never a crash --
{
    my $out = `"$^X" "$script" 2>&1`;
    my $rc  = $? >> 8;
    ok($rc == 0 || $rc == 2, "real run yields a clean verdict (exit $rc in {0,2}, not a crash)")
        or diag($out);
}

# ---- macOS is a supported host ----------------------------------------------
{
    my $home = tempdir(CLEANUP => 1);
    local $ENV{HOME} = $home;
    local $ENV{USERPROFILE} = $home;
    my $out = `"$^X" "$script" --platform=macos 2>&1`;
    my $rc  = $? >> 8;
    ok($rc == 0 || $rc == 2, "--platform=macos is supported (exit $rc in {0,2}, not 3)")
        or diag($out);
    like($out, qr/=== butler preflight \(platform: macos\) ===/, 'macos: the report names the platform');
    for my $id (qw(bin.curl bin.perl tls.ca creds.path repo.usable)) {
        unlike($out, qr/^\[ skip \] \Q$id\E\s+n\/a on macos/m, "macos: $id applies (not n/a)");
    }
    like($out, qr/^\[ skip \] runtime\.container\s+n\/a on macos/m,
        'macos: the container runtime is not required (drive-solo needs none)');
}

SKIP: {
    skip 'detection of a real darwin host', 1 unless $^O eq 'darwin';
    my $home = tempdir(CLEANUP => 1);
    local $ENV{HOME} = $home;
    local $ENV{USERPROFILE} = $home;
    my $out = `"$^X" "$script" 2>&1`;
    like($out, qr/platform: macos/, 'darwin is detected as macos');
}

# ---- macOS credentials come from the Keychain (fake `security`) --------------
{
    my $home = tempdir(CLEANUP => 1);
    my $bin  = tempdir(CLEANUP => 1);
    my $tok  = 'tok-PREFLIGHT-SENTINEL';
    my $json = JSON::PP->new->canonical->encode({ claudeAiOauth => {
        accessToken => $tok, refreshToken => 'r', expiresAt => 4_102_444_800_000,
        scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 't' } });
    open my $f, '>:raw', "$bin/security" or die $!;
    print {$f} "#!/bin/sh\ncat <<'EOF'\n$json\nEOF\n";
    close $f;
    chmod 0755, "$bin/security";
    # Named by BP_CREDS_SECURITY_BIN: BpCreds runs /usr/bin/security by
    # absolute path otherwise, never whatever `security` is first on PATH.
    local $ENV{BP_CREDS_SECURITY_BIN} = "$bin/security";
    local $ENV{HOME} = $home;
    local $ENV{USERPROFILE} = $home;
    local $ENV{BP_CREDS_KEYCHAIN} = '1';
    delete local $ENV{BP_CREDS_PATH};
    my $out = `"$^X" "$script" --platform=macos 2>&1`;
    like($out, qr/^\[  ok  \] creds\.path\s+creds present \+ parseable \(macOS Keychain\)/m,
        'macos: creds.path reads the Keychain item when no file exists')
        or diag($out);
    like($out, qr/^\[  ok  \] creds\.shape\s+creds shape valid/m, 'macos: creds.shape validates the Keychain JSON');
    unlike($out, qr/SENTINEL/, 'macos: the secret never appears in the report');
}
