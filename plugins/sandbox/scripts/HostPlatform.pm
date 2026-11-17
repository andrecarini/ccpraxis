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
#     read-only or read-write, and which bind mounts fall outside them or
#     would need to write through a read-only share. (WHAT the macOS machine
#     should share is PodmanMachine.pm's business; this module only reads what
#     it does share.)
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
#   darwin: podman, docker -- podman (via the rootful `podman machine` that
#     podman-machine.pl sets up) is the supported runtime on a Mac; docker is
#     only a fallback for a Mac that has nothing else.
#   anything else: docker, podman (unchanged).
sub cli_candidates {
    my ($os) = @_;
    $os = $^O unless defined $os;
    return ('docker.exe', 'podman.exe') if $os =~ /^(MSWin32|cygwin|msys)$/;
    return ('podman', 'docker')         if $os eq 'darwin';
    return ('docker', 'podman');
}

# os_family($os) -> 'windows' | 'macos' | 'linux'. The one spelling of "which
# kind of host is this" for anything chosen per host by file name (the
# container CLAUDE.md parts, ContainerClaudeMd). The Windows family is the same
# set every $WINDOWS_FAMILY test in this plugin uses.
sub os_family {
    my ($os) = @_;
    $os = $^O unless defined $os;
    return 'windows' if $os =~ /^(MSWin32|cygwin|msys)$/;
    return 'macos'   if $os eq 'darwin';
    return 'linux';
}

# runtime_family($cli) -> 'podman' | 'docker'. The launcher's own rule, which
# it spells inline as `$PODMAN =~ /podman/i` wherever behaviour differs: a CLI
# whose name says podman is podman, and anything else speaks docker's CLI.
sub runtime_family {
    my ($cli) = @_;
    return (defined $cli && !ref $cli && $cli =~ /podman/i) ? 'podman' : 'docker';
}

# build_extra_args($cli) -> extra `build` arguments, shared by every image
# build (bootstrap.pl and launcher.pl).
#
# The Containerfile bakes real device nodes into the bp-jail skeleton with
# mknod. Podman leaves CAP_MKNOD out of a build step's default capabilities,
# so even a ROOTFUL machine failed that step (measured 2026-10-30, podman
# 6.1.4: "mknod: Operation not permitted") and the jail fell back to empty-file
# stand-ins. Granting it back is all the build needs. On a rootless machine the
# user namespace still forbids device nodes and the Containerfile records why;
# Docker's build keeps MKNOD by default and has no such flag.
sub build_extra_args {
    my ($cli) = @_;
    return runtime_family($cli) eq 'podman' ? ('--cap-add', 'MKNOD') : ();
}

