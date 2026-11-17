#!/usr/bin/env perl
# platform: any
# The sandbox container's CLAUDE.md is built for the host that launched it and
# the container runtime in use (ContainerClaudeMd.pm), never copied whole.
#
# The design rule this pins: no agent is handed prose irrelevant to its
# platform. The file used to carry every host's networking facts side by side,
# so a container started from a Mac was told about WSL2's wslrelay.exe and
# `wsl --shutdown`, and about Docker Desktop host names under Podman.
#
#   A. the real template: a darwin launch carries no WSL / Windows / Docker
#      text; a Windows + Podman launch carries the SANDBOX_HOST_IP and 9p
#      facts; each runtime names only its own host-gateway name.
#   B. the shared file alone names no host or runtime.
#   C. every CLAUDE.*.md in container/ is a part some launch can deliver (a
#      misspelt part name would otherwise be silently never delivered).
#   D. render(): the join, byte for byte; render_dir() through its read seam.
#   E. HostPlatform: os_family, runtime_family, host_gateway_args.
#   F. launcher.pl wiring, read as source (never run): the drift hash is taken
#      over the rendered text and both copies write the rendered text, so a
#      changed part triggers "Container CLAUDE.md upstream changed".
#
# Pure: reads the repo's own files and temp files only. Never starts a
# container and never runs launcher.pl.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use Digest::MD5 ();
use HostPlatform ();
use ContainerClaudeMd ();

my $DIR      = "$Bin/../../container";
my $LAUNCHER = "$Bin/../../scripts/launcher.pl";

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub rendered {
    my ($host, $runtime) = @_;
    my $t = ContainerClaudeMd::render_dir($DIR, $host, $runtime);
    BAIL_OUT("render_dir returned undef for $host/$runtime: is $DIR/CLAUDE.md missing?")
        unless defined $t;
    return $t;
}

# Text that only a Windows launch may carry.
my @WINDOWS_ONLY = (qr/\bWSL/i, qr/wslrelay/i, qr/wsl --shutdown/, qr/\b9p\b/,
                    qr/SANDBOX_HOST_IP/, qr/\bWindows\b/);

# ---------------------------------------------------------------------------
# A. the real template, per launch
# ---------------------------------------------------------------------------
{
    my $mac = rendered('macos', 'podman');
    for my $re (@WINDOWS_ONLY) {
        unlike($mac, $re, "A: a darwin + podman launch's CLAUDE.md has no $re");
    }
    unlike($mac, qr/Docker Desktop|host\.docker\.internal/,
        'A: a darwin + podman launch names no Docker host name');
    like($mac, qr/host\.containers\.internal/,
        'A: a darwin + podman launch names host.containers.internal');
    like($mac, qr/runs under Podman/, 'A: ...and says the runtime is Podman');
    like($mac, qr/http:\/\/localhost:/, 'A: ...and gives the user localhost URLs');

    my $win = rendered('windows', 'podman');
    like($win, qr/wslrelay\.exe/, 'A: a Windows + podman launch explains wslrelay.exe');
    like($win, qr/\$SANDBOX_HOST_IP/, 'A: ...tells agents to use $SANDBOX_HOST_IP');
    like($win, qr/wsl --shutdown/, '...and when that value goes stale');
    like($win, qr/\b9p\b/, 'A: ...and that the /project bind mount is 9p');
    like($win, qr/host\.containers\.internal/, 'A: ...and names host.containers.internal');
    unlike($win, qr/host\.docker\.internal/, 'A: ...and no Docker host name');

    my $win_docker = rendered('windows', 'docker');
    unlike($win_docker, qr/SANDBOX_HOST_IP|wslrelay/,
        'A: a Windows + docker launch does not carry the podman-only SANDBOX_HOST_IP text (the launcher sets it only under podman)');
    like($win_docker, qr/\b9p\b/, 'A: ...but does carry the Windows bind-mount fact');
    like($win_docker, qr/host\.docker\.internal/, 'A: ...and names host.docker.internal');

    my $linux = rendered('linux', 'docker');
    for my $re (@WINDOWS_ONLY) {
        unlike($linux, $re, "A: a linux + docker launch's CLAUDE.md has no $re");
    }
    like($linux, qr/host\.docker\.internal/, 'A: a linux + docker launch names host.docker.internal');
    unlike($linux, qr/host\.containers\.internal/, 'A: ...and not the Podman name');

    my $mac_docker = rendered('macos', 'docker');
    unlike($mac_docker, qr/host\.containers\.internal|\bWSL/i,
        'A: a darwin + docker launch names neither the Podman host name nor WSL');
}

