#!/usr/bin/env perl
# A8 preflight (bp-preflight.pl): asserts environment support from the manifest
# and HALTS LOUD on an unsupported platform (Decisions #29/#31). A bare linux
# host must NOT be mistaken for our sandbox.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;

my $script   = "$Bin/../../scripts/bp-preflight.pl";
my $manifest = "$Bin/../../docs/assumptions.json";

plan tests => 11;

ok(-f $script,   'bp-preflight.pl exists');
ok(-f $manifest, 'assumptions.json exists');

# ---- manifest structure ---------------------------------------------------
my $m = do { open my $fh,'<:raw',$manifest or die; local $/; JSON::PP->new->decode(<$fh>) };
is_deeply([sort @{$m->{supported_envs}}], ['sandbox-linux','win32'], 'supported_envs = {win32, sandbox-linux}');
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
