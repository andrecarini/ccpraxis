package HostPlatform;
# HostPlatform.pm -- the host-platform decisions launcher.pl, bootstrap.pl and
# the container-test harness used to make separately, each with its own copy:
#
#   * which container CLI to drive (and the CCPRAXIS_CONTAINER_CLI override);
#   * what to tell an operator whose runtime is missing or whose podman
#     machine does not exist yet;
#   * the case-canonical spelling of a directory on a case-insensitive
#     filesystem (APFS);
#   * which host directories a podman machine actually shares with its VM,
#     and which bind-mount sources fall outside them.
#
# WHY ONE MODULE. The CLI detection was three verbatim copies (launcher.pl,
# bootstrap.pl, tests/lib/TestSandbox.pm) that all preferred docker. On macOS
# that preference is wrong twice over: podman is the runtime this project
# supports there, and a Mac can carry an unrelated docker on PATH (a Lima VM's
# wrapper, Docker Desktop) that the sandbox must never silently adopt. Fixing
# it three times is how the three copies would drift.
#
# Windows behaviour is deliberately UNCHANGED: the Windows family still probes
# docker.exe before podman.exe, exactly as before. Linux keeps docker-then-
# podman. Only darwin changes order.
#
# Every decision is a pure function with its I/O passed in as a seam, so the
# tests drive it without a container runtime; the default seams are the real
# probes.
use strict;
use warnings;
use Cwd ();
use JSON::PP ();

our $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/ ? 1 : 0;
our $DARWIN         = $^O eq 'darwin' ? 1 : 0;

# The override's name, in one place, for the messages that mention it.
use constant OVERRIDE_VAR => 'CCPRAXIS_CONTAINER_CLI';

# cli_candidates($os) -> the CLIs to probe, most preferred first.
#   Windows family: docker.exe, podman.exe -- named with .exe on purpose
#     (Git-for-Windows perl's PATH search finds an extensionless shell-wrapper
#     shim first and fails to spawn it).
#   darwin: podman, docker -- podman (rootless, via `podman machine`) is the
#     supported runtime on a Mac; docker is only a fallback for a Mac that has
#     nothing else.
#   anything else: docker, podman (unchanged).
sub cli_candidates {
    my ($os) = @_;
    $os = $^O unless defined $os;
    return ('docker.exe', 'podman.exe') if $os =~ /^(MSWin32|cygwin|msys)$/;
    return ('podman', 'docker')         if $os eq 'darwin';
    return ('docker', 'podman');
}

# _cli_responds($cli) -> 1 if `$cli --version` exits 0. The only reliable
# check on Windows (see cli_candidates); harmless everywhere else.
sub _cli_responds {
    my ($cli) = @_;
    return system("$cli --version > /dev/null 2>&1") == 0 ? 1 : 0;
}

# valid_override($value) -> 1|0. The CLI name is interpolated into shell
# command strings throughout the launcher (`$PODMAN inspect ...`), so an
# override is limited to characters that are inert there: a bare command name
# or a path without spaces or shell metacharacters.
sub valid_override {
    my ($v) = @_;
    return 0 unless defined $v && !ref $v && length $v;
    return $v =~ m{\A[A-Za-z0-9._/:\\+-]+\z} ? 1 : 0;
}

# detect_container_cli(%seams) -> ($cli, $error)
#   env   => hashref (default \%ENV)
#   os    => $^O override (default $^O)
#   probe => sub { $cli -> 1|0 } (default: `$cli --version` exits 0)
#
# CCPRAXIS_CONTAINER_CLI, when set and non-empty, is the ONLY candidate: an
# operator who names a CLI gets that CLI or an error naming it, never a quiet
# fall-back to something else. Unset, the platform's candidates are probed in
# order. ($undef, undef) means "nothing found"; ($undef, $msg) means the
# override itself is unusable and $msg says why.
sub detect_container_cli {
    my (%o) = @_;
    my $env   = ref $o{env} eq 'HASH' ? $o{env} : \%ENV;
    my $os    = defined $o{os} ? $o{os} : $^O;
    my $probe = ref $o{probe} eq 'CODE' ? $o{probe} : \&_cli_responds;
    my $var   = OVERRIDE_VAR;

    my $override = $env->{$var};
    if (defined $override && length $override) {
        return (undef, "$var='$override' is not a usable command (allowed: letters, digits and . _ / : \\ + -, no spaces)")
            unless valid_override($override);
        return ($override, undef) if $probe->($override);
        return (undef, "$var='$override' does not respond to `$override --version`");
    }
    for my $c (cli_candidates($os)) {
        return ($c, undef) if $probe->($c);
    }
    return (undef, undef);
}

