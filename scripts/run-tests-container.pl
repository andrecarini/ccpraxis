#!/usr/bin/env perl
# run-tests-container.pl -- a throwaway, CPU- and memory-capped run-mode that
# executes a given set of .t files inside the EXISTING claude-sandbox:latest
# image, with the repo tree landed on the container's own overlay filesystem
# rather than the /project bind mount launcher.pl uses for the interactive
# sandbox. Spec:
#   .ccpraxis-local-data/blueprints/test-platform-split/specs/05-container-lane-spec.md
#
# WHY: bind-mount I/O on Windows/WSL2 is an order of magnitude slower per file
# than the container's own native overlay -- see
# plugins/butler/skills/coordinator-protocol/SKILL.md's "Fast test I/O"
# section. This file is a standalone, self-disposing lane; nothing wires it
# into scripts/run-tests.pl's routing yet (that is a separate package).
#
# THIS FILE IS DUAL-PURPOSE: a script AND a requireable library. Its top-level
# statements are constants, `use`, and `sub` definitions only -- no
# argv-parsing, no podman call, no container creation happens merely by
# requiring this file. The actual run happens in the main entry point,
# invoked only by this file's own last line. plugins/butler/tests/t/container-lane.t
# requires this file to reach every sub/constant below directly, unqualified
# (neither file declares `package`, so both are main::).
#
# DECISION: reuse the existing image, never build one (Decision 5 -- no
# second Containerfile -- and additionally: no build-triggering either).
# Building duplicates launcher.pl's own build orchestration (lock, staleness
# checks, interactive rebuild prompt) and a `podman build` here is
# multi-minute and network-dependent -- an unattended lane silently paying
# that cost the first time it runs is precisely the surprise-expense this
# initiative exists to eliminate. If the image is absent, this file REFUSES;
# it never calls podman build or anything resembling launcher.pl's own
# build_image().
#
# DECISION: --entrypoint sleep is mandatory. The image's ENTRYPOINT is
# /usr/local/bin/sandbox-heartbeat (Containerfile:288); without the override
# a trailing "sleep infinity" is passed as ARGUMENTS to the heartbeat, not
# run as a command -- a runtime break, not a review one.
#
# DECISION: every container-side path is embedded inside a single `sh -c`
# string, never passed as a bare leading-slash argv element next to a native
# podman/docker binary. This is the MSYS2 rewrite that blinded the sandbox
# busy-lease probe for three weeks (see
# plugins/sandbox/tests/t/busy-lease-path-conversion.t): MSYS2 silently
# rewrites a bare POSIX-looking argv element on the way to a native Windows
# binary. sh -c is correct under either conversion state and cannot be broken
# by a caller's environment.
#
# DECISION: the tree is materialized via `git archive REF | podman exec -i
# ... sh -c 'tar -x -C ...'` -- a real fork/pipe/exec, no shell string, so
# there is no outer-shell quoting layer to defend. This only ever reflects a
# git ref (default HEAD); uncommitted/untracked changes are NOT reflected --
# a stated, permanent limitation, not a silent gap.
#
# DECISION 14 (container disposal, three separately-mechanized obligations,
# because a WSL VM memory kill takes the podman daemon and every container
# down at once with nothing left inside or beside the VM able to clean up):
#   (a) normal exit removes the container (main()'s own last act).
#   (b) an interrupted run removes it (%SIG handlers + END, re-raising with
#       the default disposition afterward).
#   (c) the NEXT run sweeps orphans by this lane's own
#       ccpraxis-container-lane- prefix, before creating its own container --
#       this is what covers the VM-kill case, which (a)/(b) cannot.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Temp ();
use POSIX ();

our $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $WINDOWS_FAMILY;

# ---------------------------------------------------------------------------
# Named constants -- 100% new surface (no existing --cpus/--memory flag
# anywhere under plugins/** to extend). Value justification lives in the spec
# (section 2.2): both are sized relative to the one documented WSL-VM-level
# ceiling this repo has ever written down (bootstrap.pl:405, --cpus 4
# --memory 3584), leaving headroom for the podman daemon and everything else
# on the host rather than letting one throwaway container saturate the VM.
# ---------------------------------------------------------------------------
our $IMAGE                 = 'claude-sandbox:latest';
our $CONTAINER_LANE_CPUS   = '2';       # podman --cpus value (string)
our $CONTAINER_LANE_MEMORY = '1536m';   # podman --memory value (string)
our $CONTAINER_NAME_PREFIX = 'ccpraxis-container-lane-';
our $NATIVE_TREE_ROOT      = '/root/ccpraxis-container-lane';