# ---------------------------------------------------------------------------
# B. the shared file alone is host- and runtime-neutral
# ---------------------------------------------------------------------------
{
    my $shared = slurp("$DIR/CLAUDE.md");
    ok(defined $shared, 'B: container/CLAUDE.md exists');
    for my $re (@WINDOWS_ONLY, qr/\bmacOS\b/, qr/Docker Desktop/, qr/Docker Engine/,
                qr/host\.docker\.internal/, qr/host\.containers\.internal/) {
        unlike($shared // '', $re, "B: the shared container/CLAUDE.md has no $re");
    }
    like($shared // '', qr/^## This sandbox's runtime and host\s*\n.*\z/ms,
        'B: the shared file ends in the section the parts are appended under');
}

# ---------------------------------------------------------------------------
# C. no orphan parts
# ---------------------------------------------------------------------------
{
    opendir my $dh, $DIR or BAIL_OUT("cannot open $DIR: $!");
    my @parts = sort grep { /\ACLAUDE\..+\.md\z/ } readdir $dh;
    closedir $dh;
    my %known = map { $_ => 1 } ContainerClaudeMd::all_part_names();
    ok(scalar(@parts) >= 2, 'C: container/ carries runtime parts');
    for my $p (@parts) {
        ok($known{$p}, "C: $p is a part some launch delivers");
    }
    for my $r (@ContainerClaudeMd::RUNTIMES) {
        ok(-f "$DIR/CLAUDE.$r.md",
            "C: CLAUDE.$r.md exists, so the closing section is never empty");
    }
}

# ---------------------------------------------------------------------------
# D. render / render_dir
# ---------------------------------------------------------------------------
{
    is(ContainerClaudeMd::render("S\n"), "S\n", 'D: no parts -> the shared file byte for byte');
    is(ContainerClaudeMd::render("S\n", "P1\n", undef, '', "P2\n"), "S\n\nP1\n\nP2\n",
        'D: each part after one blank line; undef and empty parts skipped');
    is(ContainerClaudeMd::render('S', 'P'), "S\n\nP", 'D: a shared file without a final newline gets one');
    is(ContainerClaudeMd::render("S\r\n", "P\r\n"), "S\r\n\r\nP\r\n", 'D: CRLF shared file -> CRLF join');

    is_deeply([ContainerClaudeMd::part_names('macos', 'podman')],
        ['CLAUDE.podman.md', 'CLAUDE.macos.md', 'CLAUDE.macos-podman.md'],
        'D: part order is runtime, host, host-runtime');
    is_deeply([ContainerClaudeMd::part_names('beos', 'lxc')], [],
        'D: an unknown host or runtime selects no part');

    my %files = (
        '/c/CLAUDE.md'                => "shared\n",
        '/c/CLAUDE.podman.md'         => "podman\n",
        '/c/CLAUDE.windows-podman.md' => "winpod\n",
    );
    my $read = sub { $files{ $_[0] } };
    my ($text, $used) = ContainerClaudeMd::render_dir('/c', 'windows', 'podman', read => $read);
    is($text, "shared\n\npodman\n\nwinpod\n", 'D: render_dir appends the parts that exist, in order');
    is_deeply($used, ['CLAUDE.podman.md', 'CLAUDE.windows-podman.md'], 'D: ...and reports which');
    is(scalar ContainerClaudeMd::render_dir('/none', 'macos', 'podman', read => sub { undef }), undef,
        'D: no shared file -> undef');

    # Changing a part that applies changes the drift hash; one that does not
    # apply leaves it alone.
    my $d = tempdir(CLEANUP => 1);
    my $put = sub { my ($n, $c) = @_; open my $fh, '>:raw', "$d/$n" or die $!; print $fh $c; close $fh };
    $put->('CLAUDE.md', "shared\n");
    $put->('CLAUDE.podman.md', "podman v1\n");
    $put->('CLAUDE.windows.md', "windows v1\n");
    my $h1 = Digest::MD5::md5_hex(scalar ContainerClaudeMd::render_dir($d, 'macos', 'podman'));
    $put->('CLAUDE.windows.md', "windows v2\n");
    my $h2 = Digest::MD5::md5_hex(scalar ContainerClaudeMd::render_dir($d, 'macos', 'podman'));
    is($h2, $h1, 'D: editing a part this launch does not use leaves its hash unchanged');
    $put->('CLAUDE.podman.md', "podman v2\n");
    my $h3 = Digest::MD5::md5_hex(scalar ContainerClaudeMd::render_dir($d, 'macos', 'podman'));
    isnt($h3, $h1, 'D: editing a part this launch uses changes its hash');
}

# ---------------------------------------------------------------------------
# E. HostPlatform
# ---------------------------------------------------------------------------
{
    is(HostPlatform::os_family('darwin'), 'macos',   'E: darwin -> macos');
    is(HostPlatform::os_family($_), 'windows', "E: $_ -> windows") for qw(MSWin32 cygwin msys);
    is(HostPlatform::os_family('linux'), 'linux',    'E: linux -> linux');
    is(HostPlatform::runtime_family('podman'), 'podman', 'E: podman -> podman');
    is(HostPlatform::runtime_family('podman.exe'), 'podman', 'E: podman.exe -> podman');
    is(HostPlatform::runtime_family('/opt/homebrew/bin/podman'), 'podman', 'E: a podman path -> podman');
    is(HostPlatform::runtime_family('docker.exe'), 'docker', 'E: docker.exe -> docker');
    is(HostPlatform::runtime_family(undef), 'docker', 'E: undef -> docker (never dies)');
    is_deeply([HostPlatform::host_gateway_args('docker', 'linux')],
        ['--add-host', 'host.docker.internal:host-gateway'],
        'E: Docker Engine on Linux gets host.docker.internal mapped to the host gateway');
    is_deeply([HostPlatform::host_gateway_args('docker.exe', 'msys')], [],
        'E: Windows + docker: nothing added (Docker Desktop provides the name)');
    is_deeply([HostPlatform::host_gateway_args('docker', 'darwin')], [], 'E: macOS + docker: nothing added');
    is_deeply([HostPlatform::host_gateway_args('podman', 'linux')], [], 'E: podman on Linux: nothing added');
}

# ---------------------------------------------------------------------------
# F. launcher wiring (source only)
# ---------------------------------------------------------------------------
{
    my $src = slurp($LAUNCHER);
    ok(defined $src, 'F: launcher.pl readable') or BAIL_OUT('cannot read launcher.pl');
    my $code = join '', map { (my $l = $_) =~ s/^\s*#.*$//; "$l\n" } split /\n/, $src;

    like($code, qr/^use ContainerClaudeMd \(\);/m, 'F: launcher loads ContainerClaudeMd');
    like($code, qr/\$CONTAINER_CLAUDE_MD_TEXT\s*=\s*ContainerClaudeMd::render_dir\(\s*\$CONTAINER_CONFIG,\s*HostPlatform::os_family\(\),\s*HostPlatform::runtime_family\(\$PODMAN\)\)/,
        'F: the text is rendered for this host and this container CLI');
    like($code, qr/\$CURRENT_CLAUDE_MD_HASH\s*=\s*md5_of_string\(\$CONTAINER_CLAUDE_MD_TEXT\)/,
        'F: the drift hash is taken over the rendered text');
    unlike($code, qr/md5_of_file\(\s*"\$CONTAINER_CONFIG\/CLAUDE\.md"\s*\)/,
        'F: nothing hashes the raw shared file any more');
    unlike($code, qr/_copy_file\(\s*"\$CONTAINER_CONFIG\/CLAUDE\.md"/,
        'F: nothing copies the raw shared file into the container any more');
    # Since 2026-11-02 the rendered text reaches the sandbox in ONE place, on
    # every create (Rebuild or not): SandboxSettings::refresh_claude_md, which
    # backs up a copy the sandbox edited and records the render as given.
    my @gives = ($code =~ /SandboxSettings::refresh_claude_md\((.*?)\);/sg);
    is(scalar @gives, 1, 'F: one call gives the sandbox its CLAUDE.md');
    like($gives[0] // '', qr/render\s*=>\s*\$CONTAINER_CLAUDE_MD_TEXT/, 'F: ... the rendered text');
    like($gives[0] // '', qr/last_render\s*=>\s*\$CONTAINER_CLAUDE_MD\b/, 'F: ... recorded as the last render given');
    like($code, qr/_write_file\(\s*\$CLAUDE_MD_HASH_FILE\s*,\s*\$CURRENT_CLAUDE_MD_HASH\s*\)/,
        'F: the first create records the rendered hash');
    like($code, qr/Container CLAUDE\.md upstream changed/,
        'F: the drift still surfaces as a stale reason');
    like($code, qr/SandboxIdentity::blocked_host_args\(\),\s*\n(?:\s*\n)*\s*HostPlatform::host_gateway_args\(\$PODMAN\),/,
        'F: podman create receives host_gateway_args');
}

done_testing();
