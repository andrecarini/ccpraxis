#!/usr/bin/env perl
# platform: any
# HostPlatform.pm: the host-platform decisions launcher.pl, bootstrap.pl and
# the container-test harness share. Every decision is driven through its
# seams, so nothing here needs a container runtime.
#
#   A. container CLI choice: darwin prefers podman (a Mac may carry an
#      unrelated docker wrapper on PATH); Windows and Linux orders unchanged;
#      CCPRAXIS_CONTAINER_CLI is the only candidate when set.
#   B. operator-facing remedies: when there is no machine to start, macOS is
#      sent to podman-machine.pl, Windows to `podman machine init --provider wsl`.
#   C. canonical_dir: the stored case of a directory on APFS (darwin only).
#   D. machine shares + bind sources: which bind mounts a podman machine
#      cannot see, or would write through a share it has read-only, and a
#      refusal that names podman-machine.pl. Fixtures are the real shapes
#      podman 6.1.4 printed on macOS.
#   E. TestSandbox with no container CLI: a clean skip_all, not a load-time die.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use Cwd ();
use HostPlatform ();

# ---------------------------------------------------------------------------
# A. container CLI choice
# ---------------------------------------------------------------------------
is_deeply([HostPlatform::cli_candidates('darwin')], ['podman', 'docker'],
    'A: darwin probes podman before docker');
is_deeply([HostPlatform::cli_candidates('cygwin')], ['docker.exe', 'podman.exe'],
    'A: Git-for-Windows perl (cygwin) order is unchanged: docker.exe, podman.exe');
is_deeply([HostPlatform::cli_candidates('msys')], ['docker.exe', 'podman.exe'],
    'A: msys order is unchanged');
is_deeply([HostPlatform::cli_candidates('linux')], ['docker', 'podman'],
    'A: Linux order is unchanged: docker, podman');

{
    my @asked;
    my $both = sub { push @asked, $_[0]; 1 };
    my ($cli, $err) = HostPlatform::detect_container_cli(env => {}, os => 'darwin', probe => $both);
    is($cli, 'podman', 'A: darwin with BOTH podman and docker responding picks podman');
    ok(!defined $err, 'A: ...with no error');
    is_deeply(\@asked, ['podman'], 'A: ...and never even probes docker once podman answered');

    ($cli) = HostPlatform::detect_container_cli(env => {}, os => 'darwin', probe => sub { $_[0] eq 'docker' });
    is($cli, 'docker', 'A: darwin with only docker responding still finds docker (a fallback, not a ban)');

    ($cli) = HostPlatform::detect_container_cli(env => {}, os => 'cygwin', probe => $both);
    is($cli, 'docker.exe', 'A: Windows with both responding still picks docker.exe (unchanged)');

    ($cli, $err) = HostPlatform::detect_container_cli(env => {}, os => 'darwin', probe => sub { 0 });
    ok(!defined $cli && !defined $err, 'A: nothing responding -> (undef, undef): "nothing found", not an error');
}

