#!/usr/bin/env perl
# run-tests.pl -- the repo-wide test runner. Parallel where that is safe,
# serial where it is not.
#
# WHY THIS EXISTS. A full sweep was ~70 minutes of CPU across 243 files, run
# one at a time, and a suite nobody wants to run is a suite that stops getting
# run. Measured on this host: 4190s of CPU, 915s wall at six-way parallelism.
# The work is dominated by PROCESS CREATION -- a bare statusline spawn costs
# ~292ms here -- not by CPU, so parallelism buys more than the core count
# suggests.
#
# `prove` is not an option: the Git-for-Windows perl ships no TAP::Harness
# (see the repo CLAUDE.md). This runs each .t as its own process and judges it
# by exit code plus `not ok` count, which is the same rule the project already
# applies by hand.
#
# CONTAINER TESTS RUN SERIALLY, and that is not a limitation to remove later.
# They start real podman containers against ONE podman machine, so running them
# concurrently makes them contend for the same resource -- slower in wall-clock
# AND flakier, which is the documented failure signature of this suite
# (EXIT=124/255 with no failing assertion). They are detected by what they
# import rather than by a tag, so a new one is classified correctly without
# anybody remembering to mark it.
#
# ROUTING BY MARKER (blueprint test-platform-split, package 06-route-by-marker).
# classify_file() below is the sole routing predicate: marker gate first (an
# illegal/absent marker is refused, package 03), then the pre-existing serial
# heuristic (still wins -- ten of the fifteen podman-starting tests are marked
# `any`, and routing those into ANOTHER container would be podman-in-podman),
# then the declared marker value. A file classify_file routes to 'container'
# only actually reaches the container lane (scripts/run-tests-container.pl,
# package 05, required into its own namespace below) when the
# CCPRAXIS_CONTAINER_LANE_ENABLED env var is set truthy -- an explicit,
# lane-AVAILABILITY opt-in, off by default, never a routing switch: with it
# off, every file classify_file would have routed to 'container' simply runs
# on the host instead, exactly as it did before this package existed. This is
# deliberately NOT a new CLI flag (out of scope per the package spec) -- see
# run_sweep()'s own comment at the gate for the full rationale.
#
# Usage:
#   perl scripts/run-tests.pl                    # everything
#   perl scripts/run-tests.pl --fast             # skip the container tests
#   perl scripts/run-tests.pl --jobs 8           # override parallelism
#   perl scripts/run-tests.pl --nice             # low-impact: cap workers, see below
#   perl scripts/run-tests.pl plugins/sandbox    # limit to a plugin or a glob
#   perl scripts/run-tests.pl --state=failed     # re-run only last run's red files
#
# --nice / CCPRAXIS_TEST_JOBS -- a low-impact mode, added because the default
# below (cores-2) is a throughput-maximising choice that is wrong for the
# common case of an agent kicking off a sweep while the operator is still
# using the machine. Named "--nice" after the Unix tool it rhymes with in
# INTENT (be a considerate background citizen) -- it does NOT touch OS
# scheduling priority the way `nice(1)` does; that would need to cover every
# spawned git/podman child too, which is a separate, larger change.
#
# --nice caps parallelism at max(2, cores/4): a quarter of the machine,
# floored at 2 rather than letting it round down to 1 on a 4-core host --
# 1 worker turns a sweep serial and "unbearably long" rather than merely
# slower. On this repo's reference 8-core host that is 2 workers, the same
# total CPU-seconds spread over roughly four times the wall-clock, leaving
# the operator three quarters of the machine.
#
# CCPRAXIS_TEST_JOBS=N is the same idea as an ambient default: set once in an
# agent's environment so every sweep it kicks off is gentle without having to
# remember a flag per invocation.
#
# Precedence (most to least specific): explicit `--jobs N` > `--nice` >
# `CCPRAXIS_TEST_JOBS` env var > the plain cores-2 default. The plain default
# is UNCHANGED -- this adds a choice, it does not remove the fast path for
# someone who is actively waiting on the result.
#
# --fast's meaning is UNCHANGED by the routing above: it skips tests that
# start real containers (a property of a file's own content, the serial
# heuristic), never the container LANE (an execution-environment choice,
# orthogonal to that contract). --fast still empties only the host-serial
# set; it never touches the container set.
use strict;
use warnings;
use File::Basename qw(basename dirname);
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Find ();
use Cwd qw(abs_path);
use POSIX qw(:sys_wait_h);
use Time::HiRes ();
use File::Temp ();
# bsd_glob(), NOT the builtin glob() -- the builtin word-splits its PATTERN
# argument on whitespace (csh-style), so an explicit target whose own path
# contains a space (e.g. a real checkout under "C:\Users\Andre\Personal
# Files") silently matches nothing and the whole invocation exits "no test
# files matched" without ever naming the file. Same defect, same fix, as
# scripts/backfill-test-platform.pl (package 02) -- fix-batch
# 03-enforce-marker step 7, finding A2.
use File::Glob qw(bsd_glob);

# NOT FindBin: $Bin is computed ONCE per process, at the first `use FindBin`
# anywhere -- if a caller (e.g. plugins/butler/tests/t/lane-routing.t, which
# also `use`s FindBin) has already triggered that computation against ITS
# OWN $0 before `require`ing this file, this file's own `use FindBin qw($Bin)`
# would silently reuse the caller's cached value instead of recomputing,
# producing a wrong, doubled path the moment this file is required rather
# than run directly. Separators normalised BEFORE dirname (__FILE__ may carry
# backslashes on Windows) -- same shape as run-tests-container.pl's own
# project_root computation and turn-cap-consistency.t's C9 rule.
my $ROOT_ABS = do {
    (my $self = __FILE__) =~ s{\\}{/}g;
    my $here = Cwd::abs_path($self) // $self;
    abs_path(dirname($here) . '/..');
};

# Package 21-test-sandbox: the REAL global gitconfig path, captured ONCE at
# load time, BEFORE run_sweep() ever overrides $ENV{HOME} for a per-file
# sandbox. Each sandboxed child gets GIT_CONFIG_GLOBAL pointed back at this
# so `git config`/`git commit` inside a test still see the operator's real
# identity/config, even though HOME itself now resolves to a throwaway dir.
# Read-only from the sandbox's point of view -- nothing here ever writes to
# it. undef when the outer HOME is unset/empty; callers must treat that as
# "leave GIT_CONFIG_GLOBAL unset" rather than guessing a path.
my $REAL_GIT_CONFIG_GLOBAL = do {
    my $home = $ENV{HOME};
    (defined $home && length $home) ? File::Spec->catfile($home, '.gitconfig') : undef;
};

# FIX-BATCH M4 (review, step 7): the operator's REAL butler-state and
# continuity-active dirs, captured ONCE at load time -- before run_one() ever
# overrides these two env vars for a per-file sandbox -- so the audit can
# snapshot them before/after the sweep and catch a write that reached them
# despite the sandboxing (e.g. a test that shells out without inheriting the
# per-file override). undef when unset in the invoking environment.
my $REAL_BUTLER_STATE_DIR = (defined $ENV{BUTLER_STATE_DIR} && length $ENV{BUTLER_STATE_DIR})
    ? $ENV{BUTLER_STATE_DIR} : undef;
my $REAL_CONTINUITY_ACTIVE_DIR = (defined $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} && length $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR})
    ? $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} : undef;

# FIX-BATCH M5 (review, step 7): the operator's real keep-awake pid, if any --
# a pid recorded here is the operator's OWN legitimate refresher, not a leak,
# and the wake-lock audit must never flag it.
my $REAL_KEEPAWAKE_PID = do {
    my $f = defined $REAL_BUTLER_STATE_DIR ? File::Spec->catfile($REAL_BUTLER_STATE_DIR, 'keepawake.pid') : undef;
    my $pid;
    if (defined $f && -f $f) {
        if (open my $fh, '<', $f) {
            local $/;
            my $raw = <$fh>;
            close $fh;
            $pid = $1 if defined $raw && $raw =~ /(\d+)/;
        }
    }
    $pid;
};

# Package 21-test-sandbox: the ambient, real %TEMP%/%TMP% path (a genuine
# Windows drive-letter form, e.g. "C:\Users\<name>\AppData\Local\Temp"),
# captured ONCE at load time, BEFORE run_sweep() ever overrides $ENV{TEMP}/
# $ENV{TMP} for a per-file sandbox. WHY THIS MUST STAY A WINDOWS PATH, NOT
# THE SHORTER MSYS "/tmp" alias _short_tmp_base() below prefers for HOME:
# at least one oracle in this suite (plugins/steward/tests/t/
# preflight-git-argv-leak.t) reads $ENV{TEMP}/$ENV{TMP} directly and builds
# its OWN fixture tempdir under it specifically because it needs a real
# drive-rooted path to reproduce an MSYS argv-translation bug -- File::Temp's
# own "/tmp" default (a bind mount whose physical target is NOT the drive
# path native git.exe/_native_path() expect) would make that reproduction
# fail for a reason unrelated to the bug the file targets. Every per-file
# sandbox still gets its OWN throwaway TEMP/TMP subdirectory (see run_one())
# -- this is only the BASE that subdirectory is created under, so the
# isolation guarantee (never the operator's bare system temp itself) holds
# regardless. undef when the ambient TEMP/TMP is unset/empty; callers must
# treat that as "fall back to the short /tmp base instead" rather than
# guessing a path.
my $REAL_WINDOWS_TMP = $ENV{TEMP} // $ENV{TMP};
$REAL_WINDOWS_TMP = undef unless defined $REAL_WINDOWS_TMP && length $REAL_WINDOWS_TMP && -d $REAL_WINDOWS_TMP;

# The sweep-wide sandbox root (one File::Temp dir; every per-file sandbox is a
# fresh subdirectory under it) and the --keep-sandbox flag. Both are file-
# scope so run_one() -- called both in-process (serial phase) and inside a
# forked child (parallel phase, which inherits this process's memory at fork
# time) -- sees the SAME root and the SAME flag value without any IPC.
my $SANDBOX_SWEEP_ROOT;
my $KEEP_SANDBOX = 0;

# never-halt 03: the --ledger path, taken verbatim (no rel2abs, no separator
# folding -- File::Spec on Git-for-Windows perl is the Unix flavour, and
# rel2abs of a C:/ path is wrong). undef unless --ledger was given. Set once
# during argv parsing in run_sweep(), read-only afterward. tooling-fixes 07:
# lint mode is on exactly when this is defined.
my $LEDGER_PATH;

# tooling-fixes 07: the repo-wide lints a --ledger run also runs, once each,
# defined exactly once here (DC3) so every caller agrees on the set. `our`,
# file-scope, so a file that `require`s this script can read it. Relative,
# forward-slash paths, in this fixed order -- a list, not a marker, by design
# (a lint-registry marker is explicitly out of scope).
our @REPO_LINTS = (
    'plugins/butler/tests/t/test-naming-hygiene.t',
    'plugins/butler/tests/t/tests-never-run-tests.t',
    'plugins/butler/tests/t/turn-cap-consistency.t',
);

# The recognisable prefix every per-file sandbox/win-tmp dir carries (m4).
# Lets an operator (or a stray-orphan reaper) tell this runner's own scratch
# apart from anything else under %TEMP%/"/tmp" at a glance. Deliberately NOT
# the name of a wrapping directory every per-file dir nests inside -- an
# earlier version of this fix wrapped every per-file sandbox in one shared,
# similarly-prefixed parent directory, and that EXTRA path segment (plus the
# 14-character prefix text itself) pushed an otherwise-ordinary fixture path
# (guards-remake-blueprint-write.t's BW-5 cases, which build a fixed-shape
# path under a bare `tempdir()` of their own) past
# BpHook::Guards::Common::path_echo's 90-character display-truncation
# threshold -- confirmed by direct measurement: 91 chars with the wrapping
# dir at its most compact possible size, 88 chars flattened. Each per-file
# dir instead carries the prefix ITSELF, directly under the short base --
# one path segment shorter, and the only shape that keeps both this budget
# and the oracle's literal "ccpraxis-sweep" substring requirement (AC m4)
# satisfied at once.
my $SWEEP_TEMPLATE = 'ccpraxis-sweep-XXXXXX';

# Package 10-nested-runner-audit (Decision 28, amendment 1 -- red-team
# MEDIUM-1): whether THIS process itself inherited the "enclosing sweep owns
# the audit" marker, captured ONCE at load time -- before run_one() ever sets
# CCPRAXIS_SWEEP_OWNS_AUDIT for a CHILD it is about to spawn. Capturing it
# here (rather than re-reading %ENV at each audit site) means run_one()'s own
# assignment, scoped to its `local %ENV` for a child process, can never
# retroactively make THIS process think it should skip its own audit.
#
# The marker's VALUE is no longer a bare, guessable/copy-pasteable literal
# "1" -- it is run_one()'s own per-file sandbox path (the same string it
# assigns to $ENV{HOME} for that child). "Active" requires ALL THREE to hold,
# checked byte-exact with no normalization:
#   (a) both CCPRAXIS_SWEEP_OWNS_AUDIT and HOME are non-empty and equal,
#   (b) that path exists as a directory on disk right now, and
#   (c) its basename has the exact shape $SWEEP_TEMPLATE produces (derived
#       from that template below, not a hand-maintained duplicate pattern).
# A marker failing any of these is treated as absent, SILENTLY -- no stdout/
# stderr about the rejection, so a rejected marker fails safe and quiet
# rather than becoming a new way to leak why it was rejected. This closes the
# hand-exportable `CCPRAXIS_SWEEP_OWNS_AUDIT=1` bypass (red-team MEDIUM-1):
# a bare literal can no longer satisfy (a), let alone (b)/(c).
my $ENCLOSING_SWEEP_OWNS_AUDIT = do {
    my $m = $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT};
    my $h = $ENV{HOME};
    my $shape_re = do {
        (my $t = $SWEEP_TEMPLATE) =~ s/X+\z//;
        qr/\A\Q$t\E[A-Za-z0-9_]{6}\z/;
    };
    (defined $m && length $m && defined $h && length $h && $m eq $h
        && -d $m
        && (basename($m) =~ $shape_re)) ? 1 : 0;
};

