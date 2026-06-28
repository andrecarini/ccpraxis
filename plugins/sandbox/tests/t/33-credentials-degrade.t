#!/usr/bin/env perl
# Fix 1 robustness: materialize-credentials must DEGRADE (reseed claudeAiOauth
# from the host, drop the regenerable mcpOAuth) rather than ABORT the launch when
# its own accumulator output is persistently unparseable. That output is a real
# file in the RW claude-home dir bind, so it can be left corrupt by a stale
# 0-byte placeholder from an older era OR a write torn by a hard container kill.
# The original code die()d on that read, which propagated as exit 255 and bricked
# the entire `claude-sandbox` launch. mcpOAuth is re-auth'd in-container, so
# losing it is acceptable; bricking the launch is not.
#
# Also pins the standing invariants: claudeAiOauth always comes from the host,
# and host mcpOAuth is NEVER propagated into the sandbox.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

BEGIN { $ENV{SANDBOX_SKILLS_NO_DISPATCH} = 1; }
require "$Bin/../../scripts/skills.pl";

plan tests => 9;

my $dir = tempdir(CLEANUP => 1);
sub spew { my ($p,$c)=@_; open my $f,'>:raw',$p or die "$p: $!"; print $f $c; close $f; }
sub slurp_json { my $p=shift; open my $f,'<:raw',$p or die "$p: $!"; local $/;
                 JSON::PP->new->utf8->decode(scalar <$f>); }

# A valid host creds file. claudeAiOauth is always sourced from here; its
# mcpOAuth (host-server) must NEVER cross into the sandbox accumulator.
my $host = "$dir/host_creds.json";
spew($host, JSON::PP->new->encode({
    claudeAiOauth => { accessToken=>'HOSTACCESS', refreshToken=>'R', expiresAt=>1, scopes=>['x'] },
    mcpOAuth      => { 'host-server' => { tok=>'HOSTONLY' } },
}));

my $out = "$dir/out_creds.json";

# --- Case 1: stale 0-byte accumulator (the exact bug) — must not abort --------
spew($out, "");
my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
is($@, '', 'zero-byte accumulator: no die (launch is not aborted)');
is($rc, 0, 'zero-byte accumulator: returns success');
my $m1 = slurp_json($out);
is($m1->{claudeAiOauth}{accessToken}, 'HOSTACCESS', 'zero-byte: claudeAiOauth reseeded from host');
ok(!exists $m1->{mcpOAuth}, 'zero-byte: host mcpOAuth NOT propagated (accumulator empty after reseed)');

# --- Case 2: non-JSON garbage accumulator — likewise degrades -----------------
spew($out, "{ this is not valid json ");
$rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
is($@, '', 'garbage accumulator: no die');
my $m2 = slurp_json($out);
is($m2->{claudeAiOauth}{accessToken}, 'HOSTACCESS', 'garbage: claudeAiOauth still reseeded from host');

# --- Case 3: a VALID accumulator's in-container mcpOAuth is preserved ----------
spew($out, JSON::PP->new->encode({ mcpOAuth => { 'sandbox-server' => { tok=>'KEEP' } } }));
$rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
is($@, '', 'valid accumulator: no die');
my $m3 = slurp_json($out);
is($m3->{mcpOAuth}{'sandbox-server'}{tok}, 'KEEP',
   'valid accumulator: in-container mcpOAuth preserved (no regression)');
ok(!exists $m3->{mcpOAuth}{'host-server'},
   'valid accumulator: host mcpOAuth still not injected');