our $ACTIVE_CONTAINER_NAME;   # undef until main() creates one; cleared after removal
our $ACTIVE_PODMAN_BIN;

my $COUNTER = 0;
my $PODMAN_CACHE;

# ---------------------------------------------------------------------------
# podman_bin() -- CLI detection. Deliberately does NOT die (unlike
# TestSandbox::_detect_container_cli, which dies at use time): this file must
# be requireable purely for its pure builders, with zero cost, even on a box
# with no container CLI at all.
# ---------------------------------------------------------------------------
sub podman_bin {
    return $PODMAN_CACHE if defined $PODMAN_CACHE;
    for my $c ($WINDOWS_FAMILY ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        if (system("$c --version > /dev/null 2>&1") == 0) { return $PODMAN_CACHE = $c }
    }
    return $PODMAN_CACHE = '';   # checked, absent -- falsy, never undef after the first call
}

# ---------------------------------------------------------------------------
# _podman_capture(@argv) -> ($rc, $out)
# The one podman-invocation primitive for every call that is NOT part of the
# extraction pipeline: run (container create), rm (disposal), ps -a (orphan
# listing), image inspect. Real fork+exec(LIST), no outer shell, combined
# stdout+stderr captured through a real temp file (reopening STDOUT/STDERR
# onto an in-memory scalar fails with "Bad file descriptor" on this host).
# ---------------------------------------------------------------------------
sub _podman_capture {
    my @argv = @_;
    my ($fh, $tmp) = File::Temp::tempfile();
    close $fh;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $tmp) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
        open(STDIN, '<', '/dev/null');
        exec(@argv) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    open my $rfh, '<', $tmp or die "open $tmp: $!";
    local $/; my $out = <$rfh>; close $rfh; unlink $tmp;
    return ($rc, $out // '');
}

# ---------------------------------------------------------------------------
# image_present($podman, $image) -> bool
# DECISION: refuse, never build. Runs `$podman image inspect $image` and
# returns true iff exit code is 0.
# ---------------------------------------------------------------------------
sub image_present {
    my ($podman, $image) = @_;
    my ($rc, undef) = _podman_capture($podman, 'image', 'inspect', $image);
    return $rc == 0 ? 1 : 0;
}

# ---------------------------------------------------------------------------
# build_run_argv($podman, $name) -> @argv  (pure, no I/O). Exactly 13
# elements. --entrypoint sleep is required -- see the file header.
# ---------------------------------------------------------------------------
sub build_run_argv {
    my ($podman, $name) = @_;
    return (
        $podman, 'run', '-d', '--name', $name,
        '--cpus', $CONTAINER_LANE_CPUS,
        '--memory', $CONTAINER_LANE_MEMORY,
        '--entrypoint', 'sleep',
        $IMAGE, 'infinity',
    );
}

# ---------------------------------------------------------------------------
# build_extract_argv($podman, $name) -> @argv (pure). Exactly 7 elements.
# The container-side path is embedded inside a single sh -c string.
# ---------------------------------------------------------------------------
sub build_extract_argv {
    my ($podman, $name) = @_;
    return (
        $podman, 'exec', '-i', $name, 'sh', '-c',
        "mkdir -p '$NATIVE_TREE_ROOT' && tar -x -C '$NATIVE_TREE_ROOT'",
    );
}

