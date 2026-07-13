#!/usr/bin/env perl
# Fix 1 robustness: materialize-credentials must DEGRADE (preserve in-container
# mcpOAuth) rather than ABORT the launch when its own accumulator output is
# persistently unparseable. That output is a real file in the RW claude-home dir
# bind, so it can be left corrupt by a stale 0-byte placeholder from an older era
# OR a write torn by a hard container kill. The original code die()d on that read,
# which propagated as exit 255 and bricked the entire `claude-sandbox` launch.
# mcpOAuth is re-auth'd in-container, so losing it is acceptable; bricking the
# launch is not.
#
# Also pins the standing invariants (blueprint 01-independent-grant):
#   - claudeAiOauth NEVER comes from the host (host token is never injected).
#   - claudeAiOauth is preserved from the CONTAINER accumulator only when the
#     reset marker <output-dir>/.launcher/oauth-independent-migrated is PRESENT.
#   - When the marker is ABSENT, any accumulator claudeAiOauth is a stale
#     host-copy and is CLEARED; the marker is then created for future runs.
#   - host mcpOAuth is NEVER propagated into the sandbox.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

BEGIN { $ENV{SANDBOX_SKILLS_NO_DISPATCH} = 1; }
require "$Bin/../../scripts/skills.pl";

plan tests => 23;

sub spew { my ($p,$c)=@_; open my $f,'>:raw',$p or die "$p: $!"; print $f $c; close $f; }
sub slurp_json { my $p=shift; open my $f,'<:raw',$p or die "$p: $!"; local $/;
                 JSON::PP->new->utf8->decode(scalar <$f>); }
sub marker_path { my $out=shift; File::Spec->catfile(File::Basename::dirname($out), '.launcher', 'oauth-independent-migrated'); }

# ---------------------------------------------------------------------------
# Shared host creds fixture — claudeAiOauth with a distinctive marker value.
# This token must NEVER appear in any materialized output.
# ---------------------------------------------------------------------------
my $global_dir = tempdir(CLEANUP => 1);
my $host = "$global_dir/host_creds.json";
spew($host, JSON::PP->new->encode({
    claudeAiOauth => { accessToken=>'HOST_SENTINEL_TOKEN', refreshToken=>'R', expiresAt=>1, scopes=>['x'] },
    mcpOAuth      => { 'host-server' => { tok=>'HOSTONLY' } },
}));

# ===========================================================================
# Case 1: stale 0-byte accumulator (the exact degrade bug) — no marker present
# U1 (host never injected): zero-byte accumulator + no marker → claudeAiOauth
# absent from output (degrade resets to empty; host token never injected).
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out_creds.json";
    spew($out, "");
    my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
    is($@, '', 'zero-byte accumulator: no die (launch is not aborted)');
    is($rc, 0, 'zero-byte accumulator: returns success');
    my $m1 = slurp_json($out);
    ok(!exists $m1->{claudeAiOauth} || ($m1->{claudeAiOauth}{accessToken} // '') ne 'HOST_SENTINEL_TOKEN',
       'zero-byte: host claudeAiOauth NOT injected into output (U1)');
    ok(!exists $m1->{mcpOAuth}, 'zero-byte: host mcpOAuth NOT propagated (accumulator empty after degrade)');
}

# ===========================================================================
# Case 2: non-JSON garbage accumulator — likewise degrades, host never injected
# U1 (host never injected): garbage accumulator + no marker → host token absent.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out_creds.json";
    spew($out, "{ this is not valid json ");
    my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
    is($@, '', 'garbage accumulator: no die');
    my $m2 = slurp_json($out);
    ok(!exists $m2->{claudeAiOauth} || ($m2->{claudeAiOauth}{accessToken} // '') ne 'HOST_SENTINEL_TOKEN',
       'garbage: host claudeAiOauth NOT injected into output (U1)');
}

# ===========================================================================
# Case 3: a VALID accumulator's in-container mcpOAuth is preserved
# (No claudeAiOauth in accumulator → none in output regardless of marker.)
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out_creds.json";
    spew($out, JSON::PP->new->encode({ mcpOAuth => { 'sandbox-server' => { tok=>'KEEP' } } }));
    my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
    is($@, '', 'valid accumulator: no die');
    my $m3 = slurp_json($out);
    is($m3->{mcpOAuth}{'sandbox-server'}{tok}, 'KEEP',
       'valid accumulator: in-container mcpOAuth preserved (no regression)');
    ok(!exists $m3->{mcpOAuth}{'host-server'},
       'valid accumulator: host mcpOAuth still not injected');
}

