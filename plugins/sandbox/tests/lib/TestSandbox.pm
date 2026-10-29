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
use Exporter ();
our @ISA = ('Exporter');
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# HostCaps.pm: the sole owner of scratch_root() (blueprint test-platform-
# split, package 04-scratch-root). __FILE__-derived, never FindBin/$Bin --
# $Bin above is the INVOKING SCRIPT's directory (a process-wide singleton),
# not this module's own directory, so it is only correct when THIS file is
# the one doing the requiring of its OWN siblings (MountSpec, above); a
# sibling-lookup for HostCaps needs this module's own path regardless of who
# required it. Bareword `require HostCaps;` (not a string-path require) so
# every caller lands on the identical %INC key and the file loads exactly
# once no matter which of HostCaps.pm / StewardTest.pm / TestSandbox.pm is
# required first.
use lib dirname(abs_path(__FILE__)) . "/../../../butler/tests/lib";
require HostCaps;

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
    container_runtime_reachable
    container_unreachable_reason
);

# HostPlatform.pm, resolved from THIS file's own location for the same reason
# HostCaps is above: $Bin belongs to whichever test loaded us.
use lib dirname(abs_path(__FILE__)) . "/../../scripts";
require HostPlatform;

our $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;
# Detect docker OR podman — both supported. The SAME detection launcher.pl
# and bootstrap.pl use (HostPlatform::detect_container_cli): the
# CCPRAXIS_CONTAINER_CLI override, then the platform's own preference order.
#
# NO CLI IS NOT A LOAD-TIME DEATH ANY MORE. This used to `die` here, which
# killed every caller at `use TestSandbox` with exit 255 -- including callers
# that only wanted catalog helpers (new_temp_dir) and callers whose own
# reachability skip (import(), below) would have said exactly why. Now $PODMAN
# is undef, the catalog helpers keep working, and a caller that imports a
# symbol that needs a runtime gets a clean skip_all naming the cause.
my $CLI_ERROR;
sub _detect_container_cli {
    my ($cli, $err) = HostPlatform::detect_container_cli();
    $CLI_ERROR = $err;
    return $cli;
}
our $PODMAN = _detect_container_cli();
our $PROBE_IMAGE = 'docker.io/library/debian:bookworm-slim';