# no_cli_message($os) -> the lines to print when no container CLI was found.
sub no_cli_message {
    my ($os) = @_;
    $os = $^O unless defined $os;
    my $var = OVERRIDE_VAR;
    if ($os eq 'darwin') {
        return (
            "ERROR: no container CLI on PATH (looked for podman, docker).",
            "       Install podman (for example `brew install podman`), then create and start its",
            "       rootless VM once:  podman machine init && podman machine start",
            "       To use a CLI under another name or path, set $var.",
        );
    }
    if ($os =~ /^(MSWin32|cygwin|msys)$/) {
        return (
            "ERROR: no container CLI on PATH (looked for docker, podman).",
            "       Install Docker Desktop (https://docker.com) or Podman Desktop (https://podman-desktop.io/) and re-run.",
        );
    }
    return (
        "ERROR: no container CLI on PATH (looked for docker, podman).",
        "       Install podman or docker with your package manager and re-run.",
        "       To use a CLI under another name or path, set $var.",
    );
}

# machine_remedy_lines($os, $machine_state) -> what to run when the podman
# machine is not usable. $machine_state is one of Dashboard::
# classify_machine_state's words ('absent', 'stopped', ...). 'absent' is the
# case a bare "start it" cannot fix: there is nothing to start until
# `podman machine init` has created one.
sub machine_remedy_lines {
    my ($os, $state) = @_;
    $os = $^O unless defined $os;
    $state = '' unless defined $state;
    if ($state eq 'absent') {
        return $os =~ /^(MSWin32|cygwin|msys)$/
            ? ("  No podman machine exists yet. Create one (WSL2 provider), then start it:",
               "    podman machine init --provider wsl",
               "    podman machine start")
            : ("  No podman machine exists yet. Create one (rootless is the default), then start it:",
               "    podman machine init",
               "    podman machine start");
    }
    return ("  Try, in a terminal:   podman machine start");
}

# canonical_dir($path) -> $path spelled with the case the filesystem stores.
#
# APFS is case-insensitive, so `cd ~/projects/foo` works for a directory named
# ~/Projects/foo -- and Cwd::abs_path keeps the TYPED case on macOS. Every
# identity the launcher derives from the project path (the container name's
# hash, the claude-home location it reports, the host session directory that
# Claude Code itself names from getcwd()) would then differ between two
# spellings of one directory. getcwd() after a chdir reports the stored case,
# so that is the canonical form.
#
# darwin only; everywhere else, and for anything that is not a directory we
# can enter, the input is returned unchanged. The caller's working directory
# is restored before returning.
sub canonical_dir {
    my ($p, %o) = @_;
    my $os = defined $o{os} ? $o{os} : $^O;
    return $p unless $os eq 'darwin';
    return $p unless defined $p && !ref $p && length $p && -d $p;
    my $orig = Cwd::getcwd();
    return $p unless defined $orig && length $orig;
    chdir($p) or return $p;
    my $canon = Cwd::getcwd();
    chdir($orig);
    return (defined $canon && length $canon) ? $canon : $p;
}

# parse_machine_inspect($json) -> { name => ..., config_dir => ... } | undef.
# `podman machine inspect` prints a JSON array with one element per machine.
# The share list itself is NOT in that output on podman 6.x; it is in the
# machine's own config file, ConfigDir.Path/<Name>.json.
sub parse_machine_inspect {
    my ($raw) = @_;
    return undef unless defined $raw && !ref $raw && $raw =~ /\S/;
    my $d = eval { JSON::PP->new->decode($raw) };
    return undef unless defined $d;
    $d = $d->[0] if ref $d eq 'ARRAY';
    return undef unless ref $d eq 'HASH';
    my $name = $d->{Name};
    my $dir  = ref $d->{ConfigDir} eq 'HASH' ? $d->{ConfigDir}{Path} : undef;
    return undef unless defined $name && !ref $name && length $name;
    my $ci   = ref $d->{ConnectionInfo} eq 'HASH' ? $d->{ConnectionInfo} : {};
    my $sock = ref $ci->{PodmanSocket} eq 'HASH' ? $ci->{PodmanSocket}{Path} : undef;
    $sock = undef unless defined $sock && !ref $sock && $sock =~ m{\A/};
    return { name => $name, config_dir => $dir, mounts => _mount_sources_of($d),
             api_socket => $sock };
}

# owner_home() -> the home directory the OS records for this user (getpwuid),
# whatever $ENV{HOME} says, or undef (native Windows perl has no getpwuid).
sub owner_home {
    return undef if $^O eq 'MSWin32';
    my @pw = eval { getpwuid($<) };
    return (@pw && defined $pw[7] && length $pw[7]) ? $pw[7] : undef;
}

