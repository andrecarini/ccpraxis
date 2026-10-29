#!/usr/bin/env perl
# platform: any
# ProjectSandbox: a project's claude-sandbox.json may add its own image layer and ask for a fixed
# allowlist of extra container settings. Every rule that keeps an agent-editable manifest from
# granting more than that list is held here: unknown keys, devices, security options, volume
# names and targets, paths that escape the project, and build args.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use ProjectSandbox qw(load validate create_args spec_signature image_hash image_tag describe);

sub write_file { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh }

my $proj = tempdir(CLEANUP => 1);
make_path("$proj/container/dev");
write_file("$proj/container/dev/Containerfile", "ARG BASE_IMAGE\nFROM \${BASE_IMAGE}\n");
write_file("$proj/container/dev/versions.env", "A=1\n");

my $good = {
    image => { context => 'container/dev', containerfile => 'Containerfile', build_args => { PIN_MODE => 'record' } },
    run   => { devices => ['/dev/fuse'], security_opt => ['label=disable'],
               volumes => [ { name => 'cells', target => '/var/lib/containers' },
                            { name => 'dev-core-data', target => '/var/lib/acxpraxis-dev' } ] },
};

# --- load ------------------------------------------------------------------------------

{
    my ($spec, $err) = load($proj);
    ok(!defined $spec && !@$err, 'no manifest: no spec and no errors');

    write_file("$proj/claude-sandbox.json", JSON::PP->new->encode($good));
    ($spec, $err) = load($proj);
    is_deeply($err, [], 'a valid manifest loads without errors');
    is_deeply($spec, $good, '... and returns its content');

    write_file("$proj/claude-sandbox.json", "{ not json");
    ($spec, $err) = load($proj);
    ok(!defined $spec, 'invalid JSON: no spec');
    like($err->[0], qr/not valid JSON/, '... and says why');
    unlink "$proj/claude-sandbox.json";
}

# --- validate: what is refused ------------------------------------------------------------

sub errs { my ($d) = @_; return join "\n", validate($d, $proj) }

is(errs($good), '', 'the reference manifest is valid');
like(errs([]), qr/top level must be an object/, 'a non-object manifest is refused');
like(errs({ %$good, network => 'host' }), qr/unknown key 'network'/, 'an unknown top-level key is refused');
like(errs({ run => { privileged => JSON::PP::true } }), qr/unknown key 'privileged'/, 'run.privileged is refused');
like(errs({ run => { cap_add => ['SYS_ADMIN'] } }), qr/unknown key 'cap_add'/, 'capabilities cannot be added');
like(errs({ run => { devices => ['/dev/kvm'] } }), qr{'/dev/kvm' is not allowed}, 'a device outside the allowlist is refused');
like(errs({ run => { devices => '/dev/fuse' } }), qr/run.devices: must be a list/, 'devices must be a list');
is(errs({ run => { devices => ['/dev/fuse', '/dev/net/tun'] } }), '',
   '/dev/net/tun is allowed (nested containers need it for a network of their own)');
for my $d ('/dev/net', '/dev/net/tun/', '/dev/net/tun:/dev/net/tun', '/dev/net/tun:/dev/net/tun:rwm',
           '/dev/net/../kvm', '/dev/mem') {
    like(errs({ run => { devices => [$d] } }), qr{'\Q$d\E' is not allowed}, "device '$d' is refused");
}
like(errs({ run => { security_opt => ['seccomp=unconfined'] } }), qr/'seccomp=unconfined' is not allowed/,
     'a security option outside the allowlist is refused');
like(errs({ run => { security_opt => ['apparmor=unconfined'] } }), qr/not allowed/, 'apparmor=unconfined is refused');

for my $t ('/', '/project', '/project/sub', '/root/.claude', '/root/.claude/x', '/proc', '/etc/ssh', '/usr/local') {
    like(errs({ run => { volumes => [ { name => 'v', target => $t } ] } }), qr/not allowed|must be an absolute path/,
         "volume target $t is refused");
}
like(errs({ run => { volumes => [ { name => 'v', target => 'relative/path' } ] } }), qr/absolute path/,
     'a relative volume target is refused');
like(errs({ run => { volumes => [ { name => 'v', target => '/var/../etc' } ] } }), qr/absolute path without/,
     'a volume target with .. is refused');
like(errs({ run => { volumes => [ { name => 'Bad_Name', target => '/var/x' } ] } }), qr/must be 1-40/,
     'a volume name with upper case or underscore is refused');
like(errs({ run => { volumes => [ { name => '/host/path', target => '/var/x' } ] } }), qr/must be 1-40/,
     'a host path as a volume name (a bind in disguise) is refused');
like(errs({ run => { volumes => [ { name => 'a', target => '/var/x' }, { name => 'a', target => '/var/y' } ] } }),
     qr/used twice/, 'a duplicate volume name is refused');
like(errs({ run => { volumes => [ { name => 'a', target => '/var/x' }, { name => 'b', target => '/var/x/' } ] } }),
     qr/target '\/var\/x\/' is used twice/, 'a duplicate volume target is refused');
like(errs({ run => { volumes => [ { name => 'a', target => '/var/x', options => 'rw' } ] } }), qr/unknown key 'options'/,
     'volume options are refused');

like(errs({ image => { context => '../elsewhere' } }), qr/without '\.\.'/, 'an image context outside the project is refused');
like(errs({ image => { context => '/abs/path' } }), qr/relative path/, 'an absolute image context is refused');
like(errs({ image => { context => 'missing/dir' } }), qr/is not a directory/, 'a missing image context is refused');
like(errs({ image => { context => 'container/dev', containerfile => 'Nope' } }), qr/does not exist/,
     'a missing Containerfile is refused');
