#!/usr/bin/env perl
# platform: any
# HostPlatform.pm: the host-platform decisions launcher.pl, bootstrap.pl and
# the container-test harness share. Every decision is driven through its
# seams, so nothing here needs a container runtime.
#
#   A. container CLI choice: darwin prefers podman (a Mac may carry an
#      unrelated docker wrapper on PATH); Windows and Linux orders unchanged;
#      CCPRAXIS_CONTAINER_CLI is the only candidate when set.
#   B. the no-CLI message is platform-aware: a Mac is told how to install
#      podman and create its machine, not sent to Docker Desktop.
#   C. canonical_dir: the stored case of a directory on APFS (darwin only).
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
    like($mac, qr/podman machine init/, 'B: darwin no-CLI message says how to create the podman machine');
    like($mac, qr/CCPRAXIS_CONTAINER_CLI/, 'B: darwin no-CLI message names the override');
    unlike($mac, qr/Docker Desktop/, 'B: darwin no-CLI message does not send a Mac user to Docker Desktop');
    my $win = join "\n", HostPlatform::no_cli_message('cygwin');
    like($win, qr/Docker Desktop.*Podman Desktop/s, 'B: Windows no-CLI message is the established wording');

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