# parse_machine_config($json) -> [ share sources ] | undef. Reads the
# `Mounts[].Source` list from a machine config file (or an inspect document
# that carries Mounts, as older podman versions printed).
sub parse_machine_config {
    my ($raw) = @_;
    return undef unless defined $raw && !ref $raw && $raw =~ /\S/;
    my $d = eval { JSON::PP->new->decode($raw) };
    return undef unless defined $d;
    $d = $d->[0] if ref $d eq 'ARRAY';
    return undef unless ref $d eq 'HASH';
    return _mount_sources_of($d);
}

sub _mount_sources_of {
    my ($d) = @_;
    return undef unless ref $d eq 'HASH' && ref $d->{Mounts} eq 'ARRAY';
    my @src;
    for my $m (@{ $d->{Mounts} }) {
        next unless ref $m eq 'HASH';
        my $s = $m->{Source};
        next unless defined $s && !ref $s && $s =~ m{\A/};
        $s =~ s{/+\z}{} unless $s eq '/';
        push @src, $s;
    }
    return \@src;
}

# machine_shares(%seams) -> [ host directories shared into the VM ] | undef.
#   inspect   => sub { raw `podman machine inspect` stdout, or undef }
#   read_file => sub { $path -> contents or undef }
# undef means "could not tell" and must be treated as such by the caller --
# never as "nothing is shared", which would refuse every launch.
sub machine_shares {
    my (%o) = @_;
    my $inspect = ref $o{inspect} eq 'CODE' ? $o{inspect} : sub { undef };
    my $read    = ref $o{read_file} eq 'CODE' ? $o{read_file} : \&_slurp;
    my $info = parse_machine_inspect(scalar $inspect->());
    return undef unless $info;
    return $info->{mounts} if ref $info->{mounts} eq 'ARRAY' && @{ $info->{mounts} };
    return undef unless defined $info->{config_dir} && length $info->{config_dir};
    return parse_machine_config(scalar $read->("$info->{config_dir}/$info->{name}.json"));
}

sub _slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# bind_sources(@podman_args) -> host paths of every bind mount in a podman
# argv, from both spellings the launcher emits: `--mount type=bind,source=X,...`
# and an unconverted `-v X:Y[:opts]`. Named volumes are not host paths and are
# skipped.
sub bind_sources {
    my @args = @_;
    my @out;
    for (my $i = 0; $i < @args; $i++) {
        my $a = $args[$i];
        next unless defined $a;
        if ($a eq '--mount' && defined $args[$i + 1]) {
            my %kv = map { /\A([^=]+)=(.*)\z/ ? ($1 => $2) : ($_ => 1) } split /,/, $args[$i + 1];
            my $type = $kv{type} // '';
            my $src  = $kv{source} // $kv{src};
            push @out, $src if $type eq 'bind' && defined $src && length $src;
            $i++;
        } elsif ($a eq '-v' && defined $args[$i + 1]) {
            my ($src) = $args[$i + 1] =~ m{\A(/[^:]*):};
            push @out, $src if defined $src;
            $i++;
        }
    }
    return @out;
}

# sources_outside_shares(\@sources, \@shares) -> the sources no share covers.
# A share covers a source that is the share itself or lies beneath it, by
# whole path components (/Users covers /Users/a, never /Users2). Compared
# LITERALLY: podman hands the path to the VM as written, so /tmp/x is NOT
# covered by a /private share even though /tmp is a symlink into it on macOS
# (measured: `statfs /tmp/x: no such file or directory`).
sub sources_outside_shares {
    my ($sources, $shares) = @_;
    return () unless ref $sources eq 'ARRAY' && ref $shares eq 'ARRAY';
    my @out;
    my %seen;
    SRC: for my $s (@$sources) {
        next unless defined $s && length $s;
        for my $sh (@$shares) {
            next unless defined $sh && length $sh;
            next SRC if $sh eq '/' || $s eq $sh || index($s, "$sh/") == 0;
        }
        push @out, $s unless $seen{$s}++;
    }
    return @out;
}

# outside_shares_message(\@outside, \@shares) -> the refusal text.
sub outside_shares_message {
    my ($outside, $shares) = @_;
    my @l = (
        "ERROR: the podman machine cannot see " . (@$outside == 1 ? 'this directory' : 'these directories')
            . ", so the sandbox cannot bind-mount " . (@$outside == 1 ? 'it' : 'them') . ":",
        (map { "         $_" } @$outside),
        "       A podman machine only shares the host folders it was created with:",
        (map { "         $_" } @$shares),
        "       Move the project under one of those folders, or recreate the machine sharing it too:",
        "         podman machine rm, then podman machine init with one --volume <dir>:<dir> per folder",
        "         to share (an explicit --volume replaces the default list, so repeat the ones above).",
    );
    return @l;
}

1;