# _sandbox_registry_path() -> $path -- FIX-BATCH m4 (review, step 7): with no
# single wrapping directory left to nuke on interrupt (see $SWEEP_TEMPLATE's
# own comment above for why), the INT/TERM handler instead needs to know
# exactly which per-file dirs are currently live. Every run_one() call
# (in-process serial, or inside a forked parallel/container-batch child --
# each such child still shares this lexical because it inherits the
# PARENT's memory at fork time) appends its own sandbox/win-tmp path here
# the moment it creates them, before running the test file itself. Lazily
# created once per top-level process; forked children reuse the SAME path
# (inherited at fork time), so every append lands in one file regardless of
# which process wrote it.
my $SANDBOX_REGISTRY_PATH;
sub _sandbox_registry_path {
    return $SANDBOX_REGISTRY_PATH if defined $SANDBOX_REGISTRY_PATH;
    my $base = _short_tmp_base();
    my ($fh, $path) = defined $base
        ? File::Temp::tempfile('ccpraxis-sweep-registry-XXXXXX', DIR => $base, SUFFIX => '.txt', UNLINK => 0)
        : File::Temp::tempfile(SUFFIX => '.txt', UNLINK => 0);
    close $fh;
    $SANDBOX_REGISTRY_PATH = $path;
    return $SANDBOX_REGISTRY_PATH;
}

# _register_sandbox_dir($path) -- appends one line, best-effort (a failure
# to record means only that an interrupt cannot clean this ONE dir up early;
# run_one()'s own end-of-call removal is unaffected).
sub _register_sandbox_dir {
    my ($path) = @_;
    return unless defined $path && length $path;
    my $reg = _sandbox_registry_path();
    if (open my $fh, '>>', $reg) {
        print {$fh} "$path\n";
        close $fh;
    }
}

# The pid that INSTALLED the INT/TERM cleanup handler below (m4) -- set the
# moment run_sweep() starts, i.e. the top-level sweep process, never a forked
# worker. A worker inherits the SAME %SIG entries by fork semantics, and must
# NOT act on them: removing the shared sweep root out from under sibling
# workers still using their own per-file subdirectory would be its own bug.
my $SWEEP_OWNER_PID;

# _force_remove_tree($dir) -> 1 (fully removed) | 0 (left something behind,
# reported to STDERR). FIX-BATCH M1 (review, step 7): the previous
# `remove_tree(..., { safe => 1 })` silently skips any file that is not
# writable (a git object is 0444), so a sandbox holding one leaked FOREVER
# and the failure was swallowed by an `eval`. Clearing every read-only bit
# first (finddepth so files are cleared before their parent dir) and dropping
# `safe => 1` means the only thing that can still block removal is something
# genuinely outside this process's control (e.g. a file another process still
# has open) -- and that case is now reported by name instead of silently
# leaked.
sub _force_remove_tree {
    my ($dir) = @_;
    return 1 unless defined $dir && length $dir && -e $dir;
    eval {
        File::Find::finddepth(sub {
            chmod(0777, $File::Find::name) if -e $File::Find::name;
        }, $dir);
    };
    chmod(0777, $dir) if -e $dir;
    # File::Path::remove_tree's `error` option wants a SCALAR ref (which it
    # then points at a fresh arrayref itself) -- NOT an arrayref directly.
    # Passing \@errors dies with "Not a SCALAR reference", which the eval
    # below swallowed, leaving remove_tree() never actually called.
    my $errors_ref;
    eval { remove_tree($dir, { error => \$errors_ref }) };
    my @errors = (ref $errors_ref eq 'ARRAY') ? @$errors_ref : ();
    if (@errors) {
        for my $e (@errors) {
            my ($file, $msg) = %$e;
            $file = $dir unless length $file;
            print STDERR "sandbox not fully removed: $file ($msg)\n";
        }
        return 0;
    }
    return 1;
}

# _install_sweep_cleanup_handlers() -- FIX-BATCH m4 (review, step 7): a
# `timeout N perl scripts/run-tests.pl` or an operator Ctrl-C used to leave
# the sweep root (and every live per-file dir under it) behind with no
# cleanup at all. Installed once, at the very start of run_sweep(); guarded
# by $SWEEP_OWNER_PID so a forked worker (which inherits these same %SIG
# entries) never acts on a signal meant for the parent.
sub _install_sweep_cleanup_handlers {
    $SWEEP_OWNER_PID = $$;
    my $handler = sub {
        my ($sig) = @_;
        return unless defined $SWEEP_OWNER_PID && $$ == $SWEEP_OWNER_PID;
        unless ($KEEP_SANDBOX) {
            if (defined $SANDBOX_REGISTRY_PATH && -f $SANDBOX_REGISTRY_PATH) {
                if (open my $fh, '<', $SANDBOX_REGISTRY_PATH) {
                    while (my $line = <$fh>) {
                        $line =~ s/\s+\z//;
                        _force_remove_tree($line) if length $line;
                    }
                    close $fh;
                }
                unlink $SANDBOX_REGISTRY_PATH;
            }
        }
        exit(1);
    };
    $SIG{INT}  = $handler;
    $SIG{TERM} = $handler;
}

# _short_tmp_base() -> $dir | undef -- on this project's actual host (a
# cygwin/msys-flavored Git-for-Windows perl), "/tmp" is a real, writable
# mount aliasing the same physical directory $ENV{TEMP} names, but through a
# MUCH shorter path (4 bytes vs. the operator's real
# "C:\Users\<name>\AppData\Local\Temp", 30+ bytes on this machine). Package
# 21's own File::Temp::tempdir() calls default to whatever
# File::Spec->tmpdir() resolves given the AMBIENT %ENV at the moment this
# process started -- and that resolution was observed to be unstable across
# otherwise-identical invocations (sometimes the short "/tmp" alias,
# sometimes the long %ENV{TMPDIR}-derived path), which is exactly the
# nondeterminism that let this package's own sandbox occasionally build
# fixture paths long enough to cross BpHook::Guards::Common::path_echo's
# 90-character display-truncation threshold -- a threshold no PLAIN `perl
# some.t` run ever approaches, because a bare run's own File::Temp calls are
# not nested inside this runner's extra sandbox-root/per-file layers to begin
# with. Preferring the short alias whenever it truly exists and is writable
# removes both problems at once: deterministic AND short. Falls back to
# File::Spec->tmpdir() (via a DIR-less tempdir() call) when "/tmp" is not a
# real, writable directory on this host (e.g. a non-Windows CI runner where
# "/tmp" already IS the real system tmpdir and this helper is a no-op).
sub _short_tmp_base {
    return '/tmp' if -d '/tmp' && -w '/tmp';
    return undef;
}

# _sandbox_base() -> $dir -- the (static, always-exists) directory every
# per-file sandbox is created DIRECTLY under, each carrying its own
# $SWEEP_TEMPLATE-prefixed name (see that variable's header comment for why
# there is deliberately no wrapping per-sweep directory any more). Memoized
# only so every call in one process agrees, not because anything here is
# expensive to recompute.
sub _sandbox_base {
    return $SANDBOX_SWEEP_ROOT if defined $SANDBOX_SWEEP_ROOT;
    $SANDBOX_SWEEP_ROOT = _short_tmp_base() // File::Spec->tmpdir();
    return $SANDBOX_SWEEP_ROOT;
}

# TestPlatform is package 01's sole decision point for a file's platform
# marker; loaded by literal path (not `use lib` + `use TestPlatform`) because
# this is a top-level script, not a package, and $ROOT_ABS is only known at
# runtime, not at BEGIN time.
require File::Spec->catfile($ROOT_ABS, qw(plugins butler tests lib TestPlatform.pm));

# NO TEST RUN MAY ACTUATE A REAL OS WAKE-LOCK.
#
# bp-keepawake.pl and BpContinuityLease.pm each refuse when $0 ends in ".t", and
# that covers a test calling them in-process. It does NOT cover the common case:
# a test that shells out to `perl butler-continuity.pl arm`, whose child sees $0 as a
# .pl and happily fork+execs a detached refresher and a real keep-awake.ps1 with
# its -PidFile pointing into a File::Temp directory. That is how 53 orphaned
# helpers once filled this machine and forced a restart.
#
# Every test file that drives those scripts sets this itself (enforced by
# plugins/butler/tests/t/test-wakelock-hygiene.t, which is what makes a direct
# `perl some.t` safe too). Setting it here as well means a SWEEP is safe even
# for a file nobody has classified yet — the guarantee should not depend on
# whoever adds the next test having read the rule.
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

# spend-token-report Decision 8: no sweep ever performs a live pricing fetch.
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;

# RunTestsContainerLane -- package 05's run-tests-container.pl, required into
# an ISOLATED namespace rather than main:: (blueprint test-platform-split,
# package 06-route-by-marker, spec section 2.3). Neither file declares its own
# `package`, so a plain `require` of one into the other's main:: would let a
# same-named sub silently overwrite the other's definition with no
# compile-time warning -- both files define `sub _usage` today (different
# bodies), and a future rename of run_sweep() to the more obvious `main` would
# collide with this file's own `sub main`. Every sub/`our`-variable
# run-tests-container.pl defines lands in RunTestsContainerLane:: instead:
# RunTestsContainerLane::podman_bin(), ::image_present(...),
# ::build_run_argv(...), ::run_one_in_container(...),
# $RunTestsContainerLane::IMAGE, $RunTestsContainerLane::ACTIVE_CONTAINER_NAME,
# etc. Requiring it here runs its own top-level statements (the
# MSYS2_ARG_CONV_EXCL assignment, the %SIG{INT,TERM,HUP} handler install, the
# END block) but never its main() (guarded by its own "unless caller()") --
# harmless while $ACTIVE_CONTAINER_NAME is undef, which is true for the whole
# life of any invocation that never routes a file into the container lane.
#
# FIX-BATCH C1/A1 (CRITICAL, step 7): the require above used to leave
# $ENV{MSYS2_ARG_CONV_EXCL} = '*' set for the rest of THIS process's life the
# moment run-tests-container.pl's own top-level statement ran -- and every
# one of the ~350 test children run_one()'s backticks spawn inherits this
# process's %ENV. That is the exact shell-wide condition both CLAUDE.md files
# forbid by name: disabling MSYS2 argv conversion while bare /c/... paths are
# still passed elsewhere resolves the leading slash against the current
# drive (576 stray drive-root entries on 2026-06-12). The opt-out and package
# 05's own hand-translation (_winify_path) are one technique, never
# alternatives, and only the container-batch code below actually needs the
# opt-out -- so it is scoped here (snapshotted and restored immediately
# around the require) and again, LOCALLY, inside _run_container_batch()
# itself (the only place package 05's git/podman calls that pair with it
# actually run).
my $__msys2_before_container_require =
    exists $ENV{MSYS2_ARG_CONV_EXCL} ? $ENV{MSYS2_ARG_CONV_EXCL} : undef;
package RunTestsContainerLane;
require File::Spec->catfile($ROOT_ABS, qw(scripts run-tests-container.pl));
package main;
if (defined $__msys2_before_container_require) {
    $ENV{MSYS2_ARG_CONV_EXCL} = $__msys2_before_container_require;
} else {
    delete $ENV{MSYS2_ARG_CONV_EXCL};
}