# host_gateway_args($cli, $os) -> extra `create` arguments that give the
# container a name for the host.
#
# Podman adds host.containers.internal to every container's /etc/hosts, and
# Docker Desktop (Windows, macOS) resolves host.docker.internal by itself.
# Docker Engine on Linux does neither: it defines host.docker.internal only for
# a container created with `--add-host host.docker.internal:host-gateway`.
# Passing that there is what lets the container's CLAUDE.md name one host name
# per runtime and have it be true on every host. Everywhere else this is empty,
# so a Windows or macOS launch is unchanged.
sub host_gateway_args {
    my ($cli, $os) = @_;
    return () unless runtime_family($cli) eq 'docker' && os_family($os) eq 'linux';
    return ('--add-host', 'host.docker.internal:host-gateway');
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

# machine_script_path() -> the podman-machine.pl next to this module: the one
# command that creates and reshapes the macOS podman machine. Messages name it
# by the path of the checkout the caller runs from, so the operator can paste
# it as printed.
sub machine_script_path {
    (my $self = __FILE__) =~ s{\\}{/}g;
    my $abs = Cwd::abs_path($self);
    $abs = $self unless defined $abs && length $abs;
    $abs =~ s{\\}{/}g;
    (my $dir = $abs) =~ s{/[^/]*\z}{};
    return "$dir/podman-machine.pl";
}

# _machine_script_command(@args) -> "perl <script> <args>" for a message.
sub _machine_script_command {
    my @args = @_;
    my $script = machine_script_path();
    $script = qq{"$script"} if $script =~ /\s/;
    return join ' ', 'perl', $script, map { /\s/ ? qq{"$_"} : $_ } @args;
}

# no_cli_message($os) -> the lines to print when no container CLI was found.
sub no_cli_message {
    my ($os) = @_;
    $os = $^O unless defined $os;
    my $var = OVERRIDE_VAR;
    if ($os eq 'darwin') {
        return (
            "ERROR: no container CLI on PATH (looked for podman, docker).",
            "       Install podman (for example `brew install podman`), then create the sandbox's podman machine once: " . _machine_script_command('apply'),
            "       (it prints what it will create; run it again with --confirm to create it).",
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
        return ("  No podman machine exists yet. Create one (WSL2 provider), then start it: podman machine init --provider wsl && podman machine start")
            if $os =~ /^(MSWin32|cygwin|msys)$/;
        # darwin: the machine is created by podman-machine.pl, never by a bare
        # `podman machine init`, whose defaults share /Users, /private and
        # /var/folders read-write and run rootless.
        return ("  No podman machine exists yet. Create the sandbox's machine (rootful, sharing only what the sandbox needs):",
                "    " . _machine_script_command('apply', '--confirm'))
            if $os eq 'darwin';
        return ("  No podman machine exists yet. Create one (rootless is the default), then start it: podman machine init && podman machine start");
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

# parse_machine_inspect($json) -> { name, config_dir, api_socket, state,
# rootful, resources, mounts } | undef.
# `podman machine inspect` prints a JSON array with one element per machine.
# The share list itself is NOT in that output on podman 6.x; it is in the
# machine's own config file, ConfigDir.Path/<Name>.json. `mounts` is the share
# list when an (older) inspect document carries one, else undef.
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
    my $state = (defined $d->{State} && !ref $d->{State}) ? lc $d->{State} : undef;
    return { name => $name, config_dir => $dir, mounts => _mounts_of($d),
             api_socket => $sock, state => $state,
             rootful => boolish($d->{Rootful}),
             resources => _resources_of($d) };
}

# owner_home() -> the home directory the OS records for this user (getpwuid),
# whatever $ENV{HOME} says, or undef (native Windows perl has no getpwuid).
sub owner_home {
    return undef if $^O eq 'MSWin32';
    my @pw = eval { getpwuid($<) };
    return (@pw && defined $pw[7] && length $pw[7]) ? $pw[7] : undef;
}

# parse_machine_config($json) -> [ { source, target, readonly } ] | undef.
# Reads `Mounts[]` from a machine config file (or an inspect document that
# carries Mounts, as older podman versions printed). `readonly` is the
# mount's `ReadOnly` flag -- what `podman machine init -v SRC:DST:ro` records.
sub parse_machine_config {
    my ($raw) = @_;
    my $d = _decode_doc($raw);
    return undef unless $d;
    return _mounts_of($d);
}

# parse_machine_config_details($json) -> { mounts, rootful, resources } | undef.
# The other fields PodmanMachine.pm plans from: the machine's own record of
# whether it is rootful (HostUser.Rootful) and its Resources block.
sub parse_machine_config_details {
    my ($raw) = @_;
    my $d = _decode_doc($raw);
    return undef unless $d;
    my $hu = ref $d->{HostUser} eq 'HASH' ? $d->{HostUser} : {};
    # "Mounts": null is a machine created with no shares at all: an empty
    # list, not "could not tell".
    my $mounts = (exists $d->{Mounts} && !defined $d->{Mounts}) ? [] : _mounts_of($d);
    return { mounts => $mounts, rootful => boolish($hu->{Rootful}),
             resources => _resources_of($d) };
}

sub _decode_doc {
    my ($raw) = @_;
    return undef unless defined $raw && !ref $raw && $raw =~ /\S/;
    my $d = eval { JSON::PP->new->decode($raw) };
    return undef unless defined $d;
    $d = $d->[0] if ref $d eq 'ARRAY';
    return ref $d eq 'HASH' ? $d : undef;
}

# boolish($v) -> 1 | 0 | undef: a JSON boolean, or a 1/0/true/false/yes/no
# string, as podman spells flags across versions; undef when it is neither.
sub boolish {
    my ($v) = @_;
    return undef unless defined $v;
    return $v ? 1 : 0 if JSON::PP::is_bool($v);
    return undef if ref $v;
    return 1 if $v =~ /\A(?:1|true|yes)\z/i;
    return 0 if $v =~ /\A(?:0|false|no|)\z/i;
    return undef;
}

# _resources_of($doc) -> { cpus, memory (MiB), disk (GiB) } with only the
# fields the document carries as non-negative integers, or undef.
sub _resources_of {
    my ($d) = @_;
    return undef unless ref $d eq 'HASH' && ref $d->{Resources} eq 'HASH';
    my $r = $d->{Resources};
    my %out;
    for ([cpus => 'CPUs'], [memory => 'Memory'], [disk => 'DiskSize']) {
        my ($k, $field) = @$_;
        my $v = $r->{$field};
        $out{$k} = 0 + $v if defined $v && !ref $v && $v =~ /\A\d+\z/;
    }
    return \%out;
}

sub _clean_path {
    my ($p) = @_;
    return undef unless defined $p && !ref $p && $p =~ m{\A/};
    $p =~ s{/+\z}{} unless $p eq '/';
    return $p;
}

sub _mounts_of {
    my ($d) = @_;
    return undef unless ref $d eq 'HASH' && ref $d->{Mounts} eq 'ARRAY';
    my @out;
    for my $m (@{ $d->{Mounts} }) {
        next unless ref $m eq 'HASH';
        my $s = _clean_path($m->{Source});
        next unless defined $s;
        my $t = _clean_path($m->{Target});
        push @out, { source => $s, target => (defined $t ? $t : $s),
                     readonly => (boolish($m->{ReadOnly}) ? 1 : 0) };
    }
    return \@out;
}

# machine_shares(%seams) -> [ { source, target, readonly } ] | undef: the host
# directories the podman machine shares into its VM, each with its mode.
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

# bind_mounts(@podman_args) -> ( { source, readonly } ... ) for every bind
# mount in a podman argv, from both spellings the launcher emits:
# `--mount type=bind,source=X,...[,readonly]` and an unconverted
# `-v X:Y[:opts]`. Named volumes are not host paths and are skipped.
sub bind_mounts {
    my @args = @_;
    my @out;
    for (my $i = 0; $i < @args; $i++) {
        my $a = $args[$i];
        next unless defined $a;
        if ($a eq '--mount' && defined $args[$i + 1]) {
            my %kv = map { /\A([^=]+)=(.*)\z/ ? ($1 => $2) : ($_ => 1) } split /,/, $args[$i + 1];
            my $type = $kv{type} // '';
            my $src  = $kv{source} // $kv{src};
            my $ro   = 0;
            for my $k (qw(readonly ro)) {
                next unless exists $kv{$k};
                $ro = 1 if $kv{$k} eq '1' || $kv{$k} =~ /\Atrue\z/i;
            }
            push @out, { source => $src, readonly => $ro }
                if $type eq 'bind' && defined $src && length $src;
            $i++;
        } elsif ($a eq '-v' && defined $args[$i + 1]) {
            my ($src, $opts) = $args[$i + 1] =~ m{\A(/[^:]*):[^:]+(?::(.*))?\z};
            push @out, { source => $src, readonly => ((defined $opts && $opts =~ /(?:\A|,)ro(?:,|\z)/) ? 1 : 0) }
                if defined $src;
            $i++;
        }
    }
    return @out;
}

# bind_sources(@podman_args) -> host paths of every bind mount (see bind_mounts).
sub bind_sources { return map { $_->{source} } bind_mounts(@_) }

sub _src_of   { my ($x) = @_; return ref $x eq 'HASH' ? $x->{source} : $x }
sub _under    { my ($p, $dir) = @_; return $dir eq '/' || $p eq $dir || index($p, "$dir/") == 0 }

# covering_share($path, \@shares) -> the share record the VM serves $path
# from, or undef. A share covers a path that is the share itself or lies
# beneath it, by whole path components (/Users covers /Users/a, never
# /Users2), and only when it is mounted at its own path inside the VM: podman
# hands a bind source to the VM as written, so a share mounted elsewhere (the
# default ~/.config/containers -> /etc/containers) does not make that host
# path visible there. When shares nest, the deepest one is the mount the VM
# actually reads through, so it decides the mode. Compared LITERALLY: /tmp/x
# is NOT covered by a /private share even though /tmp is a symlink into it on
# macOS (measured: `statfs /tmp/x: no such file or directory`). Plain strings
# are accepted as read-write shares mounted at their own path.
sub covering_share {
    my ($path, $shares) = @_;
    return undef unless defined $path && length $path && ref $shares eq 'ARRAY';
    my $best;
    for my $sh (@$shares) {
        my $rec = ref $sh eq 'HASH' ? $sh : { source => $sh, target => $sh, readonly => 0 };
        my $src = $rec->{source};
        next unless defined $src && length $src;
        my $tgt = defined $rec->{target} ? $rec->{target} : $src;
        next unless $tgt eq $src;
        next unless _under($path, $src);
        $best = $rec if !$best || length($src) > length($best->{source});
    }
    return $best;
}

# sources_outside_shares(\@sources, \@shares) -> the sources no share covers
# (see covering_share). Sources may be paths or bind records.
sub sources_outside_shares {
    my ($sources, $shares) = @_;
    return () unless ref $sources eq 'ARRAY' && ref $shares eq 'ARRAY';
    my @out;
    my %seen;
    for my $x (@$sources) {
        my $s = _src_of($x);
        next unless defined $s && length $s;
        next if covering_share($s, $shares);
        push @out, $s unless $seen{$s}++;
    }
    return @out;
}

# rw_binds_under_ro_shares(\@binds, \@shares) -> ( { source, share } ... ) for
# every READ-WRITE bind whose covering share is read-only. A container that
# must write through such a bind would be refused by the machine (or, where
# the provider does not enforce the flag, write through a share the operator
# declared read-only); either way the launch is wrong, and saying so before
# `podman create` names the cause. Read-only binds may lie anywhere.
sub rw_binds_under_ro_shares {
    my ($binds, $shares) = @_;
    return () unless ref $binds eq 'ARRAY' && ref $shares eq 'ARRAY';
    my @out;
    my %seen;
    for my $b (@$binds) {
        next unless ref $b eq 'HASH' && !$b->{readonly};
        my $s = $b->{source};
        next unless defined $s && length $s;
        my $sh = covering_share($s, $shares);
        next unless $sh && $sh->{readonly};
        push @out, { source => $s, share => $sh->{source} } unless $seen{$s}++;
    }
    return @out;
}

# share_lines(\@shares) -> one display line per share: "rw  /src" or
# "ro  /src -> /target".
sub share_lines {
    my ($shares) = @_;
    return () unless ref $shares eq 'ARRAY';
    return map {
        my $r = ref $_ eq 'HASH' ? $_ : { source => $_, target => $_, readonly => 0 };
        my $t = defined $r->{target} ? $r->{target} : $r->{source};
        ($r->{readonly} ? 'ro' : 'rw') . "  $r->{source}" . ($t ne $r->{source} ? " -> $t" : '');
    } @$shares;
}

# outside_shares_message(\@outside, \@shares, %o) -> the refusal text.
#   project    => the project directory being launched; when a refused path is
#                 the project or lies inside it, the remedy names it
#   read_only  => [ { source, share } ] from rw_binds_under_ro_shares
# The remedy is podman-machine.pl, never a hand-typed `podman machine init`:
# the machine's share list is machinery's to keep (an explicit --volume
# replaces podman's whole default list, and a share typed by hand is lost on
# the next recreate).
sub outside_shares_message {
    my ($outside, $shares, %o) = @_;
    $outside = [] unless ref $outside eq 'ARRAY';
    my $ro      = ref $o{read_only} eq 'ARRAY' ? $o{read_only} : [];
    my $project = $o{project};
    my @l;
    if (@$outside) {
        push @l,
            "ERROR: the podman machine cannot see " . (@$outside == 1 ? 'this directory' : 'these directories')
                . ", so the sandbox cannot bind-mount " . (@$outside == 1 ? 'it' : 'them') . ":",
            (map { "         $_" } @$outside);
    }
    if (@$ro) {
        push @l,
            (@l ? "       It also" : "ERROR: the sandbox")
                . " needs to write through " . (@$ro == 1 ? 'this directory' : 'these directories')
                . ", which the podman machine shares read-only:",
            (map { "         $_->{source}" . ($_->{share} ne $_->{source} ? "   (inside the read-only share $_->{share})" : '') } @$ro);
    }
    push @l, "       The machine shares only these host folders (rw = read-write, ro = read-only):";
    my @sl = share_lines($shares);
    push @l, @sl ? (map { "         $_" } @sl) : ("         (none)");

    my $is_project = sub {
        my ($p) = @_;
        return defined $project && length $project && defined $p && _under($p, $project);
    };
    if (grep { $is_project->($_) } (@$outside, map { $_->{source} } @$ro)) {
        push @l,
            "       To share this project with the machine (read-write), run:",
            "         " . _machine_script_command('add-project', $project),
            "       It prints what it will change and recreates the machine only when run again with --confirm.";
    }
    if (grep { !$is_project->($_) } (@$outside, map { $_->{source} } @$ro)) {
        push @l,
            "       The other folders are ones every sandbox needs; `" . _machine_script_command('plan')
                . "` shows what the machine should share, and `apply --confirm` sets it up.";
    }
    return @l;
}

1;
