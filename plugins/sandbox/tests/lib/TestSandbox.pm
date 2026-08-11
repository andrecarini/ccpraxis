package TestSandbox;
# Common helpers for plugins/sandbox/tests/.
#
# Mirrors the MSYS2-defense pattern from launcher.pl: disable MSYS argv
# path conversion, winify host paths upfront, and translate `-v` mount
# specs into `--mount type=bind|volume,source=,target=` to defeat the
# colon-as-PATH-list mangling on Git-for-Windows perl. Without these the
# test harness silently corrupts every podman command on Windows.
#
# All resources (containers, volumes, temp dirs) are tagged with the
# current PID + a counter so concurrent runs don't collide. Cleanup is
# three-layered: an END block for normal exit and `die`, signal handlers
# for the abort paths END does NOT cover (Ctrl-C, `timeout`), and a
# load-time sweep of containers whose creating PID is already dead, which
# is the only layer that can recover from a SIGKILL or an earlier run.
# See the "Orphan reaping" block below for why all three are needed.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use MountSpec qw(winify_path convert_v_to_mount);
use Exporter qw(import);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);

our @EXPORT_OK = qw(
    podman_bin
    probe_image
    new_container_name
    new_temp_dir
    winify_path
    podman_run_capture
    create_probe_container
    register_cleanup_container
    register_cleanup_dir
    cleanup_all
    sweep_orphan_containers
    test_container_prefix
    orphan_container_names
);

our $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;
# Detect docker OR podman — both supported. Same detection as
# launcher.pl / bootstrap.pl: probe `<cli> --version`, prefer docker.
sub _detect_container_cli {
    for my $candidate ($WINDOWS_FAMILY ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        my $rc = system("$candidate --version > /dev/null 2>&1");
        return $candidate if $rc == 0;
    }
    return undef;
}
our $PODMAN = _detect_container_cli() // die "TestSandbox: no container CLI on PATH (docker / podman)\n";
our $PROBE_IMAGE = 'docker.io/library/debian:bookworm-slim';

# Disable MSYS argv conversion process-wide. Same reasoning as launcher.pl:
# without this, podman -v HOST:CONTAINER args get split on `:`, each side
# POSIX→Windows-converted, and rejoined with `;` — yielding `;C`-suffixed
# garbage paths. Even single `/foo` args inside `podman exec` get rewritten
# to `C:\Program Files\Git\foo`.
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $WINDOWS_FAMILY;

my @CLEANUP_CONTAINERS;
my @CLEANUP_DIRS;
my $COUNTER = 0;

sub podman_bin { $PODMAN }
sub probe_image { $PROBE_IMAGE }

sub _tag {
    $COUNTER++;
    return "claude-sandbox-test-$$-$COUNTER";
}

sub new_container_name { return _tag() . '-c' }

# winify_path comes from MountSpec.pm (imported above).

# Anchor temp dirs under $HOME (or $USERPROFILE on Windows). On WSL2-backed
# Docker/Podman, $HOME is reachable via /mnt/c automounts; same on Linux
# native; same on macOS via virtiofs. Git-Bash /tmp is in a 9p namespace
# the VM may not see (historical Hyper-V bug — kept the anchor for
# portability across backends).
sub new_temp_dir {
    my $home = $ENV{HOME} // $ENV{USERPROFILE};
    die "neither HOME nor USERPROFILE set" unless defined $home;
    my $base = "$home/.cache/sandbox-tests";
    require File::Path;
    File::Path::make_path($base) unless -d $base;
    my $d = tempdir(DIR => $base, CLEANUP => 0);
    $d = winify_path($d);
    register_cleanup_dir($d);
    return $d;
}