like(errs({ image => { context => 'container/dev', build_args => { BASE_IMAGE => 'x' } } }), qr/set by the launcher/,
     'BASE_IMAGE cannot be overridden');
like(errs({ image => { context => 'container/dev', build_args => { lower => 'x' } } }), qr/UPPER_CASE/,
     'a lower-case build arg name is refused');
like(errs({ image => { context => 'container/dev', build_args => { A => 'x; rm -rf /' } } }), qr/plain text/,
     'a build arg value with shell characters is refused');
like(errs({ image => { context => 'container/dev', tags => ['x'] } }), qr/unknown key 'tags'/,
     'an unknown image key is refused');

# --- create_args -----------------------------------------------------------------------------

is_deeply([create_args($good, 'claude-proj-abc')],
          ['--device', '/dev/fuse', '--security-opt', 'label=disable',
           '-v', 'claude-proj-abc-cells:/var/lib/containers',
           '-v', 'claude-proj-abc-dev-core-data:/var/lib/acxpraxis-dev'],
          'create_args: devices, security options, then container-scoped named volumes');
is_deeply([create_args(undef, 'c')], [], 'create_args: no manifest, no args');
is_deeply([create_args({ image => $good->{image} }, 'c')], [], 'create_args: image only, no run args');

{
    # The launcher turns each -v into --mount; a container-scoped name must stay a volume, not a bind.
    require MountSpec;
    my @m = MountSpec::convert_v_to_mount(create_args($good, 'claude-proj-abc'));
    ok((grep { /\Atype=volume,source=claude-proj-abc-cells,target=\/var\/lib\/containers\z/ } @m),
       'the generated volume arg converts to a named-volume --mount');
    ok(!(grep { /type=bind/ } @m), '... and never to a bind');
}

# --- signatures and image identity -------------------------------------------------------------

is(spec_signature(undef), 'none', 'spec_signature without a manifest');
is(spec_signature($good), spec_signature(JSON::PP->new->decode(JSON::PP->new->encode($good))),
   'spec_signature is stable across key order');
isnt(spec_signature($good), spec_signature({ %$good, run => { devices => ['/dev/fuse'] } }),
     'spec_signature changes when the run settings change');

{
    my $h1 = image_hash($proj, $good, 'sha256:base1');
    is($h1, image_hash($proj, $good, 'sha256:base1'), 'image_hash is deterministic');
    isnt($h1, image_hash($proj, $good, 'sha256:base2'), 'image_hash changes with the base image');
    write_file("$proj/container/dev/versions.env", "A=2\n");
    isnt($h1, image_hash($proj, $good, 'sha256:base1'), 'image_hash changes when a context file changes');
    my $g2 = JSON::PP->new->decode(JSON::PP->new->encode($good));
    $g2->{image}{build_args}{PIN_MODE} = 'strict';
    isnt(image_hash($proj, $good, 'b'), image_hash($proj, $g2, 'b'), 'image_hash changes with a build arg');
    like(image_tag('claude-Proj-abc', $h1), qr{\Alocalhost/claude-proj-abc-image:[0-9a-f]{12}\z},
         'image_tag is a lower-case local reference with a 12-hex tag');
}

# --- describe ------------------------------------------------------------------------------------

is_deeply([describe($good)],
          ['image layer from container/dev/Containerfile', 'device /dev/fuse', 'security option label=disable',
           'volume cells at /var/lib/containers, dev-core-data at /var/lib/acxpraxis-dev'],
          'describe lists every grant for the launch screen');
is_deeply([describe(undef)], [], 'describe without a manifest is empty');

# --- memory and CPU limits ------------------------------------------------------------------------

{
    use ProjectSandbox qw(memory_limit resource_args);
    is(errs({ run => { memory => '6g', cpus => 3 } }), '', 'run.memory 6g and run.cpus 3 are valid');
    is(errs({ run => { memory => '4096m', cpus => '1.5' } }), '', 'run.memory in m and fractional cpus are valid');
    like(errs({ run => { memory => '256m' } }), qr/at least 512m/, 'run.memory below 512m is refused');
    like(errs({ run => { memory => '6GB' } }), qr/must look like/, 'run.memory in another unit is refused');
    like(errs({ run => { memory => 6 } }), qr/must look like/, 'run.memory without a unit is refused');
    like(errs({ run => { cpus => 0 } }), qr/0.5 to 64/, 'run.cpus 0 is refused');
    like(errs({ run => { cpus => 'all' } }), qr/0.5 to 64/, 'run.cpus that is not a number is refused');

    my $ten_gib = 10 * 1024 ** 3;
    is(memory_limit(undef, $ten_gib), '7680m', 'default memory limit is three quarters of the host');
    is(memory_limit({ run => { memory => '6g' } }, $ten_gib), '6g', 'a project value wins over the default');
    is(memory_limit(undef, undef), undef, 'no limit when the host size is unknown');
    is(memory_limit(undef, 0), undef, 'no limit when the host size is zero');
    is(memory_limit(undef, 600 * 1048576), undef, 'no default below 512m on a tiny host');
    is_deeply([resource_args(undef, $ten_gib)], ['--memory', '7680m', '--memory-swap', '7680m'],
              'resource_args: memory and an equal swap limit by default');
    is_deeply([resource_args({ run => { memory => '6g', cpus => 3 } }, $ten_gib)],
              ['--memory', '6g', '--memory-swap', '6g', '--cpus', 3], 'resource_args: project memory and cpus');
    is_deeply([resource_args(undef, undef)], [], 'resource_args: nothing when nothing is known');
    is_deeply([describe({ run => { memory => '6g', cpus => 3 } })], ['memory 6g', 'cpus 3'],
              'describe lists memory and cpus');
}

done_testing();