# ---------------------------------------------------------------------------
# materialize_tree($podman, $name, $ref, $project_root) -> ($git_rc, $extract_rc)
# Real fork/pipe/exec: `git archive $ref` on the HOST, piped straight into
# `podman exec -i $name sh -c 'tar -x -C ...'`. No outer shell, no host temp
# file, so there is no shell-string quoting layer for MSYS2 to mangle. Only
# ever reflects a git ref (default HEAD, chosen by the caller) --
# uncommitted/untracked changes are NOT reflected.
#
# NOTE: this file's own `exec('git', ...)` call below is Perl's exec builtin
# invoking git-archive on the HOST -- it has no quoted 'exec' SUBCOMMAND
# literal in it, so it is not a podman/docker exec-argv construction site and
# is correctly excluded from criterion 6's bare-path scan.
# ---------------------------------------------------------------------------
# Hand-translate a POSIX-style host path (e.g. /c/Development/ccpraxis, what
# Cwd::abs_path returns on this host's Git-for-Windows perl) to the
# forward-slash Windows form (C:/Development/ccpraxis) that native git.exe
# accepts directly -- matching the repo's own winify_path/git_path
# convention (plugins/sandbox/scripts/MountSpec.pm, plugins/steward/scripts/vault-sync.pl).
# Required precisely BECAUSE $ENV{MSYS2_ARG_CONV_EXCL} is set above: with
# conversion disabled, a bare /c/... argv element reaches git.exe
# unconverted, and this repo's native git.exe cannot resolve it ("fatal:
# cannot change to '/c/...'") -- the opt-out and the hand-translation are one
# technique, not alternatives (see CLAUDE.md's MSYS2 section).
sub _winify_path {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless $WINDOWS_FAMILY;
    $p =~ s{^/([a-zA-Z])/}{uc($1) . ':/'}e;
    return $p;
}

sub materialize_tree {
    my ($podman, $name, $ref, $project_root) = @_;
    pipe(my $rd, my $wr) or die "pipe: $!";
    my $git_pid = fork();
    die "fork (git): $!" unless defined $git_pid;
    if ($git_pid == 0) {
        close $rd;
        open(STDOUT, '>&', $wr) or POSIX::_exit(126);
        close $wr;
        open(STDIN, '<', '/dev/null');
        exec('git', '-C', _winify_path($project_root), 'archive', $ref) or POSIX::_exit(127);
    }
    close $wr;
    my $extract_pid = fork();
    die "fork (extract): $!" unless defined $extract_pid;
    if ($extract_pid == 0) {
        open(STDIN, '<&', $rd) or POSIX::_exit(126);
        close $rd;
        exec(build_extract_argv($podman, $name)) or POSIX::_exit(127);
    }
    close $rd;
    waitpid($git_pid, 0);     my $git_rc     = $? >> 8;
    waitpid($extract_pid, 0); my $extract_rc = $? >> 8;
    return ($git_rc, $extract_rc);
}

# ---------------------------------------------------------------------------
# build_test_exec_argv($podman, $name, $relpath) -> @argv (pure). Exactly 6
# elements. Preserves TAP/exit-code fidelity: rc is podman exec's own exit
# status, out is the raw combined stdout+stderr, notok is computed with the
# identical regex run-tests.pl's own run_one() uses -- so a caller cannot
# tell a container red from a host red.
#
# FIX-BATCH A1 (MAJOR, review R1 / red-team M1): $relpath used to reach this
# inner `sh -c` string with NO validation anywhere in the file -- a single
# quote closed the quoting early (shell-command injection inside the
# container) and a leading `-e` needed no quote-breakout at all (Perl reads
# it as the eval switch), both reproduced live by two independent reviewers,
# one of whom observed a nonexistent file return exit 0 -- a forged TAP pass,
# exactly what AC5's fidelity guarantee promises cannot happen. Fixed by
# allow-listing, not by quoting harder: _is_valid_test_file() (defined below,
# next to _is_absolute_path) is enforced HERE, at the one place every relpath
# funnels through on its way into a shell string, so a library caller who
# skips main()'s own CLI-boundary check (also added, in main()'s file loop)
# still cannot construct an unsafe payload.
# ---------------------------------------------------------------------------
sub build_test_exec_argv {
    my ($podman, $name, $relpath) = @_;
    unless (_is_valid_test_file($relpath)) {
        die "build_test_exec_argv: refusing invalid test file argument: "
          . (defined $relpath ? $relpath : '<undef>') . "\n";
    }
    return (
        $podman, 'exec', $name, 'sh', '-c',
        "cd '$NATIVE_TREE_ROOT' && perl '$relpath' 2>&1",
    );
}

