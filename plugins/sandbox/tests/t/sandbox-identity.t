#!/usr/bin/env perl
# platform: any
# SandboxIdentity: the launcher's identity (image, container names, hostname,
# refusal-marker id) and its install root, which is the checkout it runs FROM.
# Also pins, structurally, that launcher.pl, bootstrap.pl and skills.pl no
# longer hard-code ~/.claude/ccpraxis or the claude-sandbox image/container
# names, so a fork that changes SandboxIdentity.pm gets a fully separate
# sandbox family that serves the fork's own tooling.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Cwd ();
use SandboxIdentity qw(install_root image_ref container_name
                       is_sandbox_container_name directory_marketplace_source);

# --- install_root ------------------------------------------------------------

{
    my $expect = Cwd::abs_path("$Bin/../../../..");
    $expect =~ s{\\}{/}g;
    $expect =~ s{^/([a-zA-Z])/}{$1:/} if $^O =~ /^(MSWin32|cygwin|msys)$/;
    is(install_root(), $expect, 'install_root is the checkout this module was loaded from');
    ok(-f install_root() . '/plugins/sandbox/scripts/SandboxIdentity.pm', '... and contains this module');
    unlike(install_root(), qr{/\z}, '... with no trailing slash');
    unlike(install_root(), qr{\\}, '... and forward slashes only');
}

# --- identity ----------------------------------------------------------------

is($SandboxIdentity::ID, 'claude-sandbox', 'ccpraxis identity is claude-sandbox');
is($SandboxIdentity::CONTAINER_PREFIX, 'claude', 'ccpraxis container prefix is claude (unchanged naming)');
is(image_ref(), 'claude-sandbox:latest', 'image_ref defaults to :latest');
is(image_ref('2.1.0'), 'claude-sandbox:2.1.0', 'image_ref with a tag');
is(container_name('my-proj', 'deadbeef'), 'claude-my-proj-deadbeef', 'container_name keeps the historic shape');
is(SandboxIdentity::hostname(), 'claude-sandbox', 'hostname is the id');

{
    local $SandboxIdentity::ID = 'fork-sandbox';
    local $SandboxIdentity::CONTAINER_PREFIX = 'fork';
    is(image_ref(), 'fork-sandbox:latest', 'a fork identity changes the image');
    is(container_name('p', '0123abcd'), 'fork-p-0123abcd', '... and the container names');
}

ok(is_sandbox_container_name('claude-proj-0123abcd'), 'port scan sees claude-sandbox containers');
ok(is_sandbox_container_name('fork-my-proj-0123abcd'), '... and another identity\'s containers');
ok(!is_sandbox_container_name('postgres'), '... but not an unrelated container');
ok(!is_sandbox_container_name('claude-proj-0123ABCD'), '... nor a name without the lowercase hash suffix');
ok(!is_sandbox_container_name(undef), '... nor undef');

# --- directory_marketplace_source -------------------------------------------

is(directory_marketplace_source('ccpraxis-local', '/somewhere/else/plugins'),
   install_root() . '/plugins',
   'ccpraxis-local is served from this checkout\'s plugins/');
is(directory_marketplace_source('other-mkt', '/x/y'), '/x/y', 'other marketplaces keep the registry path');
is(directory_marketplace_source(undef, '/x/y'), '/x/y', 'undef name keeps the registry path');

# --- structural: no hard-coded live install or identity left ----------------

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "read $f: $!";
    local $/;
    return scalar <$fh>;
}

for my $script (qw(launcher.pl bootstrap.pl skills.pl)) {
    my $src = slurp("$Bin/../../scripts/$script");
    # strip comments so prose may still mention the old paths
    (my $code = $src) =~ s/^\s*#.*$//mg;
    unlike($code, qr{/\.claude/ccpraxis/(?:plugins|scripts|skills|\.locks)},
        "$script: no hard-coded ~/.claude/ccpraxis tooling path");
    unlike($code, qr{\bclaude-sandbox:(?:latest|\$)},
        "$script: no literal claude-sandbox image reference");
    unlike($code, qr{"claude-\$\{?(?:PROJECT_NAME|n)\b},
        "$script: no literal claude- container-name construction");
    like($src, qr{use SandboxIdentity \(\);}, "$script: loads SandboxIdentity");
}
{
    my $src = slurp("$Bin/../../scripts/launcher.pl");
    like($src, qr{SandboxIdentity::directory_marketplace_source\(\$name, \$host_path\)},
        'launcher.pl routes the directory-marketplace bind through SandboxIdentity');
    like($src, qr{SandboxIdentity::is_sandbox_container_name\(\$name\)},
        'launcher.pl port scan uses the cross-identity container-name match');
}
{
    my $src = slurp("$Bin/../../scripts/RefusalMarker.pm");
    like($src, qr{our \$LAUNCHER_ID = \$SandboxIdentity::ID;}, 'RefusalMarker takes its launcher id from SandboxIdentity');
}

done_testing();
