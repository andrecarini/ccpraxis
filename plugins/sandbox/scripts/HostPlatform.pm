package HostPlatform;
# HostPlatform.pm -- the host-platform decisions launcher.pl, bootstrap.pl and
# the container-test harness used to make separately, each with its own copy:
#
#   * which container CLI to drive (and the CCPRAXIS_CONTAINER_CLI override);
#   * what to tell an operator whose runtime is missing.
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

1;