# DELIBERATELY NOT FIXED (fix-batch, step 7, Part B / red-team N3): there is
# no per-file execution timeout here -- a hung guest .t file blocks the whole
# lane indefinitely, relying on a human noticing and sending SIGINT/TERM
# (which correctly triggers container cleanup via the %SIG handlers above).
# This mirrors scripts/run-tests.pl's own host-side run_one(), also untimed,
# an explicit parity choice: diverging here would make the two lanes differ
# for no reason this package asked for. If this lane is ever run unattended,
# that gap should be closed in both lanes together, not just this one.
sub run_one_in_container {
    my ($podman, $name, $relpath) = @_;
    my $t0 = time;
    my ($rc, $out) = _podman_capture(build_test_exec_argv($podman, $name, $relpath));
    $out = '' unless defined $out;
    my $notok = () = $out =~ /^not ok/mg;
    return { file => $relpath, rc => $rc, notok => $notok, secs => time - $t0, out => $out };
}

# ---------------------------------------------------------------------------
# Disposal -- Decision 14's three obligations.
# ---------------------------------------------------------------------------
sub build_rm_argv { my ($podman, $name) = @_; return ($podman, 'rm', '-f', $name) }

sub _cleanup_active_container {
    return unless defined $ACTIVE_CONTAINER_NAME;
    _podman_capture(build_rm_argv($ACTIVE_PODMAN_BIN, $ACTIVE_CONTAINER_NAME));
    $ACTIVE_CONTAINER_NAME = undef;
}

for my $sig (qw(INT TERM HUP)) {
    $SIG{$sig} = sub {
        my ($caught) = @_;
        _cleanup_active_container();
        $SIG{$caught} = 'DEFAULT';
        kill $caught, $$;
    };
}
END { _cleanup_active_container() }

sub new_container_name { return $CONTAINER_NAME_PREFIX . $$ . '-' . $COUNTER++ }

sub _pid_from_name {
    my ($name) = @_;
    return undef unless defined $name;
    return undef unless $name =~ /\A\Q$CONTAINER_NAME_PREFIX\E([0-9]+)-[0-9]+\z/;
    return $1;
}

sub orphan_container_names {
    my ($names, $alive_fn) = @_;
    $alive_fn ||= sub { kill(0, $_[0]) ? 1 : 0 };
    my @out;
    for my $n (@{ $names || [] }) {
        next unless defined $n && length $n;
        my $pid = _pid_from_name($n);
        next unless defined $pid;
        next if $alive_fn->($pid);
        next if $pid == $$;
        push @out, $n;
    }
    return @out;
}

sub build_ps_argv { my ($podman) = @_; return ($podman, 'ps', '-a', '--format', '{{.Names}}') }