# A SANDBOXED HOME HIDES THE PODMAN MACHINE (macOS).
#
# scripts/run-tests.pl gives every test file its own throwaway HOME. On macOS
# podman is a remote client: it finds its machine and connection under
# ~/.config/containers, so with HOME moved it fell back to a local socket that
# does not exist ("dial unix /tmp/ccpraxis-sweep-*/storage-run-501/podman/
# podman.sock") and every container test skipped as "runtime unreachable"
# while the machine was up. Point it at the machine's API socket instead
# (CONTAINER_HOST, which podman reads before any config file): the socket path
# comes from `podman machine inspect` run against the OS-recorded home, read
# once, here. podman derives that socket's directory from TMPDIR, which the
# runner moves too, so the inspect also gets macOS's own per-user temp dir
# (`getconf DARWIN_USER_TEMP_DIR`, independent of the environment). Only when
# HOME is not the OS-recorded home, only on darwin with podman, and never over
# an explicit CONTAINER_HOST the caller already set.
if (defined $PODMAN && $^O eq 'darwin' && $PODMAN =~ /podman/i
    && !(defined $ENV{CONTAINER_HOST} && length $ENV{CONTAINER_HOST})) {
    my $owner = HostPlatform::owner_home();
    if (defined $owner && (($ENV{HOME} // '') ne $owner)) {
        chomp(my $utmp = `getconf DARWIN_USER_TEMP_DIR 2>/dev/null` // '');
        my $raw = do {
            local $ENV{HOME} = $owner;
            local $ENV{TMPDIR} = $utmp if length $utmp;
            `$PODMAN machine inspect 2>/dev/null`;
        };
        my $info = HostPlatform::parse_machine_inspect($raw);
        my $sock = $info ? $info->{api_socket} : undef;
        $ENV{CONTAINER_HOST} = "unix://$sock" if defined $sock && -S $sock;
    }
}

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

# ---------------------------------------------------------------------------
# Reachability probe (Decision 120(a), blueprint hook-continuity-remake
# package 36) -- `<cli> --version` above only proves the CLI binary is on
# PATH; it says nothing about whether the daemon/VM behind it is actually
# reachable. The distinguishing host state this exists for is podman on
# PATH with the machine STOPPED (this host's normal idle state): `--version`
# succeeds instantly regardless, so callers that only gate on
# _detect_container_cli() go on to run real container operations that then
# fail hard with a raw podman connection error, rather than skipping.
#
# `podman info` is used as the probe because, empirically on this host with
# the machine stopped, it fails FAST (~0.17s, exit 125, "unable to connect
# to Podman socket") rather than hanging -- so the alarm() bound below is a
# safety net for a wedged daemon, not the primary defense. Same documented,
# accepted best-effort gap as launcher.pl's _run_timed(): SIGALRM interrupts
# a pending backtick on this POSIX-ish perl; on a perl/platform where it
# doesn't, this degrades to a no-op bound rather than a hard guarantee.
#
# Memoized: the reachability of the runtime does not change within a single
# test process's lifetime for any test in this suite, and repeating the
# probe would multiply this cost across every caller.
my ($REACHABLE, $REACHABLE_REASON);
sub container_runtime_reachable {
    return $REACHABLE if defined $REACHABLE;
    unless (defined $PODMAN) {
        $REACHABLE = 0;
        $REACHABLE_REASON = defined $CLI_ERROR
            ? "no usable container CLI: $CLI_ERROR"
            : 'no container CLI on PATH (looked for ' . join(', ', HostPlatform::cli_candidates()) . ')';
        return $REACHABLE;
    }
    my $quoted_podman = _arg_quote($PODMAN);
    my $cmd = "$quoted_podman info " . _arg_quote('--format') . ' ' . _arg_quote('{{.Host.Arch}}') . ' 2>&1';
    my $out;
    my $died = 0;
    eval {
        local $SIG{ALRM} = sub { die "TestSandbox: podman info timeout\n" };
        alarm(15);
        $out = `$cmd`;
    };
    alarm(0);
    if ($@) {
        $died = 1;
    }
    my $rc = $died ? -1 : ($? >> 8);
    if ($died) {
        $REACHABLE = 0;
        $REACHABLE_REASON = "$PODMAN info did not return within 15s -- container runtime unreachable (or wedged)";
    } elsif ($rc != 0) {
        $REACHABLE = 0;
        (my $reason = $out // '') =~ s/\s+\z//;
        $reason =~ s/\s+/ /g;
        $REACHABLE_REASON = "$PODMAN is on PATH but its runtime is unreachable (rc=$rc): $reason";
    } else {
        $REACHABLE = 1;
        $REACHABLE_REASON = undef;
    }
    return $REACHABLE;
}

# The clear skip reason to hand to Test::More's skip()/plan(skip_all=>...)
# after a false container_runtime_reachable(). Runs the probe if it has not
# already run in this process.
sub container_unreachable_reason {
    container_runtime_reachable() unless defined $REACHABLE;
    return $REACHABLE_REASON;
}

# Symbols whose import means the caller intends to actually TALK to the
# runtime (spawn/exec against a real daemon), as opposed to catalog-style
# helpers (podman_bin, probe_image, new_temp_dir, new_container_name,
# register_cleanup_*, cleanup_all, sweep_orphan_containers,
# orphan_container_names, test_container_prefix, winify_path,
# container_runtime_reachable/container_unreachable_reason themselves) that
# work, and were already exercised in this suite, whether or not the daemon
# is reachable. Gating the auto-skip below on this set specifically -- not
# on every import -- matters: a caller that requires TestSandbox late, after
# other assertions already ran, and only ever imports catalog-style helpers
# (e.g. scratch-root-single.t's per-row child processes, which import only
# new_temp_dir) must keep running unaffected by machine state, exactly as it
# did before this probe existed.
my %NEEDS_REACHABLE_RUNTIME = (podman_run_capture => 1, create_probe_container => 1);

# Symbols that are meaningless without SOME container CLI on PATH, reachable or
# not: podman_bin hands the caller the CLI name to spawn, and the sweep/orphan
# helpers drive it. With no CLI at all, importing one of these is a clean
# skip_all rather than the load-time die this module used to perform.
my %NEEDS_CLI = (%NEEDS_REACHABLE_RUNTIME, podman_bin => 1, sweep_orphan_containers => 1);

# Custom import (Decision 120(a), package 36): still exports symbols exactly
# as Exporter's default import would, THEN -- only when the CLI exists (the
# pre-existing die above already covers "no CLI at all", unchanged) but
# container_runtime_reachable() is false, and only when the caller actually
# asked for a runtime-talking symbol -- calls Test::More's plan(skip_all),
# which prints "1..0 # skip <reason>" and exits 0. That is only safe to do
# at `use`/`require+import` time, before the caller's own test assertions
# have run (exactly the six `use TestSandbox qw(...)` files this covers);
# it is why the gate above matters just as much as the reachability check
# itself for any caller that imports these symbols LATER, mid-file.
sub import {
    my $class = shift;
    my @syms = @_;
    $class->export_to_level(1, $class, @syms);
    if (!defined $PODMAN && grep { exists $NEEDS_CLI{$_} } @syms) {
        container_runtime_reachable();
        require Test::More;
        Test::More::plan(skip_all => container_unreachable_reason());
    }
    if (grep { exists $NEEDS_REACHABLE_RUNTIME{$_} } @syms) {
        unless (container_runtime_reachable()) {
            require Test::More;
            Test::More::plan(skip_all => container_unreachable_reason());
        }
    }
}

sub _tag {
    $COUNTER++;
    return "claude-sandbox-test-$$-$COUNTER";
}

sub new_container_name { return _tag() . '-c' }

# winify_path comes from MountSpec.pm (imported above).

# Anchor temp dirs under HostCaps::scratch_root()."/sandbox" (blueprint
# test-platform-split, package 04-scratch-root) when defined -- i.e. on
# Windows, or under any platform where CCPRAXIS_SCRATCH_ROOT is set.
# HostCaps::scratch_root() dying on a bad override propagates uncaught here,
# deliberately -- see HostCaps.pm.
#
# When scratch_root() is undef (non-Windows, no override), fall back to
# EXACTLY today's pre-existing behavior: $HOME (or $USERPROFILE) is where
# WSL2-backed Docker/Podman, Linux-native and macOS-virtiofs backends all
# reach a bind-mounted host path from inside a container (Git-Bash /tmp is
# in a 9p namespace the VM may not see -- historical Hyper-V bug). The
# HOME/USERPROFILE lookup, and its die-if-missing, only happen on this
# branch now -- on this Windows host scratch_root() is always defined, so
# requiring HOME/USERPROFILE to be set when nothing downstream needs either
# would be a new, avoidable failure mode with no compensating benefit.
sub new_temp_dir {
    my $scratch = HostCaps::scratch_root();
    my $base;
    if (defined $scratch) {
        $base = "$scratch/sandbox";
    } else {
        my $home = $ENV{HOME} // $ENV{USERPROFILE};
        die "neither HOME nor USERPROFILE set" unless defined $home;
        $base = "$home/.cache/sandbox-tests";
    }
    require File::Path;
    File::Path::make_path($base) unless -d $base;
    # CLEANUP => 1, not 0: this used to opt out of File::Temp's own cleanup
    # and rely solely on register_cleanup_dir() below plus this file's END
    # block / SIG{INT,TERM,HUP} handlers to drain @CLEANUP_DIRS at exit. That
    # registry DOES drain reliably for every exit path Perl can act on (normal
    # exit, die, INT/TERM/HUP) -- exactly the same two paths the container
    # reaping above documents. CLEANUP => 0 bought nothing on top of that: it
    # doesn't survive a SIGKILL/hard-crash any better than CLEANUP => 1 would
    # (File::Temp's own cleanup is itself an END-time hook, no more signal-safe
    # than ours), so the only thing it was doing was DISABLING a second,
    # independent safety net for the paths that already work, which is a pure
    # loss. Leaving it at 1 costs nothing (both mechanisms check -d before
    # acting) and covers a caller that forgets to invoke cleanup_all().
    my $d = tempdir(DIR => $base, CLEANUP => 1);
    # macOS, default root only: resolve symlinks. Under the runner HOME is
    # /tmp/ccpraxis-sweep-*, and /tmp is a symlink into /private. A podman
    # machine shares /private, not /tmp, and podman hands a bind source to the
    # VM literally, so an unresolved /tmp/... source fails with "statfs: no
    # such file or directory". The resolved path is the same directory. An
    # explicit CCPRAXIS_SCRATCH_ROOT is used exactly as given (HostCaps refuses
    # to canonicalise it, by design).
    if ($^O eq 'darwin' && !defined $scratch) {
        my $r = abs_path($d);
        $d = $r if defined $r && length $r;
    }
    $d = winify_path($d);
    register_cleanup_dir($d);
    return $d;
}

# Run a podman command. Returns ($exit_status >> 8, $combined_output).
# Uses system() with a list arg so MSYS doesn't get a second crack at the
# command string; captures stdout+stderr via a temp file redirect.
sub podman_run_capture {
    die "TestSandbox::podman_run_capture: no container CLI on PATH\n" unless defined $PODMAN;
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
    @CLEANUP_CONTAINERS = () unless defined $PODMAN;
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
    return () unless defined $PODMAN;
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