# Run a podman command. Returns ($exit_status >> 8, $combined_output).
# Uses system() with a list arg so MSYS doesn't get a second crack at the
# command string; captures stdout+stderr via a temp file redirect.
sub podman_run_capture {
    my @args = convert_v_to_mount(@_);
    require File::Temp;
    my ($fh, $tmp) = File::Temp::tempfile();
    close $fh;
    my $rc = system("$PODMAN @{[map { _arg_quote($_) } @args]} > " . _arg_quote($tmp) . " 2>&1");
    open my $rfh, '<', $tmp or die "open $tmp: $!";
    local $/;
    my $output = <$rfh>;
    close $rfh;
    unlink $tmp;
    return ($rc >> 8, $output // '');
}

# Arg quoting for system(STRING) calls. system() invokes /bin/sh on
# cygwin perl, so we have to defend against the same expansions any
# shell does. Double-quotes interpolate `$VAR` and backticks — fatal
# for test probes that pass shell scripts CONTAINING those characters
# (the in-container script's `$SECONDS` was getting expanded by the
# OUTER shell before podman ever saw it, yielding a script with empty
# vars). Strategy:
#   - if the string contains no single quotes, single-quote-wrap it
#     (POSIX literal — no interpolation, no escape sequences);
#   - if it has single quotes, fall back to double-quote escaping with
#     special care for the chars that bash interprets ($, `, ", \).
sub _arg_quote {
    my $s = shift;
    return $s if $s =~ /\A[\w.\/:=+\-,]+\z/;
    if ($s !~ /'/) {
        return "'$s'";
    }
    # Has single quotes — close, escape, reopen pattern: ' '\'' '
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# Create+start a probe container running `sleep 600`. Mounts is an array
# of `-v SOURCE:TARGET[:OPTS]` pairs in launcher style — rewritten to
# `--mount` internally so they survive MSYS.
sub create_probe_container {
    my %opts = @_;
    my $mounts = $opts{mounts} || [];
    my $name = new_container_name();
    my @cmd = ('run', '-d', '--name', $name);
    push @cmd, @$mounts;
    push @cmd, $PROBE_IMAGE, 'sleep', '600';
    my ($rc, $out) = podman_run_capture(@cmd);
    die "create_probe_container($name) failed: $out" if $rc != 0;
    register_cleanup_container($name);
    return $name;
}

sub register_cleanup_container { push @CLEANUP_CONTAINERS, $_[0] }
sub register_cleanup_dir       { push @CLEANUP_DIRS,       $_[0] }

sub cleanup_all {
    for my $c (@CLEANUP_CONTAINERS) {
        system("$PODMAN rm -f " . _arg_quote($c) . " > /dev/null 2>&1");
    }
    @CLEANUP_CONTAINERS = ();
    for my $d (@CLEANUP_DIRS) {
        # Convert back to MSYS form if needed for remove_tree
        my $rm = $d;
        $rm =~ s|^([A-Za-z]):/|"/" . lc($1) . "/"|e if $WINDOWS_FAMILY;
        remove_tree($rm) if -d $rm;
    }
    @CLEANUP_DIRS = ();
}

# ---------------------------------------------------------------------------
# Orphan reaping — why this exists, and why END was never enough.
#
# The header of this file used to claim the END block "cleans up reliably even
# if a test aborts mid-flight". That is true for `die` and for a normal exit,
# and FALSE for the way these tests most often actually stop: a signal. Perl
# does not run END blocks when the process takes an unhandled SIGINT/SIGTERM/
# SIGHUP, and this suite is routinely run under `timeout` (project CLAUDE.md
# mandates it for anything that could reach launcher.pl) and interrupted by
# hand with Ctrl-C. Every one of those paths left `sleep 600` probe containers
# behind, and because each run tags names with its own PID they accumulate
# silently rather than colliding — the operator found a pile of them in
# `podman ps -a` long after the runs were gone.
#
# Two layers, because neither alone is sufficient:
#   1. Signal handlers, so the common abort paths clean up their OWN containers
#      the way an ordinary exit does. Handlers re-raise with the default
#      disposition afterwards, so the exit status still reports the signal
#      rather than silently becoming 0.
#   2. A sweeper for containers whose creating process is already gone. Layer 1
#      cannot help a run that was SIGKILLed, that crashed the interpreter, or
#      that predates this change. The name carries the creating PID, so
#      liveness is decidable without any extra state: a test container whose
#      PID is not alive owns nothing and is safe to remove. A LIVE PID's
#      containers are never touched, which is what keeps concurrent runs safe.
# ---------------------------------------------------------------------------

sub test_container_prefix { 'claude-sandbox-test-' }

# Parse a container name back to the PID that created it, or undef if the name
# is not ours. Deliberately strict: only `claude-sandbox-test-<pid>-<counter>`
# plus an optional suffix matches, so an unrelated container that merely starts
# with the prefix is left alone rather than removed on a loose match.
sub _pid_from_test_container_name {
    my ($name) = @_;
    return undef unless defined $name;
    my $p = test_container_prefix();
    return undef unless $name =~ /\A\Q$p\E([0-9]+)-[0-9]+(?:-.*)?\z/;
    return $1;
}

# Is $pid alive? kill 0 is the portable probe; on Windows perl it answers for
# the emulated process table, which is where these PIDs come from. An undef or
# non-numeric pid is reported NOT alive so a malformed name is reapable rather
# than immortal.
sub _pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /\A[0-9]+\z/ && $pid > 0;
    return kill(0, $pid) ? 1 : 0;
}

# orphan_container_names(\@all_names, $alive_fn) -> @orphans
# Pure and total, so the reaping RULE is unit-testable without a container
# runtime: names not ours are skipped, ours-but-live are skipped, ours-and-dead
# are returned. $alive_fn is injectable purely for the tests.
sub orphan_container_names {
    my ($names, $alive_fn) = @_;
    $alive_fn ||= \&_pid_alive;
    my @out;
    for my $n (@{ $names || [] }) {
        next unless defined $n && length $n;
        my $pid = _pid_from_test_container_name($n);
        next unless defined $pid;
        next if $alive_fn->($pid);
        next if $pid == $$;        # never reap our own, even mid-run
        push @out, $n;
    }
    return @out;
}

# Remove every test container whose creating process is gone. Returns the list
# actually reaped. Best-effort by construction: a podman that is absent, slow
# or erroring must never fail a test run, so every failure path returns empty
# rather than dying.
sub sweep_orphan_containers {
    my ($rc, $out) = eval { podman_run_capture('ps', '-a', '--format', '{{.Names}}') };
    return () if $@ || !defined $rc || $rc != 0;
    my @names = grep { length } map { s/\s+\z//r } split /\n/, ($out // '');
    my @orphans = orphan_container_names(\@names);
    for my $c (@orphans) {
        system("$PODMAN rm -f " . _arg_quote($c) . " > /dev/null 2>&1");
    }
    return @orphans;
}

# Signal-path cleanup. Restore the default disposition and re-raise so the
# waiting shell still sees "killed by SIGTERM" — swallowing the signal here
# would turn an interrupted run into an apparently successful one.
for my $sig (qw(INT TERM HUP)) {
    $SIG{$sig} = sub {
        my ($caught) = @_;
        cleanup_all();
        $SIG{$caught} = 'DEFAULT';
        kill $caught, $$;
    };
}

# Reap other runs' leftovers once at load, before this run creates anything.
# Skippable via CCPRAXIS_TEST_NO_SWEEP=1 for the tests that exercise the
# sweeper itself (and for anyone debugging a container by hand).
sweep_orphan_containers() unless $ENV{CCPRAXIS_TEST_NO_SWEEP};

END { cleanup_all() }

1;
