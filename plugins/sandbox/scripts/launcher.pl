#!/usr/bin/env perl
# launcher.pl — unified `claude-sandbox` launcher (plugins/sandbox/scripts/).
#
# Replaces the duplicated logic that used to live in the launcher
# .sh and .ps1 files. Both are now thin shims that locate perl and
# exec this script.
#
# Responsibilities (mirrored from the original .sh/.ps1 line-for-line):
#   - Arg parsing (positional project-path, --resume-session UUID).
#   - Bootstrap path: if the sandbox home doesn't exist, ask the user whether
#     to set up a sandbox here; on confirm, invoke bootstrap.pl
#     (deterministic perl-driven setup — no agent in the loop); re-check
#     after; abort if still not set up.
#   - Per-project mkdir-based lock + dead-PID cleanup + signal trap.
#   - Image presence + Containerfile/launcher hash drift, with rebuild prompt.
#   - Pin discovery snapshots (skills + plugins + MCP) for the whole run.
#   - Run the TUI (perl select-interactive).
#   - Compute staleness reasons (version, age, hashes, drift) + interactive
#     [r]/[c] rebuild prompt.
#   - Materialize plugin registry + sandbox credentials.
#   - Build skill/plugin/extra-env/extra-mount lists.
#   - Writable claude.json seeding.
#   - Launch or reattach (podman exec/start/create) with the full mount
#     set; exec replaces this perl process at the end.

use strict;
use warnings;
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);
# Resolve the script's own directory so MountSpec.pm next to us is
# discoverable. Three traps to avoid here:
#   (a) FindBin::$Bin proved unreliable on cygwin perl with a Windows-
#       style $0 — pointed at CWD instead of the launcher dir.
#   (b) Cwd::abs_path also fails on cygwin: doesn't recognise `C:/...`
#       as absolute, prepends CWD, yields `/cwd/C:/path/...` garbage.
#   (c) Backslashes in __FILE__ on native Win32 perl confuse dirname.
# Strategy: take __FILE__ as-is (perl sets it from $0 + the require
# chain, so for the main script it's whatever path perl was invoked
# with — always absolute when called via the .ps1 / .sh shims),
# normalise backslashes, and take the dirname. No abs_path involved.
BEGIN {
    my $here = __FILE__;
    $here =~ s|\\|/|g;
    my $dir = dirname($here);
    unshift @INC, $dir;
}
use MountSpec qw(winify_path v_to_mount convert_v_to_mount);
use LaunchLog ();   # B1: durable per-launch diagnostic log (next to us in scripts/)
use Dashboard ();   # B2: the raw-ANSI TUI dashboard framework
use BackpackApproval ();  # #21: per-item, machine-local backpack approval memory
use BackpackReview ();    # #21: the I/O-seam-injected interactive approval walk
use KeepAwake ();         # B5: dashboard wake-lock decision + lifecycle holder
use ConnectorHold ();     # Fix 3: hold-the-window decision when a connector loses the container
use ClaudeConfig ();      # self-heal .claude.json onboarding-bypass (0-byte / lost-keys)
use PluginSync ();        # Fix 2: copy-model plugin-store reconcile (copy/prune/reconcile)
use PortAlloc ();         # fix-multiple-running-sandboxes: per-container port-block allocation
use SandboxLock ();       # 04-build-race-lock: generalised mkdir lock + global build-race guard
use JSON::PP ();          # parse backpack.json + write the approved install-set
use File::Path qw(make_path);
use File::Spec;
use Digest::MD5 qw();
use POSIX qw(strftime);
use Time::Piece;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

# =====================================================================
# Constants + platform detection
# =====================================================================

my $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;

# Detect which container CLI is installed: prefer docker (Docker Desktop's
# `docker.exe` is the more universally installed runtime), fall back to
# podman. Probing by spawning `<cli> --version` is the only reliable check
# on Windows — relying on file-existence in $PATH is fragile because of
# .exe vs extensionless shim hijacks (Docker Desktop historically dropped
# an extensionless `docker` shell-wrapper alongside `docker.exe` that
# Git-for-Windows perl's POSIX `PATH` search would find first and fail to
# spawn). Always name the .exe explicitly on Windows.
sub _detect_container_cli {
    for my $candidate ($WINDOWS_FAMILY ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        my $rc = system("$candidate --version > /dev/null 2>&1");
        return $candidate if $rc == 0;
    }
    return undef;
}
my $PODMAN = _detect_container_cli();
unless (defined $PODMAN) {
    print STDERR "ERROR: no container CLI on PATH (looked for docker, podman).\n";
    print STDERR "       Install Docker Desktop (https://docker.com) or Podman Desktop\n";
    print STDERR "       (https://podman-desktop.io/) and re-run.\n";
    exit 1;
}

# Disable MSYS2 argument-path conversion before spawning any subprocess.
# MSYS2 (Git for Windows) treats every argv element that looks like a POSIX
# path and TRANSLATES it to a Windows path before invoking native binaries.
# For podman `-v HOST:CONTAINER[:opts]` args, MSYS2 sees the colons, treats
# the whole thing as a `:`-separated PATH-like list, converts each side
# separately, and re-joins with `;`. Result: podman receives
# `C:\host\path;C:\fake\container\path` (note the `;C`), tries to mount the
# `;C`-suffixed host path, can't find it, and silently creates a directory
# at that mangled name on the host — leaving onboarding-bypass / CLAUDE.md /
# settings.json mounts pointing at empty dirs. Setting MSYS2_ARG_CONV_EXCL=*
# disables the translation entirely for this perl process and its children.
#
# BUT — podman.exe (Podman on Windows) does NOT auto-translate `/c/foo` style
# POSIX paths. With MSYS2 disabled, we must hand it Windows-style paths or
# it errors with "no such file or directory" on the build context / mount
# source. So we ALSO convert every host path that goes into a podman arg to
# `C:/foo` form upfront (see `winify_path` below). The two together give us
# full control: podman gets clean Windows paths, MSYS2 doesn't silently
# rewrite them mid-flight.
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $WINDOWS_FAMILY;

# winify_path / v_to_mount / convert_v_to_mount come from MountSpec.pm (loaded
# above) so the test suite can hold the same logic accountable.

# Reset Windows Terminal's Line Feed / New Line Mode (LNM). Without this,
# a prior `podman exec -it claude` can leave LNM off, causing subsequent
# stdout lines to staircase across the screen. CSI 20 h sets LNM on for
# the terminal window; the effect persists. No-op on Linux/macOS.
sub reset_terminal {
    return unless $WINDOWS_FAMILY;
    local $| = 1;
    print STDOUT "\e[20h";
}
reset_terminal();

# Home directory: prefer $HOME (always set under Git Bash) and fall back
# to $USERPROFILE on native Windows perl. Die loudly if neither is set —
# every subsequent path is relative to this. Always returns Windows-style
# (`C:/Users/...`) on Windows so podman.exe can resolve it directly.
sub home_dir {
    my $h = $ENV{HOME} // $ENV{USERPROFILE};
    die "ERROR: neither HOME nor USERPROFILE is set\n" unless defined $h && length $h;
    $h =~ s|\\|/|g;
    $h =~ s|/+$||;
    return winify_path($h);
}

my $HOME              = home_dir();
my $CLAUDE_HOST_CONFIG = "$HOME/.claude";
my $SANDBOX_PLUGIN    = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/sandbox";
my $CONTAINER_CONFIG  = "$SANDBOX_PLUGIN/container";
my $SANDBOX_SKILLS_PL = "$SANDBOX_PLUGIN/scripts/skills.pl";
my $SELECT_SESSION_PL = "$SANDBOX_PLUGIN/scripts/select-session.pl";
my $HOST_PLUGINS_DIR  = "$CLAUDE_HOST_CONFIG/plugins";
# B2: the canonical entry paths the dashboard spawns for a new claude session,
# and whether the raw-ANSI TUI is even possible (else the plain heartbeat loop).
my $LAUNCHER_PL       = "$SANDBOX_PLUGIN/scripts/launcher.pl";
my $SANDBOX_PS1       = "$SANDBOX_PLUGIN/bin/claude-sandbox.ps1";
my $READKEY_OK        = eval { require Term::ReadKey; 1 } ? 1 : 0;

# =====================================================================
# Arg parsing
# =====================================================================
#
# Accepts an optional positional <project-path> and an optional
# --resume-session <uuid> flag (used by claude-beacon to resume a
# specific session). Flag accepted before OR after the positional.
# `=`-joined form (--resume-session=UUID) accepted too. Missing UUID
# at end-of-argv is an explicit error.

my $RESUME_SESSION = '';
my $SESSION_MODE   = 0;   # B2: --session => internal connector entry (Decision #19),
                          # spawned by the dashboard's launch-claude hotkey in a
                          # new window. Bare `claude-sandbox` always lands on the
                          # dashboard instead.
my @POSITIONAL;
{
    my @argv = @ARGV;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--resume-session') {
            die "ERROR: --resume-session requires a UUID argument\n" unless @argv;
            $RESUME_SESSION = shift @argv;
        } elsif ($a =~ /^--resume-session=(.*)$/) {
            $RESUME_SESSION = $1;
        } elsif ($a eq '--session') {
            $SESSION_MODE = 1;
        } elsif ($a eq '--') {
            push @POSITIONAL, @argv;
            @argv = ();
        } else {
            push @POSITIONAL, $a;
        }
    }
}

if (length $RESUME_SESSION
    && $RESUME_SESSION !~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) {
    die "ERROR: --resume-session value is not a UUID: $RESUME_SESSION\n";
}

# =====================================================================
# Resolve project path + derived per-project paths
# =====================================================================

my $PROJECT_PATH = @POSITIONAL ? $POSITIONAL[0] : Cwd::getcwd();
$PROJECT_PATH = abs_path($PROJECT_PATH)
    or die "ERROR: cannot resolve project path '$POSITIONAL[0]'\n";
$PROJECT_PATH =~ s|\\|/|g;
$PROJECT_PATH =~ s|/+$||;
$PROJECT_PATH = winify_path($PROJECT_PATH);

my $PROJECT_NAME = lc(basename($PROJECT_PATH));
$PROJECT_NAME =~ s/ /-/g;

# The project carries a SINGLE ccpraxis data dir at its root:
# <project>/.ccpraxis-local-data/ (self-gitignored via an inner .gitignore=*).
# The sandbox's container-home projection (bind source for /root/.claude) lives
# under it at claude-home/ — historically this was <project>/.claude-data/, now
# migrated in (see the migration block below). Everything the sandbox persists
# (sessions, credentials, launcher metadata, logs, beacons) is nested under
# $CLAUDE_DATA, exactly as it was under .claude-data — only the parent changed.
my $CCPRAXIS_DATA            = "$PROJECT_PATH/.ccpraxis-local-data";
my $CLAUDE_DATA              = "$CCPRAXIS_DATA/claude-home";
my $LAUNCHER_DIR              = "$CLAUDE_DATA/.launcher";
my $SELECTION_FILE            = "$LAUNCHER_DIR/selected-skills.json";
my $MANIFEST_FILE             = "$LAUNCHER_DIR/container-manifest.json";
my $SNAPSHOT_FILE             = "$LAUNCHER_DIR/.discovery-snapshot.json";
my $PLUGINS_SNAPSHOT_FILE     = "$LAUNCHER_DIR/.plugins-snapshot.json";
my $MCP_SNAPSHOT_FILE         = "$LAUNCHER_DIR/.mcp-snapshot.json";
my $SETTINGS_LOCAL_FILE       = "$PROJECT_PATH/.claude/settings.local.json";
# installed_plugins.json lives under claude-home/plugins/ (Fix 2), NOT
# .launcher/ — so it appears at /root/.claude/plugins/installed_plugins.json as
# a REAL RW file through the parent claude-home bind, exactly like
# known_marketplaces.json below. Claude Code rewrites it (write-tmp + rename)
# when a plugin is installed INSIDE the sandbox; a single-file RO bind couldn't
# accept that. The launcher re-materializes it each launch, merge-preserving
# sandbox-added entries (see cmd_materialize_plugins).
my $MATERIALIZED_PLUGINS_FILE = "$CLAUDE_DATA/plugins/installed_plugins.json";
# .credentials.json lives at claude-home/ (the RW dir bind), NOT inside
# .launcher/ — so it appears at /root/.claude/.credentials.json as a REAL
# file through the parent claude-home bind, not as a single-file mount.
# Why it can't be a single-file bind: on Linux you cannot rename() over a
# single-file bind mountpoint (EBUSY), and BOTH Claude Code and butler's
# token-keeper persist an OAuth refresh with the atomic temp+rename pattern.
# A single-file overlay rejected that rename, so a refreshed token could
# never be saved — the on-disk token went stale and forced a relaunch. As a
# real file inside the RW dir bind, both in-place and rename writes land, so
# in-container token refresh persists with no relaunch.
my $SANDBOX_CREDENTIALS_FILE  = "$CLAUDE_DATA/.credentials.json";
# known_marketplaces.json lives under claude-home/plugins/ (NOT .launcher/)
# so it appears at /root/.claude/plugins/known_marketplaces.json as a real
# file through the parent claude-home bind — not as a single-file mount.
# Claude Code rewrites the file with write-tmp + rename on every load; a
# file-level bind would reject the rename with EROFS. The parent-bind
# approach lets the rename land naturally; the launcher regenerates the
# file on every launch so in-container mutations are ephemeral, which
# matches the desired "no marketplace state leaks across runs" posture.
my $MATERIALIZED_MARKETPLACES_FILE = "$CLAUDE_DATA/plugins/known_marketplaces.json";
# Fix 2 host-tier copy-plan manifests (live in .launcher/, RO in the container).
# skills.pl writes them: which selected-plugin code dirs + marketplace metadata
# dirs the launcher copied into claude-home this launch. The launcher reads the
# PRIOR manifest to reconcile (remove what it placed before that's gone now ->
# no zombies) and the NEW one to copy the current set; materialize reads the
# plugins manifest back as merge provenance (sandbox-installed vs deselected).
my $PLUGINS_COPY_MANIFEST      = "$LAUNCHER_DIR/.host-tier-plugins.json";
my $MARKETPLACES_COPY_MANIFEST = "$LAUNCHER_DIR/.host-tier-marketplaces.json";
# Container CLAUDE.md and settings.json: per-project copies (blueprint
# model). Container can modify these freely; changes never propagate
# back to ccpraxis. Drift from upstream is detected via stored hash;
# user picks rebuild to refresh.
my $CONTAINER_CLAUDE_MD       = "$LAUNCHER_DIR/container-CLAUDE.md";
my $CONTAINER_SETTINGS_JSON   = "$LAUNCHER_DIR/container-settings.json";
my $CLAUDE_MD_HASH_FILE       = "$LAUNCHER_DIR/.container-CLAUDE-md-hash";
my $SETTINGS_HASH_FILE        = "$LAUNCHER_DIR/.container-settings-json-hash";
my $LOCK_DIR                  = "$LAUNCHER_DIR/.launcher.lock";

# B1: per-launch diagnostic log. Opened just after the lock is acquired (below);
# declared here so the signal handlers / END block can close it. log_ev() is a
# no-op until the log is open and never throws — instrumentation must not be able
# to take down the launcher it instruments.
my $LAUNCH_LOG;
my $LAUNCH_ID = strftime("%Y%m%dT%H%M%SZ", gmtime()) . "-$$";
sub log_ev { LaunchLog::event($LAUNCH_LOG, @_) }

# A non-empty backpack-install warning (set during the setup pass) that the
# dashboard renders as a red alert banner — so a failure isn't lost behind the
# alt-screen the way the pre-dashboard stdout warning is (#20). File-scope so the
# enter_dashboard gather closure (defined far below) sees the value set up here.
my $INSTALL_WARNING = '';

# Full launch transcript (#19): the raw combined stdout/stderr of the heavy
# setup-phase child processes (image build, the backpack summary, the install
# pass) — the scrolling output the structured JSON log can NOT hold. Together
# they are "everything from launch start". Interactive pickers run as their own
# child processes that write straight to the console, so they stay out of the
# transcript by nature; and we stop teeing before the dashboard, so its ANSI
# never pollutes the file.
my $TRANSCRIPT;

# _open_transcript($path) -> fh | undef. Raw bytes (so UTF-8 / André paths pass
# through untouched, like LaunchLog) + autoflushed; parent dir created. undef on
# failure so a transcript problem can never block a launch.
sub _open_transcript {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    (my $dir = $path) =~ s{[\\/][^\\/]+$}{};
    if (length $dir && !-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 } or return undef;
    }
    open my $fh, '>:raw', $path or return undef;
    my $old = select($fh); $| = 1; select($old);
    return $fh;
}

# _tx(@msg) — append to the transcript only (no console). No-op without a handle.
sub _tx { return unless $TRANSCRIPT; print {$TRANSCRIPT} @_; }

# _close_transcript — flush + close, tolerant of undef / double-call.
sub _close_transcript { if ($TRANSCRIPT) { close $TRANSCRIPT; undef $TRANSCRIPT; } }