sub _usage { return <<'USAGE' }
usage: perl scripts/run-tests.pl [--fast] [--jobs N] [--nice] [--state=failed] [--keep-sandbox] [--ledger PATH] [PATH-OR-GLOB ...]
  --fast          skip the host-serial lane. Membership is a TEXT MATCH on a file's own source, NOT an answer to "does this start a real container" -- a file that merely mentions the container helpers is skipped too (report 20260918-042312-02db). The summary names every file skipped, so check it rather than reading "0 serial" as "there were none". This does NOT touch the container LANE below -- if that is enabled, its files still run there regardless of --fast.
  --jobs N        parallelism for non-container tests (default: cores - 2)
  --nice          low-impact mode: cap parallelism at max(2, cores/4), leaving the machine usable for whoever else is on it. Does not touch OS scheduling priority (spawned git/podman children aren't covered by that). Env var CCPRAXIS_TEST_JOBS=N sets the same kind of ambient low-impact default without a per-run flag.
  --state=failed  re-run only the files recorded failing by the previous run
  --keep-sandbox  do not remove each file's per-file sandbox HOME after it runs (package 21-test-sandbox). Default: removed.
  --ledger PATH   name the package ledger this run validates (must exist; exit 2 otherwise). The validation interlock scopes the run to that package's write set, and the run also runs the repo lints once each (tooling-fixes 07), reporting a red that also fails at HEAD as pre-existing.

Precedence for parallelism (most to least specific):
  --jobs N  >  --nice  >  CCPRAXIS_TEST_JOBS env var  >  default (cores - 2)

Container lane (opt-in, off by default -- a lane-AVAILABILITY switch, never a routing switch; see classify_file()'s own header comment):
  CCPRAXIS_CONTAINER_LANE_ENABLED=1|true|yes|on   run any/linux-marked, non-serial-classified files inside the existing claude-sandbox:latest container instead of on this host. Any other value (unset, "", "0", "false", "no", "off", ...) means OFF -- those files simply run on the host instead, exactly as before this env var existed. Only the whole working tree that was last committed is reflected in the container (package 05's own limitation), so an ordinary sweep tests HEAD, not uncommitted edits, for every file this sends there.
USAGE

# --- tooling-fixes 07: repo-lint mode helpers --------------------------------
#
# _lint_root() -- the tree a --ledger run's repo lints are read from and
# compared against HEAD in. CCPRAXIS_TEST_LINT_ROOT, if set and non-empty, is
# a test-isolation hook (same convention as CCPRAXIS_TEST_STATE_DIR), used
# verbatim: no abs_path, no separator folding. Read only in lint mode.
#
# FIX-BATCH M1 (red-team, step 7): CCPRAXIS_TEST_LINT_ROOT used to be honored
# in a REAL (non-test) invocation too -- a worker could point the lints at a
# directory of green stubs and get exit 0, with only a stdout "(root: ...)"
# line revealing it. Gated behind CCPRAXIS_TEST_STATE_DIR also being set and
# non-empty: every oracle invocation in this suite that sets
# CCPRAXIS_TEST_LINT_ROOT sets CCPRAXIS_TEST_STATE_DIR in the SAME env hash
# (the harness's own convention -- see validation-runs-repo-lints.t and
# runner-ledger-flag.t), so this is inert for exactly nothing the oracles
# exercise, and inert for a real run, which has no reason to ever set either.
sub _lint_root {
    return $ENV{CCPRAXIS_TEST_LINT_ROOT}
        if defined $ENV{CCPRAXIS_TEST_LINT_ROOT} && length $ENV{CCPRAXIS_TEST_LINT_ROOT}
        && defined $ENV{CCPRAXIS_TEST_STATE_DIR} && length $ENV{CCPRAXIS_TEST_STATE_DIR};
    return $ROOT_ABS;
}

# _path_identity($path) -- the same "is this the same file" test the
# collection step uses to avoid adding a lint a target already selected
# (spec section 2.4): Cwd::abs_path, falling back to the path itself when
# abs_path can't resolve it (e.g. a path under a HEAD snapshot that no
# longer exists by the time this is called), backslashes folded to forward
# slashes, lowercased on a Windows-family perl (case-insensitive filesystem).
sub _path_identity {
    my ($p) = @_;
    my $id = Cwd::abs_path($p);
    $id = $p unless defined $id;
    $id =~ s{\\}{/}g;
    $id = lc($id) if $^O =~ /^(MSWin32|cygwin|msys)$/;
    return $id;
}

# _drive_form($p) -- "/c/x" -> "C:/x"; undef when $p is not that shape.
sub _drive_form {
    my ($p) = @_;
    return "\U$1\E:/$2" if defined $p && $p =~ m{^/([A-Za-z])/(.*)$};
    return undef;
}

# _backslash_form($p) -- $p with every forward slash turned into a backslash;
# undef when that is a no-op (nothing to add as a distinct spelling).
sub _backslash_form {
    my ($p) = @_;
    return undef unless defined $p;
    (my $b = $p) =~ s{/}{\\}g;
    return $b eq $p ? undef : $b;
}

# _root_spellings($r) -> @spellings, longest first -- every textual form a
# tree root $r might appear as inside a lint's own TAP output (spec section
# 2.5 step 3): $r itself; Cwd::abs_path($r) when defined; the drive form of
# each; the backslash form of each of those. Longest-first so a substring
# spelling (e.g. the bare drive-relative form) never partially shadows a
# longer one when both are replaced by sub.
sub _root_spellings {
    my ($r) = @_;
    my (@out, %seen);
    my $add = sub {
        my ($s) = @_;
        return unless defined $s && length $s;
        push @out, $s unless $seen{$s}++;
    };
    my @base = ($r);
    my $abs = Cwd::abs_path($r);
    push @base, $abs if defined $abs;
    $add->($_) for @base;
    my @drive = grep { defined } map { _drive_form($_) } @base;
    $add->($_) for @drive;
    my @backslash = grep { defined } map { _backslash_form($_) } @out;
    $add->($_) for @backslash;
    return sort { length($b) <=> length($a) } @out;
}

# _lint_signature($out, $root) -> \@sorted_normalised_lines -- spec section
# 2.5 step 3's sig(): the set of "not ok"/comment lines (excluding a "# Looks
# like ..." summary line), with the "not ok" test number blanked and every
# occurrence of $root's own spellings replaced by "<ROOT>", longest spelling
# first so one spelling never partially shadows another.
sub _lint_signature {
    my ($out, $root) = @_;
    my @spellings = _root_spellings($root);
    my %sig;
    for my $line (split /\r?\n/, (defined $out ? $out : '')) {
        next unless $line =~ /^not ok\b/ || $line =~ /^\s*#/;
        next if $line =~ /^\s*#\s*Looks like /;
        (my $norm = $line) =~ s/^not ok \d+/not ok/;
        for my $sp (@spellings) {
            my $q = quotemeta($sp);
            $norm =~ s/$q/<ROOT>/g;
        }
        $sig{$norm} = 1;
    }
    return [ sort keys %sig ];
}

# _run_git_capture(@cmd) -> ($out, $rc) -- list-form fork+exec (no shell, no
# string interpolation anywhere in the command line: every element of @cmd
# reaches exec() as its own argv entry). stderr is folded into the captured
# stdout (same "caller only cares about rc, output is for a diagnostic
# string" contract the old backtick calls had). (red-team LOW, step 7:
# replaces the backtick `git -C "$root" ...` forms below, which ran through a
# real shell -- a $root/rev containing `$(...)` was live shell syntax there.)
sub _run_git_capture {
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    return (undef, -1) unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&', \*STDOUT) or close(STDERR);
        open(STDIN, '<', File::Spec->devnull) or close(STDIN);
        exec(@cmd) or POSIX::_exit(127);
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    return (defined $out ? $out : '', $rc);
}

# _head_rev_parse_rc($root, $rev) -> $rc -- `git -C $root rev-parse --verify
# -q $rev`'s exit code (0 == $rev resolves). $rev defaults to 'HEAD'. List-
# form (_run_git_capture), never a shell.
sub _head_rev_parse_rc {
    my ($root, $rev) = @_;
    $rev = 'HEAD' unless defined $rev && length $rev;
    my (undef, $rc) = _run_git_capture('git', '-C', $root, 'rev-parse', '--verify', '-q', $rev);
    return $rc;
}

# _ledger_blueprint($ledger_path) -> $blueprint_name | undef -- the blueprint
# a --ledger path belongs to, read straight off the path's own
# ".../blueprints/<blueprint>/packages/..." shape (the same layout every real
# package ledger lives at; bp-baseline.pl's ref is keyed on this same name).
# undef for anything else (a bare fixture path, as every oracle in this suite
# uses) -- callers must treat that as "no baseline ref to even try".
sub _ledger_blueprint {
    my ($ledger_path) = @_;
    return undef unless defined $ledger_path && length $ledger_path;
    (my $norm = $ledger_path) =~ s{\\}{/}g;
    return $1 if $norm =~ m{/blueprints/([^/]+)/packages/};
    return undef;
}

# _first_non_wip_rev($root) -> $rev | undef -- walks `git log` from HEAD
# backward (newest first) and returns the first commit whose subject does NOT
# match bp-checkpoint.pl's own `wip(<pkg>): ...` shape (is_checkpoint_subject,
# \A\s*wip\( ), i.e. the fallback half of H1 (red-team, step 7) for a repo/
# branch with no refs/butler/baseline/<blueprint> ref recorded at all (outside
# a blueprint run, or before bp-baseline.pl has ever advanced one). Bounded at
# 200 commits -- deliberately not unbounded (this already walks history on
# every red-lint run; see spec section 5's documented no-timeout limitation).
# undef only when $root has no commit at all (HEAD itself doesn't resolve).
sub _first_non_wip_rev {
    my ($root) = @_;
    return undef if _head_rev_parse_rc($root, 'HEAD') != 0;
    my ($out, $rc) = _run_git_capture('git', '-C', $root, 'log', '--format=%H %s', '-n', '200', 'HEAD');
    return 'HEAD' if $rc != 0 || !defined $out || !length $out;
    my $last_sha;
    for my $line (split /\n/, $out) {
        next unless $line =~ /^(\S+)(?:\s(.*))?$/;
        my ($sha, $subj) = ($1, $2);
        $last_sha = $sha;
        return $sha unless defined $subj && $subj =~ /\A\s*wip\(/;
    }
    return defined $last_sha ? $last_sha : 'HEAD';
}

# _resolve_baseline_rev($root, $ledger_path) -> $rev | undef -- H1 (red-team,
# step 7). The comparison baseline used to be bare HEAD unconditionally,
# which is wrong under dispatch-fleet specifically: the orchestrator makes
# `wip(<pkg>): ...` checkpoint commits (orchestrator-protocol/SKILL.md) BEFORE
# this package's own validation step runs, so by the time this comparison
# fires, HEAD already contains the very regression this feature exists to
# catch -- it reads as "pre-existing" and the exit code stays 0.
# refs/butler/baseline/<blueprint> (bp-baseline.pl's own ref, advanced only
# past done+harvest-passed work -- it skips WIP commits by construction) is
# tried first, keyed off the blueprint name embedded in --ledger's own path.
# Falls back to _first_non_wip_rev when that ref is absent (no blueprint name
# parseable from $ledger_path, or the ref itself doesn't exist yet) --
# drive-solo and every oracle in this suite land here, and get the exact same
# answer bare HEAD used to give (no WIP commits -> first commit IS HEAD).
sub _resolve_baseline_rev {
    my ($root, $ledger_path) = @_;
    my $blueprint = _ledger_blueprint($ledger_path);
    if (defined $blueprint) {
        my $ref = "refs/butler/baseline/$blueprint";
        return $ref if _head_rev_parse_rc($root, $ref) == 0;
    }
    return _first_non_wip_rev($root);
}

# _materialize_head_archive($root, $dest, $rev) -> $rc -- `git archive $rev`
# piped into `tar -x -C $dest` entirely in Perl (two list-form children, this
# process pumping the bytes between them) -- no shell, no string
# interpolation anywhere (red-team LOW, step 7: the previous `/bin/sh -c`
# form built a shell command line; even though its own quoting happened to
# neutralise `$(...)`, a lint-root path is untrusted input and this removes
# the shell from the picture entirely rather than relying on quoting being
# right forever). $rev defaults to 'HEAD'. Must never write anything into
# $root itself (no worktree/stash/checkout/reset).
sub _materialize_head_archive {
    my ($root, $dest, $rev) = @_;
    $rev = 'HEAD' unless defined $rev && length $rev;

    my $git_pid = open(my $git_fh, '-|', 'git', '-C', $root, 'archive', $rev);
    return -1 unless defined $git_pid;
    binmode $git_fh;

    my $tar_pid = open(my $tar_fh, '|-', 'tar', '-x', '-C', $dest);
    unless (defined $tar_pid) {
        close $git_fh;
        return -1;
    }
    binmode $tar_fh;

    my $buf;
    while (my $n = sysread($git_fh, $buf, 65536)) {
        last unless $n > 0;
        my $off = 0;
        while ($off < $n) {
            my $w = syswrite($tar_fh, $buf, $n - $off, $off);
            last unless defined $w;
            $off += $w;
        }
    }
    close $git_fh;
    my $git_rc = $? == -1 ? -1 : ($? >> 8);
    close $tar_fh;
    my $tar_rc = $? == -1 ? -1 : ($? >> 8);
    return $git_rc != 0 ? $git_rc : $tar_rc;
}

# --- state file (--state=failed) --------------------------------------------
# Path: .ccpraxis-local-data/test-state/last-failures.txt, relative to $ROOT_ABS.
# CCPRAXIS_TEST_STATE_DIR, if set and non-empty, replaces just the directory
# component -- test-isolation hook only, not a documented user flag.
sub _state_dir {
    return $ENV{CCPRAXIS_TEST_STATE_DIR}
        if defined $ENV{CCPRAXIS_TEST_STATE_DIR} && length $ENV{CCPRAXIS_TEST_STATE_DIR};
    return File::Spec->catdir($ROOT_ABS, '.ccpraxis-local-data', 'test-state');
}
sub _state_file_path { return File::Spec->catfile(_state_dir(), 'last-failures.txt') }

sub _read_state_file {
    my $path = _state_file_path();
    return () unless -f $path;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $raw = <$fh>;
    close $fh;
    return () unless defined $raw && length $raw;

    # NORMALISE ON READ TOO, not only on write. Report 20260916-162952-5ae3.
    #
    # Folding `x/../` in _relpath stops NEW mismatched entries being recorded.
    # It does nothing for the ones already on disk: %ran is keyed on the freshly
    # computed shape, a stored entry in the old shape never matches it, so the
    # merge reads it as "not touched by this run" and carries it forward --
    # forever. Measured after fixing only the write side: all three phantom
    # entries survived a run that executed those exact files and reported them
    # green.
    #
    # A fix that cannot clear the entries that prompted the report is half a
    # fix, and the half that looks finished.
    my @out;
    for my $l (split /\n/, $raw) {
        next unless length $l;
        $l =~ s{\\}{/}g;
        $l =~ s{^\./}{};
        1 while $l =~ s{(?:^|/)(?!\.\./)[^/]+/\.\./}{/};
        $l =~ s{^/}{};
        push @out, $l;
    }
    return @out;
}

# _to_abs($relpath) -- reconstructs a real path from a relpath recorded in the
# state file, anchored on $ROOT_ABS so it works whether the recorded entry is
# a real repo file (plugins/foo/tests/t/bar.t) or a fixture path outside the
# repo tree entirely (../../../tmp/xxx/tests/t/bar.t, in the test suite).
sub _to_abs { my ($rel) = @_; return File::Spec->rel2abs($rel, $ROOT_ABS) }

# _relpath($abs) -- the inverse: a forward-slash path relative to $ROOT_ABS,
# used both to write the state file and to decide what "this invocation
# actually ran" (%ran) means for the merge in the report phase below.
# Deliberately does NOT re-resolve $abs through abs_path(): on this host's
# perl, /tmp is a mount point whose realpath differs from its own name, and
# resolving it here would disagree with how fixture paths are constructed
# and compared elsewhere (RunnerStateHarness::relpath_from_root does the
# same plain abs2rel, no realpath, for exactly this reason).
sub _relpath {
    my ($abs) = @_;
    my $rel = File::Spec->abs2rel($abs, $ROOT_ABS);
    $rel =~ s{\\}{/}g;
    # A refusal message exists so a human can FIND the file. $ROOT_ABS on this
    # host is always MSYS-style (/c/Development/ccpraxis); an explicit target
    # given/produced in Windows drive-letter style (C:/Users/...) has no
    # common ancestor abs2rel can express cleanly, so the "relative" result
    # still embeds the raw "C:/..." segment after a run of "../" hops
    # (reproduced live: "../../../../C:/Users/..."). That is longer AND
    # harder to follow than either a clean relative or a clean absolute path
    # -- worse than doing nothing. Fall back to the absolute path whenever
    # the computed "relative" form still looks like a second drive-letter
    # path spliced onto a climb; this never fires for a real in-tree file
    # (fix-batch 03-enforce-marker step 7, finding A3).
    return $abs if $rel =~ m{^(?:\.\./)*[A-Za-z]:[/\\]};

    # COLLAPSE INTERIOR `x/../` LEXICALLY. Report 20260916-162952-5ae3, the
    # over-reporting half, and this is its mechanism -- found by reading the
    # state file rather than by reasoning about it. It currently holds TWO
    # SHAPES FOR THE SAME TREE:
    #
    #   plugins/butler/tests/t/wait-shape-guard.t                <- one shape
    #   scripts/../plugins/butler/tests/t/cache-state.t          <- the other
    #
    # abs2rel does no `..` folding, so an $abs that arrived with an interior
    # climb keeps it. Both forms RESOLVE on disk, so the vanished-entry pruning
    # never removes the odd one -- and because %ran is keyed on the freshly
    # computed shape, the stale shape is never "touched by this run" either, so
    # the merge carries it forward FOREVER. That is a permanent phantom entry:
    # a file reported failing that passes when you run it, which is exactly
    # what this report measured and what makes the baseline untrustworthy.
    #
    # Measured 2026-09-17: three such entries, all three green standalone --
    # cache-state.t, git-mutation-guard-reach.t, animation-cadence.t, the last
    # two fixed earlier the same day and unable to clear themselves.
    #
    # LEXICAL, not realpath, and deliberately so: the comment above explains why
    # this function must not re-resolve, and folding `a/b/../c` to `a/c` is a
    # pure string operation that cannot disagree with how fixture paths are
    # constructed elsewhere. A LEADING `../` is left alone -- it means genuinely
    # outside the tree and there is nothing to fold it against.
    $rel =~ s{^\./}{};
    1 while $rel =~ s{(?:^|/)(?!\.\./)[^/]+/\.\./}{/};
    $rel =~ s{^/}{};

    return $rel;
}

sub _write_state_atomic {
    my ($lines) = @_;
    my $dir = _state_dir();
    make_path($dir) unless -d $dir;
    my $final_path = _state_file_path();
    my $tmp_path   = "$final_path.tmp.$$";
    open my $fh, '>:raw', $tmp_path or die "cannot write $tmp_path: $!";
    print {$fh} "$_\n" for @$lines;
    close $fh;
    unless (rename($tmp_path, $final_path)) {
        unlink $final_path;
        rename($tmp_path, $final_path)
            or warn "run-tests.pl: cannot rename $tmp_path to $final_path: $!";
    }
}

# --- durations (longest-first scheduling) -----------------------------------
# test-state/durations.tsv: one "<seconds>\t<relpath>" line per file, merged
# on every sweep exactly like the failure state (a file this run did not
# execute keeps its last timing; a vanished file is dropped).
#
# WHY. The parallel queue ran in alphabetical order, so where the slowest
# files landed was an accident of their names. Measured 2026-09-23 at -j2:
# almanac-store-ordering.t alone took 440s of a 1957s sweep; started late,
# it is the tail every other worker idles behind. Starting the longest
# files first (LPT scheduling) bounds that tail by the longest single file
# rather than by where it sorts.
sub _durations_path { return File::Spec->catfile(_state_dir(), 'durations.tsv') }

sub _read_durations {
    my %d;
    open my $fh, '<:raw', _durations_path() or return \%d;
    while (my $l = <$fh>) {
        $l =~ s/\r?\n\z//;
        my ($secs, $rel) = split /\t/, $l, 2;
        next unless defined $rel && length $rel && defined $secs && $secs =~ /\A\d+(?:\.\d+)?\z/;
        $d{$rel} = $secs + 0;
    }
    close $fh;
    return \%d;
}

sub _write_durations {
    my ($d) = @_;
    my $dir = _state_dir();
    make_path($dir) unless -d $dir;
    my $final = _durations_path();
    my $tmp   = "$final.tmp.$$";
    open my $fh, '>:raw', $tmp or return;
    print {$fh} "$d->{$_}\t$_\n" for sort keys %$d;
    close $fh;
    unless (rename($tmp, $final)) {
        unlink $final;
        rename($tmp, $final) or warn "run-tests.pl: cannot rename $tmp to $final: $!";
    }
}

# _order_longest_first(\@abs_files, \%durations_by_relpath) -> @abs_files.
# Pure. Longest recorded time first; a file with no recorded time goes
# before every timed one (it is new or renamed, and may be slow); ties,
# including a first-ever run with no timings at all, keep path order.
sub _order_longest_first {
    my ($files, $dur) = @_;
    my %t = map { ($_ => $dur->{ _relpath($_) }) } @$files;
    return sort {
        (defined $t{$b} ? 0 : 1) <=> (defined $t{$a} ? 0 : 1)
            || ($t{$b} // 0) <=> ($t{$a} // 0)
            || $a cmp $b
    } @$files;
}

sub _cores {
    return $ENV{NUMBER_OF_PROCESSORS} if $ENV{NUMBER_OF_PROCESSORS} && $ENV{NUMBER_OF_PROCESSORS} =~ /^\d+$/;
    if (open my $c, '<', '/proc/cpuinfo') {
        my $n = grep { /^processor\s*:/ } <$c>;
        close $c;
        return $n if $n;
    }
    return 4;
}

# _resolve_jobs(%args) -> $jobs
# Pure by construction (every input is a parameter, nothing read from %ENV or
# @ARGV directly) so the precedence chain is unit-testable without spawning
# the runner. Precedence, most to least specific:
#   explicit_jobs (--jobs N)  >  nice (--nice)  >  env_jobs (CCPRAXIS_TEST_JOBS)
#   >  the plain cores-2 default (unchanged from before --nice existed).
sub _resolve_jobs {
    my (%a) = @_;
    my $cores = $a{cores} || 4;

    return $a{explicit_jobs} if $a{explicit_jobs};

    if ($a{nice}) {
        my $n = int($cores / 4);
        $n = 2 if $n < 2;
        return $n;
    }

    if (defined $a{env_jobs} && $a{env_jobs} =~ /^\d+$/ && $a{env_jobs} > 0) {
        return $a{env_jobs};
    }

    return $cores > 3 ? $cores - 2 : 1;
}

# run_one($file) -> \%result. The judgement rule the project already uses by
# hand: non-zero exit is red, and the `not ok` count says whether it was a
# failed assertion or the process dying (EXIT != 0 with NOTOK == 0 is the
# signature of a timeout or a kill, not a broken expectation).
# _skip_all_reason($out) -> $reason | undef -- true iff $out carries a bare
# "1..0" plan line (Test::More's plan skip_all => $reason shape: "1..0 #
# SKIP $reason", case-insensitive on SKIP). Returns the reason text (may be
# empty) when found, undef otherwise -- undef is the "not a skip_all file"
# signal, distinct from a skip with an empty reason.
sub _skip_all_reason {
    my ($out) = @_;
    return undef unless defined $out;
    return undef unless $out =~ /^1\.\.0\s*(?:#\s*(?:SKIP\S*\s*)?(.*))?$/mi;
    my $reason = defined $1 ? $1 : '';
    $reason =~ s/\s+\z//;
    return $reason;
}

# run_one($file) -> \%result. The judgement rule the project already uses by
# hand: non-zero exit is red, and the `not ok` count says whether it was a
# failed assertion or the process dying (EXIT != 0 with NOTOK == 0 is the
# signature of a timeout or a kill, not a broken expectation).
#
# PACKAGE 21-TEST-SANDBOX: every invocation below runs inside a fresh,
# throwaway HOME/USERPROFILE/APPDATA/LOCALAPPDATA/TEMP/TMP/TMPDIR/
# BUTLER_STATE_DIR/CCPRAXIS_CONTINUITY_ACTIVE_DIR -- a per-file subdirectory
# of the sweep-wide sandbox root -- so a test that writes real user state
# (a hook's own $HOME/.claude/butler-state, a lease file, etc.) never
# touches the operator's actual home directory. `local %ENV = %ENV` scopes
# every override to this call: the parent (serial phase) and any later
# sibling call in the SAME process see the unmodified %ENV again once this
# sub returns. GIT_CONFIG_GLOBAL is pointed at the REAL global gitconfig
# (captured at load time, above) so `git commit`/`git config` inside a test
# still resolve an identity even though HOME no longer does.
sub run_one {
    my ($f) = @_;
    # Sub-second: durations.tsv orders the next sweep, and whole seconds
    # tie every short file together.
    my $t0  = Time::HiRes::time();
    # FIX-BATCH M3 (step 7): the container-lane opt-in is a property of the
    # invocation a human/agent made, not of the process tree it spawns.
    # Without this, a nested `perl scripts/run-tests.pl` invoked BY one of
    # the swept files below (five host-lane tests do exactly this, via
    # RunnerStateHarness::spawn_runner) would inherit the outer sweep's own
    # opt-in and start a REAL container from inside a test, with no ceiling
    # on how many. `local` + `delete` scopes the removal to this call only.
    local $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED};
    delete $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED};

    local %ENV = %ENV;

    # FIX-BATCH M3 (review, step 7): every ambient ccpraxis path variable a
    # dispatched worker/agent carries (BP_LEDGER and its many siblings,
    # CCPRAXIS_DATA_DIR, CLAUDE_PROJECT_DIR, CLAUDE_CONFIG_DIR, ALMANAC_HOME)
    # used to pass straight through to every test unchanged -- a test that
    # shells out to bp-ledger.pl or similar without itself scrubbing these
    # would mutate REAL, LIVE blueprint/almanac/claude-config state. Deleted
    # BEFORE the sandbox overrides below so nothing here can resurrect one.
    for my $k (keys %ENV) {
        delete $ENV{$k} if $k =~ /^BP_/;
    }
    delete $ENV{$_} for qw(CCPRAXIS_DATA_DIR CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR ALMANAC_HOME);
    # tooling-fixes 07: a lint-root override is a test-isolation hook for THIS
    # process's own lint collection, never something a child (including a
    # nested runner) should inherit.
    delete $ENV{CCPRAXIS_TEST_LINT_ROOT};

    my $base    = _sandbox_base();
    my $sandbox = File::Temp::tempdir($SWEEP_TEMPLATE, DIR => $base, CLEANUP => 0);
    _register_sandbox_dir($sandbox);

    # Package 10-nested-runner-audit (Decision 28, amendment 1 -- red-team
    # MEDIUM-1): every host test process this runner starts sees
    # CCPRAXIS_SWEEP_OWNS_AUDIT set to this SAME per-file sandbox path it is
    # about to assign to $ENV{HOME} below, whether or not THIS process itself
    # inherited the marker (see $ENCLOSING_SWEEP_OWNS_AUDIT above, captured
    # before this sub could ever run). Placed AFTER the scrub above so no
    # future scrub addition can delete it by accident -- it matches neither
    # ^BP_ nor CCPRAXIS_TEST_LINT_ROOT, so it was never at risk from the
    # existing deletes, but the ordering keeps that true structurally, not by
    # luck. Placed AFTER $sandbox exists (not before, as the unhardened
    # version had it) because the value IS that path -- a nested runner
    # trusts the marker only when it equals its own inherited HOME, that path
    # exists on disk, and its basename has the expected sweep-template shape;
    # a bare hand-typed literal can no longer satisfy any of that. A runner
    # nested under this one inherits it and skips its own audit, printing one
    # notice line in place of it; this outer process's own audit is
    # unaffected (it decided already, at load time).
    $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT} = $sandbox;
    # TMPDIR points at $sandbox itself now, NOT a "Temp" subdirectory of it.
    # A fixture's own File::Temp/File::Spec->tmpdir()-based tempfiles landing
    # in the same directory as its sandboxed HOME is harmless (nothing here
    # or in any test depends on them differing) -- but the extra path
    # SEGMENT that subdirectory used to add was not harmless: it was one of
    # the layers of nesting (sweep root / per-file sandbox / "Temp" / a
    # fixture's own tempdir()) that pushed an otherwise-ordinary fixture path
    # past BpHook::Guards::Common::path_echo's 90-character
    # display-truncation threshold, a threshold a bare `perl some.t` run
    # never approaches because it never nests inside any of this runner's
    # own sandbox layers to begin with. Combined with _short_tmp_base()
    # above (deterministically short SWEEP root and per-file sandbox
    # names), this keeps a sandboxed fixture's own tempdir()-based paths
    # close to what the SAME fixture would get run plain.
    #
    # TEMP/TMP are DELIBERATELY NOT the same value as TMPDIR/HOME here. They
    # get their OWN throwaway subdirectory, created under $REAL_WINDOWS_TMP
    # (the ambient real %TEMP%, captured at load time) rather than under
    # $sandbox -- see that variable's own comment for why a file in this
    # suite needs $ENV{TEMP} itself to stay a genuine Windows drive-letter
    # path rather than the shorter MSYS "/tmp" alias _short_tmp_base()
    # prefers for HOME. Falls back to $sandbox when the ambient TEMP/TMP was
    # missing/unusable (a non-Windows host, where "/tmp" already IS the real
    # system tmpdir and this whole distinction is moot).
    my $win_tmp = defined $REAL_WINDOWS_TMP
        ? File::Temp::tempdir($SWEEP_TEMPLATE, DIR => $REAL_WINDOWS_TMP, CLEANUP => 0)
        : $sandbox;
    _register_sandbox_dir($win_tmp) if $win_tmp ne $sandbox;
    $ENV{HOME}                              = $sandbox;
    $ENV{USERPROFILE}                       = $sandbox;
    $ENV{APPDATA}                           = File::Spec->catdir($sandbox, 'AppData', 'Roaming');
    $ENV{LOCALAPPDATA}                      = File::Spec->catdir($sandbox, 'AppData', 'Local');
    $ENV{TEMP}                              = $win_tmp;
    $ENV{TMP}                               = $win_tmp;
    $ENV{TMPDIR}                            = $sandbox;
    $ENV{BUTLER_STATE_DIR}                  = File::Spec->catdir($sandbox, '.claude', 'butler-state');
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}    = File::Spec->catdir($sandbox, 'active');
    $ENV{CCPRAXIS_NO_WAKELOCK}              = 1;
    # spend-token-report Decision 8: no per-file sandbox ever performs a live pricing fetch.
    $ENV{CCPRAXIS_SPEND_NO_FETCH}           = 1;

    # FIX-BATCH M2 (review, step 7): GIT_CONFIG_GLOBAL used to point straight
    # at the operator's REAL ~/.gitconfig -- git has no read-only mode for
    # that file, so a `git config --global ...` run by a test (or a script
    # under test) wrote the operator's real identity file. Copy it (an
    # inbound GIT_CONFIG_GLOBAL takes precedence over the load-time-captured
    # real ~/.gitconfig, so an outer override is respected rather than
    # clobbered) into the sandbox instead, and point GIT_CONFIG_GLOBAL at
    # that copy. No real source at all -> an empty file, so `git config
    # --global` inside a test still has somewhere harmless to write.
    my $sandboxed_gitconfig = File::Spec->catfile($sandbox, '.gitconfig-sandbox');
    {
        my $src = (defined $ENV{GIT_CONFIG_GLOBAL} && length $ENV{GIT_CONFIG_GLOBAL} && -f $ENV{GIT_CONFIG_GLOBAL})
            ? $ENV{GIT_CONFIG_GLOBAL}
            : $REAL_GIT_CONFIG_GLOBAL;
        if (defined $src && -f $src) {
            eval { copy($src, $sandboxed_gitconfig) };
        }
        unless (-f $sandboxed_gitconfig) {
            if (open my $fh, '>', $sandboxed_gitconfig) { close $fh }
        }
    }
    $ENV{GIT_CONFIG_GLOBAL} = $sandboxed_gitconfig;

    my $out = `perl "$f" 2>&1`;
    my $rc  = $? >> 8;
    $out = '' unless defined $out;
    my $notok = () = $out =~ /^not ok/mg;
    my $skip_reason = _skip_all_reason($out);

    unless ($KEEP_SANDBOX) {
        _force_remove_tree($sandbox);
        _force_remove_tree($win_tmp) if $win_tmp ne $sandbox;
    }

    return { file => $f, rc => $rc, notok => $notok,
             skipped => (defined $skip_reason ? 1 : 0), skip_reason => $skip_reason,
             secs => 0 + sprintf('%.1f', Time::HiRes::time() - $t0), out => $out };
}

# _marker_fix_message($file, $marker) -- the exact, pinned refusal text per
# outcome/reason (blueprint test-platform-split, package 03-enforce-marker,
# spec section 1.4). Both surfaces (this script and
# plugins/butler/tests/t/test-platform-hygiene.t) decide SOLELY through
# TestPlatform::parse_marker; this sub only turns its outcome/reason into the
# words a human fixes the file from -- never a second regex over marker
# syntax.
# _escape_marker_text($text) -- renders C0 control characters and DEL
# inertly (a readable "\xHH" escape, not silent stripping) before marker text
# reaches a terminal or the state file. Without this, a malformed marker line
# containing a raw \r or an ANSI escape reaches the printed "not ok" line
# verbatim -- a .t file can then visually spoof or overwrite its own refusal
# line during a live sweep (confirmed live by the red-team: an embedded \r
# repaints the terminal line; a raw ESC carries a full ANSI sequence through).
# This is the ONLY place marker text is rendered for output -- both callers
# below (unrecognized-value/malformed-marker-line's raw[0], and
# conflicting-markers' joined list) route through it. Escaping, not
# stripping, so the message still tells the human what is actually in their
# file (fix-batch 03-enforce-marker step 7, finding A1).
sub _escape_marker_text {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02x', ord($1))/ge;
    return $text;
}

sub _marker_fix_message {
    my ($file, $marker) = @_;
    my $rel = _relpath($file);
    my $body;
    if ($marker->{outcome} eq 'absent') {
        $body = 'no platform marker found. Fix: add "# platform: windows|linux|any" near the top '
              . 'of the file (within the first 4096 bytes).';
    } elsif ($marker->{outcome} eq 'invalid' && $marker->{reason} eq 'unrecognized-value') {
        my $raw = _escape_marker_text($marker->{raw}[0] // '');
        $body = qq{unrecognized platform value "$raw". Fix: change it to one of: windows, linux, any.};
    } elsif ($marker->{outcome} eq 'invalid' && $marker->{reason} eq 'conflicting-markers') {
        my $joined = join(', ', map { _escape_marker_text($_) } @{ $marker->{raw} // [] });
        $body = "conflicting platform markers found ($joined). Fix: keep exactly one "
              . '"# platform: ..." line with a single legal value.';
    } elsif ($marker->{outcome} eq 'invalid' && $marker->{reason} eq 'malformed-marker-line') {
        my $raw = _escape_marker_text($marker->{raw}[0] // '');
        $body = qq{malformed platform marker line ("$raw"). Fix: use exactly "# platform: windows|linux|any" }
              . '(lowercase keyword "platform", one legal value, no trailing text).';
    } else {
        # Defensive fallback for any future fourth reason value -- must never
        # fire against today's TestPlatform.pm.
        $body = 'platform marker is not legal. Fix: use exactly "# platform: windows|linux|any".';
    }
    return "PLATFORM MARKER REFUSED: $rel -- $body";
}

sub _refusal_result {
    my ($entry) = @_;
    my $msg = _marker_fix_message($entry->{file}, $entry->{marker});
    return { file => $entry->{file}, rc => 1, notok => 1, secs => 0,
             out => "not ok 1 - $msg\n", refused => 1 };
}

# classify_file($abs_path) -> \%decision | undef -- the SOLE routing
# predicate (blueprint test-platform-split, package 06-route-by-marker, spec
# section 2.1). Pure with respect to everything except reading the one file
# given; never dies; mirrors the pre-existing `open ... or next` silent-skip
# for an unreadable file by returning undef. Exactly four `lane` values:
# refused, host-serial, host-parallel, container. Takes exactly one
# parameter and reads neither %ENV nor @ARGV, by construction -- its per-file
# verdict cannot be overridden by any flag, environment variable or argument
# (Decision 18: the lane-AVAILABILITY gate lives in run_sweep()'s wiring,
# never here).
# _loads_test_sandbox($src) -> 1 | 0
# True iff $src, with WHOLE-LINE comments removed, contains a genuine
# TestSandbox-loading construct: `use TestSandbox`, `require TestSandbox`,
# a word-bounded `TestSandbox::` reference, or a quoted-string-literal
# `require "TestSandbox"` / `require "TestSandbox.pm"` (single or double
# quotes). Comment-stripping and the construct list are BOTH pinned by
# Decision 6 -- do not add quote/string masking (no real file in the
# 362-file tree needs it; see spec section 5). The quoted-literal require
# form is a narrow, statically-analyzable exception to that precedent --
# it names the module as a literal string, not via a variable -- added to
# close a confirmed false-negative regression vs. the old raw regex
# (redteam-01.md MEDIUM finding). Variable-indirected `require $mod` and
# wrapper/re-export modules remain deliberately out of scope (not
# statically analyzable from source text alone).
sub _loads_test_sandbox {
    my ($src) = @_;
    return 0 unless $src =~ /TestSandbox/;   # every branch below needs this substring
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src, -1;
    return ($code =~ /\b(?:use|require)\s+TestSandbox\b/
            || $code =~ /\bTestSandbox::/
            || $code =~ /\brequire\s+["']TestSandbox(?:\.pm)?["']/) ? 1 : 0;
}

sub classify_file {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;   # unchanged silent-skip precedent
    my $src = do { local $/; <$fh> };
    close $fh;

    my $marker = TestPlatform::parse_marker($src);
    if ($marker->{outcome} ne 'legal') {
        return { lane => 'refused', marker => $marker, serial => undef };
    }

    # PRECEDENCE (pinned, spec section 0.1): the serial heuristic outranks
    # the marker value. A file that starts real podman containers must never
    # be sent into ANOTHER container, and must never run concurrently with
    # other podman-touching work, regardless of what platform it declares
    # needing.
    my $serial = _loads_test_sandbox($src) ? 1 : 0;
    if ($serial) {
        return { lane => 'host-serial', marker => $marker, serial => 1 };
    }
    if ($marker->{value} eq 'windows') {
        return { lane => 'host-parallel', marker => $marker, serial => 0 };
    }
    # 'any' or 'linux', not serial-classified.
    return { lane => 'container', marker => $marker, serial => 0 };
}

# _container_infra_result($abs_file, $reason) -> \%result -- rc => 1,
# notok => 0 deliberately (nothing ran; no TAP was ever produced). No
# fallback to the host, ever: an unavailable container lane marks every file
# it was supposed to run as red, with a message naming why, rather than
# silently running them on the host or aborting the whole sweep.
sub _container_infra_result {
    my ($abs_file, $reason) = @_;
    my $rel = _relpath($abs_file);
    return {
        file => $abs_file, rc => 1, notok => 0, secs => 0,
        out  => "CONTAINER LANE UNAVAILABLE: $rel -- $reason. This file needs the "
              . "container lane (platform: any|linux) and was not run anywhere -- an "
              . "unavailable lane never silently falls back to the host.\n",
        container_infra => 1,
    };
}

# _run_container_batch(@abs_files) -> @results -- orchestration, one
# container per sweep. Reproduces run-tests-container.pl::main()'s own flow
# using only the low-level, namespaced primitives -- never calling
# RunTestsContainerLane::main, both because that sub parses a CLI argv shape
# this call site does not have, and because bypassing it keeps this package
# out of run-tests-container.pl's write set entirely.
sub _run_container_batch {
    my (@abs_files) = @_;                      # ABSOLUTE paths -- same convention every
    return () unless @abs_files;               # other lane's @results uses (section 2.4.1)

    # FIX-BATCH C1/A1: re-apply the MSYS2 argv-conversion opt-out ONLY for the
    # dynamic scope of this call. Package 05's git/podman calls inside
    # materialize_tree() are written expecting it, paired with their own
    # _winify_path hand-translation (run-tests-container.pl's header) -- the
    # opt-out and the translation are one technique. `local` means it never
    # escapes back into the caller once this sub returns, whether that
    # caller is a throwaway forked batch child (the normal run_sweep() path)
    # or this file's own direct in-process calls (the oracle's Part B/C).
    no warnings 'once';   # RunTestsContainerLane::WINDOWS_FAMILY is only ever
                           # read here, in this file's compilation unit
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $RunTestsContainerLane::WINDOWS_FAMILY;

    my $podman = RunTestsContainerLane::podman_bin();
    return map { _container_infra_result($_, 'no docker/podman CLI found on PATH') } @abs_files
        unless $podman;

    unless (RunTestsContainerLane::image_present($podman, $RunTestsContainerLane::IMAGE)) {
        return map { _container_infra_result($_,
            "image '$RunTestsContainerLane::IMAGE' is not present locally -- run the "
          . "interactive sandbox launcher once (plugins/sandbox/scripts/launcher.pl) to build it"
        ) } @abs_files;
    }

    RunTestsContainerLane::sweep_orphan_containers($podman);         # obligation (c)

    my $name = RunTestsContainerLane::new_container_name();
    {   # fix-batch A4's exact-name reclaim, mirrored from package 05's own main() step 5
        my ($ps_rc, $ps_out) =
            RunTestsContainerLane::_podman_capture(RunTestsContainerLane::build_ps_argv($podman));
        if ($ps_rc == 0 && defined $ps_out && $ps_out =~ /^\Q$name\E\s*$/m) {
            RunTestsContainerLane::_podman_capture(RunTestsContainerLane::build_rm_argv($podman, $name));
        }
    }

    my ($run_rc, undef) =
        RunTestsContainerLane::_podman_capture(RunTestsContainerLane::build_run_argv($podman, $name));
    return map { _container_infra_result($_, "podman run failed (rc=$run_rc)") } @abs_files
        if $run_rc != 0;

    {
        # SHOULD-FIX-1 (review, step 7): these two fully-qualified globals
        # are written here but only ever READ inside run-tests-container.pl's
        # own compilation unit, so this file's compiler flags them "used
        # only once" on every single invocation -- cosmetic, but this is the
        # repo's most-invoked script.
        no warnings 'once';
        $RunTestsContainerLane::ACTIVE_CONTAINER_NAME = $name;
        $RunTestsContainerLane::ACTIVE_PODMAN_BIN     = $podman;     # arms obligations (a)/(b)
    }

    my ($git_rc, $extract_rc) =
        RunTestsContainerLane::materialize_tree($podman, $name, 'HEAD', $ROOT_ABS);
    if ($git_rc != 0 || $extract_rc != 0) {
        RunTestsContainerLane::_cleanup_active_container();
        return map { _container_infra_result($_,
            "materialize_tree failed (git_rc=$git_rc, extract_rc=$extract_rc)") } @abs_files;
    }

    my @results;
    for my $abs (@abs_files) {
        my $rel = _relpath($abs);              # existing sub, reused verbatim
        my $r = RunTestsContainerLane::run_one_in_container($podman, $name, $rel);
        $r->{file} = $abs;                     # see section 2.4.1 -- overwrite the relpath
        push @results, $r;
    }

    RunTestsContainerLane::_cleanup_active_container();   # obligation (a)
    return @results;
}

# --- sweep-level audit (package 21-test-sandbox) ---------------------------
#
# _git_status_paths($repo_root_abs) -> @relpaths -- every path `git status
# --porcelain --untracked-files=all` reports under $repo_root_abs, MINUS
# anything under .ccpraxis-local-data/test-state/ (this runner's own
# bookkeeping, exempted by the contract -- it writes there on every sweep
# regardless). Returns () if git itself is unavailable/fails rather than
# dying -- an audit that cannot run is not the same claim as "nothing new".
sub _git_status_paths {
    my ($repo) = @_;
    my $out = `git -C "$repo" status --porcelain --untracked-files=all 2>&1`;
    return () unless defined $out && $? == 0;
    my @paths;
    for my $line (split /\n/, $out) {
        next unless length $line;
        my $p = $line;
        $p =~ s/^..\s+//;
        $p =~ s/^"(.*)"$/$1/;
        $p =~ s{\\}{/}g;
        next if $p =~ m{^\.ccpraxis-local-data/test-state/};
        push @paths, $p;
    }
    return sort @paths;
}

# _wakelock_pids() -> @{ {pid, cmd} } -- every live process (WINPID
# namespace, per Get-CimInstance) whose command line names one of the fake/
# real wake-lock stand-ins the contract lists: keep-awake.ps1,
# BpContinuityLease, bp-keepawake. Windows-only (the whole concept of a
# WINPID vs. a perl pid is a Windows landmine -- see CLAUDE.md); returns ()
# unqualified elsewhere or if the CIM query itself is unavailable/unparsable.
sub _wakelock_pids {
    if ($^O =~ /^(MSWin32|cygwin|msys)$/) {
        my $ps = 'powershell.exe -NoProfile -NonInteractive -Command '
               . '"Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | '
               . 'Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress -Depth 3"';
        my $raw = `$ps 2>/dev/null`;
        return () unless defined $raw && $raw =~ /\S/;
        my $data = eval { require JSON::PP; JSON::PP->new->utf8(0)->decode($raw) };
        return () unless ref $data;
        $data = [$data] if ref $data eq 'HASH';
        my @out;
        for my $p (@$data) {
            next unless ref $p eq 'HASH';
            my $cmd = $p->{CommandLine};
            next unless defined $cmd && length $cmd;
            next unless $cmd =~ /keep-awake\.ps1|BpContinuityLease|bp-keepawake/;
            push @out, { pid => $p->{ProcessId}, cmd => $cmd };
        }
        return @out;
    }

    # FIX-BATCH M7 (review, step 7): the container lane runs the oracle (and
    # any real in-container sweep) on Linux, where the CIM branch above
    # returns () unconditionally -- a leftover wake-lock-style process there
    # was never detected at all. `ps -eo pid=,args=` is the POSIX equivalent:
    # bare pid and full argv, no header line (the trailing `=` on each field
    # suppresses it).
    my $raw = `ps -eo pid=,args= 2>/dev/null`;
    return () unless defined $raw && $raw =~ /\S/;
    my @out;
    for my $line (split /\n/, $raw) {
        next unless $line =~ /^\s*(\d+)\s+(.*)$/;
        my ($pid, $cmd) = ($1, $2);
        next unless $cmd =~ /keep-awake\.ps1|BpContinuityLease|bp-keepawake/;
        push @out, { pid => $pid, cmd => $cmd };
    }
    return @out;
}

# _stable_wakelock_pids() -> @{ {pid, cmd} } -- FIX-BATCH M5 (review, step
# 7): a single wake-lock snapshot flags a transient invocation (many test
# files themselves spawn/re-spawn a fake bp-keepawake.pl under
# CCPRAXIS_NO_WAKELOCK, alive for well under a second) as a leak. Two
# snapshots ~2s apart, intersected on pid, keep only what is ALIVE across the
# whole window -- AC-4's real `sleep(60)` leftover survives that easily; a
# one-second transient does not.
sub _stable_wakelock_pids {
    my @first = _wakelock_pids();
    return () unless @first;
    Time::HiRes::sleep(2);
    my @second   = _wakelock_pids();
    my %alive_at_second = map { ($_->{pid} => 1) } @second;
    return grep { $alive_at_second{ $_->{pid} } } @first;
}

# _dir_snapshot($dir) -> \%{ relpath => "mtime:size" } -- FIX-BATCH M4
# (review, step 7): git status never reports a gitignored path, and most of
# the real state this package cares about (butler-state, continuity active
# dir) lives outside the repo entirely. A plain existence/path-set diff also
# misses a MODIFICATION of a file that was already there, so this snapshots
# (mtime, size) per file, not just presence. Returns {} for an undef/missing
# dir -- "nothing to audit" is not the same claim as "audited and clean".
sub _dir_snapshot {
    my ($dir) = @_;
    my %snap;
    return \%snap unless defined $dir && length $dir && -d $dir;
    eval {
        File::Find::find(sub {
            return unless -f $_;
            my $rel = File::Spec->abs2rel($File::Find::name, $dir);
            $rel =~ s{\\}{/}g;
            my @st = stat($_);
            $snap{$rel} = (@st ? "$st[9]:$st[7]" : '?');
        }, $dir);
    };
    return \%snap;
}

# _snapshot_diff($pre, $post) -> @relpaths -- every relpath present in $post
# that is either new or whose (mtime,size) signature changed since $pre.
sub _snapshot_diff {
    my ($pre, $post) = @_;
    my @changed;
    for my $k (sort keys %$post) {
        push @changed, $k unless exists $pre->{$k} && $pre->{$k} eq $post->{$k};
    }
    return @changed;
}

# _read_inflight_write_sets($repo_root_abs) -> @relpath_or_dir_entries --
# FIX-BATCH M6 (review, step 7): every write_set entry declared by another
# package currently in flight, read from .ccpraxis-local-data/.drive-solo/
# inflight.json (a list of {blueprint,package,ledger} records) and that
# package's own ledger frontmatter (`write_set: a:b:c`, colon-separated --
# same shape bp-checks.pl's own _split_set already assumes). Never dies: a
# missing/unparsable inflight file or ledger just means "nothing to
# attribute", not a sweep-crashing condition. With no inflight file at all,
# returns () and every new path fails the audit exactly as before this
# package existed.
sub _read_inflight_write_sets {
    my ($root) = @_;
    my $path = File::Spec->catfile($root, qw(.ccpraxis-local-data .drive-solo inflight.json));
    return () unless -f $path;
    my $raw = do {
        open my $fh, '<:raw', $path or return ();
        local $/;
        <$fh>;
    };
    return () unless defined $raw && length $raw;
    my $data = eval { require JSON::PP; JSON::PP->new->utf8(0)->decode($raw) };
    return () unless ref $data eq 'HASH' && ref $data->{packages} eq 'ARRAY';

    my @sets;
    for my $p (@{ $data->{packages} }) {
        next unless ref $p eq 'HASH';
        my $ledger_rel = $p->{ledger};
        next unless defined $ledger_rel && length $ledger_rel;
        my $ledger_abs = File::Spec->catfile($root, split m{/}, $ledger_rel);
        next unless -f $ledger_abs;
        my $text = do {
            open my $fh, '<', $ledger_abs or next;
            local $/;
            <$fh>;
        };
        next unless defined $text;
        my ($fm) = $text =~ /\A---\s*\n(.*?)\n---\s*\n/s;
        next unless defined $fm;
        my ($ws) = $fm =~ /^write_set:\s*(.*?)\s*$/m;
        next unless defined $ws && length $ws;
        push @sets, grep { length } split /:/, $ws;
    }
    return @sets;
}

# _path_attributed($relpath, @write_sets) -> 1 | 0 -- true iff $relpath
# equals a declared write_set entry, or sits inside one that names a
# directory.
sub _path_attributed {
    my ($relpath, @sets) = @_;
    for my $entry (@sets) {
        return 1 if $relpath eq $entry || $relpath =~ m{^\Q$entry\E/};
    }
    return 0;
}

# run_sweep(@argv) -> $exit_code -- everything that used to be this script's
# top-level executable flow, wrapped in one sub so merely `require`ing this
# file (as plugins/butler/tests/t/lane-routing.t must, to reach classify_file
# et al. directly) never runs a real sweep as a side effect of loading the
# file. Every `exit N;` below is a real, unchanged process exit, not a
# `return` -- converting them was judged a larger diff than any done
# criterion requires, and nothing in this package's own test plan ever calls
# run_sweep() (doing so would either run a real ~1000s sweep in-process or
# hit a bare exit() that kills the caller).
sub run_sweep {
    my @argv = @_;
    local @ARGV = @argv;

    my ($fast, $jobs, $nice, $state_mode, @targets) = (0, 0, 0, 0);
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--fast')            { $fast = 1 }
        elsif ($a eq '--nice')            { $nice = 1 }
        elsif ($a eq '--jobs')            { $jobs = shift(@ARGV) || 0 }
        elsif ($a =~ /^--jobs=(\d+)$/)    { $jobs = $1 }
        elsif ($a eq '--state=failed')    { $state_mode = 1 }
        elsif ($a =~ /^--state=/)         {
            print STDERR "error: unsupported value for $a (only --state=failed is recognized)\n";
            exit 2;
        }
        elsif ($a eq '--help' || $a eq '-h') { print _usage(); exit 0 }
        elsif ($a eq '--keep-sandbox')    { $KEEP_SANDBOX = 1 }
        elsif ($a eq '--ledger') {
            if (defined $LEDGER_PATH) {
                print STDERR "error: --ledger given more than once\n";
                exit 2;
            }
            unless (@ARGV) {
                print STDERR "error: --ledger requires a value\n";
                exit 2;
            }
            $LEDGER_PATH = shift @ARGV;
        }
        elsif ($a =~ /^--ledger=(.*)$/s) {
            if (defined $LEDGER_PATH) {
                print STDERR "error: --ledger given more than once\n";
                exit 2;
            }
            my $v = $1;
            unless (length $v) {
                print STDERR "error: --ledger= requires a non-empty value\n";
                exit 2;
            }
            $LEDGER_PATH = $v;
        }
        else                              { push @targets, $a }
    }
    if (defined $LEDGER_PATH && !-f $LEDGER_PATH) {
        print STDERR "error: --ledger path does not exist or is not a file: $LEDGER_PATH\n";
        exit 2;
    }
    if ($state_mode && @targets) {
        print STDERR "error: --state=failed cannot be combined with a path/glob target\n";
        exit 2;
    }
    if (defined $LEDGER_PATH) {
        print "ledger: $LEDGER_PATH\n";
    }

    # Force the sandbox base and the sandbox registry into existence NOW,
    # before any host-parallel/host-serial worker is spawned -- forked
    # children inherit this process's memory at fork time, so every one of
    # them sees the SAME base and SAME registry path without any IPC
    # (package 21-test-sandbox).
    _sandbox_base();
    _sandbox_registry_path();

    # FIX-BATCH m4 (review, step 7): installed as early as possible, right
    # after the registry above exists, so an interrupt lands with something
    # to clean up but before any worker is forked (a forked worker inherits
    # these same %SIG entries but is guarded off by $SWEEP_OWNER_PID).
    _install_sweep_cleanup_handlers();

    # Pre-sweep audit snapshot (package 21-test-sandbox). Taken here, before
    # any test file runs, so a file that appears afterward is genuinely new
    # -- never a pre-existing artifact of this same run's own state-file
    # bookkeeping (that write happens later, and is filtered by path below
    # regardless).
    #
    # Package 10-nested-runner-audit (Decision 28): when THIS process itself
    # inherited the "enclosing sweep owns the audit" marker (captured at load
    # time, above -- never re-read here), the pre-snapshot is skipped
    # entirely: no git status, no wake-lock query, no butler-state/continuity
    # snapshot. The enclosing sweep's own pre-snapshot, taken before this
    # nested run was ever spawned, already covers this window.
    my @audit_pre_paths;
    my @audit_pre_procs;
    my $audit_pre_bs;
    my $audit_pre_ca;
    unless ($ENCLOSING_SWEEP_OWNS_AUDIT) {
        @audit_pre_paths = _git_status_paths($ROOT_ABS);
        @audit_pre_procs = grep { !(defined $REAL_KEEPAWAKE_PID && $_->{pid} eq $REAL_KEEPAWAKE_PID) } _wakelock_pids();
        # FIX-BATCH M4 (review, step 7): the real butler-state dir and continuity
        # active dir are never under $ROOT_ABS, so git status can never see a
        # write into them -- snapshot them directly, by (mtime,size) per file so
        # a modification of an already-existing file counts, not only a brand
        # new path.
        $audit_pre_bs = _dir_snapshot($REAL_BUTLER_STATE_DIR);
        $audit_pre_ca = _dir_snapshot($REAL_CONTINUITY_ACTIVE_DIR);
    }

    # --- collect ---------------------------------------------------------------
    my @files;
    if ($state_mode) {
        my @recorded = _read_state_file();
        my @live     = grep { -f _to_abs($_) } @recorded;
        for my $gone (grep { !-f _to_abs($_) } @recorded) {
            print STDERR "state: $gone no longer exists, skipping\n";
        }
        unless (@live) {
            print "no recorded failures -- nothing to run\n";
            exit 0;
        }
        @files = map { _to_abs($_) } @live;
    } elsif (@targets) {
        for my $t (@targets) {
            my @m = bsd_glob($t);
            @m = bsd_glob("$t/tests/t/*.t")  if !@m || -d $t;
            @m = bsd_glob("$ROOT_ABS/$t")        unless @m;
            @m = bsd_glob("$ROOT_ABS/$t/tests/t/*.t") unless @m;
            push @files, grep { /\.t$/ && -f $_ } @m;
        }
    } else {
        push @files, bsd_glob("$ROOT_ABS/plugins/*/tests/t/*.t");
    }
    @files = sort @files;
    unless (@files) { print STDERR "no test files matched\n"; exit 2 }

    # tooling-fixes 07: lint mode is on exactly when --ledger was given
    # (BP_VALIDATE_LEDGER in the environment has no effect -- runner-ledger-
    # flag.t AC-6 pins that). Collection happens AFTER the empty-selection
    # exits above, so the lints never turn an empty selection into a run
    # (spec section 2.4).
    my $LINT_MODE = defined $LEDGER_PATH;
    my $LINT_ROOT;
    my %LINT_RELPATH_BY_IDENTITY;   # identity(lint path) => its @REPO_LINTS relpath
    my @LINT_MISSING_RESULTS;
    if ($LINT_MODE) {
        $LINT_ROOT = _lint_root();
        my %existing_identity = map { (_path_identity($_) => 1) } @files;
        for my $relpath (@REPO_LINTS) {
            my $lint_path = "$LINT_ROOT/$relpath";
            if (!-f $lint_path) {
                push @LINT_MISSING_RESULTS, {
                    file => $lint_path, rc => 1, notok => 0, secs => 0,
                    lint_missing => 1,
                    out => "REPO LINT MISSING: $relpath -- not found under $LINT_ROOT\n",
                };
                next;
            }
            # LOW (red-team, step 7): a lint that EXISTS but can't be read
            # used to fall through to classify_file()'s own silent skip
            # (permissions, corruption, ...) -- the file simply vanished from
            # the run with no trace. Same loud treatment as REPO LINT MISSING.
            unless (-r $lint_path) {
                push @LINT_MISSING_RESULTS, {
                    file => $lint_path, rc => 1, notok => 0, secs => 0,
                    lint_missing => 1,
                    out => "REPO LINT MISSING: $relpath -- exists under $LINT_ROOT but could not be read\n",
                };
                next;
            }
            my $id = _path_identity($lint_path);
            $LINT_RELPATH_BY_IDENTITY{$id} = $relpath;
            unless ($existing_identity{$id}) {
                push @files, $lint_path;
                $existing_identity{$id} = 1;
            }
        }
        # S3 (review, step 7): a launch's own target selection can already
        # contain the same physical lint file twice under two different
        # spellings (e.g. an explicit lint path alongside a plugin-dir glob
        # that also matches it) -- done criterion 1 ("each lint runs once")
        # broke in that case even though the injection step above never
        # re-added an already-present lint. Dedupe the WHOLE selection by
        # identity, not just the injected lints, now that it's fully built.
        my %dedupe_seen;
        @files = grep { !$dedupe_seen{ _path_identity($_) }++ } @files;
        @files = sort @files;

        my $line = 'repo lints: ' . join(' ', map { basename($_) } @REPO_LINTS);
        $line .= " (root: $ENV{CCPRAXIS_TEST_LINT_ROOT})"
            if defined $ENV{CCPRAXIS_TEST_LINT_ROOT} && length $ENV{CCPRAXIS_TEST_LINT_ROOT}
            && defined $ENV{CCPRAXIS_TEST_STATE_DIR} && length $ENV{CCPRAXIS_TEST_STATE_DIR};
        print "$line\n";
    }

    # MARKER GATE, SERIAL HEURISTIC, THEN MARKER VALUE -- classify_file() is
    # the sole routing predicate (spec section 2.1/2.6). A refused file never
    # spawned a process; it is synthesised as a red result below so it flows
    # through the existing report/state/exit-code machinery unchanged.
    my (@host_serial, @host_parallel, @container, @refused);
    for my $f (@files) {
        my $d = classify_file($f);
        unless (defined $d) { next }   # unreadable -- unchanged silent-skip precedent
        if    ($d->{lane} eq 'refused')       { push @refused,      { file => $f, marker => $d->{marker} } }
        elsif ($d->{lane} eq 'host-serial')   { push @host_serial,  $f }
        elsif ($d->{lane} eq 'host-parallel') { push @host_parallel,$f }
        elsif ($LINT_MODE && exists $LINT_RELPATH_BY_IDENTITY{ _path_identity($f) }) {
            # M2 (red-team, step 7): the 3 repo lints are meta-checks about
            # this repo's OWN conventions, not platform-dependent product
            # code -- with CCPRAXIS_CONTAINER_LANE_ENABLED set they would
            # otherwise be eligible for the container lane (they declare
            # `# platform: any`) and run against a CONTAINER's copy of a git
            # ref instead of the working tree, so a real working-tree
            # regression would never go red. Force the host lane always,
            # regardless of the lane-availability gate below.
            push @host_parallel, $f;
        }
        else                                  { push @container,    $f }
    }
    # --fast empties the host-serial lane. Keep what it dropped so the summary
    # can SAY so: reporting "0 serial" for a run that skipped sixteen files
    # reads as "there were none", and a baseline whose coverage is invisible is
    # exactly the untrustworthy signal report 20260916-162952-5ae3 is about
    # (filed as 20260918-042312-02db).
    #
    # The serial lane is decided by _loads_test_sandbox() -- whether the file
    # genuinely `use`s/`require`s TestSandbox or references TestSandbox::,
    # comments stripped -- not by a raw text match over the whole file. A file
    # that merely discusses the container lane in a comment or string literal
    # no longer lands here (package 01-container-lane-is-a-property, the other
    # half of 02db).
    my @fast_skipped;
    if ($fast) { @fast_skipped = @host_serial; @host_serial = () }
    # UNCHANGED semantics -- @container is NEVER emptied by --fast (spec 2.8).

    # LANE-AVAILABILITY CAPABILITY GATE (Decision 18: a lane-availability
    # switch, never a routing switch -- classify_file() itself is pure of any
    # %ENV/@ARGV, so its per-file verdict can never be overridden by this or
    # any other flag). This decides only whether the container LANE is
    # reachable at all THIS run. Off by default: the container lane must be
    # reachable by an explicit opt-in, never by default (Decision 17),
    # because package 05's container lane only ever materializes a git ref
    # (default HEAD) -- routing to it by default would make an ordinary
    # sweep silently test the last commit instead of the working tree for
    # roughly two thirds of the suite. When the gate is off, every file
    # classify_file routed to 'container' simply runs on the host instead,
    # exactly as it did before this package existed (a non-serial any/linux
    # file was, and again is, just part of the parallel host set).
    # Deliberately an env var, not a new CLI flag (spec section 7's
    # "out of scope" list already forbids a routing-configuring flag; this
    # is a lane-availability switch, a different thing per Decision 18, and
    # the ledger wins where the two texts disagree -- see the oracle's own
    # header comment for the full adjudication).
    # FIX-BATCH M4 (step 7): a bare Perl truthiness test treated "false",
    # "no" and "off" as ON -- only "" and "0" are falsy to Perl, and none of
    # those three spellings are. An operator writing
    # CCPRAXIS_CONTAINER_LANE_ENABLED=false to explicitly OPT OUT landed
    # squarely in the lane instead. Recognize the operator's INTENT: only
    # 1/true/yes/on (case-insensitively) enable it; every other value,
    # including unset, "", "0", "false", "no" and "off", is OFF.
    my $lane_on = defined $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED}
               && $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED} =~ /^(?:1|true|yes|on)$/i;
    unless ($lane_on) {
        push @host_parallel, @container;
        @container = ();
    }

    $jobs = _resolve_jobs(
        explicit_jobs => $jobs,
        nice          => $nice,
        env_jobs      => $ENV{CCPRAXIS_TEST_JOBS},
        cores         => _cores(),
    );
    $jobs = scalar(@host_parallel) if $jobs > @host_parallel && @host_parallel;
    $jobs = 1 if $jobs < 1;

    my $start = time;
    my @results;

    # --- parallel phase ----------------------------------------------------
    # fork/waitpid with a result file per child: the MSYS2 perl on this host
    # has a real fork, but no shared memory, so children report through the
    # filesystem. The container-lane batch (when the capability gate above
    # left @container non-empty) runs as ONE additional forked child in the
    # SAME wave as the host-parallel workers -- it does not consume one of
    # the $jobs worker slots, and it is one of the things the waitpid loop
    # below drains before the serial phase starts, which is what makes the
    # container-lane batch and @host_serial never overlap in wall-clock
    # without any new synchronization (spec section 0.4/2.6).
    if (@host_parallel || @container) {
        require File::Temp;
        my $dir = File::Temp::tempdir(CLEANUP => 1);
        my (%pid_of, @queue);
        @queue = _order_longest_first(\@host_parallel, _read_durations());
        my $i = 0;
        my %slot;
        my %is_batch;
        my %batch_files;   # id => \@container files that batch owned (H1: lets
                            # the reap loop synthesize infra results for every
                            # file in a batch whose child died/wrote nothing,
                            # instead of silently losing them from @results).

        my $spawn = sub {
            my $f = shift @queue or return 0;
            my $id = $i++;
            my $pid = fork();
            if (!defined $pid) { unshift @queue, $f; return 0 }
            if ($pid == 0) {
                my $r = run_one($f);
                open my $o, '>', "$dir/$id" or exit 1;
                print {$o} join("\x1f", $r->{rc}, $r->{notok}, $r->{secs}, $r->{file}), "\x1e", $r->{out};
                close $o;
                exit 0;
            }
            $slot{$pid} = $id;
            return 1;
        };

        if (@container) {
            my $id = $i++;               # same counter host-parallel children use
            my $pid = fork();
            if (!defined $pid) {
                # FIX-BATCH H2 (step 7): fork() returns undef on failure, and
                # this spawn used to test "$pid == 0" with no defined check --
                # undef == 0 is TRUE, so the code below ran the whole batch
                # INLINE in the sweep's own process and then called exit(0)
                # mid-sweep, before the report/state-write/serial phase ever
                # ran. The host-parallel spawn above already gets this right;
                # this one didn't. Never fall through to the child branch:
                # record an infra failure for every file this batch was going
                # to run and keep going.
                push @results, _container_infra_result($_,
                    'fork() failed for the container-lane batch child') for @container;
            } elsif ($pid == 0) {
                # FIX-BATCH H1 (step 7): a die anywhere inside
                # _run_container_batch (podman_bin, materialize_tree,
                # build_test_exec_argv's allow-list refusal, etc.) used to
                # kill this child with NO result file ever written, silently
                # erasing every file in the batch from @results while the
                # sweep printed "all green" and exited 0. Turn a die into the
                # same infra-failure shape the sub already uses for its own
                # "podman unavailable" cases instead of losing the batch.
                my @batch = eval { _run_container_batch(@container) };
                if ($@) {
                    my $err = $@;
                    $err =~ s/\s+\z//;
                    @batch = map { _container_infra_result($_, "container batch died: $err") } @container;
                }
                open my $o, '>', "$dir/$id" or exit 1;
                print {$o} join("\x1d", map {
                    join("\x1f", $_->{rc}, $_->{notok}, $_->{secs}, $_->{file}) . "\x1e" . $_->{out}
                } @batch);
                close $o;
                exit 0;
            } else {
                $slot{$pid} = $id;
                $is_batch{$id} = 1;          # tells the reap loop to split, not treat as one record
                $batch_files{$id} = [@container];
            }
        }

        $spawn->() for 1 .. $jobs;
        while (%slot) {
            my $pid = waitpid(-1, 0);
            last if $pid <= 0;
            my $id = delete $slot{$pid};
            my $handled = 0;
            if (defined $id && open my $in, '<', "$dir/$id") {
                my $raw = do { local $/; <$in> };
                close $in;
                if ($is_batch{$id}) {
                    my @chunks = grep { length } split /\x1d/, (defined $raw ? $raw : '');
                    if (@chunks) {
                        for my $chunk (@chunks) {
                            my ($head, $out) = split /\x1e/, $chunk, 2;
                            my ($rc, $notok, $secs, $file) = split /\x1f/, (defined $head ? $head : ''), 4;
                            push @results, { file => $file // '?', rc => $rc // 1, notok => $notok // 0,
                                             secs => $secs // 0, out => $out // '' };
                        }
                        $handled = 1;
                    }
                } else {
                    my ($head, $out) = split /\x1e/, (defined $raw ? $raw : ''), 2;
                    my ($rc, $notok, $secs, $file) = split /\x1f/, (defined $head ? $head : ''), 4;
                    push @results, { file => $file // '?', rc => $rc // 1, notok => $notok // 0,
                                     secs => $secs // 0, out => $out // '' };
                    $handled = 1;
                }
            }
            if (!$handled && defined $id && $is_batch{$id}) {
                # FIX-BATCH H1 (step 7): the batch child either never wrote
                # $dir/$id at all (killed before opening it) or wrote an
                # empty/unparseable file (e.g. it died between open() and the
                # first print). Either way, never let a dead batch child
                # silently erase every file it owned from @results.
                push @results, _container_infra_result($_,
                    'container-lane batch child produced no result for this file')
                    for @{ $batch_files{$id} // [] };
            }
            $spawn->();
        }
    }

    # --- serial phase ----------------------------------------------------------
    push @results, run_one($_) for @host_serial;

    # --- refused phase -----------------------------------------------------------
    push @results, _refusal_result($_) for @refused;

    # --- repo-lint missing phase (tooling-fixes 07, spec section 2.6) ------------
    push @results, @LINT_MISSING_RESULTS;

    # --- repo-lint HEAD comparison (tooling-fixes 07, spec section 2.5) ---------
    # Lint mode only. Covers every result whose file is a lint (by identity),
    # that is red, not refused, not container-infra and not missing. HEAD is
    # materialised at most once per run, lazily, only when at least one lint
    # is actually red -- a plain green run never pays this cost.
    my %LINT_ANNOTATION;   # $result->{file} => { pre_existing => 0|1, reason => ..., new_lines => [...] }
    if ($LINT_MODE) {
        my @lint_reds = grep {
            $_->{rc} != 0 && !$_->{refused} && !$_->{container_infra} && !$_->{lint_missing}
                && exists $LINT_RELPATH_BY_IDENTITY{ _path_identity($_->{file}) }
        } @results;

        if (@lint_reds) {
            my $head_dir;
            my $head_unavailable;
            # H1 (red-team, step 7): the comparison baseline is no longer
            # bare HEAD -- see _resolve_baseline_rev's own header comment.
            my $baseline_rev = _resolve_baseline_rev($LINT_ROOT, $LEDGER_PATH);
            if (!defined $baseline_rev) {
                $head_unavailable = "no resolvable baseline/HEAD revision in the lint root";
            } else {
                $head_dir = File::Temp::tempdir($SWEEP_TEMPLATE, DIR => _sandbox_base(), CLEANUP => 0);
                _register_sandbox_dir($head_dir);
                my $arc_rc = _materialize_head_archive($LINT_ROOT, $head_dir, $baseline_rev);
                if ($arc_rc != 0) {
                    $head_unavailable = "git archive|tar exited $arc_rc materialising the lint root's baseline ($baseline_rev)";
                }
            }

            for my $r (@lint_reds) {
                my $relpath = $LINT_RELPATH_BY_IDENTITY{ _path_identity($r->{file}) };
                if (defined $head_unavailable) {
                    $LINT_ANNOTATION{ $r->{file} } = { pre_existing => 0, reason => "HEAD comparison unavailable: $head_unavailable" };
                    next;
                }
                my $head_file = "$head_dir/$relpath";
                unless (-f $head_file) {
                    $LINT_ANNOTATION{ $r->{file} } = { pre_existing => 0, reason => 'not present at HEAD' };
                    next;
                }
                my $head_result = run_one($head_file);   # NOT added to @results (spec 2.5 step 2)
                if ($head_result->{rc} == 0) {
                    $LINT_ANNOTATION{ $r->{file} } = { pre_existing => 0, reason => 'not red at HEAD' };
                    next;
                }
                my $work_sig = _lint_signature($r->{out}, $LINT_ROOT);
                my $head_sig = _lint_signature($head_result->{out}, $head_dir);
                my %head_sig_set = map { ($_ => 1) } @$head_sig;
                my @new_lines = sort grep { !$head_sig_set{$_} } @$work_sig;
                my $is_subset = !@new_lines;
                # S1 (review, step 7): also require rc <= HEAD's own rc -- a
                # duplicated/degenerate failure signature (e.g. an empty
                # work_sig whose rc happens to equal HEAD's by coincidence,
                # or a WORSE working-tree exit code that still produces a
                # signature subset) must never misclassify as pre-existing.
                if ($is_subset && (@$work_sig || $r->{rc} == $head_result->{rc}) && $r->{rc} <= $head_result->{rc}) {
                    $LINT_ANNOTATION{ $r->{file} } = { pre_existing => 1 };
                } else {
                    $LINT_ANNOTATION{ $r->{file} } = {
                        pre_existing => 0, reason => 'new failure lines vs HEAD', new_lines => \@new_lines,
                    };
                }
            }

            _force_remove_tree($head_dir) if defined $head_dir && !$KEEP_SANDBOX;
        }
    }

    # --- report ----------------------------------------------------------------
    my $wall = time - $start;
    my @red  = grep { $_->{rc} != 0 } @results;
    my $pre_existing_lint_reds = grep { $LINT_ANNOTATION{ $_->{file} } && $LINT_ANNOTATION{ $_->{file} }{pre_existing} } @red;

    # NIT-1 (review, promoted for step 7): the container-lane batch's file
    # count used to be invisible in this breakdown (folded into the leading
    # %d files total but nowhere else), which makes the still-deferred
    # criterion-5 measurement (how many files actually went to the lane)
    # harder to read off than it needs to be. @container is already empty
    # here whenever the lane is off (folded into @host_parallel above), so
    # this is always accurate, never a phantom nonzero count.
    printf "\n%d files  %ds wall  (%d parallel at -j%d, %d serial, %d container)\n",
        scalar(@results), $wall, scalar(@host_parallel), $jobs, scalar(@host_serial), scalar(@container);

    # Say what --fast dropped. "0 serial" on a run that skipped sixteen files is
    # a true statement that reads as a false one, and this line is the baseline
    # CLAUDE.md instructs every agent to record before changing anything.
    if (@fast_skipped) {
        printf "  --fast skipped %d host-serial file(s); this run did NOT cover them:\n",
            scalar(@fast_skipped);
        printf "    %s\n", basename($_) for sort @fast_skipped;
    }

    if (@red) {
        print "\nRED:\n";
        for my $r (sort { $a->{file} cmp $b->{file} } @red) {
            my $ann = $LINT_ANNOTATION{ $r->{file} };
            my $is_lint = defined $ann || $r->{lint_missing};
            # A repo lint is named by its FULL path (not just basename): the
            # attribution/pre-existing line that follows needs the reader to
            # be able to find it, and tooling-fixes 07's own oracle looks for
            # the exact lint path on this line.
            my $label = $is_lint ? $r->{file} : basename($r->{file});
            printf "  %-52s exit=%-3d notok=%d%s\n", $label, $r->{rc}, $r->{notok},
                ($r->{refused}          ? '   <- refused: platform marker missing/invalid'
                 : $r->{container_infra} ? '   <- container lane unavailable, never run (see message)'
                 : $r->{lint_missing}    ? '   <- repo lint missing'
                 : $r->{notok} == 0      ? '   <- died, no failing assertion'
                                         : '');
            if (defined $ann) {
                if ($ann->{pre_existing}) {
                    print "repo lint: pre-existing (fails identically at HEAD); not counted\n";
                } else {
                    print "repo lint: attributed to this change ($ann->{reason})\n";
                    if ($ann->{reason} eq 'new failure lines vs HEAD') {
                        print "        new vs HEAD: $_\n" for @{ $ann->{new_lines} };
                    }
                }
            }
            for my $line (grep { /^not ok/ } split /\n/, $r->{out}) {
                print "      $line\n";
            }
            if ($r->{lint_missing}) {
                for my $line (split /\n/, $r->{out}) {
                    print "      $line\n" if length $line;
                }
            }
        }
    } else {
        print "all green\n";
    }
    if ($pre_existing_lint_reds > 0) {
        print "pre-existing lint reds: $pre_existing_lint_reds (not counted in the exit code)\n";
    }

    # SKIPPED (package 21-test-sandbox, task 42): a skip_all file is listed
    # by name with its own reason, not folded silently into "all green" --
    # rc==0/notok==0 for these already, so without this section they were
    # indistinguishable from a file that genuinely ran and passed.
    # Derived from each result's captured TAP output, not from run_one()'s
    # skipped/skip_reason fields: parallel children report back only
    # rc/notok/secs/file/out, so those fields never survive the fork.
    # FIX-BATCH m1 (review, step 7): a file that crashes with zero tests
    # (a bare "1..0" plan line, exit != 0, no skip_all call) matched the same
    # regex as a legitimate skip_all and was listed as BOTH red AND SKIPPED.
    # A file that ran zero tests because it died is not a skip -- require the
    # rc==0/notok==0 shape a genuine skip_all always has.
    my @skipped = grep { $_->{rc} == 0 && $_->{notok} == 0 && defined _skip_all_reason($_->{out}) } @results;
    if (@skipped) {
        print "\nSKIPPED:\n";
        for my $r (sort { $a->{file} cmp $b->{file} } @skipped) {
            my $reason = _skip_all_reason($r->{out});
            printf "  %-52s %s\n", basename($r->{file}),
                (defined $reason && length $reason) ? $reason : '(no reason given)';
        }
    }

    my @slow = (sort { $b->{secs} <=> $a->{secs} } @results)[0 .. ($#results < 9 ? $#results : 9)];
    print "\nslowest:\n";
    printf "  %5ds  %s\n", $_->{secs}, basename($_->{file}) for grep { defined } @slow;

    # Timings for the next run's ordering. Refused and container-infra
    # results never ran, so they carry no timing worth keeping.
    {
        my $dur = _read_durations();
        for my $rel (keys %$dur) { delete $dur->{$rel} unless -f _to_abs($rel) }
        for my $r (@results) {
            # S4 (review, step 7): a REPO LINT MISSING synthetic result never
            # ran either -- same reasoning as refused/container_infra above,
            # and spec section 2.6 rules it out explicitly.
            next if $r->{refused} || $r->{container_infra} || $r->{lint_missing};
            next unless defined $r->{file} && $r->{file} ne '?';
            $dur->{ _relpath($r->{file}) } = $r->{secs} // 0;
        }
        _write_durations($dur);
    }

    # --- state write (merge, never replace) -------------------------------------
    # %ran is the boundary: "did this invocation actually execute it" -- true
    # whether a file was excluded by --fast, by a path/glob target, or
    # (transitively) never reached because of --state=failed scope. Anything not
    # in %ran is carried forward from the prior state file, provided it still
    # exists on disk; a vanished old entry is dropped unconditionally.
    my %ran = map { _relpath($_->{file}) => 1 } @results;
    my %red = map { _relpath($_->{file}) => 1 } @red;

    my @old     = _read_state_file();
    my @carried = grep { !$ran{$_} && -f _to_abs($_) } @old;
    my %seen;
    my @final = sort grep { !$seen{$_}++ } (@carried, keys %red);

    _write_state_atomic(\@final);

    if (@final) {
        print "\nstate: " . scalar(@final) . " failing recorded to .ccpraxis-local-data/test-state/last-failures.txt\n";
    } else {
        print "\nstate: all green, .ccpraxis-local-data/test-state/last-failures.txt cleared\n";
    }

    # --- post-sweep audit (package 21-test-sandbox) -----------------------------
    # A new repo path (git status, minus .ccpraxis-local-data/test-state/) or a
    # surviving fake/real wake-lock process (WINPID namespace) that was NOT
    # present before this sweep started FAILS the sweep and is NAMED, even when
    # every test file itself was green. The real ~/.claude/butler-state is never
    # part of this -- it is not under $ROOT_ABS, so git status never sees it.
    #
    # Package 10-nested-runner-audit (Decision 28): when THIS process itself
    # inherited the marker, the post-audit is replaced by one notice line
    # instead -- no git status, no _stable_wakelock_pids (so no 2s double
    # sample), no butler-state/continuity diff, no AUDIT FAILED section. The
    # enclosing sweep's own post-audit, which runs after this nested run has
    # fully exited, still catches anything left behind.
    my $audit_failed = 0;
    if ($ENCLOSING_SWEEP_OWNS_AUDIT) {
        print "\naudit: skipped -- the enclosing sweep owns the repo, wake-lock and "
            . "butler-state audit (CCPRAXIS_SWEEP_OWNS_AUDIT)\n";
    } else {
        my @post_paths = _git_status_paths($ROOT_ABS);
        my %pre_path = map { ($_ => 1) } @audit_pre_paths;
        my @new_paths = grep { !$pre_path{$_} } @post_paths;

        # FIX-BATCH M6 (review, step 7): a new path that lands squarely inside
        # another IN-FLIGHT package's own write_set is not this sweep's own
        # defect -- it is a concurrent worker doing legitimate, disjoint work
        # while this sweep happened to run. Split, rather than either failing
        # the sweep on every such path (the observed false positive) or
        # silently dropping the check (losing the audit's value for anything
        # else). With no inflight file, @inflight_sets is empty and every new
        # path fails exactly as before this fix.
        my @inflight_sets = _read_inflight_write_sets($ROOT_ABS);
        my (@new_unattributed, @new_attributed);
        for my $p (@new_paths) {
            if (@inflight_sets && _path_attributed($p, @inflight_sets)) {
                push @new_attributed, $p;
            } else {
                push @new_unattributed, $p;
            }
        }

        my @post_procs = _stable_wakelock_pids();
        @post_procs = grep { !(defined $REAL_KEEPAWAKE_PID && $_->{pid} eq $REAL_KEEPAWAKE_PID) } @post_procs;
        my %pre_pid = map { ($_->{pid} => 1) } @audit_pre_procs;
        my @new_procs = grep { !$pre_pid{$_->{pid}} } @post_procs;

        # FIX-BATCH M4 (review, step 7): the real butler-state dir and
        # continuity active dir are outside $ROOT_ABS, so git status never
        # sees a write into them -- diff the (mtime,size) snapshots taken
        # before the sweep started against a fresh one now.
        my @bs_changed = _snapshot_diff($audit_pre_bs, _dir_snapshot($REAL_BUTLER_STATE_DIR));
        my @ca_changed = _snapshot_diff($audit_pre_ca, _dir_snapshot($REAL_CONTINUITY_ACTIVE_DIR));
        my @bs_paths = map { File::Spec->catfile($REAL_BUTLER_STATE_DIR, $_) } @bs_changed;
        my @ca_paths = map { File::Spec->catfile($REAL_CONTINUITY_ACTIVE_DIR, $_) } @ca_changed;

        if (@new_unattributed || @new_procs || @bs_paths || @ca_paths) {
            $audit_failed = 1;
            print "\nAUDIT FAILED:\n";
            if (@new_unattributed) {
                print "  new repo path(s) appeared during this sweep (git status):\n";
                print "    $_\n" for @new_unattributed;
            }
            if (@new_procs) {
                print "  wake-lock-style process(es) survived this sweep:\n";
                printf "    pid=%s  %s\n", $_->{pid}, $_->{cmd} for @new_procs;
            }
            if (@bs_paths || @ca_paths) {
                print "  the real butler-state/continuity-active dir(s) changed during this sweep:\n";
                print "    $_\n" for (@bs_paths, @ca_paths);
            }
        }
        if (@new_attributed) {
            print "\nappeared during sweep (in-flight package; not attributed):\n";
            print "    $_\n" for @new_attributed;
        }
    }

    # Best-effort: drop the sandbox registry file (every per-file dir already
    # removed itself in run_one() unless --keep-sandbox). Never fatal, never
    # reported -- this is hygiene, not a done criterion.
    unless ($KEEP_SANDBOX) {
        eval { unlink $SANDBOX_REGISTRY_PATH if defined $SANDBOX_REGISTRY_PATH };
    }

    my $exit_code = scalar(@red) - $pre_existing_lint_reds;
    $exit_code = 1 if $audit_failed && $exit_code == 0;
    exit $exit_code;
}

exit run_sweep(@ARGV) unless caller();