# sweep_orphan_containers -- obligation (c). Covers the WSL-VM-kill case by
# construction: on the NEXT run, before this run creates its own container,
# any leftover ccpraxis-container-lane- container whose encoded pid is no
# longer alive is removed. Runs inside main(), never at file-load time, so
# merely requiring this file (as container-lane.t does for its pure
# assertions) costs nothing.
sub sweep_orphan_containers {
    my ($podman) = @_;
    my ($rc, $out) = eval { _podman_capture(build_ps_argv($podman)) };
    return () if $@ || !defined $rc || $rc != 0;
    my @names = grep { length } map { s/\s+\z//r } split /\n/, ($out // '');
    my @orphans = orphan_container_names(\@names);
    for my $c (@orphans) { _podman_capture(build_rm_argv($podman, $c)) }
    return @orphans;
}

# ---------------------------------------------------------------------------
# main(@argv) -- the CLI contract. See the spec's usage/flow/exit-code table.
# ---------------------------------------------------------------------------
sub _usage {
    return <<'USAGE';
usage: perl scripts/run-tests-container.pl [--ref REF] FILE.t [FILE2.t ...]
  --ref REF   git ref to materialize (default: HEAD). Uncommitted/untracked changes are NOT reflected -- this lane archives a git ref. Must not start with '-' (refused, exit 2) -- git would parse it as an option, not a revision.
  FILE.t ...  one or more paths, given relative to the repo root with forward slashes (e.g. plugins/butler/tests/t/foo.t). An absolute path (POSIX, Windows drive-letter, or UNC) is refused (exit 2) -- a host path has no meaning inside the container's own tree. Every other path must match [A-Za-z0-9_][A-Za-z0-9_./-]*.t with no '..' segment, refused (exit 2) otherwise -- nothing legitimate needs a quote, a leading dash, or a shell metacharacter here, and this allow-list is what keeps a filename from reaching the inner container shell unsafely.
USAGE
}

sub _is_absolute_path {
    my ($p) = @_;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    # FIX-BATCH A2 (MINOR, review R2): a UNC path (\\server\share\...) is
    # absolute but was not recognised, so the documented "an absolute path
    # is refused (exit 2)" contract silently did not fire for this spelling.
    # It failed safe (a generic "can't open" error, never reached the host or
    # escaped the container), but the stated contract was not honoured.
    return 1 if $p =~ m{^\\\\};
    return 0;
}

# ---------------------------------------------------------------------------
# FIX-BATCH A1 (MAJOR, review R1 / red-team M1): allow-list every file
# argument before it can reach build_test_exec_argv's inner `sh -c` string.
# Allow-listing, not quoting harder: nothing legitimate needs a quote, a
# leading dash, or a shell metacharacter in a repo-relative .t path. A `..`
# path segment is refused separately (red-team N4) -- the character class
# alone permits it (it allows '.'), so it needs its own check; even though
# this lane has no bind mount, a traversal can still make the container run
# an arbitrary file inside ITS OWN filesystem and leak its contents into
# `out`, which main() prints verbatim.
# ---------------------------------------------------------------------------
sub _is_valid_test_file {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 0 if _is_absolute_path($p);
    return 0 unless $p =~ m{\A[A-Za-z0-9_][A-Za-z0-9_./-]*\.t\z};
    return 0 if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 1;
}

# ---------------------------------------------------------------------------
# FIX-BATCH A3 (review R3 / red-team N1): --ref reaches `git archive` as a
# single, unvalidated argv element. exec(LIST) means it cannot break out to a
# host shell, but a value starting with '-' is parsed by git as an OPTION,
# not a revision (the classic `--remote=ext::<cmd>` shape -- already blocked
# by git's own default protocol allowlist per the red-team's own live check,
# so this is defence in depth, not a live hole, and is kept proportionate to
# that: reject a leading '-', nothing more elaborate).
# ---------------------------------------------------------------------------
sub _is_valid_git_ref {
    my ($ref) = @_;
    return 0 unless defined $ref && length $ref;
    return 0 if $ref =~ /^-/;
    return 1;
}

# ---------------------------------------------------------------------------
# FIX-BATCH A5: pre-flight notice. No admission control is added deliberately
# (a heuristic refusal would make an already-throwaway lane unreliable, and
# it is the operator's own machine/memory budget to police, not this file's)
# -- but the actual numbers this lane is about to add to are surfaced before
# it creates anything, rather than assumed. Uses MEASURED values (a real
# `podman ps` count), never the spec's own worst-case arithmetic -- see the
# spec correction in Part D: bootstrap.pl:405's "--cpus 4 --memory 3584" is a
# remediation string printed TO an operator, not a read of this host's real
# ~/.wslconfig.
# ---------------------------------------------------------------------------
sub _running_container_count {
    my ($podman) = @_;
    my ($rc, $out) = _podman_capture($podman, 'ps', '--format', '{{.Names}}');
    return undef if $rc != 0;
    my @names = grep { length } split /\n/, ($out // '');
    return scalar(@names);
}

sub _preflight_notice_text {
    my ($count) = @_;
    my $count_str = defined $count ? $count : 'unknown';
    return "container-lane pre-flight: $count_str container(s) currently running on this host "
         . "(podman ps); this lane is about to start one more, capped at "
         . "--cpus $CONTAINER_LANE_CPUS --memory $CONTAINER_LANE_MEMORY.\n";
}

sub main {
    my @argv = @_;
    my $ref = 'HEAD';
    my @files;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--ref') {
            $ref = shift @argv;
            unless (defined $ref && length $ref) {
                print STDERR "--ref requires a value\n";
                print STDERR _usage();
                return 2;
            }
            # FIX-BATCH A3: reject an implausible ref before it ever reaches
            # git archive.
            unless (_is_valid_git_ref($ref)) {
                print STDERR "invalid --ref value (must not start with '-'): $ref\n";
                print STDERR _usage();
                return 2;
            }
        } else {
            push @files, $a;
        }
    }

    if (!@files) {
        print STDERR "no test files given\n";
        print STDERR _usage();
        return 2;
    }
    for my $f (@files) {
        if (_is_absolute_path($f)) {
            print STDERR "absolute path not allowed: $f\n";
            print STDERR _usage();
            return 2;
        }
        # FIX-BATCH A1: allow-list every file argument at the CLI boundary
        # too (build_test_exec_argv enforces it again, so a library caller
        # bypassing main() cannot reach an unsafe payload either).
        if (!_is_valid_test_file($f)) {
            print STDERR "invalid test file argument (must match "
                . "[A-Za-z0-9_][A-Za-z0-9_./-]*.t with no '..' segment): $f\n";
            print STDERR _usage();
            return 2;
        }
    }

    my $podman = podman_bin();
    if (!$podman) {
        print STDERR "no docker/podman CLI found on PATH\n";
        return 125;
    }

    if (!image_present($podman, $IMAGE)) {
        print STDERR "image '$IMAGE' is not present locally.\n";
        print STDERR "Run the interactive sandbox launcher once to build it: "
            . "plugins/sandbox/scripts/launcher.pl (i.e. claude-sandbox).\n";
        print STDERR "This lane never builds images itself.\n";
        return 125;
    }

    # Obligation (c): sweep orphans from a previous, possibly hard-killed run
    # BEFORE this run creates its own container.
    sweep_orphan_containers($podman);

    # FIX-BATCH A5: pre-flight notice -- see the sub comment above for why no
    # admission control is added, only visibility.
    print STDERR _preflight_notice_text(_running_container_count($podman));

    my $name = new_container_name();

    # FIX-BATCH A4 (red-team N2): orphan_container_names' own $$-guard (A17,
    # deliberately not touched -- it is correct for a real alive_fn, which
    # can never truthfully report the CURRENT process's own pid as dead) can
    # perpetually protect a genuinely dead container left by an OLDER process
    # that happened to share this PID (PID reuse), and this run's own
    # `podman run --name $name` then fails on the collision. This process
    # cannot have created $name itself yet -- the sweep above ran before any
    # podman run this invocation -- so if a container by this EXACT name
    # already exists, it must be a stale leftover. Reclaim it by exact name
    # only, never by pid/prefix heuristic, so the prefix-anchored sweep above
    # is untouched.
    {
        my ($ps_rc, $ps_out) = _podman_capture(build_ps_argv($podman));
        if ($ps_rc == 0 && defined $ps_out && $ps_out =~ /^\Q$name\E\s*$/m) {
            _podman_capture(build_rm_argv($podman, $name));
        }
    }

    my ($run_rc, $run_out) = _podman_capture(build_run_argv($podman, $name));
    if ($run_rc != 0) {
        print STDERR "podman run failed (rc=$run_rc):\n$run_out";
        return 125;   # nothing to clean up yet -- no container exists
    }
    $ACTIVE_CONTAINER_NAME = $name;
    $ACTIVE_PODMAN_BIN     = $podman;

    # Separators FIRST, then dirname. __FILE__ can carry backslashes on Windows
    # and dirname on a mixed-separator path misbehaves, so normalising before
    # splitting is the order that matters -- not a style preference. Same shape
    # as BpContinuityLease.pm's own __FILE__ handling and bp-turn-caps.pl's
    # script_dir_for, and asserted repo-wide by turn-cap-consistency.t's C9,
    # which is what caught this file doing it the raw way.
    my $project_root = do {
        (my $self = __FILE__) =~ s{\\}{/}g;
        my $here = Cwd::abs_path($self) // $self;
        abs_path(File::Basename::dirname($here) . '/..');
    };
    my ($git_rc, $extract_rc) = materialize_tree($podman, $name, $ref, $project_root);
    if ($git_rc != 0 || $extract_rc != 0) {
        print STDERR "materialize_tree failed (git_rc=$git_rc, extract_rc=$extract_rc)\n";
        _cleanup_active_container();
        return 125;
    }

    my @results;
    for my $relpath (@files) {
        my $result = run_one_in_container($podman, $name, $relpath);
        print $result->{out};
        push @results, $result;
    }

    _cleanup_active_container();

    my @red = grep { $_->{rc} != 0 } @results;
    return scalar(@red);
}

exit main(@ARGV) unless caller();