# Whether to colorize the interactive setup phase. Off when stdout isn't a TTY or
# NO_COLOR is set (https://no-color.org). Passed to BackpackReview (the #21 walk
# does its own ANSI); #21 part-A (below) reuses this flag for the launcher's own
# setup-phase status lines.
my $USE_COLOR = (-t STDOUT && !exists $ENV{NO_COLOR}) ? 1 : 0;

# #21 part-A: colorize the launcher's OWN setup-phase status lines so a long
# build/create/backpack scroll reads as navigable sections instead of a flat
# wall. Deliberately NARROW in scope:
#   - NOT the teed podman output (`_tee_system`) — those are podman's own bytes;
#     we pass them through verbatim and never inject SGR into them.
#   - NOT the dashboard — it owns its own raw-ANSI frame after this phase ends.
#   - NOT the transcript — these are plain `print`s that never reach $TRANSCRIPT,
#     so no color code ever lands in the on-disk log.
# All gated on $USE_COLOR, so a non-TTY run / NO_COLOR / a redirect emits the
# exact same bytes as before (tests run non-TTY → zero behavioral change). Codes
# match the BackpackReview palette so the whole setup phase is one visual family.
sub _c { my ($code, $s) = @_; $USE_COLOR ? "\e[${code}m$s\e[0m" : $s }
sub _c_step { _c('1;36', $_[0]) }   # bold cyan  — a build/container phase landmark
sub _c_ok   { _c('32',   $_[0]) }   # green      — a setup step succeeded
sub _c_warn { _c('33',   $_[0]) }   # yellow     — a WARNING: label
sub _c_err  { _c('1;31', $_[0]) }   # bold red   — an ERROR: label

# B5 keep-awake holder (set up in enter_dashboard). File-scope so the signal/END
# teardown can release the wake-lock — a leaked PowerShell helper would keep the
# machine awake forever. Release is idempotent + tolerant of an unset holder.
my $KEEPAWAKE;
sub _keepawake_release_global { eval { $KEEPAWAKE->release if $KEEPAWAKE }; }

# _tee_system(@cmd) — run @cmd streaming its combined stdout+stderr LIVE to the
# console AND into the transcript. system()-style return value ($? convention:
# 0 ok, child exit = rc>>8). Falls back to a plain system() when there is no
# transcript or the fork/pipe can't be opened, so capture never blocks a launch.
sub _tee_system {
    my @cmd = @_;
    return system(@cmd) unless $TRANSCRIPT;
    my $pid = open(my $ph, '-|');
    return system(@cmd) unless defined $pid;   # fork/pipe failed -> uncaptured run
    if (!$pid) {                               # child: merge stderr, exec the cmd
        open(STDERR, '>&', \*STDOUT);
        # _exit (not exit) on exec failure: skip END so we don't double-close the
        # parent's log/transcript handles inherited across the fork.
        exec { $cmd[0] } @cmd
            or do { print STDERR "exec failed: $cmd[0]: $!\n"; POSIX::_exit(127); };
    }
    local $| = 1;
    while (my $line = <$ph>) { print STDOUT $line; print {$TRANSCRIPT} $line; }
    close $ph;
    return $?;
}

# ensure_ccpraxis_data_dir — the project's single ccpraxis data root exists and
# self-gitignores (inner .gitignore = '*', matching steward/blueprint onboard).
# Idempotent; never clobbers an existing .gitignore (butler/blueprint may own it).
sub ensure_ccpraxis_data_dir {
    make_path($CCPRAXIS_DATA) unless -d $CCPRAXIS_DATA;
    my $gi = "$CCPRAXIS_DATA/.gitignore";
    unless (-f $gi) {
        if (open my $g, '>', $gi) { print $g "*\n"; close $g }
    }
}

# =====================================================================
# One-time migration: .claude-data -> .ccpraxis-local-data/claude-home
# =====================================================================
#
# The per-project sandbox home used to live at <project>/.claude-data so the
# project root carried TWO ccpraxis data dirs (.claude-data + the blueprint
# .ccpraxis-local-data). It now nests under the single .ccpraxis-local-data.
# Move the whole tree intact on first launch after the change — this preserves
# sessions, credentials, memories, plans (an in-FS rename, atomic + instant).
# Runs before any container/bootstrap decision so the rest of the launch sees
# only the new location.
{
    my $old = "$PROJECT_PATH/.claude-data";
    if (-d $old && ! -d $CLAUDE_DATA) {
        ensure_ccpraxis_data_dir();

        # A container created against the OLD .claude-data path keeps a
        # bind-mount handle on that directory. On Windows the podman machine
        # holds that handle alive until the container is REMOVED — merely
        # stopping it is not enough — so the atomic rename below fails with
        # EACCES ("Permission denied") even when nothing is "running". That
        # container is about to be invalidated anyway (its mount source is
        # moving out from under it), so reap it first. The one case we must
        # NOT touch is a *running* container: that's a live session, so we
        # bail and tell the user to close it instead of killing it.
        {
            my $name = _read_file("$old/.launcher/container-name");
            chomp $name if defined $name;
            $name = '' unless defined $name;
            unless (length $name) {
                $name = "claude-${PROJECT_NAME}-"
                      . substr(md5_of_string($PROJECT_PATH), 0, 8);
            }
            if (_container_exists($name)) {
                my $st = `$PODMAN inspect --format '{{.State.Status}}' "$name" 2>/dev/null`;
                chomp $st if defined $st;
                $st = '' unless defined $st;
                if ($st eq 'running') {
                    print STDERR "ERROR: a sandbox container ($name) is running and still bind-mounts\n";
                    print STDERR "       the old .claude-data, which blocks the one-time migration to\n";
                    print STDERR "       .ccpraxis-local-data/claude-home. Close its dashboard / session\n";
                    print STDERR "       first, then re-run.\n";
                    reset_terminal();
                    exit 1;
                }
                # Stopped / exited / created: safe to remove. Only the
                # container's ephemeral writable layer goes; the host-bound
                # data tree (the thing we're about to move) is untouched, and
                # the next launch recreates the container against the new path.
                print _c_step("Reaping stale container holding the old data dir: $name ($st)"), "\n";
                system($PODMAN, 'rm', '-f', $name);
                log_ev('migrate_reap_container', { container => $name, state => $st });
            }
        }

        if (rename($old, $CLAUDE_DATA)) {
            print _c_ok("Migrated sandbox home: $old -> $CLAUDE_DATA"), "\n";
            log_ev('migrate_claude_data', { from => $old, to => $CLAUDE_DATA });
        } else {
            print STDERR "ERROR: could not migrate $old -> $CLAUDE_DATA: $!\n";
            print STDERR "       Something holds a handle on the old .claude-data so it can't be\n";
            print STDERR "       moved. The usual culprit is another editor or Claude Code session\n";
            print STDERR "       open on THIS project folder — its recursive file-watcher keeps a\n";
            print STDERR "       handle on the directory (a running sandbox, a shell whose cwd is\n";
            print STDERR "       inside it, or a file indexer do the same). Close it, then re-run.\n";
            print STDERR "       (Or move it by hand once nothing holds it:\n";
            print STDERR "         mv '$old' '$CLAUDE_DATA')\n";
            reset_terminal();
            exit 1;
        }
    }
}

# =====================================================================
# Bootstrap path (no sandbox home yet)
# =====================================================================
#
# Ask the user whether to set up a new sandbox; on confirm, run the
# perl-driven bootstrap (no agent in the loop). After it returns,
# verify the sandbox home was created and continue into the normal
# launch flow.

if (! -d $CLAUDE_DATA) {
    print "\n";
    print "==============================================================\n";
    print "  No sandbox found in this project.\n";
    print "==============================================================\n";
    print "\n";
    print "Set up a new sandbox for this project? [Y/n]: ";
    my $ans = <STDIN>;
    chomp $ans if defined $ans;
    if (defined $ans && length $ans && lc(substr($ans, 0, 1)) eq 'n') {
        print "Aborted by user.\n";
        reset_terminal();
        exit 0;
    }
    chdir $PROJECT_PATH or die "chdir $PROJECT_PATH: $!\n";
    my $bootstrap_pl = "$SANDBOX_PLUGIN/scripts/bootstrap.pl";
    unless (-f $bootstrap_pl) {
        print STDERR "ERROR: $bootstrap_pl not found - reinstall ccpraxis.\n";
        reset_terminal();
        exit 1;
    }
    my $rc = system($^X, $bootstrap_pl, '--project-path', $PROJECT_PATH);
    if ($rc != 0) {
        print STDERR "Bootstrap failed (exit @{[$rc >> 8]}). Aborting.\n";
        reset_terminal();
        exit ($rc >> 8 || 1);
    }
    if (! -d $CLAUDE_DATA) {
        print STDERR "Bootstrap finished but $CLAUDE_DATA not found. Aborting.\n";
        reset_terminal();
        exit 1;
    }
}

# =====================================================================
# Ensure launcher metadata dir
# =====================================================================

make_path($LAUNCHER_DIR) unless -d $LAUNCHER_DIR;

# =====================================================================
# Cross-process lock (per-project)
# =====================================================================
#
# Acquire via atomic mkdir; cleanup on signals + END.
# The lock serializes setup flow. When a container is already running
# for this project, we attach directly without lock contention worth
# noting — but the lock still wraps the TUI + post-TUI work here.

sub _rmtree {
    my $path = shift;
    return unless -e $path;
    require File::Path;
    File::Path::remove_tree($path, { safe => 1, error => \my $err });
    # Best-effort; ignore residual errors.
}

# Signal handlers + END block — exec at the end skips these, so every
# exec path calls SandboxLock::release explicitly before exec.
# release_all() frees BOTH the per-project lock AND the global image-build
# lock if it happens to be held at signal time.
$SIG{INT}  = sub { log_ev('signal', { sig => 'INT' });  _keepawake_release_global(); LaunchLog::close_log($LAUNCH_LOG); _close_transcript(); SandboxLock::release_all(); reset_terminal(); exit 130 };
$SIG{TERM} = sub { log_ev('signal', { sig => 'TERM' }); _keepawake_release_global(); LaunchLog::close_log($LAUNCH_LOG); _close_transcript(); SandboxLock::release_all(); reset_terminal(); exit 143 };
END { _keepawake_release_global(); LaunchLog::close_log($LAUNCH_LOG); _close_transcript(); SandboxLock::release_all() }

SandboxLock::acquire($LOCK_DIR, windows => $WINDOWS_FAMILY) or do {
    print STDERR "ERROR: another claude-sandbox is doing setup for this project (lock held > 10s at $LOCK_DIR).\n";
    print STDERR "       If you're sure no other launcher is running, delete the lock dir and retry.\n";
    reset_terminal();
    exit 1;
};

# B1: open the per-launch log now that the lock is held. Best-effort — a failure
# leaves $LAUNCH_LOG undef and every log_ev() becomes a no-op (the launch still
# runs; it just isn't logged). Manager and connector invocations are separate
# processes, each with its own uniquely-named log file (no double-open).
$LAUNCH_LOG = LaunchLog::open_log("$CLAUDE_DATA/sandbox-logs/launch-$LAUNCH_ID.log");
log_ev('launch_start', { project => $PROJECT_PATH, project_name => $PROJECT_NAME, podman => $PODMAN, pid => $$ });

# Companion raw-output transcript (#19): the build/install console stream the JSON
# log can't hold. Best-effort, same naming as the JSON log (.transcript.log).
$TRANSCRIPT = _open_transcript("$CLAUDE_DATA/sandbox-logs/launch-$LAUNCH_ID.transcript.log");
_tx("=== claude-sandbox launch $LAUNCH_ID - $PROJECT_PATH ===\n");

# =====================================================================
# Get host Claude Code version
# =====================================================================

my $HOST_VERSION = '';
{
    my $out = `claude --version 2>/dev/null`;
    if (defined $out && length $out) {
        ($HOST_VERSION) = split /\s+/, $out;
        $HOST_VERSION //= '';
    }
}

# =====================================================================
# Hash helpers (MD5 via core Digest::MD5; no md5sum dependency)
# =====================================================================