# ===========================================================================
# U2 (accumulator preserved, marker PRESENT):
# Marker present + accumulator has its own claudeAiOauth (a real /login grant) →
# output claudeAiOauth == accumulator value verbatim (not the host value).
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out_creds.json";
    # Create the reset marker to signal migration is done.
    my $marker = marker_path($out);
    make_path(File::Basename::dirname($marker));
    spew($marker, '');
    # Accumulator holds the sandbox's OWN grant (distinct from the host token).
    my $sandbox_token = { accessToken=>'SANDBOX_OWN_TOKEN', refreshToken=>'SR', expiresAt=>999, scopes=>['y'] };
    spew($out, JSON::PP->new->encode({ claudeAiOauth => $sandbox_token }));
    my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
    is($@, '', 'U2: no die when marker present');
    my $m = slurp_json($out);
    is($m->{claudeAiOauth}{accessToken}, 'SANDBOX_OWN_TOKEN',
       'U2: accumulator claudeAiOauth preserved verbatim when marker present');
}

# ===========================================================================
# U3 (fresh → none):
# No accumulator claudeAiOauth (fresh sandbox) → output has no claudeAiOauth.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out_creds.json";
    # Marker present (already migrated, stable state) but no claudeAiOauth in accumulator.
    my $marker = marker_path($out);
    make_path(File::Basename::dirname($marker));
    spew($marker, '');
    spew($out, JSON::PP->new->encode({ mcpOAuth => { 'some-server' => { tok=>'MCP' } } }));
    my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
    is($@, '', 'U3: no die on fresh-grant case');
    my $m = slurp_json($out);
    ok(!exists $m->{claudeAiOauth},
       'U3: no claudeAiOauth in output when accumulator has none (fresh → none)');
}

# ===========================================================================
# U4a (reset, marker ABSENT):
# No marker + accumulator holds a claudeAiOauth (stale host-copy) + an mcpOAuth
# → output has NO claudeAiOauth (cleared) AND the marker file now exists
# AND mcpOAuth is still preserved.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out_creds.json";
    # Confirm marker does not exist yet.
    my $marker = marker_path($out);
    ok(!-e $marker, 'U4a: marker absent before first run');
    # Accumulator has a stale host-copy claudeAiOauth AND a real mcpOAuth grant.
    spew($out, JSON::PP->new->encode({
        claudeAiOauth => { accessToken=>'STALE_HOST_COPY', refreshToken=>'X', expiresAt=>1, scopes=>['z'] },
        mcpOAuth      => { 'in-container-server' => { tok=>'MCPKEEP' } },
    }));
    my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
    is($@, '', 'U4a: no die during reset');
    my $m = slurp_json($out);
    ok(!exists $m->{claudeAiOauth},
       'U4a: claudeAiOauth cleared from output when marker absent (stale host-copy reset)');
    ok(-e $marker, 'U4a: marker file created after reset run');
    is($m->{mcpOAuth}{'in-container-server'}{tok}, 'MCPKEEP',
       'U4a: mcpOAuth preserved despite claudeAiOauth reset');
}

# ===========================================================================
# U4b (preserve, marker PRESENT):
# Marker present + accumulator claudeAiOauth → preserved (not cleared).
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out_creds.json";
    my $marker = marker_path($out);
    make_path(File::Basename::dirname($marker));
    spew($marker, '');
    spew($out, JSON::PP->new->encode({
        claudeAiOauth => { accessToken=>'PERSISTENT_SANDBOX_TOKEN', refreshToken=>'P', expiresAt=>42, scopes=>['q'] },
    }));
    my $rc = eval { cmd_materialize_credentials(output=>$out, host_credentials=>$host) };
    is($@, '', 'U4b: no die when marker present and accumulator has claudeAiOauth');
    my $m = slurp_json($out);
    is($m->{claudeAiOauth}{accessToken}, 'PERSISTENT_SANDBOX_TOKEN',
       'U4b: claudeAiOauth preserved (not cleared) when marker is present');
}

# ===========================================================================
# U5 (settings lock):
# container/settings.json has DISABLE_LOGIN_COMMAND == "0"
# AND DISABLE_LOGOUT_COMMAND == "0"  (regression guard — must never flip to "1").
# ===========================================================================
{
    use File::Basename qw(dirname);
    # $Bin = plugins/sandbox/tests/t — walk up to plugin root, then into container/
    my $settings = File::Spec->catfile($Bin, '..', '..', 'container', 'settings.json');
    ok(-f $settings, "U5: container/settings.json exists at $settings");
    SKIP: {
        skip "settings.json not found", 2 unless -f $settings;
        open my $fh, '<:raw', $settings or die "open $settings: $!";
        local $/;
        my $data = JSON::PP->new->utf8->decode(scalar <$fh>);
        close $fh;
        is($data->{env}{DISABLE_LOGIN_COMMAND},  '0',
           'U5: DISABLE_LOGIN_COMMAND is "0" (login command enabled in sandbox)');
        is($data->{env}{DISABLE_LOGOUT_COMMAND}, '0',
           'U5: DISABLE_LOGOUT_COMMAND is "0" (logout command enabled in sandbox)');
    }
}