{
    my @asked;
    my ($cli, $err) = HostPlatform::detect_container_cli(
        env => { CCPRAXIS_CONTAINER_CLI => '/opt/homebrew/bin/podman' }, os => 'darwin',
        probe => sub { push @asked, $_[0]; 1 });
    is($cli, '/opt/homebrew/bin/podman', 'A: CCPRAXIS_CONTAINER_CLI names the CLI to use');
    is_deeply(\@asked, ['/opt/homebrew/bin/podman'], 'A: ...and is the ONLY candidate probed');

    @asked = ();
    ($cli, $err) = HostPlatform::detect_container_cli(
        env => { CCPRAXIS_CONTAINER_CLI => 'nerdctl' }, os => 'linux',
        probe => sub { push @asked, $_[0]; $_[0] ne 'nerdctl' });
    ok(!defined $cli, 'A: an override that does not respond yields no CLI (no quiet fall-back to docker/podman)');
    like($err // '', qr/CCPRAXIS_CONTAINER_CLI='nerdctl'.*--version/, 'A: ...and an error naming the override');
    is_deeply(\@asked, ['nerdctl'], 'A: ...having probed nothing else');

    ($cli, $err) = HostPlatform::detect_container_cli(
        env => { CCPRAXIS_CONTAINER_CLI => 'podman; rm -rf ~' }, os => 'darwin', probe => sub { 1 });
    ok(!defined $cli, 'A: an override with shell metacharacters is refused (it is interpolated into command strings)');
    like($err // '', qr/not a usable command/, 'A: ...with a reason');

    ($cli) = HostPlatform::detect_container_cli(
        env => { CCPRAXIS_CONTAINER_CLI => '' }, os => 'darwin', probe => sub { 1 });
    is($cli, 'podman', 'A: an EMPTY override is the same as unset');
}

# ---------------------------------------------------------------------------
# B. operator-facing remedies
# ---------------------------------------------------------------------------
{
    my $mac = join "\n", HostPlatform::no_cli_message('darwin');
    my $script = HostPlatform::machine_script_path();
    like($script, qr{/plugins/sandbox/scripts/podman-machine\.pl\z}, 'B: machine_script_path() is the podman-machine.pl beside HostPlatform.pm');
    ok(-f $script, 'B: ...and that file exists');
    like($mac, qr/\Q$script\E apply/, 'B: darwin no-CLI message creates the machine with podman-machine.pl apply');
    unlike($mac, qr/podman machine init/, 'B: ...never with a bare `podman machine init` (its defaults share /Users read-write)');
    like($mac, qr/CCPRAXIS_CONTAINER_CLI/, 'B: darwin no-CLI message names the override');
    unlike($mac, qr/Docker Desktop/, 'B: darwin no-CLI message does not send a Mac user to Docker Desktop');
    my $win = join "\n", HostPlatform::no_cli_message('cygwin');
    like($win, qr/Docker Desktop.*Podman Desktop/s, 'B: Windows no-CLI message is the established wording');

    my $absent = join "\n", HostPlatform::machine_remedy_lines('darwin', 'absent');
    like($absent, qr/\Q$script\E apply --confirm/, 'B: an absent macOS machine is remedied with podman-machine.pl apply --confirm');
    unlike($absent, qr/podman machine init/, 'B: ...not with a hand-typed `podman machine init`');
    my $absent_win = join "\n", HostPlatform::machine_remedy_lines('cygwin', 'absent');
    like($absent_win, qr/podman machine init --provider wsl && podman machine start/,
        'B: on Windows the init remedy is unchanged (WSL2 provider, then start)');
    unlike($absent_win, qr/podman-machine\.pl/, 'B: ...and never mentions the macOS script');
    my $absent_linux = join "\n", HostPlatform::machine_remedy_lines('linux', 'absent');
    like($absent_linux, qr/podman machine init && podman machine start/, 'B: the Linux wording is unchanged');
    my $stopped = join "\n", HostPlatform::machine_remedy_lines('darwin', 'stopped');
    unlike($stopped, qr/machine init/, 'B: a merely stopped machine is NOT told to init a new one');
    like($stopped, qr/podman machine start/, 'B: ...it is told to start it');
}

# ---------------------------------------------------------------------------
# C. canonical_dir
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    mkdir "$root/CamelDir" or die "mkdir: $!";
    my $cwd_before = Cwd::getcwd();
    is(HostPlatform::canonical_dir("$root/cameldir", os => 'linux'), "$root/cameldir",
        'C: canonical_dir is a no-op off darwin');
    is(HostPlatform::canonical_dir("$root/nope", os => 'darwin'), "$root/nope",
        'C: a path that is not a directory comes back unchanged');
  SKIP: {
        skip 'C: APFS case canonicalisation only measurable on darwin', 2 unless $^O eq 'darwin';
        my $stored = do { chdir "$root/CamelDir" or die; my $c = Cwd::getcwd(); chdir $cwd_before; $c };
        is(HostPlatform::canonical_dir("$root/cameldir"), $stored,
            'C: darwin: a case-mismatched spelling resolves to the stored case');
        is(Cwd::getcwd(), $cwd_before, 'C: ...and the caller\'s working directory is restored');
    }
}

# ---------------------------------------------------------------------------
# D. machine shares and bind sources
# ---------------------------------------------------------------------------
my $INSPECT = <<'JSON';
[
     {
          "ConfigDir": { "Path": "/Users/u/.config/containers/podman/machine/applehv" },
          "ConnectionInfo": { "PodmanSocket": { "Path": "/var/folders/xx/T/podman/podman-machine-default-api.sock" }, "PodmanPipe": null },
          "Name": "podman-machine-default",
          "State": "running",
          "Rootful": false
     }
]
JSON
# podman's default machine, as podman 6.1.4 recorded it on this Mac.
my $CONFIG = <<'JSON';
{ "Name": "podman-machine-default",
  "HostUser": { "HostUserModified": false, "Rootful": false, "UID": 501 },
  "Resources": { "CPUs": 6, "DiskSize": 100, "Memory": 12288, "USBs": [] },
  "Mounts": [
    { "OriginalInput": "", "ReadOnly": false, "Source": "/Users", "Tag": "a2a0", "Target": "/Users", "Type": "virtiofs", "VSockNumber": null },
    { "OriginalInput": "", "ReadOnly": false, "Source": "/private", "Tag": "7170", "Target": "/private", "Type": "virtiofs", "VSockNumber": null },
    { "OriginalInput": "", "ReadOnly": false, "Source": "/var/folders", "Tag": "a0bb", "Target": "/var/folders", "Type": "virtiofs", "VSockNumber": null },
    { "OriginalInput": "", "ReadOnly": false, "Source": "/Users/u/.config/containers", "Tag": "9dde", "Target": "/etc/containers", "Type": "virtiofs", "VSockNumber": null }
  ] }
JSON
# The machine podman-machine.pl creates: rootful, the live install and the
# container-files folder read-only, the test scratch and one project read-write.
my $NARROW = <<'JSON';
{ "Name": "podman-machine-default",
  "HostUser": { "Rootful": true, "UID": 501 },
  "Mounts": [
    { "ReadOnly": true,  "Source": "/Users/u/.claude/ccpraxis", "Target": "/Users/u/.claude/ccpraxis", "Type": "virtiofs" },
    { "ReadOnly": true,  "Source": "/Users/u/.cache/ccpraxis/container-files", "Target": "/Users/u/.cache/ccpraxis/container-files", "Type": "virtiofs" },
    { "ReadOnly": false, "Source": "/Users/u/.cache/ccpraxis/container-test-scratch", "Target": "/Users/u/.cache/ccpraxis/container-test-scratch", "Type": "virtiofs" },
    { "ReadOnly": false, "Source": "/Users/u/Projects/app", "Target": "/Users/u/Projects/app", "Type": "virtiofs" }
  ] }
JSON
{
    my $script = HostPlatform::machine_script_path();
    my $info = HostPlatform::parse_machine_inspect($INSPECT);
    is($info->{name}, 'podman-machine-default', 'D: inspect parse: machine name');
    is($info->{config_dir}, '/Users/u/.config/containers/podman/machine/applehv', 'D: inspect parse: config dir');
    is($info->{api_socket}, '/var/folders/xx/T/podman/podman-machine-default-api.sock',
        'D: inspect parse: the API socket (what the test harness hands podman as CONTAINER_HOST)');
  SKIP: {
        skip 'getpwuid is unimplemented on native Windows perl', 1 if $^O eq 'MSWin32';
        ok(defined HostPlatform::owner_home() && -d HostPlatform::owner_home(),
            'D: owner_home() is the OS-recorded home, whatever $ENV{HOME} says');
    }

    my @read;
    my $shares = HostPlatform::machine_shares(
        inspect   => sub { $INSPECT },
        read_file => sub { push @read, $_[0]; $CONFIG });
    is_deeply(\@read, ['/Users/u/.config/containers/podman/machine/applehv/podman-machine-default.json'],
        'D: shares are read from <ConfigDir>/<Name>.json (podman 6.x inspect omits them)');
    is_deeply($shares, [
            { source => '/Users',       target => '/Users',       readonly => 0 },
            { source => '/private',     target => '/private',     readonly => 0 },
            { source => '/var/folders', target => '/var/folders', readonly => 0 },
            { source => '/Users/u/.config/containers', target => '/etc/containers', readonly => 0 },
        ], 'D: every share is returned with its VM path and mode');

    my $older = '[{"Name":"m","Mounts":[{"Source":"/Users/"}]}]';
    is_deeply(HostPlatform::machine_shares(inspect => sub { $older }, read_file => sub { die 'not read' }),
        [{ source => '/Users', target => '/Users', readonly => 0 }],
        'D: an inspect document that carries Mounts is used directly (trailing slash trimmed; no Target = same path)');

    my $narrow = HostPlatform::machine_shares(inspect => sub { $INSPECT }, read_file => sub { $NARROW });
    is_deeply([ map { $_->{readonly} } @$narrow ], [1, 1, 0, 0],
        'D: ReadOnly true in the machine config reads as a read-only share');
    my $details = HostPlatform::parse_machine_config_details($CONFIG);
    is($details->{rootful}, 0, 'D: config details: HostUser.Rootful false -> rootful 0');
    is_deeply($details->{resources}, { cpus => 6, memory => 12288, disk => 100 }, 'D: config details: Resources');
    is(HostPlatform::parse_machine_config_details($NARROW)->{rootful}, 1, 'D: config details: Rootful true -> 1');
    is(HostPlatform::parse_machine_inspect($INSPECT)->{state}, 'running', 'D: inspect parse: State');
    is(HostPlatform::parse_machine_inspect($INSPECT)->{rootful}, 0, 'D: inspect parse: Rootful');

    ok(!defined HostPlatform::machine_shares(inspect => sub { undef }),
        'D: no inspect output -> undef ("cannot tell"), never an empty share list');
    ok(!defined HostPlatform::machine_shares(inspect => sub { $INSPECT }, read_file => sub { undef }),
        'D: unreadable machine config -> undef');
    ok(!defined HostPlatform::machine_shares(inspect => sub { 'Error: VM does not exist' }),
        'D: an error message instead of JSON -> undef');

    my @args = ('podman', 'create', '-it', '--name', 'c',
        '--mount', 'type=bind,source=/Users/u/proj,target=/project',
        '--mount', 'type=bind,source=/opt/homebrew/share/x,target=/x,readonly',
        '--mount', 'type=volume,source=named-vol,target=/v',
        '-v', '/tmp/legacy:/legacy:ro',
        '-p', '9000-9019:9000-9019',
        'claude-sandbox:latest');
    is_deeply([HostPlatform::bind_sources(@args)], ['/Users/u/proj', '/opt/homebrew/share/x', '/tmp/legacy'],
        'D: bind_sources reads --mount bind sources and -v host paths, skipping named volumes and -p');

    my @out = HostPlatform::sources_outside_shares([HostPlatform::bind_sources(@args)], $shares);
    is_deeply(\@out, ['/opt/homebrew/share/x', '/tmp/legacy'],
        'D: sources outside every share are reported; /tmp is NOT covered by /private (podman passes it literally)');
    is_deeply([HostPlatform::sources_outside_shares(['/Users2/x', '/Users'], ['/Users'])], ['/Users2/x'],
        'D: coverage is by whole path component (/Users does not cover /Users2)');
    is_deeply([HostPlatform::sources_outside_shares(['/anything'], ['/'])], [],
        'D: a "/" share covers everything');

    is_deeply([HostPlatform::bind_mounts(@args)], [
            { source => '/Users/u/proj',          readonly => 0 },
            { source => '/opt/homebrew/share/x',  readonly => 1 },
            { source => '/tmp/legacy',            readonly => 1 },
        ], 'D: bind_mounts reads each bind\'s mode (--mount ...,readonly and -v ...:ro)');
    is_deeply([HostPlatform::bind_mounts('--mount', 'type=bind,source=/a,target=/b,ro=true',
                                         '--mount', 'type=bind,source=/c,target=/d,readonly=false',
                                         '-v', '/e:/f:rw,z')],
        [{ source => '/a', readonly => 1 }, { source => '/c', readonly => 0 }, { source => '/e', readonly => 0 }],
        'D: ro=true reads as read-only; readonly=false and -v ...:rw,z as read-write');

    # A share mounted somewhere else in the VM does not serve its host path:
    # podman looks the bind source up at the same path inside the VM.
    is_deeply([HostPlatform::sources_outside_shares(['/Users/u/.config/containers/x'],
                [{ source => '/Users/u/.config/containers', target => '/etc/containers', readonly => 0 }])],
        ['/Users/u/.config/containers/x'],
        'D: a share whose VM path differs from its host path (-> /etc/containers) covers nothing');

    my $msg = join "\n", HostPlatform::outside_shares_message(\@out, $shares, project => '/Users/u/proj');
    like($msg, qr{/opt/homebrew/share/x}, 'D: the refusal names the unshared source');
    like($msg, qr{rw  /var/folders}, 'D: ...and lists what the machine does share, with each mode');
    like($msg, qr{/Users/u/\.config/containers -> /etc/containers}, 'D: ...a share mounted elsewhere is shown with its VM path');
    unlike($msg, qr/podman machine (?:init|rm)/, 'D: ...and never asks the operator to hand-type podman machine rm/init');
    like($msg, qr/\Q$script\E plan/, 'D: a refused path that is not the project points at podman-machine.pl plan');
    unlike($msg, qr/add-project/, 'D: ...and does not offer add-project for it');

    # The machine podman-machine.pl creates, with NO project shared yet: a
    # launch in any project is refused, and the message names add-project <dir>.
    my $proj = '/Users/u/Projects/other';
    my @launch = ({ source => $proj, readonly => 0 },
                  { source => "$proj/.ccpraxis-local-data/claude-home", readonly => 0 },
                  { source => "$proj/.ccpraxis-local-data/claude-home/.launcher", readonly => 1 },
                  { source => '/Users/u/.claude/ccpraxis/plugins', readonly => 1 },
                  { source => '/Users/u/.claude/ccpraxis/scripts/statusline.pl', readonly => 1 },
                  { source => '/Users/u/.cache/ccpraxis/container-files/almanac-global-counts.json', readonly => 1 });
    my @o2 = HostPlatform::sources_outside_shares(\@launch, $narrow);
    is_deeply(\@o2, [$proj, "$proj/.ccpraxis-local-data/claude-home", "$proj/.ccpraxis-local-data/claude-home/.launcher"],
        'D: narrowed machine: an unlisted project and its claude-home are outside; the install and counts copy are served');
    my $m2 = join "\n", HostPlatform::outside_shares_message(\@o2, $narrow, project => $proj);
    like($m2, qr/\Q$script\E add-project \Q$proj\E/, 'D: ...the refusal names `podman-machine.pl add-project <dir>` for that project');
    like($m2, qr{ro  /Users/u/\.claude/ccpraxis}, 'D: ...and shows the read-only shares as ro');
    unlike($m2, qr/\bplan`/, 'D: ...and adds no plan hint when only the project is missing');

    # Read-write through a read-only share.
    is(HostPlatform::covering_share('/Users/u/Projects/app/src', $narrow)->{source}, '/Users/u/Projects/app',
        'D: covering_share picks the share the path lies under');
    my $nested = [{ source => '/Users/u/w', target => '/Users/u/w', readonly => 1 },
                  { source => '/Users/u/w/rwpart', target => '/Users/u/w/rwpart', readonly => 0 }];
    is(HostPlatform::covering_share('/Users/u/w/rwpart/x', $nested)->{readonly}, 0,
        'D: when shares nest, the deepest one decides the mode');
    my @ro = HostPlatform::rw_binds_under_ro_shares(
        [{ source => '/Users/u/.claude/ccpraxis/plugins', readonly => 1 },
         { source => '/Users/u/.claude/ccpraxis/work', readonly => 0 },
         { source => '/Users/u/Projects/app', readonly => 0 },
         { source => '/elsewhere', readonly => 0 }], $narrow);
    is_deeply(\@ro, [{ source => '/Users/u/.claude/ccpraxis/work', share => '/Users/u/.claude/ccpraxis' }],
        'D: only a READ-WRITE bind under a READ-ONLY share is reported (ro binds and rw shares are fine; unshared is the other check)');
    my $m3 = join "\n", HostPlatform::outside_shares_message([], $narrow, read_only => \@ro, project => '/Users/u/Projects/app');
    like($m3, qr/needs to write through this directory, which the podman machine shares read-only/,
        'D: the read-only refusal says what is wrong');
    like($m3, qr{/Users/u/\.claude/ccpraxis/work\s+\(inside the read-only share /Users/u/\.claude/ccpraxis\)},
        'D: ...names the bind and the read-only share it falls in');
    is_deeply([HostPlatform::share_lines([{ source => '/a', target => '/a', readonly => 1 }, '/b'])], ['ro  /a', 'rw  /b'],
        'D: share_lines: mode, then path (a plain string reads as rw)');
}

# ---------------------------------------------------------------------------
# E. TestSandbox with no container CLI on PATH
# ---------------------------------------------------------------------------
{
    my $lib     = "$Bin/../lib";
    my $scripts = "$Bin/../../scripts";   # MountSpec: real callers live in tests/t, whose $Bin finds it
    my $mod = 'Test' . 'Sandbox';   # spelled apart: this file must not be classified as a container test
    my $run = sub {
        my ($imports) = @_;
        my ($fh, $script) = tempfile(SUFFIX => '.pl', UNLINK => 1);
        print {$fh} "use strict; use warnings; use lib '$lib', '$scripts';\n"
                  . "use $mod qw($imports);\n"
                  . "print \"LOADED\\n\";\n";
        close $fh;
        local $ENV{PATH} = '/usr/bin:/bin';
        local $ENV{CCPRAXIS_TEST_NO_SWEEP} = 1;
        delete local $ENV{CCPRAXIS_CONTAINER_CLI};
        my $out = `"$^X" "$script" 2>&1`;
        return ($? >> 8, $out);
    };
  SKIP: {
        skip 'E: a container CLI is reachable even on PATH=/usr/bin:/bin here', 4
            if grep { system("PATH=/usr/bin:/bin $_ --version >/dev/null 2>&1") == 0 } qw(docker podman);
        my ($rc, $out) = $run->('podman_bin');
        is($rc, 0, 'E: with no CLI, importing a runtime symbol exits 0 (a skip), not 255 (a die)')
            or diag($out);
        like($out, qr/^1\.\.0 # (?:skip|SKIP)\b.*no container CLI/m, 'E: ...as skip_all naming the cause');

        ($rc, $out) = $run->('new_temp_dir');
        is($rc, 0, 'E: catalog-only imports still load with no CLI') or diag($out);
        like($out, qr/^LOADED$/m, 'E: ...and the caller runs');
    }
}

done_testing();