sub md5_of_file {
    my $path = shift;
    open my $fh, '<:raw', $path or die "md5_of_file: open $path: $!\n";
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

sub md5_of_string {
    my $s = shift;
    return Digest::MD5->new->add($s)->hexdigest;
}

sub containerfile_hash {
    # Hash the Containerfile AND every file it COPYs into the image, so editing a
    # build input (e.g. the entrypoint script heartbeat.sh) triggers a rebuild on
    # the next launch. Hashing only the Containerfile would let a changed
    # heartbeat.sh ship stale in a cached image.
    my $parts = md5_of_file("$CONTAINER_CONFIG/Containerfile");
    for my $f ('heartbeat.sh') {
        my $p = "$CONTAINER_CONFIG/$f";
        $parts .= ':' . (-f $p ? md5_of_file($p) : 'absent');
    }
    return md5_of_string($parts);
}

sub launcher_hash {
    # Hash the perl script that actually drives the launch — the .sh/.ps1
    # shims contain no behavior worth detecting drift on (changing a shim
    # error message doesn't affect what lands in the container). Existing
    # per-project hash files (which were based on the old fat .sh + .ps1)
    # will mismatch once and trigger a one-time staleness prompt; after
    # rebuild the new hash is saved and drift detection stabilizes.
    my $ctx = Digest::MD5->new;
    open my $fh, '<:raw', "$SANDBOX_PLUGIN/scripts/launcher.pl"
        or return '';
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

# =====================================================================
# Mount-spec helpers
# =====================================================================
#
# MSYS2 (Git-for-Windows perl) silently mangles any argv element that
# contains `:` — it treats the value as a POSIX PATH-list, splits on `:`,
# runs each side through POSIX→Windows conversion, and re-joins with `;`.
# So `-v HOST:CONTAINER` becomes `HOST_winpath;C:\?\CONTAINER_winpath` and
# podman bind-mounts a `;C`-suffixed phantom path. The env-var disable
# (MSYS2_ARG_CONV_EXCL=*) only matches argv values literally starting with
# `*`, which is useless here.
#
# Fix: emit mount specs in podman's `--mount` syntax. Commas and `=`
# separate fields instead of `:`, and the value starts with `type=` which
# MSYS2 won't recognize as a path-like arg → no conversion attempt. All
# existing call sites continue to push `'-v', 'HOST:CONTAINER[:opts]'`
# into the args list (that's still the most readable form to author); we
# rewrite the whole list right before `system(@args)` via
# `convert_v_to_mount`. Belt-and-suspenders alongside the env-var guard
# and the runtime `;C` corruption detector.

# v_to_mount + convert_v_to_mount are imported from MountSpec.pm above.

# =====================================================================
# Image build
# =====================================================================

sub build_image {
    print _c_step("Building claude-sandbox image with Claude Code v${HOST_VERSION}..."), "\n";
    log_ev('image_build_start', { version => $HOST_VERSION });
    _tx("\n--- image build (v${HOST_VERSION}) ---\n");
    my $rc = _tee_system($PODMAN, 'build',
        '--build-arg', "CLAUDE_VERSION=${HOST_VERSION}",
        '-t', "claude-sandbox:${HOST_VERSION}",
        '-t', 'claude-sandbox:latest',
        $CONTAINER_CONFIG);
    if ($rc != 0) {
        log_ev('image_build_failed', { exit => $rc >> 8 });
        print STDERR _c_err("ERROR:"), " podman build failed (exit @{[$rc >> 8]}).\n";
        LaunchLog::close_log($LAUNCH_LOG);
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
    log_ev('image_build_ok', { version => $HOST_VERSION });
    _write_file("$LAUNCHER_DIR/containerfile-hash", containerfile_hash());
}

sub _write_file {
    my ($path, $contents) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!\n";
    print $fh $contents;
    close $fh or die "close $path: $!\n";
}

sub _read_file {
    my $path = shift;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# backpack_review($file, $pl, $approvals_path, $legacy_trust, $file_hash)
#   -> (\@approved_items, $deferred_count)
#
# Thin launcher glue over BackpackReview::review (the testable, I/O-seam-injected
# walk). Wires the launcher's STDIN/STDOUT, color flag, and transcript sink into
# the module. The per-item approval gate proper — content-hash memory, the
# approve/remove/quit-defer dispatch, and the legacy-trust migration — all live
# in BackpackReview.pm + BackpackApproval.pm, where they are unit-tested.
sub backpack_review {
    my ($file, $pl, $approvals_path, $legacy_trust, $file_hash) = @_;
    return BackpackReview::review(
        file         => $file,
        pl           => $pl,
        approvals    => $approvals_path,
        legacy_trust => $legacy_trust,
        file_hash    => $file_hash,
        in           => \*STDIN,
        out          => \*STDOUT,
        use_color    => $USE_COLOR,
        tx           => \&_tx,
    );
}

# Ensure base image exists. Capture instead of redirect — `> /dev/null`
# under cmd.exe (native Win32 perl) wouldn't resolve; backticks with
# `2>&1` discard cleanly on all shells.
# Global cross-project build lock (Decision #9): prevents two launchers from
# simultaneously building the same image. Fail-open: if acquire times out (e.g.
# a crashed previous holder), proceed anyway — a missed lock must never
# permanently block a launch. After acquiring, RE-CHECK the image (the winner
# may have already built it); only build if still missing. release() frees this
# lock; release_all() in END/signals also covers it.
{
    my $build_lock = "$CLAUDE_HOST_CONFIG/ccpraxis/.locks/image-build";
    File::Path::make_path(dirname($build_lock));
    my $got_build_lock = SandboxLock::acquire($build_lock, timeout => 600, windows => $WINDOWS_FAMILY);
    # fail-open: proceed even if !$got_build_lock
    `$PODMAN image inspect claude-sandbox:latest 2>&1`;
    if ($? != 0) {
        build_image();
    }
    SandboxLock::release($build_lock);
}

# =====================================================================
# Container name (generate + persist)
# =====================================================================

my $CONTAINER_NAME;
{
    my $name_file = "$LAUNCHER_DIR/container-name";
    if (-f $name_file) {
        $CONTAINER_NAME = _read_file($name_file);
        chomp $CONTAINER_NAME if defined $CONTAINER_NAME;
        $CONTAINER_NAME //= '';
    }
    if (!length $CONTAINER_NAME) {
        my $path_hash = substr(md5_of_string($PROJECT_PATH), 0, 8);
        $CONTAINER_NAME = "claude-${PROJECT_NAME}-${path_hash}";
        _write_file($name_file, $CONTAINER_NAME);
    }
}

# =====================================================================
# Early mode dispatch: CONNECTOR / DASHBOARD (Decision #19)
# =====================================================================
#
# `claude-sandbox` (the only user-typed form) ALWAYS lands on the
# dashboard (the live TUI / plain heartbeat loop). The dashboard is the
# manager window: it holds the container alive and exposes a hotkey that
# spawns a NEW window running the internal connector entry
# `claude-sandbox --session` — which is what reaches the CONNECTOR branch
# below. `--resume-session` (used by claude-beacon to resume a specific
# session directly) is also connector mode.
#
# CONNECTOR: skip all setup-time work (skill picker, staleness check,
# plugin materialize, backpack approval, container create/start, rebuild
# prompt) and go straight to: session picker → kill-orphan-claudes →
# exec claude. The manager (dashboard) terminal already made those setup
# choices when it built the container.
{
    my $state = '';
    if (_container_exists($CONTAINER_NAME)) {
        $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
        chomp $state if defined $state;
        $state //= '';
    }

    my $connector_mode = ($SESSION_MODE || length $RESUME_SESSION);

    if ($connector_mode) {
        # Connector requires a manager/dashboard to already be up.
        if ($state ne 'running') {
            print STDERR _c_err("ERROR:"), " no running sandbox to connect to for this project.\n";
            print STDERR "       Run `claude-sandbox` (no flags) to start the sandbox + dashboard first,\n";
            print STDERR "       then launch a claude session from the dashboard.\n";
            SandboxLock::release($LOCK_DIR);
            reset_terminal();
            exit 1;
        }
        print _c_step("Connecting to running sandbox: $CONTAINER_NAME"), "\n";
        SandboxLock::release($LOCK_DIR);
        my @SESSION_FLAGS;
        {
            my ($action, $uuid);
            if (length $RESUME_SESSION) {
                ($action, $uuid) = ('resume', $RESUME_SESSION);
            } else {
                ($action, $uuid) = pick_session_action();
            }
            if ($action eq 'cancel') {
                print "Cancelled.\n";
                reset_terminal();
                exit 0;
            }
            push @SESSION_FLAGS, '--resume', $uuid if $action eq 'resume';
        }
        # Orphan claudes (in-container processes from a prior connector
        # that died without releasing /root/.claude lockfiles) block any
        # new session indefinitely with no error message. Detect + offer
        # to kill before exec'ing the new claude.
        kill_orphan_claudes_if_user_confirms();
        my @cmd = ($PODMAN, 'exec', '-it', $CONTAINER_NAME,
                   'claude', '--dangerously-skip-permissions',
                   @SESSION_FLAGS);
        my $rc = run_claude(@cmd);
        reset_terminal();
        # Fix 3: distinguish a clean user quit from a LOST container (the podman
        # engine or the container died mid-session, dropping the exec). On a
        # loss, hold this window open with an explanation instead of letting the
        # Windows Terminal tab vanish — the conversation is safe on disk, but the
        # user otherwise loses the window with no idea why.
        if (ConnectorHold::should_hold_window($rc, container_status($CONTAINER_NAME))) {
            print ConnectorHold::lost_message($CONTAINER_NAME);
            hold_for_keypress();
        }
        exit $rc;
    }

    # Bare `claude-sandbox` with the container ALREADY running: the manager
    # that built it already did all setup — skip straight to the dashboard.
    # (Holding the setup lock here would needlessly block a real manager, so
    # release it first, exactly as a connector does.)
    if ($state eq 'running') {
        SandboxLock::release($LOCK_DIR);
        enter_dashboard();   # never returns (loops until the user exits)
    }

    # Otherwise the container is missing/stopped: we are the MANAGER. Fall
    # through to setup (image / create / start); it ends by calling
    # enter_dashboard() in place of the old scrolling heartbeat loop.
}

# =====================================================================
# Perl + sandbox-skills.pl invocation helpers
# =====================================================================

sub run_perl_or_die {
    my ($what, @args) = @_;
    my $rc = system($^X, $SANDBOX_SKILLS_PL, @args);
    if ($rc != 0) {
        print STDERR "ERROR: $what (perl exit @{[$rc >> 8]})\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
}

sub run_perl_to_file {
    my ($what, $output_path, @args) = @_;
    # Capture via backticks (works uniformly across cygwin/msys/linux/Win32).
    # Snapshot files are KB-scale, no streaming concern.
    my $captured = _capture_or_die($what, $^X, $SANDBOX_SKILLS_PL, @args);
    _write_file($output_path, $captured);
}

sub _capture_or_die {
    my ($what, @cmd) = @_;
    # Use IPC::Open3-style capture by piping. Simplest portable: backticks
    # with proper escaping. Building a safe shell command from @cmd is
    # tricky; use qx// with shell-quoted args.
    my $cmdstr = join(' ', map { _shell_quote($_) } @cmd);
    my $captured = `$cmdstr`;
    my $rc = $?;
    if ($rc != 0) {
        print STDERR "ERROR: $what (perl exit @{[$rc >> 8]})\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
    return defined $captured ? $captured : '';
}

sub _shell_quote {
    my $s = shift;
    return $s if $s =~ /\A[\w.\/:=+-]+\z/;
    # qx// invokes /bin/sh on cygwin/msys/linux/macos and cmd.exe on
    # native Win32 perl. Match the actual shell, not the platform family
    # — cygwin perl is "Windows family" but its backticks use POSIX sh.
    if ($^O eq 'MSWin32') {
        $s =~ s/"/\\"/g;
        return qq{"$s"};
    }
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# =====================================================================
# Pin discovery snapshots (skills + plugins + MCP)
# =====================================================================
#
# Every subsequent perl invocation reads these frozen views, so a
# concurrent /plugin install in another terminal can't cause inconsistent
# state across our pipeline.

run_perl_to_file('skill discovery snapshot', $SNAPSHOT_FILE,         'discover');
run_perl_to_file('plugin discovery snapshot', $PLUGINS_SNAPSHOT_FILE, 'discover-plugins', '--project-path', $PROJECT_PATH);
run_perl_to_file('MCP discovery snapshot',    $MCP_SNAPSHOT_FILE,    'discover-mcp',     '--project-path', $PROJECT_PATH);

# =====================================================================
# TUI selector (skills + plugins + MCP)
# =====================================================================
#
# Exit codes: 0 = confirmed, 2 = cancelled, other = error.
# The TUI writes selected-skills.json AND the project's
# .claude/settings.local.json. Needs a real TTY on stdin.

{
    my $rc = system($^X, $SANDBOX_SKILLS_PL, 'select-interactive',
        '--selection-file',       $SELECTION_FILE,
        '--discovery-snapshot',   $SNAPSHOT_FILE,
        '--plugins-snapshot',     $PLUGINS_SNAPSHOT_FILE,
        '--mcp-snapshot',         $MCP_SNAPSHOT_FILE,
        '--settings-local-file',  $SETTINGS_LOCAL_FILE,
        '--project-path',         $PROJECT_PATH);
    my $exit = $rc >> 8;
    if ($exit == 2) {
        print "Cancelled.\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 0;
    }
    if ($exit != 0) {
        print STDERR "ERROR: select-interactive failed (exit $exit)\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
}

# =====================================================================
# Staleness reasoning
# =====================================================================

my @STALE_REASONS;

# Version mismatch.
if (-f "$LAUNCHER_DIR/claude-version") {
    my $cv = _read_file("$LAUNCHER_DIR/claude-version");
    chomp $cv if defined $cv;
    $cv //= '';
    if (length $cv && $cv ne $HOST_VERSION) {
        push @STALE_REASONS, "  - Claude Code version mismatch: container has v${cv}, host has v${HOST_VERSION}";
    }
}

# Container age (> 7 days).
if (-f "$LAUNCHER_DIR/container-created") {
    my $created_str = _read_file("$LAUNCHER_DIR/container-created");
    chomp $created_str if defined $created_str;
    if (defined $created_str && length $created_str) {
        my $created_epoch = eval {
            # ISO 8601 strict parse; fall back to lenient strptime for older files.
            my $t = Time::Piece->strptime($created_str, "%Y-%m-%dT%H:%M:%S");
            $t->epoch;
        };
        if (defined $created_epoch && $created_epoch > 0) {
            my $age_days = int((time - $created_epoch) / 86400);
            if ($age_days > 7) {
                push @STALE_REASONS, "  - Container is ${age_days} days old (base OS packages may be outdated)";
            }
        }
    }
}

# Containerfile hash drift.
my $CURRENT_DF_HASH = containerfile_hash();
{
    my $saved = _read_file("$LAUNCHER_DIR/containerfile-hash");
    chomp $saved if defined $saved;
    if (!defined $saved || $saved ne $CURRENT_DF_HASH) {
        push @STALE_REASONS, "  - Containerfile has changed since last build";
    }
}

# Launcher hash drift.
my $CURRENT_LAUNCHER_HASH = launcher_hash();
{
    my $saved = _read_file("$LAUNCHER_DIR/launcher-hash");
    chomp $saved if defined $saved;
    if (!defined $saved || $saved ne $CURRENT_LAUNCHER_HASH) {
        push @STALE_REASONS, "  - Launcher scripts have changed since container was created";
    }
}

# Skill/plugin drift (only meaningful if container actually exists).
if (_container_exists($CONTAINER_NAME)) {
    my $div = _skill_divergence_msg();
    if (defined $div && length $div) {
        push @STALE_REASONS, "  - Skills changed since container was created: $div";
    }
}

# Silent podman-inspect for existence check (avoids dumping the
# JSON-formatted "container not found" error or the full inspect
# document to stdout).
sub _container_exists {
    my $name = shift;
    `$PODMAN inspect "$name" 2>&1`;
    return $? == 0;
}

# _enumerate_inuse_host_ports($self_name) -> @host_port_integers
#   fix-multiple-running-sandboxes / Decision #2-#3: collect every published
#   HOST port already claimed by an existing claude-sandbox container (running
#   OR stopped), so PortAlloc can floor them to occupied bases and hand this new
#   container a free block. Excludes $self_name (this project's own container,
#   which is about to be created / recreated). Robust to no-podman / empty
#   output (returns an empty list -> next_free_base yields the 9000 base).
sub _enumerate_inuse_host_ports {
    my ($self_name) = @_;
    $self_name = defined $self_name ? $self_name : '';

    # Discover sandbox containers by NAME pattern (claude-<project>-<8 hex>), NOT
    # by `ancestor=claude-sandbox:latest`: after any image rebuild the still-running
    # OLD containers descend from a superseded image id, so the ancestor filter
    # would MISS them and their block would be handed out again -> collision.
    # Name-matching catches them regardless of image; over-matching only wastes a
    # block (harmless, Decision #4), under-matching collides.
    my $names_raw = `$PODMAN ps -a --format "{{.Names}}" 2>/dev/null`;
    return () unless defined $names_raw && length $names_raw;

    my @host_ports;
    for my $name (split /\s+/, $names_raw) {
        next unless length $name;
        next unless $name =~ /^claude-.+-[0-9a-f]{8}$/;   # our sandbox naming
        next if $name eq $self_name;

        # Read the CREATE-time published host ports via `podman inspect` — this is
        # STATE-AGNOSTIC (running AND stopped/exited). `podman port <name>` was
        # WRONG here: it reads the live network namespace and returns EMPTY for a
        # stopped container (verified, podman 5.8.3), so a stopped sibling's block
        # would be invisible and handed out again -> EADDRINUSE on its restart,
        # which Decision #5 then cannot fix. .HostConfig.PortBindings is the
        # persisted -p mapping and survives stop. ($p/$c are Go-template vars —
        # backslash-escaped so Perl does not interpolate them.)
        my $ports_raw = `$PODMAN inspect --format '{{range \$p,\$c := .HostConfig.PortBindings}}{{range \$c}}{{.HostPort}} {{end}}{{end}}' "$name" 2>/dev/null`;
        next unless defined $ports_raw;
        push @host_ports, map { $_ + 0 } ($ports_raw =~ /(\d+)/g);
    }
    return @host_ports;
}

# Container-config blueprint drift (CLAUDE.md + settings.json).
my $CURRENT_CLAUDE_MD_HASH = md5_of_file("$CONTAINER_CONFIG/CLAUDE.md");
my $CURRENT_SETTINGS_HASH  = md5_of_file("$CONTAINER_CONFIG/settings.json");
if (-f $CLAUDE_MD_HASH_FILE) {
    my $saved = _read_file($CLAUDE_MD_HASH_FILE);
    chomp $saved if defined $saved;
    if (defined $saved && $saved ne $CURRENT_CLAUDE_MD_HASH) {
        push @STALE_REASONS, "  - Container CLAUDE.md upstream changed since last sandbox refresh";
    }
}
if (-f $SETTINGS_HASH_FILE) {
    my $saved = _read_file($SETTINGS_HASH_FILE);
    chomp $saved if defined $saved;
    if (defined $saved && $saved ne $CURRENT_SETTINGS_HASH) {
        push @STALE_REASONS, "  - Container settings.json upstream changed since last sandbox refresh";
    }
}

sub _skill_divergence_msg {
    return '' unless -f $SELECTION_FILE;
    my $cmd = join(' ',
        _shell_quote($^X),
        _shell_quote($SANDBOX_SKILLS_PL),
        'diff',
        '--selection-file',     _shell_quote($SELECTION_FILE),
        '--discovery-snapshot', _shell_quote($SNAPSHOT_FILE),
        '--plugins-snapshot',   _shell_quote($PLUGINS_SNAPSHOT_FILE),
        '--project-path',       _shell_quote($PROJECT_PATH),
    );
    my $json = `$cmd 2>/dev/null`;
    return '' if $? != 0;
    return '' unless defined $json && length $json;
    my $d = eval { require JSON::PP; JSON::PP::decode_json($json) };
    return '' unless ref $d eq 'HASH';
    my @parts;
    my $fmt = sub {
        my ($label, $arr) = @_;
        return unless ref $arr eq 'ARRAY' && @$arr;
        push @parts, scalar(@$arr) . " $label (" . join(',', @$arr) . ")";
    };
    $fmt->('skill added',       $d->{added});
    $fmt->('skill removed',     $d->{removed});
    $fmt->('now host-only',     $d->{host_only_changed});
    $fmt->('plugin-path drift', $d->{plugin_path_changed});
    $fmt->('plugin added',      $d->{plugins_added});
    $fmt->('plugin removed',    $d->{plugins_removed});
    $fmt->('plugin path drift', $d->{plugins_path_changed});
    return join('; ', @parts);
}

# =====================================================================
# Rebuild prompt (interactive)
# =====================================================================

if (@STALE_REASONS) {
    my $action = prompt_stale_action(\@STALE_REASONS, $HOST_VERSION);
    if ($action eq 'rebuild') {
        # Remove old container if it exists.
        system($PODMAN, 'rm', '-f', $CONTAINER_NAME);
        # Forced rebuild — acquire the global build lock but skip the re-check
        # (the user explicitly chose rebuild, so we always build regardless of
        # whether a concurrent launcher already built it). Fail-open on timeout.
        {
            my $build_lock = "$CLAUDE_HOST_CONFIG/ccpraxis/.locks/image-build";
            File::Path::make_path(dirname($build_lock));
            SandboxLock::acquire($build_lock, timeout => 600, windows => $WINDOWS_FAMILY);
            build_image();
            SandboxLock::release($build_lock);
        }
        # Refresh per-project container blueprint copies from upstream
        # (plugins/sandbox/container/). Any in-container modifications get
        # overwritten — that's the explicit opt-in semantic of Rebuild.
        _copy_file("$CONTAINER_CONFIG/CLAUDE.md",    $CONTAINER_CLAUDE_MD);
        _copy_file("$CONTAINER_CONFIG/settings.json", $CONTAINER_SETTINGS_JSON);
        _write_file($CLAUDE_MD_HASH_FILE, $CURRENT_CLAUDE_MD_HASH);
        _write_file($SETTINGS_HASH_FILE,  $CURRENT_SETTINGS_HASH);
        # Regenerate container name.
        unlink "$LAUNCHER_DIR/container-name";
        my $path_hash = substr(md5_of_string($PROJECT_PATH), 0, 8);
        $CONTAINER_NAME = "claude-${PROJECT_NAME}-${path_hash}";
        _write_file("$LAUNCHER_DIR/container-name", $CONTAINER_NAME);
    } elsif ($action eq 'cancel') {
        print "Cancelled.\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 0;
    }
    # else 'continue' — fall through to launch as-is
}

# Arrow-key TUI for the stale-container prompt — matches the visual style
# of the skills/plugins/MCP picker. Single-key shortcuts ('r', 'c', 'q')
# also work. Falls back to a line-read prompt if Term::ReadKey is missing
# or stdin/stdout aren't tty (so CI / non-interactive uses keep working).
sub prompt_stale_action {
    my ($reasons_ref, $host_version) = @_;
    my @reasons = @$reasons_ref;
    my @options = (
        ['rebuild',  "Rebuild — fresh container with Claude Code v$host_version"],
        ['continue', "Continue as-is"],
    );

    # Non-tty / Term::ReadKey unavailable → degrade to a single-line prompt.
    my $have_readkey = eval { require Term::ReadKey; 1 };
    if (!$have_readkey || !-t STDIN || !-t STDOUT) {
        print "\n";
        print "Sandbox may be stale:\n";
        print "$_\n" for @reasons;
        print "\n";
        print "Options:\n";
        print "  [r] $options[0][1]\n";
        print "  [c] $options[1][1]\n";
        print "\n";
        print "Choice [r/c]: ";
        my $line = <STDIN>;
        $line //= '';
        chomp $line;
        my $first = lc(substr($line, 0, 1) // '');
        return 'rebuild' if $first eq 'r';
        return 'cancel'  if $first eq 'q';
        return 'continue';
    }

    my $sel = 0;
    my $printed_lines = 0;

    my $cleanup = sub {
        print "\e[?25h";          # show cursor
        print "\e[0m";             # reset attrs
        eval { Term::ReadKey::ReadMode(0) };
    };
    local $SIG{INT}  = sub { $cleanup->(); reset_terminal(); exit 130 };
    local $SIG{TERM} = sub { $cleanup->(); reset_terminal(); exit 143 };

    Term::ReadKey::ReadMode(4);    # cbreak
    print "\e[?25l";               # hide cursor

    my $render = sub {
        # Move cursor up to redraw in place. \e[NA moves N lines up.
        if ($printed_lines) {
            print "\e[${printed_lines}A";
            print "\e[J";          # clear to end of screen
        }
        my $out = "";
        $out .= "\n";
        $out .= "Sandbox may be stale:\n";
        $out .= "$_\n" for @reasons;
        $out .= "\n";
        for my $i (0 .. $#options) {
            my $label = $options[$i][1];
            if ($i == $sel) {
                $out .= "\e[1;36m  > $label\e[0m\n";
            } else {
                $out .= "    $label\n";
            }
        }
        $out .= "\n";
        $out .= "  up/down: select   enter: confirm   r/c: shortcut   q/esc: cancel\n";
        $printed_lines = () = ($out =~ /\n/g);
        print $out;
    };

    my $result;
    $render->();
    while (1) {
        my $k = Term::ReadKey::ReadKey(0);
        last unless defined $k;
        if ($k eq "\e") {
            my $k2 = Term::ReadKey::ReadKey(0.05);
            if (defined $k2 && $k2 eq '[') {
                my $k3 = Term::ReadKey::ReadKey(0.05);
                if (defined $k3) {
                    if ($k3 eq 'A' && $sel > 0)         { $sel--; $render->(); next }
                    if ($k3 eq 'B' && $sel < $#options) { $sel++; $render->(); next }
                    next;  # other arrow keys: ignore
                }
            }
            $result = 'cancel'; last;
        }
        if ($k eq "\n" || $k eq "\r") { $result = $options[$sel][0]; last }
        if (lc($k) eq 'r') { $result = 'rebuild';  last }
        if (lc($k) eq 'c') { $result = 'continue'; last }
        if (lc($k) eq 'q') { $result = 'cancel';   last }
        if ($k eq "\x03")  { $result = 'cancel';   last }   # Ctrl+C
    }

    $cleanup->();
    print "\n";
    return $result // 'cancel';
}

sub _copy_file {
    my ($src, $dst) = @_;
    my $bytes = _read_file($src);
    die "_copy_file: cannot read $src\n" unless defined $bytes;
    _write_file($dst, $bytes);
}

# =====================================================================
# Build skill mounts
# =====================================================================

my @SKILL_MOUNTS;
{
    my $cmd = join(' ',
        _shell_quote($^X),
        _shell_quote($SANDBOX_SKILLS_PL),
        'mounts',
        '--selection-file',     _shell_quote($SELECTION_FILE),
        '--discovery-snapshot', _shell_quote($SNAPSHOT_FILE),
    );
    my $output = `$cmd`;
    if ($? != 0) {
        print STDERR "ERROR: failed to enumerate skill mounts (perl exit @{[$? >> 8]})\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
    for my $line (split /\r?\n/, ($output // '')) {
        next unless length $line;
        my ($host_path, $skill_name) = split /\t/, $line, 2;
        next unless defined $host_path && length $host_path
                 && defined $skill_name && length $skill_name;
        push @SKILL_MOUNTS, '-v', "$host_path:/root/.claude/skills/$skill_name:ro";
    }
}

# =====================================================================
# Build plugin store (Fix 2 copy model) + directory-source marketplace binds
# =====================================================================
#
# Instead of MOUNTING the host plugin dirs into the container, the launcher
# COPIES the SELECTED host plugins (+ marketplace metadata) into
# claude-home/plugins/, which rides the RW claude-home bind. The host is never
# mounted into the container, so a compromised in-container process can't reach
# or damage host plugins and can't pull in anything the user didn't select; the
# selection + launcher control metadata stay RO in .launcher/. Each launch the
# host-tier is RECONCILED to exactly the current selection (refresh selected,
# remove what was placed before that isn't selected/present now -> no zombies),
# while plugins installed INSIDE the sandbox are PRESERVED. installed_plugins.json
# and known_marketplaces.json are real RW files in claude-home, merge-materialized
# (selection authoritative + sandbox installs preserved). ccpraxis (and any other
# directory-source marketplace) stays a LIVE read-only bind below.

make_path("$CLAUDE_DATA/plugins") unless -d "$CLAUDE_DATA/plugins";

# Plugins: read the prior copy-plan (for reconcile) BEFORE materialize overwrites
# it, then materialize (registry merge + fresh copy-plan), then reconcile+copy.
my $prior_plugins_plan = _read_copy_plan($PLUGINS_COPY_MANIFEST);
run_perl_or_die('materialize-plugins failed',
    'materialize-plugins',
    '--selection-file',   $SELECTION_FILE,
    '--plugins-snapshot', $PLUGINS_SNAPSHOT_FILE,
    '--project-path',     $PROJECT_PATH,
    '--manifest',         $PLUGINS_COPY_MANIFEST,
    '--output',           $MATERIALIZED_PLUGINS_FILE);
sync_copy_plan($prior_plugins_plan, _read_copy_plan($PLUGINS_COPY_MANIFEST),
               "$CLAUDE_DATA/plugins");

my @PLUGIN_MOUNTS;

# Marketplaces: same reconcile+copy pattern. The metadata of every host
# marketplace (the catalogs) is copied so the user can browse + install from
# them inside the sandbox; only SELECTED plugins are actually installed (above).
# Directory-source marketplaces are excluded from the copy by skills.pl — they
# get the LIVE read-only bind below instead.
if (-f "$HOST_PLUGINS_DIR/known_marketplaces.json") {
    my $prior_mkt_plan = _read_copy_plan($MARKETPLACES_COPY_MANIFEST);
    run_perl_or_die('materialize-known-marketplaces failed',
        'materialize-known-marketplaces',
        '--manifest', $MARKETPLACES_COPY_MANIFEST,
        '--output',   $MATERIALIZED_MARKETPLACES_FILE);
    sync_copy_plan($prior_mkt_plan, _read_copy_plan($MARKETPLACES_COPY_MANIFEST),
                   "$CLAUDE_DATA/plugins");
}

# Bind-mount each directory-source marketplace's source.path INTO the
# container's /root/.claude/plugins/marketplaces/<name> as a LIVE read-only
# bind (so the ccpraxis dev loop never drifts and the container can't modify it).
# These nest on top of the copied marketplaces/ dir in claude-home, so claude-code
# can resolve <marketplace>/.claude-plugin/marketplace.json and follow each
# plugin's relative `source` to the real code. ccpraxis-local is the canonical
# example: source.path is ~/.claude/ccpraxis/plugins/, which contains
# .claude-plugin/ + backpack/ + beacon/ + sandbox/ + steward/.
#
# materialize-known-marketplaces (above) rewrites these entries' source.path AND
# installLocation to /root/.claude/plugins/marketplaces/<name> — same target as
# these binds, so the JSON references match what's on the in-container filesystem.
if (-f "$HOST_PLUGINS_DIR/known_marketplaces.json") {
    my $km_data;
    {
        local $/;
        if (open my $fh, '<:raw', "$HOST_PLUGINS_DIR/known_marketplaces.json") {
            my $raw = <$fh>;
            close $fh;
            $km_data = eval { require JSON::PP; JSON::PP::decode_json($raw) };
        }
    }
    if (ref $km_data eq 'HASH') {
        for my $name (sort keys %$km_data) {
            my $entry = $km_data->{$name};
            next unless ref $entry eq 'HASH';
            my $src = $entry->{source};
            next unless ref $src eq 'HASH';
            next unless ($src->{source} // '') eq 'directory';
            my $host_path = $src->{path};
            next unless defined $host_path && length $host_path;
            $host_path =~ s|\\|/|g;
            $host_path =~ s|/+$||;
            $host_path = winify_path($host_path);
            next unless -d $host_path;
            # Ensure the nested mountpoint exists in claude-home (directory-source
            # marketplaces are excluded from the copy, so claude-home won't
            # already have this subdir) — podman mounts the live source on top.
            make_path("$CLAUDE_DATA/plugins/marketplaces/$name")
                unless -d "$CLAUDE_DATA/plugins/marketplaces/$name";
            my $container_path = "/root/.claude/plugins/marketplaces/$name";
            push @PLUGIN_MOUNTS, '-v', "${host_path}:${container_path}:ro";
        }
    }
}

# =====================================================================
# Materialize credentials
# =====================================================================

# One-time migration (Fix 1): older sandboxes kept the sandbox creds at
# $LAUNCHER_DIR/credentials.json and bind-mounted that single file at
# /root/.claude/.credentials.json. That single-file bind rejected rename()
# over the mountpoint (EBUSY), so an in-container OAuth refresh could never
# persist. The canonical location is now claude-home/.credentials.json (a
# real file inside the RW dir bind, rename-safe). If the new file is absent
# (or a stale 0-byte placeholder, treated as absent below) but the legacy one
# exists, carry it over so accumulated in-container
# mcpOAuth tokens survive the move (materialize-credentials below re-reads
# its own output to preserve mcpOAuth). Copy (not move): the legacy file is
# left in .launcher/ as a harmless RO orphan. Best-effort — a failure here
# just means the container re-auths its MCP servers (re-login of MCP plugins,
# no token loss). NOTE: materialize-credentials NO LONGER copies claudeAiOauth
# from the host (blueprint 01-independent-grant, Decision #1). It preserves the
# CONTAINER's own claudeAiOauth when the reset marker
# .launcher/oauth-independent-migrated is present, and performs a one-time
# reset (clears the stale host-copied token, then creates the marker) when it
# is absent — so a migrated/fresh sandbox with no own grant prompts /login.
# claude-home is RW from the container: a planted (dangling) symlink at the
# creds path makes -f false, and _copy_file would then write THROUGH it to a
# host-side target. Drop the link itself first (unlink removes the link, not its
# target) so any copy/seed lands on a real file in claude-home.
unlink $SANDBOX_CREDENTIALS_FILE if -l $SANDBOX_CREDENTIALS_FILE;
# A pre-Fix-1 sandbox can already hold a STALE 0-byte placeholder at this exact
# path (an older era touched claude-home/.credentials.json). An empty file is not
# "absent", so the old `!-f` guard skipped migration and left it in place — and
# materialize-credentials below then DIED reading that unparseable accumulator,
# aborting the whole launch. Treat a 0-byte file as absent: drop it so the legacy
# creds (with their accumulated in-container mcpOAuth) still migrate over.
unlink $SANDBOX_CREDENTIALS_FILE
    if -f $SANDBOX_CREDENTIALS_FILE && -z $SANDBOX_CREDENTIALS_FILE;
if (!-e $SANDBOX_CREDENTIALS_FILE) {
    my $legacy = "$LAUNCHER_DIR/credentials.json";
    if (-f $legacy && !-z $legacy) {
        make_path($CLAUDE_DATA) unless -d $CLAUDE_DATA;
        eval { _copy_file($legacy, $SANDBOX_CREDENTIALS_FILE); 1 }
            or print STDERR "WARNING: legacy credentials migration failed: $@";
        chmod 0600, $SANDBOX_CREDENTIALS_FILE if -f $SANDBOX_CREDENTIALS_FILE;
    }
}

run_perl_or_die('materialize-credentials failed',
    'materialize-credentials',
    '--output', $SANDBOX_CREDENTIALS_FILE);

# =====================================================================
# Extra env + extra mounts (deploy keys, PAT, SSH commands)
# =====================================================================

my @EXTRA_ENV;
my @EXTRA_MOUNTS;

if (-f "$CLAUDE_DATA/git-ssh-command.sh") {
    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=/root/.claude/git-ssh-command.sh';
} elsif (-f "$PROJECT_PATH/deploy_key") {
    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=ssh -i /project/deploy_key -o StrictHostKeyChecking=no';
}

if (-f "$CLAUDE_DATA/git-askpass.sh") {
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-askpass.sh:/root/.claude/git-askpass.sh:ro";
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-pat:/root/.claude/git-pat:ro";
    push @EXTRA_ENV,    '-e', 'GIT_ASKPASS=/root/.claude/git-askpass.sh';

    # GIT_ASKPASS alone is no longer enough. Claude Code's Bash tool scrubs
    # GIT_ASKPASS (and SSH_ASKPASS) from the subprocess environment as a
    # credential-exfiltration safeguard (v2.1.128+), so any `git` the agent
    # runs over HTTPS never sees it and fails with "could not read Username for
    # 'https://github.com'". A git *credential helper* is read by git from a
    # config FILE, not the environment, so it survives the scrub and is the
    # reliable path. We materialize a tiny helper + an additive global git
    # config and mount the config at the XDG path (read IN ADDITION to the
    # image's ~/.gitconfig, so its autocrlf/defaultBranch settings are NOT
    # masked). The GIT_ASKPASS env above is kept as harmless belt-and-suspenders
    # for any non-scrubbed context (e.g. PID 1); the helper takes precedence.
    # Regenerated every launch so sandboxes created before this fix self-heal
    # on their next container (re)create.
    ensure_git_credential_helper();
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-credential-pat.sh:/root/.claude/git-credential-pat.sh:ro";
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/gitconfig:/root/.config/git/config:ro";
}

if (-f "$CLAUDE_DATA/git-ssh-command.sh") {
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-ssh-command.sh:/root/.claude/git-ssh-command.sh:ro";
}

# =====================================================================
# SANDBOX_HOST_IP — workaround for Windows wslrelay IPv4 gaps
# =====================================================================
# On Windows + Podman, the host-side mirror of published container ports
# is owned by WSL2's wslrelay.exe, which sometimes registers only an
# IPv6 loopback listener — so `http://localhost:9000` from a host browser
# refuses to connect or TCP-RSTs mid-request even though `podman port`
# reports 0.0.0.0:9000 and the container is healthy. Docker doesn't hit
# this because Docker Desktop ships its own user-mode proxy. The WSL
# distro's external IPv4 is always reachable from the host, so we capture
# it here and expose it in the container as $SANDBOX_HOST_IP; the
# container's CLAUDE.md tells agents to prefer that URL when emitting
# user-facing links. Captured at create-time; goes stale only if WSL
# restarts before the user re-launches.
if ($WINDOWS_FAMILY && $PODMAN =~ /podman/i) {
    my $machine = `$PODMAN machine inspect --format "{{.Name}}" 2>/dev/null`;
    chomp $machine;
    $machine = 'podman-machine-default' unless $machine;
    my $ip = `wsl -d $machine -- sh -c "ip -4 addr | grep -oE 'inet [0-9.]+' | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2" 2>/dev/null`;
    chomp $ip;
    push @EXTRA_ENV, '-e', "SANDBOX_HOST_IP=$ip" if $ip =~ /^\d+\.\d+\.\d+\.\d+$/;
}

# =====================================================================
# Backpack plugin mounts (always-on, file-existence-guarded)
# =====================================================================
#
# These two scripts are mounted at stable container-side paths regardless
# of which plugins/skills the TUI selector enables, because:
#   - backpack.pl is invoked by the install pass below, which runs BEFORE
#     the user opens claude (so plugin-driven mounts may not have
#     materialized yet at install-pass time).
#   - auto-declare.pl is referenced by the container's settings.json
#     PostToolUse hook on Bash (the `[ -f ... ] && perl ... || true` guard
#     in settings.json no-ops if this mount is missing).
# Both mounts gracefully no-op if the host source file is missing — useful
# for older ccpraxis checkouts that pre-date the backpack plugin.

my @BACKPACK_MOUNTS;
{
    my $backpack_dir = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/backpack";
    if (-f "$backpack_dir/scripts/backpack.pl") {
        push @BACKPACK_MOUNTS, '-v',
            "$backpack_dir/scripts/backpack.pl:/root/.claude/backpack.pl:ro";
    }
    if (-f "$backpack_dir/hooks/auto-declare.pl") {
        push @BACKPACK_MOUNTS, '-v',
            "$backpack_dir/hooks/auto-declare.pl:/root/.claude/auto-declare.pl:ro";
    }
}

# =====================================================================
# Ensure writable claude.json in project
# =====================================================================
#
# Note: rootless Podman maps container UID 0 (root) to the host running
# user via the user namespace, so files written from inside the container
# come out owned by the host user on the host automatically — no UID
# fix-up probe needed (the equivalent of the Docker setup's chown pass
# is structurally unnecessary here).

# Seed/heal it now so a fresh or corrupt config carries the onboarding bypass
# before we go any further. Re-run at the dashboard entry (every manager path)
# and before `podman create` so all three entry points self-heal — see
# ensure_claude_json_onboarded.
ensure_claude_json_onboarded();

# =====================================================================
# Session selector helper
# =====================================================================
#
# Runs the host-side select-session.pl TUI. Returns one of:
#   ('new',    undef)   — start a fresh session (`claude` with no flags)
#   ('resume', $uuid)   — resume specific session (`claude --resume $uuid`)
#   ('cancel', undef)   — user pressed q/esc/Ctrl-C; caller should exit
#
# We invoke via system() (not backticks) so the child's stdin/stdout/stderr
# stay attached to the user's TTY — required for cbreak input + redraws.
# The decision token comes back through a temp file under .launcher/ so
# we don't need to fight the terminal to read it.
sub pick_session_action {
    my $sessions_dir = "$CLAUDE_DATA/projects/-project";
    my $out_file     = "$LAUNCHER_DIR/.session-pick";
    unlink $out_file;
    my $rc = system($^X, $SELECT_SESSION_PL,
        '--sessions-dir',  $sessions_dir,
        '--project-label', $PROJECT_NAME,
        '--output',        $out_file);
    my $exit = $rc >> 8;
    if ($exit == 2) {
        return ('cancel', undef);
    }
    if ($exit != 0) {
        # Selector failed for some other reason. Don't block the user —
        # fall through to a fresh session, which is the safest default.
        print STDERR "WARNING: session selector exited $exit; starting a new session.\n";
        return ('new', undef);
    }
    my $token = _read_file($out_file);
    unlink $out_file;
    chomp $token if defined $token;
    if (!defined $token || !length $token || $token eq 'NEW') {
        return ('new', undef);
    }
    if ($token =~ /^RESUME\s+([0-9a-fA-F-]+)\s*$/) {
        return ('resume', $1);
    }
    print STDERR "WARNING: session selector returned unrecognized token '$token'; starting a new session.\n";
    return ('new', undef);
}

# =====================================================================
# Host data layout (claude-home) + blueprint application
# =====================================================================
#
# /root/.claude inside the container is a direct bind mount of the host's
# <project>/.ccpraxis-local-data/claude-home/ ($CLAUDE_DATA). Session jsonl,
# tasks/, lockfiles, settings.json, CLAUDE.md, .credentials.json, .launcher/ —
# all are live host files. No podman cp round-trips, no seed-on-create, no
# rescue. The host filesystem IS the state.
#
# On container create we ensure the launcher's canonical copies of CLAUDE.md
# / settings.json / .credentials.json live at claude-home/ on the host so
# they appear at /root/.claude/{CLAUDE.md,settings.json,.credentials.json}
# inside the container. Same for /root/.claude.json (which lives at
# /root/, not /root/.claude/) — bind-mounted as a single-file mount from
# claude-home/.claude.json.
#
# Historical: from the first sandbox version through 2026-06, /root/.claude
# was backed by a podman xfs volume to dodge two Hyper-V 9p bugs (O_APPEND
# EIO + utimensat silent-fail). The WSL2 backend's /mnt/c bind honors both
# correctly, so the volume + sync-sidecar architecture was retired.
# Reintroduce ONLY if a future backend's host-bind fails the t/01
# (O_APPEND, utimensat UTIME_NOW, utimensat explicit-timestamp) probes.

sub apply_blueprints_to_host_data {
    my $host_data = "$CLAUDE_DATA";
    make_path($host_data) unless -d $host_data;
    if (-f $CONTAINER_CLAUDE_MD) {
        _copy_file($CONTAINER_CLAUDE_MD, "$host_data/CLAUDE.md");
    }
    if (-f $CONTAINER_SETTINGS_JSON) {
        _copy_file($CONTAINER_SETTINGS_JSON, "$host_data/settings.json");
    }
    # .credentials.json is NOT copied here — materialize-credentials
    # writes it directly at claude-home/.credentials.json (a real file in
    # the RW dir bind), so writes from inside the container (an OAuth token
    # refresh, or mcpOAuth tokens during `claude mcp add` auth) land on the
    # canonical host file and persist across container rebuild with no sync
    # step. See the $SANDBOX_CREDENTIALS_FILE definition for why this is a
    # real file and not a single-file mount.
}

# Single-file bind mounts require the host path to exist before podman
# create — otherwise podman silently creates a directory at the host
# path and the in-container mount target becomes a directory too.
# These helpers ensure each single-file bind has a host file to point at.

# Seed or self-heal claude-home/.claude.json so the in-container claude never
# lands in the onboarding wizard. Idempotent: writes ONLY when the on-disk file
# is missing / 0-byte / unparseable (reseed the template) or is valid JSON but
# missing an onboarding-bypass key (merge it in, preserving every other key).
# A valid, already-onboarded config is left untouched (heal_claude_json returns
# undef). The write is IN PLACE (_write_file truncates + rewrites) — never a
# rename — because .claude.json is a single-file bind mount and a rename would
# leave the container following the stale inode.
#
# Called at three points so every entry path self-heals: at top-level manager
# setup (above), just before `podman create` (the pre-create host file must
# exist AND be valid so the single-file bind doesn't auto-create a directory and
# claude doesn't see a 0-byte file), and at the top of enter_dashboard (which
# every manager path — fresh create, start-of-stopped, and bare-attach to an
# already-running container — funnels through). The dashboard process is the
# single per-project manager and no connector claude is running yet at that
# point, so it is the safest moment to write the shared file.
sub ensure_claude_json_onboarded {
    my $host_json = "$CLAUDE_DATA/.claude.json";
    make_path($CLAUDE_DATA) unless -d $CLAUDE_DATA;
    my $cur = _read_file($host_json);                       # undef if missing
    my $tpl = _read_file("$CONTAINER_CONFIG/claude.json");  # undef if missing
    my $new = ClaudeConfig::heal_claude_json($cur, $tpl);
    return unless defined $new;                             # already onboarded
    eval { _write_file($host_json, $new); 1 }
        or print STDERR "WARNING: couldn't heal $host_json: $@";
    chmod 0600, $host_json;
}

# Belt-and-suspenders alias kept for the pre-create call site: guarantee the
# single-file-bind source exists AND is a valid onboarding-bypass config.
sub ensure_claude_json_host_file { ensure_claude_json_onboarded() }

# Safety guard only (Fix 1): the canonical sandbox creds now live at
# claude-home/.credentials.json — a REAL file inside the RW dir bind, no
# longer a single-file mount, so it need not pre-exist before `podman
# create`. materialize-credentials always writes a valid file earlier in
# the launch, so by the time we reach create this is a no-op. Kept as a
# belt-and-suspenders seed in case materialize was skipped. This ONLY ensures
# an empty `{}` placeholder exists; it is NOT a credential copy site and never
# writes claudeAiOauth/mcpOAuth — the host token is never copied into the
# sandbox (blueprint 01-independent-grant).
sub ensure_credentials_json_host_file {
    return if -f $SANDBOX_CREDENTIALS_FILE && !-l $SANDBOX_CREDENTIALS_FILE;
    # Drop a container-planted symlink so the seed write can't follow it to a
    # host-side target (claude-home is RW from the container).
    unlink $SANDBOX_CREDENTIALS_FILE if -l $SANDBOX_CREDENTIALS_FILE;
    make_path($CLAUDE_DATA) unless -d $CLAUDE_DATA;
    open(my $fh, '>', $SANDBOX_CREDENTIALS_FILE) or do {
        print STDERR "WARNING: couldn't create $SANDBOX_CREDENTIALS_FILE: $!\n";
        return;
    };
    # Empty file would fail claude's JSON parse. Seed minimal valid JSON
    # — claude-code overwrites with full structure on first auth.
    print $fh "{}\n";
    close $fh;
    chmod 0600, $SANDBOX_CREDENTIALS_FILE;
}

# Materialize the git credential helper (+ an additive global git config) used
# for HTTPS PAT auth. Claude Code's Bash tool scrubs GIT_ASKPASS from the
# environment, so the env-based askpass is dead for any git the agent runs; a
# credential helper read from a git CONFIG FILE is immune to that scrub. The
# helper emits GitHub creds from the PAT mounted at ~/.claude/git-pat. It is
# scoped to https://github.com in the config (the PAT is a GitHub fine-grained
# token — never hand it to other hosts) and no-ops when no PAT file is present.
# Both files live in claude-home (already bind-mounted to /root/.claude); the
# config is additionally mounted at the XDG path /root/.config/git/config by
# the caller. Rewritten every launch so the logic stays current and pre-fix
# sandboxes heal. The host source files exist before `podman create` so the
# single-file binds don't auto-create directories.
sub ensure_git_credential_helper {
    my $cd = "$CLAUDE_DATA";
    return unless -d $cd;

    my $helper = "$cd/git-credential-pat.sh";
    if (open(my $h, '>:raw', $helper)) {
        print $h "#!/bin/sh\n"
               . "# Auto-generated by the ccpraxis sandbox launcher. Do not edit.\n"
               . "[ \"\$1\" = get ] || exit 0\n"
               . "[ -s \"\$HOME/.claude/git-pat\" ] || exit 0\n"
               . "printf 'username=x-access-token\\npassword=%s\\n' \"\$(cat \"\$HOME/.claude/git-pat\")\"\n";
        close $h;
        chmod 0755, $helper or print STDERR "WARNING: chmod 0755 $helper: $!\n";
    } else {
        print STDERR "WARNING: couldn't write $helper: $!\n";
    }

    my $gc = "$cd/gitconfig";
    if (open(my $g, '>:raw', $gc)) {
        print $g "[credential \"https://github.com\"]\n"
               . "\thelper = !sh /root/.claude/git-credential-pat.sh\n";
        close $g;
    } else {
        print STDERR "WARNING: couldn't write $gc: $!\n";
    }
}

# Detect orphaned in-container claude processes — survivors of a prior
# session that the user Ctrl+C'd from PowerShell. Ctrl+C only kills the
# host-side podman.exe client; the disconnect doesn't always propagate
# through conmon to the in-container claude, so claude stays alive but
# decoupled from any user terminal. The orphan keeps refreshing its
# lockfiles in /root/.claude/, which then BLOCKS any new claude session
# that tries to acquire the same locks.
#
# Heuristic: a claude process that has done ZERO read activity over a 2s
# sample AND has been alive for >=30s is considered orphan. The 30s gate
# avoids killing freshly-started claudes that just haven't read anything
# yet (e.g. during their own startup wait).
#
# We never kill silently — print the list and ASK the user. (This runs
# before the session picker / podman start chain, so user-think-time is
# fine here.)
sub find_orphan_claudes {
    return () unless _container_exists($CONTAINER_NAME);
    my $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
    chomp $state if defined $state;
    return () unless defined $state && $state eq 'running';

    # Gather (pid, rchar, etime_seconds) for each claude in container.
    my $listing = `$PODMAN exec "$CONTAINER_NAME" bash -c '
        for pid in \$(pgrep -x claude 2>/dev/null); do
            rchar=\$(awk "/^rchar:/{print \\\$2}" /proc/\$pid/io 2>/dev/null)
            etime=\$(ps -o etimes= -p \$pid 2>/dev/null | tr -d " ")
            echo "\$pid \$rchar \$etime"
        done
    ' 2>/dev/null`;
    my @candidates;
    for my $line (split /\n/, ($listing // '')) {
        my ($pid, $rchar, $etime) = split /\s+/, $line;
        next unless defined $pid && length $pid && defined $rchar && defined $etime;
        # Skip claudes too young to know if they're orphans
        next if $etime < 30;
        push @candidates, { pid => $pid, rchar => $rchar };
    }
    return () unless @candidates;

    # Sample again after 2s to see which haven't read anything
    sleep 2;
    my @orphans;
    for my $cand (@candidates) {
        my $now = `$PODMAN exec "$CONTAINER_NAME" sh -c "awk '/^rchar:/{print \\\$2}' /proc/$cand->{pid}/io 2>/dev/null"`;
        chomp $now;
        if (defined $now && length $now && $now eq $cand->{rchar}) {
            push @orphans, $cand->{pid};
        }
    }
    return @orphans;
}

sub kill_orphan_claudes_if_user_confirms {
    my @orphans = find_orphan_claudes();
    return unless @orphans;
    print "\n";
    print "Found ", scalar(@orphans), " orphan claude process(es) in the container:\n";
    print "  PID $_\n" for @orphans;
    print "\n";
    print "These are claude processes left over from a previous session — usually because\n";
    print "you Ctrl+C'd from PowerShell, which kills the local client but doesn't always\n";
    print "propagate the kill into the container. They hold lockfiles in /root/.claude/\n";
    print "that will block any new claude session you start.\n";
    print "\n";
    print "Kill them now? [Y/n]: ";
    my $resp = <STDIN>;
    $resp //= '';
    chomp $resp;
    my $first = lc(substr($resp, 0, 1) // '');
    if ($first eq 'n') {
        print "Skipping orphan cleanup. If your new session hangs, run:\n";
        print "  podman.exe exec $CONTAINER_NAME pkill claude\n";
        return;
    }
    for my $pid (@orphans) {
        system($PODMAN, 'exec', $CONTAINER_NAME, 'kill', '-9', $pid);
    }
    print _c_ok("Killed orphan claude(s)."), "\n\n";
}

# Run claude inside the container. Returns claude's exit code.
#
# Host's claude-home IS the live state via the bind mount, so claude's
# writes land directly — no sync needed after exit.
#
# IMPORTANT: do NOT `podman stop` after claude exits. Other connector
# instances may have their own claude in the same container — stopping
# would kill them. The container's heartbeat-only keep-alive loop handles
# cleanup: the container reaps itself within HB(300s)+GRACE(10s) after
# the manager terminal's last sentinel touch, independent of whether any
# claude processes are running.
sub run_claude {
    my @cmd = @_;
    my $rc = system(@cmd);
    return $rc >> 8;
}

# Current podman/docker container state ('running','exited','stopped', or ''
# when `inspect` finds no such container — it was removed). Mirrors the inline
# `inspect --format {{.State.Status}}` idiom used elsewhere in this file.
sub container_status {
    my $name = shift;
    my $s = `$PODMAN inspect --format '{{.State.Status}}' "$name" 2>/dev/null`;
    chomp $s if defined $s;
    return defined $s ? $s : '';
}

# Read a copy-plan manifest (skills.pl wrote it with ->utf8->encode): an arrayref
# of {src, dest_rel}. Delegates to PluginSync::read_copy_plan, whose decode is
# UTF-8-aware — CRITICAL because each `src` embeds the user's home dir, which may
# contain non-ASCII bytes (".../André/..."). A non-UTF-8 decode mangles those
# bytes so every `-d $src` in reconcile fails and NOTHING copies (the "selected
# but not installed" bug). Missing / unparseable -> [] ("placed nothing").
sub _read_copy_plan { return PluginSync::read_copy_plan($_[0]); }

# Reconcile a host-tier copy-plan into claude-home (Fix 2). Thin wrapper over
# PluginSync::reconcile_copy_plan (the pure, unit-tested core), passing
# winify_path so `/c/...` host srcs become `C:/...` for perl file ops on Windows.
sub sync_copy_plan {
    my ($prior, $new, $dest_root) = @_;
    PluginSync::reconcile_copy_plan($prior, $new, $dest_root, winify => \&winify_path);
}

# Fix 3: block until the user presses a key, so a held-open connector window
# (Windows Terminal tab) stays visible until the user reads the diagnostic and
# dismisses it. Prefer a single keypress via Term::ReadKey; degrade to a line
# read (Enter) when it's unavailable or stdin isn't a TTY.
sub hold_for_keypress {
    local $| = 1;
    # claude (the in-container TUI) died without restoring the terminal, so the
    # mouse/focus-reporting modes it enabled are still on. Turn them off first so
    # focusing or clicking the tab can't emit an escape sequence that the read
    # below would mistake for a keypress and close the window. (See
    # ConnectorHold::terminal_reset_seq.)
    print STDOUT ConnectorHold::terminal_reset_seq() if -t STDOUT;
    print "  Press Enter to close this window...";
    if ($READKEY_OK) {
        eval {
            Term::ReadKey::ReadMode('cbreak');
            # Drain anything already queued — a click/focus event that landed
            # while claude was dying, or leftover keystrokes — so a stale byte
            # can't dismiss the window before the user has read the message.
            my $drain = 0;
            while ($drain++ < 4096) {
                last unless defined Term::ReadKey::ReadKey(-1);   # non-blocking
            }
            # Block until the user presses ENTER specifically; ignore every other
            # key (and any stray focus/mouse byte that still slips through).
            while (1) {
                my $k = Term::ReadKey::ReadKey(0);   # block for one key
                last if !defined $k;                  # stdin EOF -> stop waiting
                last if ConnectorHold::is_dismiss_key($k);
            }
            1;
        };
        eval { Term::ReadKey::ReadMode('restore') };
    } else {
        my $ignore = <STDIN>;            # line read already requires Enter
    }
    print "\n";
}

# =====================================================================
# Container create / start (MANAGER mode)
# =====================================================================
#
# By construction the connector dispatch near the top of this file has
# already exited any launcher invocation that found the container in
# `running` state, so we know here we're the manager. Tracks whether
# this run created a new container (incl. via [r]ebuild). The backpack
# install pass below only fires on fresh creation — on a restart of an
# existing (stopped) container, tooling state was preserved and
# re-running the install pass would just be slow no-op (verify-then-
# skip on every item).

my $CONTAINER_WAS_CREATED = 0;

# At this point we are guaranteed to be in MANAGER mode — the early
# dispatch near the top of this file already redirected CONNECTOR-mode
# runs (running container) and rejected --resume-session in that mode.
# The container is either missing entirely OR exists in a non-running
# state (stopped/exited/created).

if (_container_exists($CONTAINER_NAME)) {
    print _c_step("Starting container: $CONTAINER_NAME"), "\n";
} else {
    print _c_step("Creating new container: $CONTAINER_NAME"), "\n";
}

# -----------------------------------------------------------------------
# Per-container port-block allocation (fix-multiple-running-sandboxes).
#
# Each sandbox owns one 20-port block (base..base+19). On CREATE we pick
# the lowest block not already published by another claude-sandbox
# container (running OR stopped) and persist that base to
# $LAUNCHER_DIR/port-base. On ATTACH we only read the persisted base for
# messaging — podman baked the -p mapping at create time and `podman
# start` takes no -p, so we never re-allocate or force-recreate an
# existing container (Decision #5).
#
# These are file-scoped so the port args survive from the CREATE block
# down to the podman-start retry loop below, where an EADDRINUSE at start
# re-runs the allocator against a fresh in-use set (Decision #3).
my $PORT_BASE;                 # the allocated block base (undef => no published ports)
my @PORT_INUSE_BASES;          # bases already occupied by sibling sandboxes
my @pub_port_args;         # -p flags fed into @podman_args
my @PORT_ENV_ARGS;             # -e flags fed into @podman_args (SANDBOX_PORT_BASE, ...)
my @podman_args;               # the assembled `podman create` command (file-scoped for retry)
my $build_create_args;         # closure: (re)assemble @podman_args for the current port block

# Rebuild the -p/-e port arg lists for a given base (undef => no ports).
# Kept as a closure so the create + the EADDRINUSE-retry recreate share
# one code path.
my $refresh_port_args = sub {
    my ($base) = @_;
    @pub_port_args = ();
    @PORT_ENV_ARGS     = ();
    return unless defined $base;
    # PortAlloc owns the exact -p / -e strings (module 01); we only splice
    # its result into the podman-create args. The published (-p) and env
    # (-e) halves come back as two arrayrefs.
    my ($pub_args, $env_args) = PortAlloc::build_port_args($base);
    push @pub_port_args, @$pub_args;
    push @PORT_ENV_ARGS,     @$env_args;
};

if (! _container_exists($CONTAINER_NAME)) {
    # CREATE: enumerate sibling-occupied host ports, floor them to block
    # bases, and pick the lowest free base. Robust to no-podman / empty
    # output — an empty in-use set yields the 9000 base.
    @PORT_INUSE_BASES = PortAlloc::bases_from_published(
        [ _enumerate_inuse_host_ports($CONTAINER_NAME) ]);
    $PORT_BASE = PortAlloc::next_free_base(\@PORT_INUSE_BASES);
    if (defined $PORT_BASE) {
        print _c_ok("Allocated host port block $PORT_BASE-@{[$PORT_BASE + 19]}"), "\n";
        _write_file("$LAUNCHER_DIR/port-base", $PORT_BASE);
    } else {
        print STDERR _c_warn("WARNING:"),
            " no free host port block available — launching with NO published ports.\n";
    }
    $refresh_port_args->($PORT_BASE);
} else {
    # ATTACH: read the persisted base for messaging only. Never allocate
    # or re-publish (podman baked the mapping at create; `podman start`
    # takes no -p).
    $PORT_BASE = _read_file("$LAUNCHER_DIR/port-base");
    chomp $PORT_BASE if defined $PORT_BASE;
    $PORT_BASE = ($PORT_BASE // '') =~ /^\d+$/ ? $PORT_BASE + 0 : undef;
}

if (! _container_exists($CONTAINER_NAME)) {

    # Materialize blueprint copies on first create.
    if (! -f $CONTAINER_CLAUDE_MD) {
        _copy_file("$CONTAINER_CONFIG/CLAUDE.md", $CONTAINER_CLAUDE_MD);
        _write_file($CLAUDE_MD_HASH_FILE, md5_of_file("$CONTAINER_CONFIG/CLAUDE.md"));
    }
    if (! -f $CONTAINER_SETTINGS_JSON) {
        _copy_file("$CONTAINER_CONFIG/settings.json", $CONTAINER_SETTINGS_JSON);
        _write_file($SETTINGS_HASH_FILE, md5_of_file("$CONTAINER_CONFIG/settings.json"));
    }

    # Materialize blueprint files + single-file-bind placeholders on host
    # BEFORE the bind mounts go live, so /root/.claude/ inside the
    # container sees everything at the canonical paths from the first
    # moment.
    apply_blueprints_to_host_data();
    ensure_claude_json_host_file();
    ensure_credentials_json_host_file();

    # Assemble the full `podman create` arg list. Kept as a closure so the
    # EADDRINUSE-retry loop below (at podman-start time) can rebuild it with
    # a freshly-allocated port block and recreate the container. Reads the
    # current @pub_port_args / @PORT_ENV_ARGS, which $refresh_port_args
    # rewrites on each reallocation.
    $build_create_args = sub {
        my @args = (
            $PODMAN, 'create', '-it',
            '--name',     $CONTAINER_NAME,
            '--hostname', 'claude-sandbox',
            # Sandbox-marker env var that skill guards inside the container
            # key off (instead of fragile $HOME-path sniffing). Stable across
            # any future image-internal user/path changes.
            '-e',         'CLAUDE_SANDBOX=1',
        );
        # Published host-port block, allocated above via PortAlloc. The
        # base's two sub-ranges (base..base+9 bridged, base+10..base+19 open)
        # are published here in place of the old hardcoded 9000-9019 literals,
        # so concurrent sandboxes never collide on the same host ports. The
        # matching SANDBOX_PORT_BASE / SANDBOX_*_PORTS env vars ride alongside
        # (build_port_args returns both halves). Empty when no free block was
        # available (fallback: no published ports).
        push @args, @pub_port_args;
        push @args, @PORT_ENV_ARGS;
        push @args, @EXTRA_ENV;
        push @args,
        '-v', "${PROJECT_PATH}:/project",
        # /root/.claude is a direct bind from host's claude-home/.
        # On WSL2 (and Linux/macOS hosts), the bind honors O_APPEND and
        # utimensat correctly — claude's session jsonl appends, task
        # store, lock manager, and settings writes all work as expected
        # with no volume + sync-sidecar workaround. See the "Host data
        # layout" comment block earlier in this file for history.
        '-v', "${CLAUDE_DATA}:/root/.claude",
        # .launcher is OVERLAID as RO on top of the claude-home bind.
        # The directory is launcher-managed metadata (hashes, snapshots,
        # blueprint canonicals, container-created/-name) — a compromised
        # in-container process could otherwise fake hashes to bypass
        # backpack approval or corrupt the launcher's selection state.
        # statusline.pl + skills/plugins read its contents; nothing
        # inside the container needs to write to it.
        '-v', "${LAUNCHER_DIR}:/root/.claude/.launcher:ro",
        # .credentials.json is NOT a single-file bind — it lives at
        # claude-home/.credentials.json and rides the ${CLAUDE_DATA} dir
        # bind above as a REAL file at /root/.claude/.credentials.json.
        # A single-file overlay rejected rename() over the mountpoint
        # (EBUSY), which blocked the atomic temp+rename write that both
        # Claude Code and butler's token-keeper use to persist an OAuth
        # refresh — so the in-container token went stale and forced a
        # relaunch. As a real file in the RW dir bind, both in-place and
        # rename writes land and persist, so in-container token refresh
        # works with no relaunch. mcpOAuth tokens written by `claude mcp
        # add` persist the same way (claude-home survives rebuild).
        # .claude.json lives at /root/.claude.json (NOT inside
        # /root/.claude/), so it gets its own single-file bind from
        # claude-home/.claude.json. ensure_claude_json_host_file() above
        # guarantees the host file exists so the mount doesn't auto-create
        # a directory.
        '-v', "${CLAUDE_DATA}/.claude.json:/root/.claude.json",
        '-v', "${CLAUDE_HOST_CONFIG}/ccpraxis/scripts/statusline.pl:/root/.claude/statusline.pl:ro";
        push @args, @SKILL_MOUNTS;
        push @args, @PLUGIN_MOUNTS;
        push @args, @EXTRA_MOUNTS;
        push @args, @BACKPACK_MOUNTS;
        push @args, 'claude-sandbox:latest';

        # Rewrite every `-v HOST:CONTAINER[:opts]` pair into
        # `--mount type=bind,…` to defeat MSYS2's `:`-as-path-list mangling on
        # Git-for-Windows perl. The generated `-p N-M:N-M` args are NOT `-v`
        # pairs, so convert_v_to_mount leaves them untouched — the MSYS2 guard
        # at the top of the file remains their sole colon protection.
        return convert_v_to_mount(@args);
    };

    @podman_args = $build_create_args->();

    my $rc = system(@podman_args);
    log_ev('container_create', { exit => $rc >> 8, container => $CONTAINER_NAME });
    if ($rc != 0) {
        print STDERR _c_err("ERROR:"), " podman create failed (exit @{[$rc >> 8]}) — not committing baseline.\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit ($rc >> 8);
    }

    # MSYS2 path-conversion corruption check (defense-in-depth).
    # If MSYS2's path conversion slipped past the env-var guard at the top
    # of this file and the .sh/.ps1 shim, podman would have auto-created
    # `;C`-suffixed directories on the host as bind-mount fallback targets.
    # Detect those NOW — before podman start — and bail loudly, so the
    # user discovers the bug immediately instead of an hour later when
    # onboarding screens or missing CLAUDE.md tell them something's off.
    # We scan the two paths that hold every host-side `-v` target (claude-home
    # and claude-home/.launcher); a `;C` entry in either is unambiguous evidence.
    {
        my @stray;
        for my $dir ($CLAUDE_DATA, $LAUNCHER_DIR) {
            next unless -d $dir;
            opendir(my $dh, $dir) or next;
            while (my $entry = readdir $dh) {
                next if $entry eq '.' || $entry eq '..';
                push @stray, "$dir/$entry" if $entry =~ /;C$/;
            }
            closedir $dh;
        }
        if (@stray) {
            my $n = scalar @stray;
            print STDERR "\n";
            print STDERR _c_err("ERROR:"), " MSYS2 path corruption detected after podman create.\n";
            print STDERR "       Found $n stray `;C`-suffixed bind-mount target(s):\n";
            print STDERR "         - $_\n" for @stray;
            print STDERR "\n";
            print STDERR "       Cause: the MSYS2_ARG_CONV_EXCL=* guard didn't apply when\n";
            print STDERR "       podman.exe was invoked. Likely someone edited launcher.pl\n";
            print STDERR "       or the .sh/.ps1 shim and removed the env-var setup, OR you\n";
            print STDERR "       invoked launcher.pl directly without the shim.\n";
            print STDERR "       See global-config/CLAUDE.md \"MSYS2 path-conversion\" for the\n";
            print STDERR "       full failure mode.\n";
            print STDERR "\n";
            print STDERR "       Auto-recovering: removing the stray dirs and the broken\n";
            print STDERR "       container so the next run can rebuild cleanly.\n";
            for my $path (@stray) {
                _rmtree($path);
            }
            system($PODMAN, 'rm', '-f', $CONTAINER_NAME);
            SandboxLock::release($LOCK_DIR);
            reset_terminal();
            exit 1;
        }
    }

    $CONTAINER_WAS_CREATED = 1;

    # Container created successfully — commit metadata + baseline.
    _write_file("$LAUNCHER_DIR/claude-version",   $HOST_VERSION);
    _write_file("$LAUNCHER_DIR/container-created",
        strftime("%Y-%m-%dT%H:%M:%S", gmtime(time)));
    _write_file("$LAUNCHER_DIR/launcher-hash",    launcher_hash());
    run_perl_or_die('record-mount failed', 'record-mount',
        '--selection-file',     $SELECTION_FILE,
        '--discovery-snapshot', $SNAPSHOT_FILE);
    run_perl_or_die('manifest write failed', 'manifest',
        '--selection-file',     $SELECTION_FILE,
        '--discovery-snapshot', $SNAPSHOT_FILE,
        '--output',             $MANIFEST_FILE);
}

# =====================================================================
# Backpack approval (host-side, BEFORE podman start)
# =====================================================================
#
# The container's heartbeat-only ENTRYPOINT loop exits when the
# /tmp/.launcher-alive sentinel goes stale (>HB=300s without a touch).
# There is a 10s startup grace, after which the first missing sentinel
# check causes rapid reap. If we did validate / list / prompt AFTER
# `podman start`, the user's read-and-press-y time could push past that
# grace window and the subsequent `podman exec apt-get update` would
# fail with "container state improper". Run all the interaction up here
# on the host (using the host's backpack.pl — it's the same script that
# gets mounted into the container), capture the approval, and only do
# the in-container install after start. The gap between `podman start`
# and the first `podman exec` then stays sub-second.

my @BACKPACK_APPROVED_ITEMS;
my $BACKPACK_APPROVALS_FILE = "$LAUNCHER_DIR/backpack-approvals.json";
my $BACKPACK_TRUST_FILE     = "$LAUNCHER_DIR/backpack-trusted-hash";  # legacy; migrated away on first run
my $BACKPACK_HOST_FILE      = "$CLAUDE_DATA/backpack.json";
my $BACKPACK_HOST_PL        = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/backpack/scripts/backpack.pl";

if ($CONTAINER_WAS_CREATED && -f $BACKPACK_HOST_FILE) {
    if (! -f $BACKPACK_HOST_PL) {
        $INSTALL_WARNING = 'backpack present but host backpack.pl missing - install skipped';
        print STDERR _c_warn("WARNING:"), " backpack.json present but host backpack.pl missing at $BACKPACK_HOST_PL\n";
        print STDERR "         Skipping install pass; run /backpack:install in-session after fixing.\n";
    } else {
        # Validate using host's perl — same backpack.pl, host-resident file.
        my $validate_rc = _tee_system($^X, $BACKPACK_HOST_PL, 'validate', $BACKPACK_HOST_FILE);
        if ($validate_rc != 0) {
            $INSTALL_WARNING = 'backpack.json failed validation - install skipped (see launch transcript)';
            print STDERR "\n";
            print STDERR _c_warn("WARNING:"), " backpack.json failed schema validation (see errors above).\n";
            print STDERR "         Skipping install pass. Fix the file (or delete it) and re-launch.\n";
            print STDERR "\n";
        } else {
            # Per-item approval (#21): only NEW/CHANGED items are walked; the rest
            # install silently. backpack_review returns the approved subset.
            print "\n";
            my ($approved, $deferred) = backpack_review(
                $BACKPACK_HOST_FILE, $BACKPACK_HOST_PL,
                $BACKPACK_APPROVALS_FILE, $BACKPACK_TRUST_FILE,
                md5_of_file($BACKPACK_HOST_FILE));
            @BACKPACK_APPROVED_ITEMS = @$approved;
            log_ev('backpack_review',
                { approved => scalar(@BACKPACK_APPROVED_ITEMS), deferred => $deferred });
            if (!@BACKPACK_APPROVED_ITEMS) {
                print "No backpack items approved — skipping install. Run /backpack:install in-session anytime.\n";
            } elsif ($deferred) {
                print "$deferred item(s) deferred — you'll be asked again on the next launch.\n";
            }
        }
    }
}

# Release the per-project lock before podman exec — `exec` replaces this
# perl process and skips END/signal handlers, so we release explicitly.
# Releasing here (before podman start + install pass) lets a concurrent
# second-terminal launcher attach via the running-container fast path
# without waiting on us. The install pass below is safe lock-free because
# $CONTAINER_WAS_CREATED=1 can only be true for the launcher that just
# won the create branch — no other writer can be inside the same
# container's apt/dpkg.
SandboxLock::release($LOCK_DIR);

# podman binds published host ports at START (not create), so an
# "address already in use" collision surfaces here. On the CREATE path a
# racing sandbox may have grabbed our block between enumeration and start;
# recover by rm'ing the just-created container, marking this base occupied,
# re-running PortAlloc::next_free_base for a fresh block, rebuilding the
# create args, and recreating — bounded, then giving up loudly. On the
# ATTACH path we do NOT force-recreate an existing container (Decision #5):
# its port mapping is baked in, so we tell the user to rebuild ([r]) for a
# fresh block.
#
# `podman start` returns a non-zero exit on the port-bind failure but
# system() doesn't hand us its stderr. Only when the start fails do we
# re-run it under backticks to capture the message and classify whether it
# is an address-in-use collision (a fresh `podman start` on a container
# that is still stopped reproduces the same bind error deterministically).
my $start_rc = system($PODMAN, 'start', $CONTAINER_NAME);
my $port_in_use = sub {
    my ($status) = @_;
    return 0 if $status == 0;
    my $out = `$PODMAN start "$CONTAINER_NAME" 2>&1`;
    return (defined $out
        && $out =~ /EADDRINUSE|address already in use|port is already allocated|already in use/i) ? 1 : 0;
};

if ($start_rc != 0 && $port_in_use->($start_rc)) {

    if ($CONTAINER_WAS_CREATED) {
        my $tries = 0;
        my $max_tries = 5;
        while ($start_rc != 0 && $tries < $max_tries) {
            $tries++;
            print STDERR _c_warn("WARNING:"),
                " host port block "
                . (defined $PORT_BASE ? "$PORT_BASE-@{[$PORT_BASE + 19]}" : '(none)')
                . " is already in use — reallocating (attempt $tries/$max_tries).\n";
            # Mark the collided base occupied and pick the next free block.
            push @PORT_INUSE_BASES, $PORT_BASE if defined $PORT_BASE;
            my $next = PortAlloc::next_free_base(\@PORT_INUSE_BASES);
            if (!defined $next) {
                print STDERR _c_err("ERROR:"),
                    " no free host port block available after $tries attempt(s) — giving up.\n";
                reset_terminal();
                exit 1;
            }
            $PORT_BASE = $next;
            _write_file("$LAUNCHER_DIR/port-base", $PORT_BASE);
            $refresh_port_args->($PORT_BASE);
            # Recreate with the fresh block, then retry start.
            system($PODMAN, 'rm', '-f', $CONTAINER_NAME);
            @podman_args = $build_create_args->();
            my $recreate_rc = system(@podman_args);
            if ($recreate_rc != 0) {
                print STDERR _c_err("ERROR:"),
                    " podman recreate failed (exit @{[$recreate_rc >> 8]}) during port-collision retry.\n";
                reset_terminal();
                exit ($recreate_rc >> 8 || 1);
            }
            print _c_ok("Reallocated host port block $PORT_BASE-@{[$PORT_BASE + 19]}"), "\n";
            $start_rc = system($PODMAN, 'start', $CONTAINER_NAME);
            last if $start_rc == 0;
            last unless $port_in_use->($start_rc);
        }
        if ($start_rc != 0) {
            print STDERR _c_err("ERROR:"),
                " could not find a free host port block after $tries attempt(s) — giving up.\n";
            reset_terminal();
            exit ($start_rc >> 8 || 1);   # never exit 0 on a failed/ signal-killed start
        }
    } else {
        # Existing container: its -p mapping was baked at create and cannot
        # be re-published by `podman start`. Do NOT force-recreate.
        print STDERR "\n";
        print STDERR _c_err("ERROR:"),
            " another sandbox took this container's host ports"
            . (defined $PORT_BASE ? " (block $PORT_BASE-@{[$PORT_BASE + 19]})" : '') . ".\n";
        print STDERR "       This container's port mapping is fixed for its lifetime.\n";
        print STDERR "       Rebuild ([r] at the next prompt) to recreate it with a fresh,\n";
        print STDERR "       free port block.\n\n";
        reset_terminal();
        exit ($start_rc >> 8 || 1);   # never exit 0 on a failed/ signal-killed start
    }
}
log_ev('container_start', { exit => $start_rc >> 8, container => $CONTAINER_NAME });

# Land the first sentinel touch IMMEDIATELY after `podman start`, before
# anything else (perl/helper probes, apt-get update, backpack install)
# burns through the container's 10-second startup grace. The container's
# entrypoint loop checks for /tmp/.launcher-alive at t=GRACE and reaps
# itself if missing — so any slow operation here would kill the container
# mid-flight ("container state improper" on the next exec). With the
# sentinel established first, we now have HB=300s to do the install pass
# before needing another refresh (and the install pass below maintains
# its own in-container refresher for installs that exceed that window).
system($PODMAN, 'exec', $CONTAINER_NAME, 'touch', '/tmp/.launcher-alive');

# Bind mount of claude-home → /root/.claude means host filesystem IS
# the live state. No seed, no rescue, no sync. Blueprint files were
# already materialized to claude-home/ before podman create — the bind
# now exposes them in the container at the canonical paths. Same for
# .claude.json's single-file bind. Nothing to do here.

# --- Backpack install (container side) — only the approved subset (#21) ---
# All user interaction (validate, list, per-item approve/remove) happened on the
# host before `podman start`. By this point @BACKPACK_APPROVED_ITEMS is the set
# the user OK'd; we install ONLY that subset so an un-approved item can never run
# as root in the container.
#
# Large backpack installs (e.g. chromium = 289 deps / 221MB) can easily exceed
# the container's 5-min HB window, which would otherwise let the entrypoint loop
# reap the container mid-`apt-get install`. We run apt-get update + the install +
# a parallel heartbeat refresher under a single `podman exec bash`. The heartbeat
# is a background subshell tied to the bash's lifetime via `trap EXIT`, so it
# dies the moment the install completes (or this bash is signalled). Single exec
# → single lifecycle → no orphan helper to clean up.
if (@BACKPACK_APPROVED_ITEMS) {
    # Pre-flight: confirm the container has perl + backpack.pl wired in. If the
    # mount didn't land (older ccpraxis checkout, missing source), warn and skip
    # — claude still launches.
    my $has_perl = (system($PODMAN, 'exec', $CONTAINER_NAME,
        'test', '-x', '/usr/bin/perl') == 0);
    my $has_helper = $has_perl
        && (system($PODMAN, 'exec', $CONTAINER_NAME,
            'test', '-f', '/root/.claude/backpack.pl') == 0);
    if (!$has_helper) {
        $INSTALL_WARNING = 'backpack.pl not mounted in container - install skipped';
        print STDERR _c_warn("WARNING:"), " Backpack found at $BACKPACK_HOST_FILE but backpack.pl isn't mounted in the container. Update ccpraxis (the launcher needs the plugin's backpack/scripts/backpack.pl) and rebuild.\n";
    } else {
        # Write the approved subset as a backpack-shaped file into claude-home
        # (bound at /root/.claude) and point `install` at it — the full
        # backpack.json is never installed wholesale. The container path is fixed,
        # so the install script stays a non-interpolating single-quoted heredoc.
        my $set_host = "$CLAUDE_DATA/.backpack-install-set.json";
        my $wrote = eval {
            _write_file($set_host, JSON::PP->new->utf8->canonical(1)->pretty->encode(
                { version => 2, items => \@BACKPACK_APPROVED_ITEMS }));
            1;
        };
        if (!$wrote) {
            $INSTALL_WARNING = 'could not write backpack install-set - install skipped';
            print STDERR _c_warn("WARNING:"), " could not write backpack install-set ($set_host): $@\n";
        } else {
            # Inline bash script: kick off the heartbeat refresher in the
            # background, run apt-get update + backpack install in the foreground,
            # then let the EXIT trap kill the refresher on the way out. The
            # script's exit status mirrors the install's. apt-get update failures
            # are not fatal (some backpack entries don't depend on apt), so its
            # return code is intentionally ignored.
            my $install_script = <<'BASH';
HB_PID=""
cleanup() { [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM HUP
( while true; do touch /tmp/.launcher-alive; sleep 60; done ) &
HB_PID=$!
echo "Refreshing apt index..."
apt-get update -qq
echo "Installing backpack items..."
perl /root/.claude/backpack.pl install /root/.claude/.backpack-install-set.json
BASH
            _tx("\n--- backpack install (approved subset: @{[scalar @BACKPACK_APPROVED_ITEMS]} items) ---\n");
            my $install_rc = _tee_system($PODMAN, 'exec', $CONTAINER_NAME,
                'bash', '-c', $install_script);
            unlink $set_host;   # transient; don't leave the subset lying in claude-home
            if ($install_rc != 0) {
                $INSTALL_WARNING = 'backpack install: some items failed - run /backpack:install in the session to retry';
                log_ev('backpack_install_failed', { exit => $install_rc >> 8 });
                print "\n";
                print _c_warn("WARNING:"), " Some backpack items failed (see above). Handing off to claude anyway — fix in-session via /backpack:add, /backpack:remove, or by editing the backpack file directly and running /backpack:install.\n";
                print "\n";
            } else {
                log_ev('backpack_install_ok', { installed => scalar @BACKPACK_APPROVED_ITEMS });
            }
        }
    }
}

# =====================================================================
# Dashboard (manager mode) — Decision #19
# =====================================================================
#
# Container is up + backpack install (if any) is done. This launcher now
# becomes the manager window: it lands on the dashboard, which holds the
# container alive via the same /tmp/.launcher-alive heartbeat (every 2
# minutes, well within the container's 5-minute reap window) and exposes
# the launch-claude + shutdown-all hotkeys. Closing this window — or the
# dashboard's [q] — stops the heartbeat; the container reaps itself within
# ~5 minutes (Decision #17, unchanged). On a non-TTY / no-Term::ReadKey
# terminal it degrades to the plain scrolling heartbeat loop.
enter_dashboard();   # never returns (loops until the user exits)

# ---------------------------------------------------------------------
# Dashboard wiring (B2) — these file-scope subs close over $PODMAN /
# $CONTAINER_NAME / $PROJECT_* / the loggers, supplying the real podman +
# terminal seams to the generic Dashboard::run loop.
# ---------------------------------------------------------------------

# enter_dashboard — manager-ready: log it, do an immediate heartbeat so the
# reap window starts fresh, then run the dashboard (raw-ANSI TUI when the
# terminal supports it, else the plain heartbeat loop).
sub enter_dashboard {
    log_ev('manager_ready', { container => $CONTAINER_NAME });
    # Self-heal .claude.json's onboarding bypass on EVERY manager entry (fresh
    # create, start-of-stopped, or bare-attach to an already-running container).
    # This is the single chokepoint all manager paths funnel through, and no
    # connector claude is running yet — the safest point to write the shared,
    # single-file-bound config. Heals a 0-byte/corrupt file or one that lost its
    # onboarding keys, so the next [c] never reopens the setup wizard.
    ensure_claude_json_onboarded();
    # Act on the first heartbeat: if the container is already gone, don't paint
    # a dashboard that would just die on its first tick — say so and exit clean.
    if (_heartbeat_once() eq 'gone') {
        print STDERR "Container $CONTAINER_NAME is no longer running. Nothing to attach to.\n";
        reset_terminal();
        exit 0;
    }

    my $is_tty = (-t STDOUT && -t STDIN) ? 1 : 0;
    my $mode   = Dashboard::decide_mode($is_tty, $READKEY_OK, $ENV{CCPRAXIS_NO_TUI});
    if ($mode eq 'plain') {
        plain_heartbeat_loop();   # never returns
        return;
    }

    require Term::ReadKey;
    my $log_path = "$CLAUDE_DATA/sandbox-logs/launch-$LAUNCH_ID.log";
    my $cached_status           = 'unknown';
    my $cached_busy_age         = undef;   # B5: age (s) of /tmp/.butler-busy in CONTAINER time, or undef
    my $cached_busy_stamp       = 0;       # host time() when $cached_busy_age was measured
    my $cached_needs_you        = 0;       # B3: queued "needs you" decisions
    my $cached_backpack         = undef;   # B4: backpack items + per-item approval
    my $cached_oauth_expires_at = undef;   # 01-oauth: epoch-s when the OAuth token expires
    my $last_inspect            = 0;
    my $bp_host_file      = "$CLAUDE_DATA/backpack.json";
    my $bp_appr_file      = "$LAUNCHER_DIR/backpack-approvals.json";

    # B5 keep-awake: hold a wake-lock only while the orchestrator's busy-lease is
    # fresh (active work / pending auto-resume). Reap any helper orphaned by a
    # previously-crashed launcher first, then build the seam-driven holder.
    # Keep-awake holds the host awake while the busy-lease was touched within this
    # window. 10 min (matching the loosened heartbeat HB) so a brief gap / slow
    # tick never releases the lock mid-run; the host only sleeps once the run has
    # been genuinely idle or parked this long. Env-overridable.
    my $BUSY_STALE   = ($ENV{BUSY_STALE_SECS} && $ENV{BUSY_STALE_SECS} =~ /^\d+$/)
                       ? $ENV{BUSY_STALE_SECS} : 600;
    my $ka_helper    = "$SANDBOX_PLUGIN/scripts/keep-awake.ps1";
    my $ka_pidfile   = "$LAUNCHER_DIR/keepawake.pid";
    _keepawake_reap_orphan($ka_pidfile);
    $KEEPAWAKE = KeepAwake->new(
        start => sub { _keepawake_start($ka_helper, $ka_pidfile) },
        stop  => sub { _keepawake_stop($_[0], $ka_pidfile) },
    );

    my $rc = Dashboard::run(
        color     => 1,
        enter_raw => sub {
            Term::ReadKey::ReadMode('cbreak');
            print STDOUT "\e[?1049h\e[?25l";        # alt-screen + hide cursor
        },
        leave_raw => sub {
            print STDOUT "\e[?25h\e[?1049l";        # show cursor + leave alt-screen
            eval { Term::ReadKey::ReadMode('restore') };
            reset_terminal();
        },
        read_key  => sub {
            my $k = Term::ReadKey::ReadKey(-1);   # non-blocking poll
            return undef unless defined $k;
            if ($k eq "\e") {
                # Assemble an arrow escape sequence into a token the dashboard
                # understands: UP/DOWN scroll the Activity panel. A lone ESC (no
                # following bytes) falls through as "\e" (inert in dispatch_key).
                my $k2 = Term::ReadKey::ReadKey(0.02);
                if (defined $k2 && ($k2 eq '[' || $k2 eq 'O')) {
                    my $k3 = Term::ReadKey::ReadKey(0.02);
                    if (defined $k3) {
                        return 'UP'   if $k3 eq 'A';
                        return 'DOWN' if $k3 eq 'B';
                        if ($k3 =~ /[0-9]/) {   # drain a numeric CSI (e.g. \e[5~)
                            while (defined(my $d = Term::ReadKey::ReadKey(0.01))) {
                                last if $d !~ /[0-9;]/;
                            }
                        }
                        return undef;   # other arrows / CSI: ignore
                    }
                }
                # ESC + a non-CSI byte (e.g. Alt+key): surface that byte rather
                # than dropping it. A lone ESC (k2 undef) falls through as inert.
                return $k2 if defined $k2;
                return "\e";
            }
            return $k;
        },
        term_size => sub {
            my @s = eval { Term::ReadKey::GetTerminalSize() };
            my $cols = (@s && $s[0]) ? $s[0] : 80;
            my $rows = (@s && $s[1]) ? $s[1] : 24;
            return ($cols, $rows);
        },
        heartbeat => \&_heartbeat_once,
        gather    => sub {
            # podman inspect is comparatively expensive; cache it ~10s so the
            # input loop stays responsive. The cheap log tail refreshes every
            # state interval. (B3 may make the inspect fully async.)
            my $now = time;
            if ($now - $last_inspect >= 10) {
                my $s = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
                chomp $s if defined $s;
                $cached_status = (defined $s && length $s) ? $s : 'unknown';
                # B5: busy-lease freshness (the orchestrator keeps /tmp/.butler-busy
                # fresh only while there's active work or a pending auto-resume).
                # Compute the age ENTIRELY in container time — read the lease mtime
                # AND the container clock, both via exec, and subtract here. Doing
                # `host_now - container_mtime` instead skews the age by the host-vs-
                # container clock offset (seen as a NEGATIVE busy_age in the wild),
                # which released keep-awake mid-run and let the host sleep. Read
                # mtime first, then now, so the inter-exec gap can't read negative.
                my $bm = `$PODMAN exec "$CONTAINER_NAME" stat -c %Y /tmp/.butler-busy 2>/dev/null`;
                my $cn = `$PODMAN exec "$CONTAINER_NAME" date +%s 2>/dev/null`;
                my ($lmt)  = ($bm && $bm =~ /^(\d+)/) ? ($1) : ();
                my ($cnow) = ($cn && $cn =~ /^(\d+)/) ? ($1) : ();
                if (defined $lmt && defined $cnow) {
                    my $a = $cnow - $lmt;
                    $cached_busy_age = $a < 0 ? 0 : $a;   # clamp the tiny exec-gap race
                } else {
                    $cached_busy_age = undef;
                }
                $cached_busy_stamp = $now;
                $cached_needs_you  = _count_needs_you($PROJECT_PATH);          # B3
                $cached_backpack   = _gather_backpack($bp_host_file, $bp_appr_file);  # B4
                $cached_oauth_expires_at = _gather_oauth_expiry();
                $last_inspect  = $now;
            }
            # Advance the skew-free baseline by host-measured elapsed since the
            # last measurement (elapsed rate matches on both clocks; only the
            # absolute offset differed, and that's gone now).
            my $busy_age = defined $cached_busy_age ? $cached_busy_age + ($now - $cached_busy_stamp) : undef;
            # B5: the single keep-awake decision, shared by the seam below AND the
            # Run panel (so the view never re-derives the freshness threshold).
            my $stay = KeepAwake::should_stay_awake($busy_age, $BUSY_STALE) ? 1 : 0;
            my @lines = _tail_lines($log_path, 200);
            return {
                project_name    => $PROJECT_NAME,
                container       => $CONTAINER_NAME,
                status          => $cached_status,
                events          => Dashboard::recent_events(\@lines, 50),
                install_warning => $INSTALL_WARNING,
                busy_age        => $busy_age,
                stay_awake      => $stay,
                needs_you        => $cached_needs_you,
                backpack         => $cached_backpack,
                oauth_expires_at => $cached_oauth_expires_at,
            };
        },
        keepawake => sub {
            my ($st) = @_;
            my $act = $KEEPAWAKE->sync($st->{stay_awake} ? 1 : 0);
            log_ev('keepawake', { want => ($st->{stay_awake} ? 1 : 0), action => $act,
                                  busy_age => $st->{busy_age} }) if $act ne 'noop';
        },
        spawn         => \&_spawn_session,
        write_signals => sub {
            my $n = Dashboard::write_shutdown_signals(Dashboard::shutdown_targets($PROJECT_PATH));
            log_ev('shutdown_all', { signals => $n });
            return $n;
        },
    );
    _keepawake_release_global();   # drop the wake-lock on clean dashboard exit
    exit($rc // 0);
}

# _heartbeat_once — touch the container's keep-alive sentinel. Returns
# 'ok' | 'fail' | 'gone' (the dashboard ends its loop on 'gone'). Shared by
# the TUI seam and the plain loop so the container-gone detection lives once.
sub _heartbeat_once {
    # CAPTURE (don't inherit) podman's stderr. When the podman machine SSH
    # connection drops — e.g. the host enters Modern Standby and the WSL2 VM is
    # suspended — `podman exec` prints a multi-line "Cannot connect to Podman …
    # wsarecv: An existing connection was forcibly closed …" error. With the
    # dashboard on the alt-screen, an inherited STDERR would splatter that text
    # across the live frame (the corruption André saw). Backticks + 2>&1 keep it
    # off-screen (MSYS2_ARG_CONV_EXCL=* is set, so the /tmp path passes through),
    # and the captured reason is surfaced in the launch log instead.
    my $out = `$PODMAN exec "$CONTAINER_NAME" touch /tmp/.launcher-alive 2>&1`;
    my $rc  = $?;
    if ($rc != 0) {
        my $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
        chomp $state if defined $state;
        $state //= '';
        my $reason = _trim_err($out);
        if ($state ne 'running') {
            log_ev('container_gone', { state => $state, container => $CONTAINER_NAME, reason => $reason });
            return 'gone';
        }
        # $? is a wait status: exit code is >>8, low 7 bits are the signal. A
        # podman reaped by a signal (host waking from standby kills the WSL2 VM)
        # has exit 0 but a non-zero signal — log both so the field that exists to
        # diagnose these wakeup failures isn't misleadingly 0.
        log_ev('heartbeat_fail', { exit => ($rc >> 8), signal => (($rc & 127) || undef),
                                   state => $state, reason => $reason });
        return 'fail';
    }
    log_ev('heartbeat', {});
    return 'ok';
}

# _trim_err($s) -> $s collapsed to a single, bounded line for a log field: fold
# whitespace/newlines to single spaces, strip ends, cap length. Keeps a captured
# multi-line podman error readable as one JSON log value.
sub _trim_err {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    $s = substr($s, 0, 300) . '...' if length($s) > 300;
    return $s;
}

# ---------------------------------------------------------------------
# B5 keep-awake helpers — the real spawn/kill seams for the KeepAwake holder.
# The host perl is Git-for-Windows (cygwin) perl with no Win32::API, so the
# wake-lock is a dedicated PowerShell child (keep-awake.ps1) whose lifetime IS
# the lock's lifetime. NOTE: the actual spawn/kill + whether the machine really
# stays awake is verified on a real desktop (attended); the decision + lifecycle
# logic is unit-tested in KeepAwake.pm / t/28.
# ---------------------------------------------------------------------

# _keepawake_start($ps1, $pidfile) -> child pid | undef. fork+exec the PowerShell
# helper detached (stdio to /dev/null so it can't touch the dashboard alt-screen).
# Returns the cygwin child pid (the holder's handle, used by _keepawake_stop).
# The helper self-reports its WINDOWS pid into $pidfile for cross-crash reaping.
sub _keepawake_start {
    my ($ps1, $pidfile) = @_;
    unless (-f $ps1) {
        log_ev('keepawake_start_failed', { reason => "helper missing: $ps1" });
        return undef;
    }
    my $win_ps1 = winify_path($ps1);
    my $win_pid = winify_path($pidfile);
    my $pid = fork();
    if (!defined $pid) {
        log_ev('keepawake_start_failed', { reason => "fork: $!" });
        return undef;
    }
    if ($pid == 0) {
        # child: detach stdio, then exec the helper. _exit (not exit) on failure
        # so the parent's END handlers don't run in the child.
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        exec('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-WindowStyle', 'Hidden', '-File', $win_ps1, '-PidFile', $win_pid)
            or do { POSIX::_exit(127); };
    }
    log_ev('keepawake_started', { pid => $pid });
    return $pid;
}

# _keepawake_stop($child_pid, $pidfile) — kill our helper child (releases the
# wake-lock: process death drops ES_CONTINUOUS) and clear the pidfile. SIGKILL so
# it's immediate; waitpid reaps the zombie (it's a direct fork of ours).
sub _keepawake_stop {
    my ($pid, $pidfile) = @_;
    if (defined $pid && $pid =~ /^\d+$/ && $pid > 0) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        log_ev('keepawake_stopped', { pid => $pid });
    }
    unlink $pidfile if defined $pidfile && -f $pidfile;
}

# _keepawake_reap_orphan($pidfile) — on dashboard entry, kill a helper left
# running by a previously-CRASHED launcher (its wake-lock would persist forever).
# Uses the helper's self-reported WINDOWS pid + taskkill, guarded by a name check
# so a recycled pid that now belongs to something else is left alone.
sub _keepawake_reap_orphan {
    my ($pidfile) = @_;
    return unless defined $pidfile && -f $pidfile;
    my $wpid = _read_file($pidfile);
    chomp $wpid if defined $wpid;
    unlink $pidfile;
    return unless defined $wpid && $wpid =~ /^\d+$/;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $name = `powershell.exe -NoProfile -Command "(Get-Process -Id $wpid -ErrorAction SilentlyContinue).ProcessName" 2>/dev/null`;
    chomp $name if defined $name;
    if (defined $name && $name =~ /powershell/i) {
        system('taskkill.exe', '/PID', $wpid, '/F', '/T');
        log_ev('keepawake_orphan_reaped', { pid => $wpid });
    }
}

# ---------------------------------------------------------------------
# B3/B4 dashboard gather helpers (host-side reads feeding build_panels).
# ---------------------------------------------------------------------

# _count_needs_you($project) -> count of queued "needs you" decision entries
# across every blueprint's runs/needs-you/ (Decision #27's dashboard indicator).
# opendir/readdir (not glob) so project paths with spaces / André bytes are safe.
sub _count_needs_you {
    my ($project) = @_;
    my $base = "$project/.ccpraxis-local-data/blueprints";
    return 0 unless -d $base;
    my $n = 0;
    opendir(my $bd, $base) or return 0;
    for my $bp (readdir $bd) {
        next if $bp eq '.' || $bp eq '..';
        my $nd = "$base/$bp/runs/needs-you";
        next unless -d $nd;
        opendir(my $d, $nd) or next;
        for my $f (readdir $d) {
            next if $f =~ /^\./ || $f =~ /\.tmp$/;   # skip dotfiles + atomic-write temps
            $n++ if -f "$nd/$f";
        }
        closedir $d;
    }
    closedir $bd;
    return $n;
}

# _gather_backpack($bp_file, $appr_file) -> { total, approved, items=>[{key,
# approved}] } for the B4 panel, or undef when there's no backpack. Cheap (two
# small host JSON reads); reuses BackpackApproval so the panel's approval state
# matches the #21 gate exactly.
sub _gather_backpack {
    my ($bp_file, $appr_file) = @_;
    return undef unless -f $bp_file;
    my $data = eval { JSON::PP->new->decode(_read_file($bp_file) // '') };
    return { total => 0, approved => 0, items => [] }
        unless ref $data eq 'HASH' && ref $data->{items} eq 'ARRAY';
    my $appr = BackpackApproval::load($appr_file);
    my (@items, $napprove);
    $napprove = 0;
    for my $it (@{ $data->{items} }) {
        next unless ref $it eq 'HASH';
        my $ok = BackpackApproval::is_approved($it, $appr) ? 1 : 0;
        $napprove++ if $ok;
        push @items, { key => BackpackApproval::item_key($it), approved => $ok };
    }
    return { total => scalar(@items), approved => $napprove, items => \@items };
}

# _gather_oauth_expiry() -> epoch-seconds when the OAuth token expires, or undef.
# Reads $SANDBOX_CREDENTIALS_FILE (read-only; never writes/refreshes it), decodes
# JSON, and extracts claudeAiOauth.expiresAt (milliseconds -> seconds). Returns
# undef when the file is absent, unparseable, or lacks the key.
sub _gather_oauth_expiry {
    my $raw = _read_file($SANDBOX_CREDENTIALS_FILE);
    return undef unless defined $raw && length $raw;
    my $data = eval { JSON::PP->new->decode($raw) };
    return undef unless ref $data eq 'HASH';
    my $oauth = $data->{claudeAiOauth};
    return undef unless ref $oauth eq 'HASH';
    my $exp = $oauth->{expiresAt};
    return undef unless defined $exp && $exp =~ /^\d+$/;
    return int($exp / 1000);
}

# _tail_lines — last $n chomped lines of a file (the B1 launch log), or ().
# Seek-based + byte-capped: a long-lived dashboard re-reads this every state
# tick, and the log grows for the whole run, so reading the WHOLE file each time
# would be unbounded. Read only the last 128 KB (plenty for $n lines), dropping
# the first partial line when we start mid-file.
sub _tail_lines {
    my ($path, $n) = @_;
    open my $fh, '<', $path or return ();
    binmode $fh, ':raw';
    my $size = -s $fh;
    $size = 0 if !defined $size;
    my $cap  = 128 * 1024;
    my $from = $size > $cap ? $size - $cap : 0;
    seek $fh, $from, 0;
    local $/;
    my $blob = <$fh>;
    close $fh;
    return () if !defined $blob || !length $blob;
    $blob =~ s/^[^\n]*\n// if $from > 0;   # drop the partial leading line
    my @lines = split /\n/, $blob;
    chomp @lines;
    return @lines > $n ? @lines[-$n .. -1] : @lines;
}

# _spawn_session — the dashboard's launch-claude hotkey: open a NEW Windows
# Terminal window running the internal connector entry
# (`claude-sandbox --session <project>`). A native wt.exe can't exec the .ps1 by
# bare name, so we drive it through powershell -File.
#
# Windows Terminal is REQUIRED (user directive / Decision #19): there is NO silent
# degradation to a bare PowerShell console. If wt.exe is not installed we FAIL
# LOUDLY — suspend the TUI, print a clear, actionable error, wait for a keypress,
# and return to the dashboard. find_wt asserts availability (PATH + the canonical
# %LOCALAPPDATA%\Microsoft\WindowsApps app-execution-alias location).
sub _spawn_session {
    my @inner = ('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                 '-File', $SANDBOX_PS1, '--session', $PROJECT_PATH);

    my $wt = Dashboard::find_wt($ENV{PATH}, $ENV{LOCALAPPDATA});
    if (!$wt) {
        # Fail loudly: leave the alt-screen, say exactly what's missing + how to
        # fix it, block for a key, then restore the dashboard.
        print STDOUT "\e[?25h\e[?1049l";
        eval { Term::ReadKey::ReadMode('restore') };
        print STDERR "\n";
        print STDERR "  ", _c_err("ERROR:"), " Windows Terminal (wt.exe) was not found.\n";
        print STDERR "  [c] launch-claude opens a NEW Windows Terminal window and requires it —\n";
        print STDERR "  there is no fallback to a plain console (by design).\n";
        print STDERR "  Fix: install \"Windows Terminal\" from the Microsoft Store, or put wt.exe on\n";
        print STDERR "  PATH, then press [c] again.\n";
        print STDERR "  (Searched PATH and %LOCALAPPDATA%\\Microsoft\\WindowsApps.)\n";
        print STDERR "\n  Press any key to return to the dashboard...";
        eval { Term::ReadKey::ReadKey(0) };       # block for a key
        eval { Term::ReadKey::ReadMode('cbreak') };
        print STDOUT "\e[?1049h\e[?25l";
        log_ev('launch_session_failed', { reason => 'wt-not-found' });
        return 'redraw';
    }

    my $argv = Dashboard::spawn_argv('wt', { cmd => \@inner });   # ['wt.exe','-w','new',…]
    log_ev('launch_session', { mode => 'wt' });
    my $rc = system(@$argv);   # returns immediately (detached window)
    log_ev('launch_session_done', { mode => 'wt', exit => ($rc >> 8) });
    return;
}

# plain_heartbeat_loop — the non-TTY fallback: the original scrolling manager
# loop, preserved verbatim in behavior. Touch every 2 min; exit cleanly when
# the container goes away.
sub plain_heartbeat_loop {
    print "\n";
    print "=" x 60 . "\n";
    print "Sandbox ready: $CONTAINER_NAME\n";
    print "=" x 60 . "\n";
    print "This terminal is the manager — keep it open. Closing it stops\n";
    print "the sandbox (~5 minutes after the last heartbeat).\n";
    print "Press Ctrl+C to stop now.\n";
    print "\n";

    my $BEAT_INTERVAL = 120;  # Container's HB is 300 (5 min); 120s gives 2.5x margin.
    while (1) {
        sleep $BEAT_INTERVAL;
        my $hb = _heartbeat_once();
        if ($hb eq 'gone') {
            print STDERR "\n";
            print STDERR "Container $CONTAINER_NAME is no longer running.\n";
            print STDERR "Manager exiting.\n";
            reset_terminal();
            exit 0;
        }
        if ($hb eq 'fail') {
            printf STDERR "[%s] WARNING: heartbeat refresh failed; will retry next tick\n",
                strftime("%H:%M:%S", localtime);
            next;
        }
        printf "[%s] heartbeat\n", strftime("%H:%M:%S", localtime);
    }
}
